import Foundation

/// Permission to adjust an existing native variant. Kept separate from clone
/// provenance so it can never authorize variant deletion.
public struct EditingRecord: Codable, Equatable {
    public static func isEditingReference(_ ref: String) -> Bool { ref.hasPrefix("c1_edit_") }
    public let workingRef: String
    public let variantId: String
    public let documentPath: String
    public let documentToken: String
    public let parentImagePath: String
    public let baselineAdjustments: Adjustments
    public let baselineMetadata: VariantMetadata?
    public let baselineGeometry: Geometry?
    public let baselineStateHash: String
    public let baselineGeometryStateHash: String?
    public let createdAt: String

    init(source: GetResult, document: DocumentInfo) {
        workingRef = "c1_edit_" + UUID().uuidString.lowercased()
        variantId = source.id
        documentPath = document.documentPath
        documentToken = document.openToken
        parentImagePath = source.parentImagePath!
        baselineAdjustments = source.adjustments
        baselineMetadata = VariantMetadata.from(source.metadata)
        baselineGeometry = source.geometry
        baselineStateHash = source.stateHash
        baselineGeometryStateHash = source.geometryStateHash
        createdAt = ISO8601DateFormatter().string(from: Date())
    }

    func validate(document: DocumentInfo, parent: String) throws {
        guard documentToken == document.openToken, documentPath == document.documentPath else {
            throw C1Error.documentChanged("Editing reference predates this application/database identity. Inspect the variant and create a fresh editing reference.")
        }
        guard !parentImagePath.isEmpty,
              URL(fileURLWithPath: parentImagePath).resolvingSymlinksInPath().path == URL(fileURLWithPath: parent).resolvingSymlinksInPath().path else {
            throw C1Error.identityAmbiguous("Existing variant parent image no longer matches its editing reference.")
        }
    }
}

struct EditingStore {
    let file: URL
    init(document: DocumentInfo) {
        file = URL(fileURLWithPath: document.documentPath).appendingPathComponent(".c1/editing.json")
    }
    private func records() throws -> [String: EditingRecord] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSONDecoder().decode([String: EditingRecord].self, from: Data(contentsOf: file))
    }
    func resolve(_ ref: String, document: DocumentInfo) throws -> EditingRecord {
        guard EditingRecord.isEditingReference(ref), let record = try records()[ref], record.workingRef == ref else {
            throw C1Error.unmanagedVariant("No editing permission exists for '\(ref)' in this document. Use variant edit first.")
        }
        try record.validate(document: document, parent: record.parentImagePath)
        return record
    }
    func register(_ record: EditingRecord) throws {
        var all = try records()
        all[record.workingRef] = record
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
