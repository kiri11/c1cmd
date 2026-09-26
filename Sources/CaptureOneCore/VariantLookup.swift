import Foundation

/// What Capture One reports for one already-known native variant ID.
/// A thrown lookup error is never an outcome: it must not be read as absence.
public enum VariantLookupOutcome: Equatable {
    case present
    case absent
    case parentChanged(observed: String)
}

/// Resolves known native IDs without enumerating the document. Identity
/// evidence only; an outcome never authorizes a write or rebinds a reference.
struct VariantLookup {
    let executor: ScriptExecuting

    func resolve(_ id: String, expectedParent: String, in document: DocumentInfo) throws -> VariantLookupOutcome {
        struct Row: Decodable { let variantId: String; let isPresent: Bool; let parentImagePath: String }
        let rows: [Row] = try executor.executeAndDecode(handler: "lookupVariantIdentities", args: [
            NSAppleEventDescriptor(string: document.documentId),
            NSAppleEventDescriptor(list: [NSAppleEventDescriptor(string: id)])])
        guard rows.count == 1, let row = rows.first, row.variantId == id else {
            throw C1Error.identityAmbiguous("Known-ID lookup for '\(id)' returned a different identity.")
        }
        guard row.isPresent else { return .absent }
        guard row.parentImagePath.hasPrefix("/") else {
            throw C1Error.identityAmbiguous("Known-ID lookup for '\(id)' returned no parent image path.")
        }
        return row.parentImagePath == expectedParent ? .present : .parentChanged(observed: row.parentImagePath)
    }
}
