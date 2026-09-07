import Foundation
import ImageIO
import CoreGraphics
import CryptoKit

func decoded(_ path: String) throws -> (CGImage, [UInt8]) {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(domain: "decode", code: 1)
    }
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let ok = pixels.withUnsafeMutableBytes { bytes -> Bool in
        guard let context = CGContext(data: bytes.baseAddress, width: image.width,
            height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    guard ok else { throw NSError(domain: "decode", code: 2) }
    return (image, pixels)
}
var records = [[String: Any]]()
var previous: [UInt8]?
for path in CommandLine.arguments.dropFirst() {
    let (img, pixels) = try decoded(path)
    var record: [String: Any] = ["path": path, "width": img.width, "height": img.height,
        "pixelSHA256": SHA256.hash(data: Data(pixels)).map { String(format: "%02x", $0) }.joined()]
    if let old = previous {
        record["equalsPreviousPixels"] = old == pixels
        if old.count == pixels.count {
            record["maxChannelDifference"] = zip(old, pixels).map { abs(Int($0) - Int($1)) }.max()!
        }
    }
    previous = pixels
    records.append(record)
}
print(String(data: try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
