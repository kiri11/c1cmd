import Foundation
import CaptureOneCore

struct ExifReaderTests {
    static func run() {
        print("Running ExifReaderTests...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = GeometryFake(directory: directory)
        let core = SessionController(executor: fake, appInstance: { fake.base.generation }, databaseIdentity: { _ in "db-1" },
                                     imageDimensions: { _ in [6000, 4000] })
        FileManager.default.createFile(atPath: fake.base.parent, contents: Data("raw".utf8))
        let output = directory.appendingPathComponent("exif.json"), argumentLog = directory.appendingPathComponent("args.txt")
        let tool = directory.appendingPathComponent("exiftool")
        try! "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(argumentLog.path)'\ncat '\(output.path)'\n".write(to: tool, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        func exif(_ tags: [String: Any], orientation: Int = 0, flip: String = "none") throws -> ExifResult {
            var record = fake.record("1"); record["orientationDegrees"] = orientation; record["flipName"] = flip
            fake.records["1"] = record
            var row = tags; row["SourceFile"] = fake.base.parent
            try JSONSerialization.data(withJSONObject: [row]).write(to: output)
            return try ExifReader.read(core.get(ref: "1"), executable: tool.path)
        }

        XCTAssertNoThrowBlock {
            let level = try exif(["Make": "Canon", "LensModel": "RF50mm F1.2 L USM", "FocalLength35efl": 50.0041731104415,
                                  "ExposureCompensation": -0.3, "Orientation": 1, "RollAngle": 7.1, "PitchAngle": 0.8])
            XCTAssertEqual(level, ExifResult(id: "1", workingRef: nil, levelRotation: 7.1, pitchAngle: 0.8, focalLength35mm: 50.0),
                           "Clockwise camera roll levels with a clockwise Capture One rotation; other tags are not reported")
            let arguments = try String(contentsOf: argumentLog).split(separator: "\n").map(String.init)
            XCTAssertEqual(arguments.last, fake.base.parent)
            XCTAssertFalse(arguments.dropLast().contains { $0.contains("=") || $0.hasPrefix("-overwrite") || !$0.hasPrefix("-") },
                           "exiftool receives only read options and the original path")

            let vertical = try exif(["Orientation": 6, "RollAngle": 93.9, "PitchAngle": -7], orientation: 90)
            XCTAssertEqual(vertical.levelRotation, 3.9, "A vertical frame's roll is measured from its orientation")
            let reoriented = try exif(["Orientation": 6, "RollAngle": 93.9], orientation: 0)
            XCTAssertNil(reoriented.levelRotation, "Capture One's orientation, not EXIF's, sets the level frame; more than 45 degrees off level has no hint")
            let upsideDown = try exif(["Orientation": 3, "RollAngle": -178.5], orientation: 180)
            XCTAssertEqual(upsideDown.levelRotation, 1.5, "Roll wraps across ±180 degrees")
            let flipped = try exif(["Orientation": 1, "RollAngle": 2.0], flip: "horizontal")
            XCTAssertNil(flipped.levelRotation)
            let recorded = try exif(["FocalLengthIn35mmFormat": 28, "FocalLength35efl": 27.9])
            XCTAssertEqual(recorded.focalLength35mm, 28, "A recorded 35 mm focal length is preferred over exiftool's estimate")

            // Without native geometry, EXIF orientation sets the level frame.
            let unreadable = SessionController(executor: fake, appInstance: { fake.base.generation }, databaseIdentity: { _ in "db-1" }, imageDimensions: { _ in nil })
            _ = try exif(["Orientation": 6, "RollAngle": 93.9], orientation: 0)
            let fallback = try ExifReader.read(unreadable.get(ref: "1"), executable: tool.path)
            XCTAssertEqual(fallback.levelRotation, 3.9)
            _ = try exif(["Orientation": 2, "RollAngle": 1.0])
            let mirrored = try ExifReader.read(unreadable.get(ref: "1"), executable: tool.path)
            XCTAssertNil(mirrored.levelRotation, "A mirrored EXIF orientation has no level frame")

            let unrecorded = try exif(["Make": "SONY", "Orientation": 6], orientation: 90)
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(unrecorded)) as! [String: Any]
            XCTAssertEqual(json.keys.sorted(), ["id"], "Unrecorded values are omitted, not null")
        }

        XCTAssertThrowsError(try ExifReader.read(core.get(ref: "1"), executable: nil)) {
            XCTAssertEqual(($0 as? C1Error)?.errorCode, "dependency-missing")
        }
        try! JSONSerialization.data(withJSONObject: [["SourceFile": fake.base.parent, "Error": "File format error"]]).write(to: output)
        XCTAssertThrowsError(try ExifReader.read(core.get(ref: "1"), executable: tool.path)) {
            XCTAssertEqual(($0 as? C1Error)?.errorCode, "script-error")
        }
        try! FileManager.default.removeItem(atPath: fake.base.parent)
        XCTAssertThrowsError(try ExifReader.read(core.get(ref: "1"), executable: tool.path)) {
            XCTAssertEqual(($0 as? C1Error)?.errorCode, "invalid-request", "An offline original is reported before exiftool runs")
        }

        XCTAssertEqual(ExifReader.locate(["C1_EXIFTOOL": tool.path]), tool.path)
        XCTAssertNil(ExifReader.locate(["C1_EXIFTOOL": argumentLog.path]), "A non-executable override is not replaced by PATH")
        XCTAssertEqual(ExifReader.locate(["PATH": "/nonexistent:\(directory.path)"]), tool.path)
    }
}
