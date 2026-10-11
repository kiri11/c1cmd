import Foundation
import ImageIO
import CoreGraphics
import CryptoKit

public struct PreviewResult: Codable, Equatable {
    public var contextSourceRef: String? = nil
    public var geometry: Geometry? = nil
    public var geometryStateHash: String? = nil
    /// Full-frame only: the source variant's crop in this preview's pixels.
    public var currentCrop: PreviewRect? = nil
    /// Full-frame only: the requested candidate anchors.
    public var candidateCrops: [CandidateCrop]? = nil
    static let candidateUsage = "anchors (1–\(maximumCandidates)) and aspectRatio go together and require fullFrame."
    static let maximumCandidates = 9
    public let operationId: String
    public let workingRef: String?
    public let previewPath: String
    public let fileSizeBytes: Int64
    public let width: Int
    public let height: Int
    /// The requested long edge in pixels; the readback confirmed the output matches it.
    public let size: Int
    public let stateHash: String?
    public let nativeVariantId: String?
    public let pixelSha256: String

    public init(
        operationId: String,
        workingRef: String?,
        previewPath: String,
        fileSizeBytes: Int64,
        width: Int,
        height: Int,
        size: Int,
        pixelSha256: String,
        stateHash: String? = nil,
        nativeVariantId: String? = nil,
        geometry: Geometry? = nil,
        geometryStateHash: String? = nil
    ) {
        self.geometry = geometry; self.geometryStateHash = geometryStateHash
        self.stateHash = stateHash
        self.nativeVariantId = nativeVariantId
        self.operationId = operationId
        self.workingRef = workingRef
        self.previewPath = previewPath
        self.fileSizeBytes = fileSizeBytes
        self.width = width
        self.height = height
        self.size = size
        self.pixelSha256 = pixelSha256
    }
}

/// Preview pixels with a top-left origin, as image tools address them, to a tenth of a
/// pixel. A crop larger than the rendered context extends past the preview edges.
public struct PreviewRect: Codable, Equatable {
    public let left: Double
    public let top: Double
    public let width: Double
    public let height: Double

    /// Maps a canvas `crop` into a preview that renders the canvas rectangle `context`
    /// at `width` × `height` pixels.
    public init(_ crop: CropRect, context: CropRect, width: Int, height: Int) {
        let scaleX = Double(width) / context.width, scaleY = Double(height) / context.height
        func tenth(_ value: Double) -> Double { (value * 10).rounded() / 10 }
        left = tenth((crop.centerX - crop.width/2 - (context.centerX - context.width/2)) * scaleX)
        top = tenth((context.centerY + context.height/2 - (crop.centerY + crop.height/2)) * scaleY)
        self.width = tenth(crop.width * scaleX)
        self.height = tenth(crop.height * scaleY)
    }
}

public struct CandidateCrop: Codable, Equatable {
    public let anchor: CropAnchor
    /// The canvas crop a `geometry_set` dry run returns for this anchor and aspectRatio at the current rotation.
    public let crop: CropRect
    public let preview: PreviewRect
}

/// A preview's long edge in pixels. Each size exports through its own reserved
/// Capture One recipe, so a fixed set bounds the recipes c1 adds to a document.
public struct PreviewSize: Equatable {
    public static let allowed = [400, 800, 1200, 1500]
    public static let standard = try! PreviewSize(1500)
    public static let usage = "Preview size must be one of \(allowed.map(String.init).joined(separator: ", ")) (long-edge pixels)."
    public let longEdge: Int

    public init(_ longEdge: Int) throws {
        guard Self.allowed.contains(longEdge) else { throw C1Error.invalidRequest(Self.usage) }
        self.longEdge = longEdge
    }

    /// The standard size keeps the original recipe name, so documents reuse their existing recipe.
    public var recipeName: String { self == .standard ? "c1-preview" : "c1-preview-\(longEdge)" }
}

public final class PreviewManager {
    public static let shared = PreviewManager()
    /// Long enough for the slow exports seen in batches, where a JPEG landed about 90 s after dispatch.
    public static let defaultTimeout: TimeInterval = 120
    public static let maximumTimeout: TimeInterval = 300

    /// Whether a `width` × `height` image renders a crop of `ratio` within the readback tolerance.
    static func matchesCrop(width: Int, height: Int, ratio: Double) -> Bool {
        abs(Double(width) - Double(height) * ratio) <= max(2, ratio * 2)
    }

    private init() {}

    public func verifyAndDecodeImage(atPath path: String) throws -> (width: Int, height: Int, pixelSha256: String) {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw C1Error.readbackMismatch("Failed to decode exported preview image with ImageIO at '\(path)'.")
        }

        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        let ok = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard ok else {
            throw C1Error.readbackMismatch("Failed to render preview image into sRGB buffer.")
        }

        let digest = SHA256.hash(data: Data(pixels))
        let hashStr = digest.map { String(format: "%02x", $0) }.joined()
        return (width, height, hashStr)
    }

    public func pollForOutputFile(inDirectory dir: URL, timeout: TimeInterval = defaultTimeout) throws -> URL {
        try PerformanceTrace.measure("preview_poll", handler: "PreviewManager.pollForOutputFile") { try poll(dir, timeout: timeout) }
    }

    private func poll(_ dir: URL, timeout: TimeInterval) throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        let fm = FileManager.default
        var previous: [String: Int64] = [:]
        var stable: [String: Int] = [:]

        while Date() < deadline {
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles) {
                for file in files {
                    if file.pathExtension.lowercased() == "jpg" || file.pathExtension.lowercased() == "jpeg" {
                        let attrs = try? fm.attributesOfItem(atPath: file.path)
                        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                        if size > 0, previous[file.path] == size {
                            stable[file.path, default: 0] += 1
                            if stable[file.path, default: 0] >= 2,
                               let data = try? Data(contentsOf: file), data.suffix(2) == Data([0xff, 0xd9]),
                               (try? verifyAndDecodeImage(atPath: file.path)) != nil { return file }
                        } else { stable[file.path] = 0 }
                        previous[file.path] = size
                    }
                }
            }
            usleep(200_000) // 200ms
        }
        throw C1Error.timeout("Preview export timed out waiting for output file in '\(dir.path)'.")
    }
}
