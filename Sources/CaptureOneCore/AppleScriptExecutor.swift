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
    public let documentCount: Int?
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

public struct CreateBaselineVariantResult: Codable, Equatable {
    public let baselineId: String
}

public struct DeleteVariantResult: Codable, Equatable {
    public let deleted: Bool
    public let existsNow: Bool
}

public struct AdjustmentBatchItemRecord: Codable, Equatable {
    var geometryRecord: GeometryRecord?
    public var geometryUnavailableReason: String?
    public let variantId: String
    public let parentImagePath: String?
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

public protocol ScriptExecuting {
    func executeAndDecode<T: Decodable>(handler: String, args: [NSAppleEventDescriptor]) throws -> T
}

public final class AppleScriptExecutor: ScriptExecuting {
    public static let shared = AppleScriptExecutor()

    private var compiledScript: NSAppleScript?
    private var compiledNativeScript: NSAppleScript?
    private let lock = NSLock()

    private init() {}

    private func loadScriptSource(includeNative: Bool) throws -> String {
        // Try loading from Bundle.module first
        #if SWIFT_PACKAGE
        if let bundleUrl = Bundle.module.url(forResource: "Handlers", withExtension: "applescript"),
           let content = try? String(contentsOf: bundleUrl, encoding: .utf8) {
            if !includeNative { return content }
            guard let nativeURL = Bundle.module.url(forResource: "NativeEditing", withExtension: "applescript"),
                  let native = try? String(contentsOf: nativeURL, encoding: .utf8),
                  let actionsURL = Bundle.module.url(forResource: "NativeActions", withExtension: "applescript"),
                  let actions = try? String(contentsOf: actionsURL, encoding: .utf8) else {
                throw C1Error.scriptError("Missing native editing resources.", code: nil)
            }
            return content + "\n" + native + "\n" + actions
        }
        #endif

        throw C1Error.scriptError("Could not locate Handlers.applescript resource.", code: nil)
    }

    private func getCompiledScript(includeNative: Bool) throws -> NSAppleScript {
        lock.lock()
        defer { lock.unlock() }
        if let script = includeNative ? compiledNativeScript : compiledScript {
            return script
        }
        let source = try loadScriptSource(includeNative: includeNative)
        guard let script = NSAppleScript(source: source) else {
            throw C1Error.scriptError("Failed to initialize NSAppleScript from source.", code: nil)
        }
        var errorDict: NSDictionary?
        try PerformanceTrace.measure("script_compile", handler: includeNative ? "native" : "base") {
            script.compileAndReturnError(&errorDict)
            if let err = errorDict {
                let msg = err[NSAppleScript.errorMessage] as? String ?? "Unknown compile error"
                let num = err[NSAppleScript.errorNumber] as? Int
                throw C1Error.scriptError("Failed to compile Handlers.applescript: \(msg)", code: num)
            }
        }
        if includeNative { self.compiledNativeScript = script } else { self.compiledScript = script }
        return script
    }

    public func executeHandler(name: String, args: [NSAppleEventDescriptor]) throws -> NSAppleEventDescriptor {
        try PerformanceTrace.measure("handler_total", handler: name) {
            try executeHandlerUnprofiled(name: name, args: args)
        }
    }

    private func executeHandlerUnprofiled(name: String, args: [NSAppleEventDescriptor]) throws -> NSAppleEventDescriptor {
        let script = try PerformanceTrace.measure("script_lookup", handler: name) {
            try getCompiledScript(includeNative: name.hasPrefix("native"))
        }

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
        RequestContext.current?.appleEvent(name, waiting: true)
        defer { RequestContext.current?.appleEvent(nil, waiting: false) }
        return try PerformanceTrace.measure("apple_event", handler: name) {
            let result = script.executeAppleEvent(event, error: &errorDict)

            if let err = errorDict {
                let msg = err[NSAppleScript.errorMessage] as? String ?? "Unknown execution error"
                throw Self.error(msg, number: err[NSAppleScript.errorNumber] as? Int)
            }

            return result
        }
    }

    /// The typed error for a handler's AppleScript error number; -27001...-27004 are raised by the handlers.
    public static func error(_ msg: String, number: Int?) -> C1Error {
        switch number {
        case -27001: return .documentChanged(msg)
        case -27002: return .stateChanged(msg)
        case -27003: return .identityAmbiguous(msg)
        case -27004:
            return .variantNotFound("\(msg) Capture One resolves a variant only through a collection that holds it; make such a collection current and retry.")
        case -1712: return .timeout("Capture One Apple Event timed out (-1712): \(msg)")
        case -1743, -1744: return .permissionDenied("Automation permission denied (-1743): \(msg)")
        case -600, -609: return .appNotRunning("Capture One is not running (\(number!)): \(msg)")
        default: return .scriptError(msg, code: number)
        }
    }

    public func executeAndDecode<T: Decodable>(handler: String, args: [NSAppleEventDescriptor]) throws -> T {
        let descriptor = try executeHandler(name: handler, args: args)
        let decoder = DescriptorDecoder()
        do {
            return try PerformanceTrace.measure("descriptor_decode", handler: handler) {
                try decoder.decode(T.self, from: descriptor)
            }
        } catch {
            throw C1Error.scriptError("Failed to decode handler '\(handler)' result: \(error.localizedDescription) (Descriptor: \(descriptor.description))", code: nil)
        }
    }
}
