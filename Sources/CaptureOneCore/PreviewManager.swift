import Foundation
import ImageIO
import CoreGraphics
import CryptoKit

public struct PreviewResult: Codable, Equatable {
    public let operationId: String
    public let workingRef: String
    public let outputPath: String
    public let fileSizeBytes: Int64
    public let width: Int
    public let height: Int
    public let pixelSha256: String

    public init(
        operationId: String,
        workingRef: String,
        outputPath: String,
        fileSizeBytes: Int64,
        width: Int,
        height: Int,
        pixelSha256: String
    ) {
        self.operationId = operationId
        self.workingRef = workingRef
        self.outputPath = outputPath
        self.fileSizeBytes = fileSizeBytes
        self.width = width
        self.height = height
        self.pixelSha256 = pixelSha256
    }
}

public final class PreviewManager {
    public static let shared = PreviewManager()
    public static let defaultRecipeName = "c1-preview"

    private init() {}

    public func verifyAndDecodeImage(atPath path: String) throws -> (width: Int, height: Int, pixelSha256: String) {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
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

    public func pollForOutputFile(inDirectory dir: URL, timeout: TimeInterval = 30.0) throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        let fm = FileManager.default

        while Date() < deadline {
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles) {
                for file in files {
                    if file.pathExtension.lowercased() == "jpg" || file.pathExtension.lowercased() == "jpeg" {
                        let attrs = try? fm.attributesOfItem(atPath: file.path)
                        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                        if size > 0 {
                            return file
                        }
                    }
                }
            }
            usleep(200_000) // 200ms
        }
        throw C1Error.timeout("Preview export timed out waiting for output file in '\(dir.path)'.")
    }
}
