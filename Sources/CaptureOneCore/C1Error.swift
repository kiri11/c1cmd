import Foundation

public enum C1Error: Error, CustomStringConvertible, Codable, Equatable {
    case appNotRunning(String)
    case noDocument(String)
    case permissionDenied(String)
    case variantNotFound(String)
    case unmanagedVariant(String)
    case identityAmbiguous(String)
    case unsupportedVersion(String)
    case unsupportedField(String)
    case invalidRequest(String)
    case captureOneBusy(String)
    case documentChanged(String)
    case stateChanged(String)
    case readbackMismatch(String)
    case partialFailure(String)
    case outcomeUnknown(String)
    case timeout(String)
    case scriptError(String, code: Int?)

    public var errorCode: String {
        switch self {
        case .appNotRunning: return "app-not-running"
        case .noDocument: return "no-document"
        case .permissionDenied: return "permission-denied"
        case .variantNotFound: return "variant-not-found"
        case .unmanagedVariant: return "unmanaged-variant"
        case .identityAmbiguous: return "identity-ambiguous"
        case .unsupportedVersion: return "unsupported-version"
        case .unsupportedField: return "unsupported-field"
        case .invalidRequest: return "invalid-request"
        case .captureOneBusy: return "capture-one-busy"
        case .documentChanged: return "document-changed"
        case .stateChanged: return "state-changed"
        case .readbackMismatch: return "readback-mismatch"
        case .partialFailure: return "partial-failure"
        case .outcomeUnknown: return "outcome-unknown"
        case .timeout: return "timeout"
        case .scriptError: return "script-error"
        }
    }

    public var exitCode: Int32 {
        switch self {
        case .invalidRequest, .unmanagedVariant, .variantNotFound, .unsupportedField, .scriptError, .identityAmbiguous:
            return 1
        case .captureOneBusy:
            return 2
        case .documentChanged, .stateChanged:
            return 3
        case .partialFailure, .outcomeUnknown, .readbackMismatch, .timeout:
            return 4
        case .appNotRunning, .noDocument, .permissionDenied, .unsupportedVersion:
            return 5
        }
    }

    public var description: String {
        switch self {
        case .appNotRunning(let msg): return "app-not-running: \(msg)"
        case .noDocument(let msg): return "no-document: \(msg)"
        case .permissionDenied(let msg): return "permission-denied: \(msg)"
        case .variantNotFound(let msg): return "variant-not-found: \(msg)"
        case .unmanagedVariant(let msg): return "unmanaged-variant: \(msg)"
        case .identityAmbiguous(let msg): return "identity-ambiguous: \(msg)"
        case .unsupportedVersion(let msg): return "unsupported-version: \(msg)"
        case .unsupportedField(let msg): return "unsupported-field: \(msg)"
        case .invalidRequest(let msg): return "invalid-request: \(msg)"
        case .captureOneBusy(let msg): return "capture-one-busy: \(msg)"
        case .documentChanged(let msg): return "document-changed: \(msg)"
        case .stateChanged(let msg): return "state-changed: \(msg)"
        case .readbackMismatch(let msg): return "readback-mismatch: \(msg)"
        case .partialFailure(let msg): return "partial-failure: \(msg)"
        case .outcomeUnknown(let msg): return "outcome-unknown: \(msg)"
        case .timeout(let msg): return "timeout: \(msg)"
        case .scriptError(let msg, let code):
            if let c = code {
                return "script-error (\(c)): \(msg)"
            } else {
                return "script-error: \(msg)"
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case scriptErrorCode
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(errorCode, forKey: .code)
        switch self {
        case .appNotRunning(let msg), .noDocument(let msg), .permissionDenied(let msg),
             .variantNotFound(let msg), .unmanagedVariant(let msg), .identityAmbiguous(let msg),
             .unsupportedVersion(let msg), .unsupportedField(let msg), .invalidRequest(let msg),
             .captureOneBusy(let msg), .documentChanged(let msg), .stateChanged(let msg),
             .readbackMismatch(let msg), .partialFailure(let msg), .outcomeUnknown(let msg),
             .timeout(let msg):
            try container.encode(msg, forKey: .message)
        case .scriptError(let msg, let code):
            try container.encode(msg, forKey: .message)
            try container.encodeIfPresent(code, forKey: .scriptErrorCode)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(String.self, forKey: .code)
        let msg = try container.decode(String.self, forKey: .message)
        let sCode = try container.decodeIfPresent(Int.self, forKey: .scriptErrorCode)
        switch code {
        case "app-not-running": self = .appNotRunning(msg)
        case "no-document": self = .noDocument(msg)
        case "permission-denied": self = .permissionDenied(msg)
        case "variant-not-found": self = .variantNotFound(msg)
        case "unmanaged-variant": self = .unmanagedVariant(msg)
        case "identity-ambiguous": self = .identityAmbiguous(msg)
        case "unsupported-version": self = .unsupportedVersion(msg)
        case "unsupported-field": self = .unsupportedField(msg)
        case "invalid-request": self = .invalidRequest(msg)
        case "capture-one-busy": self = .captureOneBusy(msg)
        case "document-changed": self = .documentChanged(msg)
        case "state-changed": self = .stateChanged(msg)
        case "readback-mismatch": self = .readbackMismatch(msg)
        case "partial-failure": self = .partialFailure(msg)
        case "outcome-unknown": self = .outcomeUnknown(msg)
        case "timeout": self = .timeout(msg)
        case "script-error": self = .scriptError(msg, code: sCode)
        default: self = .invalidRequest(msg)
        }
    }
}
