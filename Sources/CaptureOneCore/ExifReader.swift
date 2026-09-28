import Foundation

/// Camera level-sensor hints for a variant's original, read with exiftool. Read-only:
/// they never come from Capture One, carry no state token and authorize nothing.
public struct ExifResult: Codable, Equatable {
    public let id: String
    public let workingRef: String?
    /// The `geometry_set` rotation that levels the camera's recorded roll for the variant's
    /// orientation. Absent when roll or orientation is unknown, flipped or more than 45° off level.
    public var levelRotation: Double? = nil
    /// Level-sensor degrees of upward lens tilt.
    public var pitchAngle: Double? = nil
    /// Recorded, or estimated by exiftool from the sensor size, so pitch can be read as convergence.
    public var focalLength35mm: Double? = nil

    public init(id: String, workingRef: String?, levelRotation: Double? = nil, pitchAngle: Double? = nil, focalLength35mm: Double? = nil) {
        self.id = id; self.workingRef = workingRef
        self.levelRotation = levelRotation; self.pitchAngle = pitchAngle; self.focalLength35mm = focalLength35mm
    }
}

public enum ExifReader {
    /// Tags requested from exiftool. `#` selects numeric values. Nothing here assigns a
    /// tag, so exiftool opens the file read-only.
    static let arguments = ["-j", "-fast", "-Orientation#", "-RollAngle#", "-PitchAngle#",
        "-FocalLengthIn35mmFormat#", "-FocalLength35efl#"]
    static let timeout: TimeInterval = 30

    /// `C1_EXIFTOOL`, then `PATH`, then the Homebrew locations a GUI-launched MCP server may lack.
    public static func locate(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let explicit = environment["C1_EXIFTOOL"], !explicit.isEmpty {
            return FileManager.default.isExecutableFile(atPath: explicit) ? explicit : nil
        }
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent("exiftool").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Reads the original behind `get`; `geometry.orientation` sets the level frame when known.
    public static func read(_ source: GetResult, executable: String? = locate()) throws -> ExifResult {
        guard let path = source.parentImagePath, path.hasPrefix("/") else {
            throw C1Error.invalidRequest("Capture One did not report an absolute original path for '\(source.id)'.")
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw C1Error.invalidRequest("The original image is offline or unreadable: \(path)")
        }
        guard let executable else {
            throw C1Error.dependencyMissing("exiftool was not found. Install it (brew install exiftool) or set C1_EXIFTOOL to its path.")
        }
        let tags = try run(executable, path: path)
        let orientation: Int?
        if let geometry = source.geometry {
            orientation = geometry.flip == "none" ? geometry.orientation : nil
        } else {
            orientation = exifDegrees(tags["Orientation"])
        }
        return result(tags, id: source.id, workingRef: source.workingRef, orientation: orientation)
    }

    static func result(_ tags: [String: Any], id: String, workingRef: String?, orientation: Int?) -> ExifResult {
        func number(_ key: String) -> Double? {
            let value = (tags[key] as? NSNumber)?.doubleValue ?? (tags[key] as? String).flatMap(Double.init)
            return value.flatMap { $0.isFinite ? $0 : nil }
        }
        var result = ExifResult(id: id, workingRef: workingRef)
        result.pitchAngle = number("PitchAngle")
        result.focalLength35mm = number("FocalLengthIn35mmFormat").flatMap { $0 > 0 ? $0 : nil } ?? number("FocalLength35efl").map(rounded)
        if let roll = number("RollAngle"), let orientation {
            result.levelRotation = levelRotation(roll: roll, orientation: orientation)
        }
        return result
    }

    /// Positive roll is clockwise camera rotation, which turns the scene counter-clockwise
    /// in the frame; Capture One rotation is positive clockwise, so it levels by `+roll`
    /// once the frame's orientation is removed.
    static func levelRotation(roll: Double, orientation: Int) -> Double? {
        var offset = (roll - Double(orientation)).truncatingRemainder(dividingBy: 360)
        if offset > 180 { offset -= 360 } else if offset <= -180 { offset += 360 }
        return abs(offset) <= Geometry.maximumRotation ? rounded(offset) : nil
    }

    /// EXIF orientation 1/6/3/8 as clockwise display degrees; mirrored values have none.
    static func exifDegrees(_ value: Any?) -> Int? {
        [1: 0, 6: 90, 3: 180, 8: 270][(value as? NSNumber)?.intValue ?? -1]
    }

    static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    static func run(_ executable: String, path: String) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments + [path]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        var stdout = Data(), stderr = Data()
        let drained = DispatchGroup()
        for (pipe, isOutput) in [(output, true), (errors, false)] {
            DispatchQueue.global().async(group: drained) {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if isOutput { stdout = data } else { stderr = data }
            }
        }
        do { try process.run() } catch {
            throw C1Error.dependencyMissing("exiftool could not be started at \(executable): \(error.localizedDescription)")
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw C1Error.timeout("exiftool did not finish within \(Int(timeout)) seconds. It only reads the file; nothing was written.")
        }
        drained.wait()
        let message = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rows = try? JSONSerialization.jsonObject(with: stdout) as? [[String: Any]], let tags = rows.first else {
            throw C1Error.scriptError("exiftool returned no readable result (exit \(process.terminationStatus)). \(message)", code: nil)
        }
        if let error = tags["Error"] as? String { throw C1Error.scriptError("exiftool: \(error)", code: nil) }
        return tags
    }
}
