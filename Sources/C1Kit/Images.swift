import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decoding, cutting, composing and encoding JPEGs. Pixel rectangles have a top-left origin.
enum Images {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A complete JPEG, or nil while it is missing, partial or undecodable.
    static func decodeJPEG(_ url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url), data.count > 4, data.suffix(2) == Data([0xff, 0xd9]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              CGImageSourceGetStatus(source) == .statusComplete else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.9) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw C1Failure(.internal, "Cannot create a JPEG encoder.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw C1Failure(.internal, "Cannot encode \(url.lastPathComponent).") }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (data as Data).write(to: url, options: .atomic)
        } catch {
            throw C1Failure(.internal, "Cannot write \(url.path): \(error.localizedDescription)")
        }
    }

    /// An opaque sRGB canvas drawn with a top-left origin through `draw`.
    final class Canvas {
        let context: CGContext
        let width: Int, height: Int

        init(width: Int, height: Int, background: CGColor) {
            self.width = width; self.height = height
            context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.interpolationQuality = .high
            fill(CGRect(x: 0, y: 0, width: width, height: height), background)
        }

        func flipped(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height) }

        func fill(_ rect: CGRect, _ color: CGColor) {
            context.setFillColor(color)
            context.fill(flipped(rect))
        }

        /// Draws the part `source` of `image` (in its own pixels) into `rect`, to a fraction of a pixel: the whole
        /// image is scaled and clipped, because cropping a CGImage rounds the source out to whole pixels.
        func draw(_ image: CGImage, from source: CGRect? = nil, in rect: CGRect) {
            let source = source ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let sx = rect.width / source.width, sy = rect.height / source.height
            context.saveGState()
            context.clip(to: flipped(rect))
            context.draw(image, in: flipped(CGRect(x: rect.minX - source.minX * sx, y: rect.minY - source.minY * sy,
                                                   width: CGFloat(image.width) * sx, height: CGFloat(image.height) * sy)))
            context.restoreGState()
        }

        /// One line of text, shrunk to fit and truncated with an ellipsis, vertically centred in `rect`.
        func text(_ string: String, in rect: CGRect, size: CGFloat, color: CGColor, centered: Bool = false) {
            func line(_ text: String, _ size: CGFloat) -> (CTLine, CTFont) {
                let font = CTFontCreateUIFontForLanguage(.system, size, nil)!
                let attributes: [NSAttributedString.Key: Any] = [kCTFontAttributeName as NSAttributedString.Key: font,
                                                                 kCTForegroundColorAttributeName as NSAttributedString.Key: color]
                return (CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), font)
            }
            let fitted = max(1, min(size, rect.height * 0.75))
            let (full, font) = line(string, fitted)
            let shown = CTLineCreateTruncatedLine(full, Double(rect.width), .end, line("…", fitted).0) ?? full
            let width = CTLineGetTypographicBounds(shown, nil, nil, nil)
            let box = flipped(rect)
            context.textPosition = CGPoint(x: centered ? box.midX - width / 2 : box.minX,
                                           y: box.midY - (CTFontGetAscent(font) - CTFontGetDescent(font)) / 2)
            CTLineDraw(shown, context)
        }

        func image() -> CGImage { context.makeImage()! }
    }

    static func color(_ red: Int, _ green: Int, _ blue: Int) -> CGColor {
        CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    static let background = color(0x26, 0x26, 0x26)
    static let placeholder = color(0x3a, 0x3a, 0x3a)
    static let amber = color(0xf2, 0xa3, 0x1b)
    static let text = color(0xe0, 0xe0, 0xe0)
    static let dimText = color(0xb3, 0xb3, 0xb3)
    static let darkText = color(0x1a, 0x1a, 0x1a)
}
