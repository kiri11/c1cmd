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
    /// `SessionController.scriptDocument` of the checked document.
    let document: NSAppleEventDescriptor

    func resolve(_ id: String, expectedParent: String) throws -> VariantLookupOutcome {
        struct Row: Decodable { let variantId: String; let isPresent: Bool; let parentImagePath: String }
        let rows: [Row] = try executor.executeAndDecode(handler: "lookupVariantIdentities", args: [
            document, NSAppleEventDescriptor(list: [NSAppleEventDescriptor(string: id)])])
        guard rows.count == 1, let row = rows.first, row.variantId == id else {
            throw C1Error.identityAmbiguous("Known-ID lookup for '\(id)' returned a different identity.")
        }
        guard row.isPresent else { return .absent }
        guard row.parentImagePath.hasPrefix("/") else {
            throw C1Error.identityAmbiguous("Known-ID lookup for '\(id)' returned no parent image path.")
        }
        return row.parentImagePath == expectedParent ? .present : .parentChanged(observed: row.parentImagePath)
    }

    /// Every variant ID of `parent`, found through one of its known variants.
    func siblings(of anchor: String, parent: String) throws -> [String] {
        let ids: [String] = try executor.executeAndDecode(handler: "readParentSiblings", args: [
            document, NSAppleEventDescriptor(string: anchor),
            NSAppleEventDescriptor(string: parent)])
        guard ids.contains(anchor), Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty }) else {
            throw C1Error.identityAmbiguous("Sibling query for '\(anchor)' returned empty, duplicate or foreign variant IDs.")
        }
        return ids
    }

    /// Siblings found through the first candidate that still belongs to `parent`,
    /// or nil when no candidate does. Lookup errors propagate.
    func siblings(anchoredBy candidates: [String], parent: String) throws -> [String]? {
        for anchor in candidates where try resolve(anchor, expectedParent: parent) == .present {
            return try siblings(of: anchor, parent: parent)
        }
        return nil
    }
}

/// Catalog All Images collection IDs by open token, read once per open document; nil
/// when the stored root names none or the Catalog cannot be read.
final class AllImagesCache {
    private var ids: [String: String?] = [:]
    private let lock = NSLock()

    func id(for openToken: String, read: () -> String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = ids[openToken] { return cached }
        let id = read()
        ids[openToken] = id
        return id
    }
}
