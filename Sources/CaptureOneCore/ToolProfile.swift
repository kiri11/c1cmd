import Foundation

/// Which contract tools a caller may use. The CLI and the MCP server read the same
/// setting, and `ToolRequest` enforces it, so a restricted agent is restricted on both.
public enum ToolProfile: String {
    case standard = "default"
    /// Crop, rotation and keystone on existing variants; no tonal, native, metadata or recipe writes.
    case composition

    /// `C1_TOOL_PROFILE`, or its older name `C1_MCP_PROFILE`. Unknown or conflicting values fail closed.
    public static func configured(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ToolProfile {
        let values = Set(["C1_TOOL_PROFILE", "C1_MCP_PROFILE"].compactMap { environment[$0] }.filter { !$0.isEmpty })
        guard values.count <= 1 else {
            throw C1Error.invalidRequest("C1_TOOL_PROFILE and C1_MCP_PROFILE disagree; set one profile.")
        }
        guard let value = values.first else { return .standard }
        guard let profile = ToolProfile(rawValue: value) else {
            throw C1Error.invalidRequest("Unknown tool profile '\(value)'; use 'default' or 'composition'.")
        }
        return profile
    }

    static let compositionExcluded = Set(Recipes.tools.filter { $0 != "edit_status" })
        .union(["native_set", "native_action", "set", "add", "reset", "variant_baseline", "metadata_set"])

    public func allows(_ tool: String) -> Bool {
        self == .standard || !Self.compositionExcluded.contains(tool)
    }

    /// Enabled tools in schema order, for transports that register them.
    public var tools: [ToolDefinition] {
        ContractSchema.names.filter(allows).map { ToolDefinition(name: $0) }
    }
}

/// How a transport presents one contract tool. Arguments are validated by `ToolRequest`.
public struct ToolDefinition {
    public let name: String

    public var description: String { Self.catalog[name]!.description }
    public var readOnly: Bool { Self.catalog[name]!.readOnly }
    public var destructive: Bool { ["variant_delete", "native_action"].contains(name) }
    public var inputSchema: [String: Any] { ContractSchema.input(name) }

    static let recipe = "Versioned reference recipes and bounded compound edits. Verification requires a managed clone. Inspect status and child operation IDs after failure; never retry automatically."
    /// One entry per `ContractSchema.names` tool; an offline test keeps them in step.
    static let catalog: [String: (description: String, readOnly: Bool)] = {
        var entries: [String: (description: String, readOnly: Bool)] = [
            "read_session_begin": ("Begin exclusive c1 browsing with a native scope baseline. No UI changes until read_session_end. Auto-routed browse results omit mutation tokens; use live:true before edits.", false),
            "read_session_end": ("End accelerated browsing before returning control to the photographer.", false),
            "read_session_status": ("Inspect read workflow state and process new journal observations.", true),
            "catalog_get": ("Inspect raw stored settings for one variant in an explicit Catalog database. Works while closed; no native tokens.", true),
            "catalog_variants": ("Discover distinct stored variants with explicit image/variant membership and optional ratings. No live mutation tokens or smart collection evaluation.", true),
            "catalog_inspect": ("Read versioned stored Catalog records from an explicit database path. No native references or live tokens; may lag Capture One.", true),
            "catalog_snapshot": ("Archive a Catalog using SQLite backup to a new destination file. Does not modify the source or include originals or external masks.", false),
            "native_set": ("Set typed native editing properties using exact dictionary field names and ifNativeState from get.nativeSnapshots. Curves use flat x,y pairs in 0...100. Saves before-state in the operation journal. Geometry guards still apply.", false),
            "native_action": ("Run an allowlisted layer, mask, color-editor, style or dehaze operation with a fresh nativeStateHash. Mask pixels cannot be captured or restored from property snapshots. Inspect a preview after commands.", false),
            "doctor": ("Check environment, app status, exact build, document readiness, and unresolved operations.", true),
            "doc_info": ("Show current open document info, folders, and open token.", true),
            "capabilities": ("Show capability matrix for the running Capture One build.", true),
            "schema": ("Output JSON Schema for c1 requests and responses.", true),
            "variants_list": ("List variants, optionally filtered by exact or minimum rating. Supply 1–512 known ids for fresh bounded discovery with minimal fields, optional summary fields and exact parentPath filtering. Subset reads return no mutation tokens.", true),
            "variant_edit": ("Prepare editing on an existing variant without cloning. Requires ifDocument from doc_info and ifState from get; optionally check ifGeometryState too. Saves its baseline and returns a c1_edit_ reference for supported adjustments and geometry. Does not authorize deletion.", false),
            "geometry_restore": ("Restore saved crop/rotation/keystone for an editing or clone reference. Requires fresh ifGeometryState; refuses changed lens/orientation context. Never delete an existing variant to reject a crop.", false),
            "variant_clone": ("Clone a source variant and return a c1-managed working reference (c1_wrk_<uuid>). Use variant_edit to edit existing variants.", false),
            "variant_delete": ("Delete a c1-managed working clone. (Originals cannot be deleted).", false),
            "variant_baseline": ("Create a managed default-settings baseline variant using native New Variant behavior.", false),
            "get": ("Read a variant: adjustments, metadata, geometry and their state tokens. Optionally include 1...16 nativeTargets for curves, lens or layer properties in nativeSnapshots, with shared validation and independent nativeStateHash tokens. Live AppleScript observations; not SQLite or an atomic multi-scope snapshot.", true),
            "exif": ("Camera level hints from the original, read with exiftool: levelRotation is the geometry_set rotation that levels the recorded roll; pitchAngle is upward lens tilt, with focalLength35mm to judge convergence. Hints to confirm against a preview. Needs exiftool; no state tokens.", true),
            "set": ("Set absolute adjustments on an editing reference or managed working clone. Requires matching ifState precondition.", false),
            "add": ("Apply relative delta adjustments on an editing reference or managed working clone. Requires matching ifState precondition.", false),
            "metadata_set": ("Set rating (0–5) and/or colorTag (0–7; 0 clears) on an editing reference or managed clone. Requires ifMetadataState from get. Preserves omitted fields and image adjustments. dryRun returns the current metadata token.", false),
            "geometry_set": ("Set crop, rotation, and keystone on a c1_edit_ existing variant or c1_wrk_ clone, requiring ifGeometryState from get. Native rotated canvas pixels with bottom-left origin. aspectRatio fits a centered crop; use explicit crop for composition. Optional keystone object sets amount, vertical, horizontal, skew, or aspect; omitted controls are preserved. Preserves lens distortion and tilt/shift using native bounds. Dry runs cannot predict keystone changes or corrected rotation crops.", false),
            "reset": ("Reset verified adjustment fields on an editing reference or managed clone to defaults; white balance uses its saved baseline.", false),
            "diff": ("Compare adjustments between two variants or compare a working variant against its baseline.", true),
            "dump": ("Batched export of variants, adjustments, and metadata in JSON format.", true),
            "preview": ("Export and verify dedicated preview JPEG for a variant or working clone. Returns JSON metadata and an image content block with JPEG data.", false),
            "request_status": ("Read stored request progress and process liveness without contacting Capture One.", true),
            "operation_status": ("Inspect status and, after an app restart, journal recovery observations without retrying the operation.", false),
        ]
        for tool in Recipes.tools { entries[tool] = (recipe, tool == "edit_status") }
        return entries
    }()
}
