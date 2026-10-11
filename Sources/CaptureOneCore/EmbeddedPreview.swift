import Foundation
import ImageIO
import CoreImage
import CryptoKit
import UniformTypeIdentifiers

/// The camera's own JPEG embedded in a variant's original, for fast visual triage. Read-only:
/// it never comes from Capture One, carries no state token and authorizes nothing.
public struct ThumbResult: Encodable, Equatable {
    public static let limitation = "The camera's embedded JPEG: no Capture One adjustments, crop or rotation. A triage aid, never review evidence for an edit; review edits with preview."
    public let id: String
    public let workingRef: String?
    public let thumbPath: String
    public let width: Int
    public let height: Int
    /// The exiftool tag the JPEG came from: `JpgFromRaw` or `PreviewImage`.
    public let embeddedTag: String
    /// The original's EXIF orientation (1–8) applied to the pixels; 1 when unrecorded.
    public let exifOrientation: Int
    public let cameraRendering: Bool
    public let limitation: String
}

public enum EmbeddedPreview {
    static let tags = ["JpgFromRaw", "PreviewImage"]
    /// With `-j`, `-b` returns binary tags as `base64:` strings. Nothing here assigns a tag,
    /// so exiftool opens the file read-only.
    static let arguments = ["-j", "-b", "-Orientation#"] + tags.map { "-" + $0 }
    static let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// Beside request status in c1's cache rather than the document: the file depends only on
    /// the original, and writing near a read-only document would be a write the photographer did not enable.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/c1/thumbs", isDirectory: true)
    }

    /// Extracts the largest embedded JPEG from the original behind `get`, turns its pixels to the
    /// EXIF orientation, fits its long edge within `maxSize` without enlarging, and replaces the
    /// original's file in `directory`.
    public static func extract(_ source: GetResult, maxSize: Int? = nil, directory: URL = defaultDirectory,
                               executable: String? = ExifReader.locate()) throws -> ThumbResult {
        let (path, executable) = try ExifReader.original(source, executable: executable)
        let values = try ExifReader.run(executable, arguments: arguments, path: path)
        let candidates = tags.compactMap { tag -> (tag: String, image: CGImageSource, width: Int, height: Int)? in
            guard let text = values[tag] as? String, text.hasPrefix("base64:"),
                  let data = Data(base64Encoded: String(text.dropFirst(7))),
                  let image = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return (tag, image, width, height)
        }
        guard let largest = candidates.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            throw C1Error.invalidRequest("The original has no decodable embedded JPEG (\(tags.joined(separator: " or "))): \(path). Use preview for a Capture One rendering.")
        }
        let orientation = (values["Orientation"] as? NSNumber).map(\.intValue).flatMap { (1...8).contains($0) ? $0 : nil } ?? 1
        // ImageIO thumbnails never enlarge, so a maxSize above the long edge keeps the full size.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: false,
                                        kCGImageSourceThumbnailMaxPixelSize: maxSize ?? max(largest.width, largest.height)]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(largest.image, 0, options as CFDictionary) else {
            throw C1Error.invalidRequest("The embedded \(largest.tag) in \(path) could not be decoded.")
        }
        let oriented = CIImage(cgImage: decoded).oriented(CGImagePropertyOrientation(rawValue: UInt32(orientation))!)
        let space = decoded.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let pixels = context.createCGImage(oriented, from: oriented.extent, format: .RGBA8, colorSpace: space) else {
            throw C1Error.invalidRequest("The embedded \(largest.tag) in \(path) could not be oriented.")
        }
        let jpeg = NSMutableData()
        let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, pixels, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw C1Error.invalidRequest("The embedded \(largest.tag) in \(path) could not be encoded.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(fileName(original: path, maxSize: maxSize))
        try (jpeg as Data).write(to: file, options: .atomic)
        return ThumbResult(id: source.id, workingRef: source.workingRef, thumbPath: file.path, width: pixels.width, height: pixels.height,
                           embeddedTag: largest.tag, exifOrientation: orientation, cameraRendering: true, limitation: ThumbResult.limitation)
    }

    /// One file per original and size, so repeated triage replaces files instead of accumulating them.
    static func fileName(original path: String, maxSize: Int?) -> String {
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return "\(stem)-\(digest)" + (maxSize.map { "-\($0)" } ?? "") + ".jpg"
    }
}
