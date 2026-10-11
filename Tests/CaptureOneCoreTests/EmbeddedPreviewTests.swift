import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import CaptureOneCore

struct EmbeddedPreviewTests {
    enum Corner: String { case topLeft, topRight, bottomLeft, bottomRight }

    /// A JPEG whose stored top-left quadrant is red and the rest blue, so every EXIF
    /// orientation lands that quadrant in a distinct corner or frame shape.
    static func marker(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height - height / 2))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// The corner whose quadrant is red in the image as displayed.
    static func redCorner(_ path: String) -> Corner? {
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!, 0, nil)!
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                .draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        func red(_ x: Int, _ y: Int) -> Bool { let i = (y * width + x) * 4; return pixels[i] > 200 && pixels[i + 2] < 80 }
        let corners: [(Corner, Int, Int)] = [(.topLeft, width / 4, height / 4), (.topRight, 3 * width / 4, height / 4),
                                             (.bottomLeft, width / 4, 3 * height / 4), (.bottomRight, 3 * width / 4, 3 * height / 4)]
        let found = corners.filter { red($0.1, $0.2) }
        return found.count == 1 ? found[0].0 : nil
    }

    static func run() {
        print("Running EmbeddedPreviewTests...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = GeometryFake(directory: directory)
        let core = SessionController(executor: fake, appInstance: { fake.base.generation }, databaseIdentity: { _ in "db-1" },
                                     imageDimensions: { _ in [6000, 4000] })
        FileManager.default.createFile(atPath: fake.base.parent, contents: Data("raw".utf8))
        let output = directory.appendingPathComponent("exif.json"), argumentLog = directory.appendingPathComponent("args.txt")
        let tool = directory.appendingPathComponent("exiftool"), cache = directory.appendingPathComponent("thumbs")
        try! "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(argumentLog.path)'\ncat '\(output.path)'\n".write(to: tool, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        func thumb(_ tags: [String: Any], maxSize: Int? = nil, executable: String? = tool.path) throws -> ThumbResult {
            var row = tags; row["SourceFile"] = fake.base.parent
            try JSONSerialization.data(withJSONObject: [row]).write(to: output)
            return try EmbeddedPreview.extract(core.get(ref: "1"), maxSize: maxSize, directory: cache, executable: executable)
        }
        let wide = "base64:" + marker(width: 120, height: 60).base64EncodedString()

        XCTAssertNoThrowBlock {
            let plain = try thumb(["Orientation": 1, "JpgFromRaw": wide])
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as! NSDictionary
            XCTAssertEqual(json, ["id": "1", "thumbPath": plain.thumbPath, "width": 120, "height": 60, "embeddedTag": "JpgFromRaw",
                                  "exifOrientation": 1, "cameraRendering": true, "limitation": ThumbResult.limitation] as NSDictionary,
                           "An unrecorded workingRef is omitted, not null")
            XCTAssertTrue(ThumbResult.limitation.contains("no Capture One adjustments, crop or rotation") && ThumbResult.limitation.contains("never review evidence"),
                          "The result states it is the camera's rendering and not review evidence")
            let arguments = try String(contentsOf: argumentLog).split(separator: "\n").map(String.init)
            XCTAssertEqual(arguments.last, fake.base.parent)
            XCTAssertTrue(arguments.contains("-b") && arguments.contains("-JpgFromRaw") && arguments.contains("-PreviewImage"))
            XCTAssertFalse(arguments.dropLast().contains { $0.contains("=") || $0.hasPrefix("-overwrite") || !$0.hasPrefix("-") },
                           "exiftool receives only read options and the original path")
            XCTAssertEqual(ToolResponse.thumb(plain).imagePath, plain.thumbPath, "MCP attaches the thumb as it does a preview")

            let expected: [Int: Corner] = [1: .topLeft, 2: .topRight, 3: .bottomRight, 4: .bottomLeft,
                                           5: .topLeft, 6: .topRight, 7: .bottomRight, 8: .bottomLeft]
            for orientation in 1...8 {
                let result = try thumb(["Orientation": orientation, "JpgFromRaw": wide])
                let transposed = orientation >= 5
                XCTAssertEqual([result.width, result.height], transposed ? [60, 120] : [120, 60], "orientation \(orientation) frame")
                XCTAssertEqual(result.exifOrientation, orientation)
                XCTAssertEqual(redCorner(result.thumbPath), expected[orientation], "orientation \(orientation) turns the stored top-left to \(expected[orientation]!)")
            }
            for unusable in [nil, 0, 9] as [Int?] {
                var tags: [String: Any] = ["JpgFromRaw": wide]; tags["Orientation"] = unusable
                let result = try thumb(tags)
                XCTAssertEqual([result.width, result.height, result.exifOrientation], [120, 60, 1], "orientation \(String(describing: unusable)) is left as stored")
                XCTAssertEqual(redCorner(result.thumbPath), .topLeft)
            }

            let small = try thumb(["Orientation": 6, "JpgFromRaw": wide], maxSize: 30)
            XCTAssertEqual([small.width, small.height], [15, 30], "maxSize fits the long edge after orientation")
            XCTAssertEqual(redCorner(small.thumbPath), .topRight)
            let unenlarged = try thumb(["Orientation": 1, "JpgFromRaw": wide], maxSize: 1000)
            XCTAssertEqual([unenlarged.width, unenlarged.height], [120, 60], "maxSize never enlarges")

            let preview = "base64:" + marker(width: 160, height: 80).base64EncodedString()
            let larger = try thumb(["JpgFromRaw": wide, "PreviewImage": preview])
            XCTAssertEqual(larger.embeddedTag, "PreviewImage", "The largest embedded JPEG wins, whichever tag holds it")
            let tiny = "base64:" + marker(width: 40, height: 20).base64EncodedString()
            let largest = try thumb(["JpgFromRaw": wide, "PreviewImage": tiny])
            XCTAssertEqual([largest.embeddedTag, "\(largest.width)"], ["JpgFromRaw", "120"])
            let corrupt = "base64:" + Data("not a jpeg".utf8).base64EncodedString()
            let skipped = try thumb(["JpgFromRaw": corrupt, "PreviewImage": tiny])
            XCTAssertEqual(skipped.embeddedTag, "PreviewImage", "An undecodable tag is skipped")

            XCTAssertEqual(EmbeddedPreview.defaultDirectory.path,
                           FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/c1/thumbs").path)
            XCTAssertEqual(URL(fileURLWithPath: plain.thumbPath).deletingLastPathComponent().path, cache.path)
            XCTAssertTrue(URL(fileURLWithPath: plain.thumbPath).lastPathComponent.hasPrefix("fixture-"), "The file is named after the original")
            let repeated = try thumb(["JpgFromRaw": wide])
            XCTAssertEqual(repeated.thumbPath, plain.thumbPath, "One file per original replaces the last extraction")
            XCTAssertNotEqual(small.thumbPath, plain.thumbPath, "Each maxSize has its own file")
            let files = try FileManager.default.contentsOfDirectory(atPath: cache.path).sorted()
            XCTAssertEqual(files, [URL(fileURLWithPath: plain.thumbPath).lastPathComponent, URL(fileURLWithPath: unenlarged.thumbPath).lastPathComponent,
                                   URL(fileURLWithPath: small.thumbPath).lastPathComponent].sorted(), "Repeated extraction leaves no other files")
        }

        for tags in [["Orientation": 1], ["JpgFromRaw": "base64:" + Data("not a jpeg".utf8).base64EncodedString()]] as [[String: Any]] {
            XCTAssertThrowsError(try thumb(tags)) {
                XCTAssertEqual(($0 as? C1Error)?.errorCode, "invalid-request")
                XCTAssertTrue("\($0)".contains("no decodable embedded JPEG"), "\($0)")
            }
        }
        try? FileManager.default.removeItem(at: cache)
        XCTAssertThrowsError(try thumb(["JpgFromRaw": wide], executable: nil)) {
            XCTAssertEqual(($0 as? C1Error)?.errorCode, "dependency-missing")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path), "Nothing is written without exiftool")
        try! FileManager.default.removeItem(atPath: fake.base.parent)
        XCTAssertThrowsError(try thumb(["JpgFromRaw": wide])) {
            XCTAssertEqual(($0 as? C1Error)?.errorCode, "invalid-request", "An offline original is reported before exiftool runs")
        }
    }
}
