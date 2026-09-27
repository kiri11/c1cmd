import Foundation
import AppKit

/// File identity is independent of SQLite contents, which change on every edit.
/// Reopening the same database within one app launch is not an observable lifetime boundary.
public enum DocumentIdentity {
    public static func fileIdentity(path: String) throws -> String {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let inode = attrs[.systemFileNumber] as? NSNumber,
              let device = attrs[.systemNumber] as? NSNumber,
              let created = attrs[.creationDate] as? Date else {
            throw C1Error.identityAmbiguous("Cannot establish database file identity: \(path)")
        }
        return "\(url.path)|\(device)|\(inode)|\(created.timeIntervalSince1970)"
    }

    public static func appInstance() throws -> String {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.captureone.captureone16").first,
              let launch = app.launchDate else {
            throw C1Error.appNotRunning("Capture One must be running.")
        }
        return "\(app.processIdentifier):\(launch.timeIntervalSince1970)"
    }

    public static func validate(record: ProvenanceRecord, document: DocumentInfo, parentImagePath: String) throws {
        guard record.documentToken == document.openToken else {
            throw C1Error.documentChanged("Working reference predates this application/database identity. Clone the source again; references are not rebound automatically.")
        }
        guard let expected = record.parentImagePath, !expected.isEmpty,
              URL(fileURLWithPath: expected).resolvingSymlinksInPath() == URL(fileURLWithPath: parentImagePath).resolvingSymlinksInPath() else {
            throw C1Error.identityAmbiguous("Working clone parent image does not match its provenance.")
        }
        guard record.sourceVariantId != record.cloneVariantId else {
            throw C1Error.unmanagedVariant("Provenance identifies the source as its own clone.")
        }
    }
}

public struct OperationFailure: Error, CustomStringConvertible {
    public let operationId: String
    public let cause: Error
    public init(operationId: String, cause: Error) { self.operationId = operationId; self.cause = cause }
    public var description: String { "Operation \(operationId): \(cause). Inspect operation status; do not retry the write." }
}

public struct CompoundFailure: Error, CustomStringConvertible {
    public let compoundId: String
    public let cause: Error
    public let persistenceError: String
    public var description: String { "Compound \(compoundId): \(cause). Report persistence failed: \(persistenceError). Inspect edit_status and linked child operations; do not retry." }
}

/// Requested native IDs that Capture One reported as no such object. The read failed as a whole.
public struct VariantsNotFound: Error, CustomStringConvertible {
    public let missingIds: [String]
    public let outOfScopeIds: [String]
    public let requested: Int
    public init(missingIds: [String], outOfScopeIds: [String], requested: Int) {
        self.missingIds = missingIds; self.outOfScopeIds = outOfScopeIds; self.requested = requested
    }
    public var cause: C1Error { .variantNotFound(summary) }
    public var description: String { cause.description }
    private var summary: String {
        func list(_ ids: [String]) -> String { ids.prefix(20).joined(separator: ", ") + (ids.count > 20 ? " and \(ids.count - 20) more" : "") }
        var parts: [String] = []
        func count(_ ids: [String]) -> String { "\(ids.count) \(ids.count == 1 ? "is" : "are")" }
        if !missingIds.isEmpty { parts.append("\(count(missingIds)) missing from the document (\(list(missingIds)))") }
        if !outOfScopeIds.isEmpty { parts.append("\(count(outOfScopeIds)) outside the requested collection (\(list(outOfScopeIds)))") }
        return "Of \(requested) requested IDs, " + parts.joined(separator: "; ") + ". No results were returned; remove these IDs or widen the scope."
    }
}

public enum ErrorResponse {
    public static func payload(_ error: Error) -> [String: Any] {
        let compound = error as? CompoundFailure
        let failure = (compound?.cause ?? error) as? OperationFailure
        let notFound = error as? VariantsNotFound
        let cause = failure?.cause ?? compound?.cause ?? notFound?.cause ?? error
        var body: [String: Any] = ["code": (cause as? C1Error)?.errorCode ?? "unexpected-error", "message": String(describing: error)]
        if let notFound {
            body["missingIds"] = notFound.missingIds
            if !notFound.outOfScopeIds.isEmpty { body["outOfScopeIds"] = notFound.outOfScopeIds }
        }
        if let compound { body["compoundId"] = compound.compoundId }
        if let failure = failure { body["operationId"] = failure.operationId; body["outcome"] = "inspect-operation" }
        return ["error": body]
    }
}
