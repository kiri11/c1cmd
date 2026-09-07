import Foundation
import AppleScriptBridge
import Carbon

public struct AppAndDocInfoResult: Codable, Equatable {
    public let appVersion: String
    public let hasDocument: Bool
    public let docName: String?
    public let docPath: String?
    public let docId: String?
    public let isSession: Bool
}

public struct VariantSummaryRecord: Codable, Equatable {
    public let variantId: String
    public let variantName: String
    public let parentImagePath: String
    public let isSelected: Bool
    public let starRating: Int
    public let colorTagVal: Int
}

public struct CloneVariantResult: Codable, Equatable {
    public let cloneId: String
}

public struct DeleteVariantResult: Codable, Equatable {
    public let deleted: Bool
    public let existsNow: Bool
}

public struct AdjustmentBatchItemRecord: Codable, Equatable {
    public let variantId: String
    public let exposureVal: Double
    public let contrastVal: Double
    public let saturationVal: Double
    public let temperatureVal: Double
    public let tintVal: Double
    public let cameraVal: String?
    public let lensVal: String?
    public let isoVal: String?
    public let shutterSpeedVal: String?
    public let asShotWBVal: String?
    public let captureDateVal: String?
    public let starRating: Int
    public let colorTagVal: Int
}

public struct ApplyAdjustmentsResult: Codable, Equatable {
    public let variantId: String
    public let beforeExposureVal: Double
    public let beforeContrastVal: Double
    public let beforeSaturationVal: Double
    public let beforeTemperatureVal: Double
    public let beforeTintVal: Double
    public let afterExposureVal: Double
    public let afterContrastVal: Double
    public let afterSaturationVal: Double
    public let afterTemperatureVal: Double
    public let afterTintVal: Double
}

public struct PreviewRecipeResult: Codable, Equatable {
    public let configured: Bool
    public let recipeName: String
}

public struct ProcessPreviewResult: Codable, Equatable {
    public let jobId: String
}

public final class AppleScriptExecutor {
    public static let shared = AppleScriptExecutor()

    private var compiledScript: NSAppleScript?
    private let lock = NSLock()

    private init() {}

    private func loadScriptSource() throws -> String {
        // Try loading from Bundle.module first
        #if SWIFT_PACKAGE
        if let bundleUrl = Bundle.module.url(forResource: "Handlers", withExtension: "applescript"),
           let content = try? String(contentsOf: bundleUrl, encoding: .utf8) {
            return content
        }
        #endif

        // Fallback to relative or current directory paths
        let paths = [
            "Sources/CaptureOneCore/Resources/Handlers.applescript",
            "../Sources/CaptureOneCore/Resources/Handlers.applescript",
            "/Users/kiri11/projects/c1cmd/Sources/CaptureOneCore/Resources/Handlers.applescript"
        ]
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                return content
            }
        }
        throw C1Error.scriptError("Could not locate Handlers.applescript resource.", code: nil)
    }

    private func getCompiledScript() throws -> NSAppleScript {
        lock.lock()
        defer { lock.unlock() }
        if let script = compiledScript {
            return script
        }
        let source = try loadScriptSource()
        guard let script = NSAppleScript(source: source) else {
            throw C1Error.scriptError("Failed to initialize NSAppleScript from source.", code: nil)
        }
        var errorDict: NSDictionary?
        script.compileAndReturnError(&errorDict)
        if let err = errorDict {
            let msg = err[NSAppleScript.errorMessage] as? String ?? "Unknown compile error"
            let num = err[NSAppleScript.errorNumber] as? Int
            throw C1Error.scriptError("Failed to compile Handlers.applescript: \(msg)", code: num)
        }
        self.compiledScript = script
        return script
    }

    public func executeHandler(name: String, args: [NSAppleEventDescriptor]) throws -> NSAppleEventDescriptor {
        let script = try getCompiledScript()

        let parameters = NSAppleEventDescriptor(list: args)
        var psn = ProcessSerialNumber(highLongOfPSN: UInt32(0), lowLongOfPSN: UInt32(kCurrentProcess))
        let target = NSAppleEventDescriptor(
            descriptorType: DescType(typeProcessSerialNumber),
            bytes: &psn,
            length: MemoryLayout<ProcessSerialNumber>.size
        )
        let handlerDesc = NSAppleEventDescriptor(string: name)

        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(handlerDesc, forKeyword: AEKeyword(keyASSubroutineName))
        event.setParam(parameters, forKeyword: AEKeyword(keyDirectObject))

        var errorDict: NSDictionary?
        let result = script.executeAppleEvent(event, error: &errorDict)

        if let err = errorDict {
            let msg = err[NSAppleScript.errorMessage] as? String ?? "Unknown execution error"
            let num = err[NSAppleScript.errorNumber] as? Int
            if num == -1712 {
                throw C1Error.timeout("Capture One Apple Event timed out (-1712): \(msg)")
            }
            if num == -1743 || num == -1744 {
                throw C1Error.permissionDenied("Automation permission denied (-1743): \(msg)")
            }
            if num == -600 || num == -609 {
                throw C1Error.appNotRunning("Capture One is not running (\(num ?? 0)): \(msg)")
            }
            throw C1Error.scriptError(msg, code: num)
        }

        return result
    }

    public func executeAndDecode<T: Decodable>(handler: String, args: [NSAppleEventDescriptor]) throws -> T {
        let descriptor = try executeHandler(name: handler, args: args)
        let decoder = DescriptorDecoder()
        do {
            return try decoder.decode(T.self, from: descriptor)
        } catch {
            throw C1Error.scriptError("Failed to decode handler '\(handler)' result: \(error.localizedDescription) (Descriptor: \(descriptor.description))", code: nil)
        }
    }
}
