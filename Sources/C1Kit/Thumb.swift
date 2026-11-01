import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ThumbArguments: Decodable {
    public var id: VariantID
    public var maxSize: Int?
    public init(id: VariantID, maxSize: Int? = nil) { self.id = id; self.maxSize = maxSize }
}

extension Service {
    static let thumbSizes = 200...8192
    static let thumbLimitation = "The camera's embedded JPEG, or a JPEG original itself: no Capture One adjustments, crop or rotation. Use preview to see edits."

    /// The camera's own rendering of a variant's original, read through ImageIO from SQLite's path; no Apple Events.
    public func thumb(_ arguments: ThumbArguments, document: String? = nil) throws -> JSONValue {
        let maxSize = arguments.maxSize ?? Preview.defaultSize
        guard Self.thumbSizes.contains(maxSize) else {
            throw C1Failure(.invalidArguments, "maxSize must be \(Self.thumbSizes.lowerBound)–\(Self.thumbSizes.upperBound) px, got \(maxSize).")
        }
        let database = try self.database(document)
        guard let original = try database.originals([arguments.id])[arguments.id] else {
            throw C1Failure(.notFound, "The database has no variant \(arguments.id); a new variant can take up to a minute to appear.")
        }
        guard let path = original.path, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }) else {
            throw C1Failure(.notFound, "The original of variant \(arguments.id) is not readable at \(original.path ?? "an unresolved location").",
                            hint: "Its volume may be offline.")
        }
        // A RAW's embedded thumbnail is the camera's full-size JPEG on the cameras measured; decoding the RAW itself
        // would be Apple's rendering and about 4 s. A JPEG's embedded thumbnail is 160 px, so the file itself is read.
        let raw = type.conforms(to: .rawImage)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxSize,
                                        raw ? kCGImageSourceCreateThumbnailFromImageIfAbsent : kCGImageSourceCreateThumbnailFromImageAlways: !raw]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw C1Failure(.scriptError, raw ? "The RAW at \(path) has no embedded JPEG that ImageIO can read; use preview." : "ImageIO cannot decode \(path).")
        }
        let file = previewsRoot.appendingPathComponent(database.documentUUID).appendingPathComponent("thumb-\(arguments.id)-\(maxSize).jpg")
        Preview.prune(previewsRoot, now: now())
        try Images.writeJPEG(image, to: file, quality: 0.85)
        return .object(["id": .string(arguments.id.description), "path": .string(file.path),
                        "width": .int(Int64(image.width)), "height": .int(Int64(image.height)),
                        "source": .string(raw ? "embedded" : "file"), "limitation": .string(Self.thumbLimitation)])
    }
}
