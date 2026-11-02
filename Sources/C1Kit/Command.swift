import Foundation

/// Every command, declared once. The CLI, its `--help` and `docs/reference/commands.md` come from this table.
public enum Command: String, CaseIterable {
    case doctor, list, collections, get, selection, set, action, revert, preview
    case cropPreview = "crop_preview"
    case contactSheet = "contact_sheet"
    case thumb

    public var summary: String {
        switch self {
        case .doctor: return "Check Capture One, the open document and its backup; warns without blocking."
        case .set: return "Write absolute values to 1–100 variants: adjustments, curves, color corrections, lens correction, geometry, crop, rating, color tag, layers."
        case .action: return "Run a layer, mask, color, dehaze, lens or reset action on 1–100 variants."
        case .revert: return "Restore variants to the snapshot c1 took before its first write; scope all, adjustments, geometry, metadata or layers."
        case .list: return "List variants from the database, filtered and paged."
        case .collections: return "List collections with kind, parent and variant count."
        case .get: return "Read live settings, geometry and layers of 1–100 variants."
        case .selection: return "Read the ids of the variants selected in Capture One."
        case .preview: return "Export a JPEG of one variant: the crop at a long edge, the full frame with a pixel mapping, or a region at a scale."
        case .cropPreview: return "Show 1–6 candidate crops side by side, cut from a cached full-frame render; the variant is not written."
        case .contactSheet: return "Tile Capture One's cached thumbnails for a page of list's scope into one JPEG, without Apple Events; fillMissing exports the photos the cache lacks."
        case .thumb: return "Read the camera's embedded JPEG of one variant's original, without Capture One's edits."
        }
    }

    /// The concepts behind the command, for `--help` and the reference.
    public var details: [String] {
        switch self {
        case .doctor:
            return ["Reports c1's version, Capture One's version and whether c1 is tested on it, the open document, its last Catalog backup, and where c1 keeps its snapshots and log. Warnings never block: an untested Capture One build, a Catalog backup missing or older than a day, and scripting terms that differ from the 16.8.5.30 terms c1 is built with.",
                    "A first call from a new terminal or agent app can wait until timeout while macOS shows the Automation consent dialog, sometimes behind other windows."]
        case .list:
            return ["Reads the document's database, not Capture One, so it is fast and works with --document on a closed Catalog or Session. Results are ordered by id; next is the cursor for the following page. Ratings and color tags may lag Capture One by up to a minute, and a new document's database can lag its first minute."]
        case .collections:
            return ["Reads the database. Kinds: album, smartAlbum, folder (Catalog), favorite (Session folder), project, group, allImages, other. Use an id as list's collection."]
        case .get:
            return ["Reads each variant through its folder, so the cost follows that folder's size, not the Catalog's: about 0.35 s, and about 1 s more for each layer other than the background. Results: variant (rating, color tag, crop and more), adjustments (with curves and colorEditor), lensCorrection, layers (the background first; other layers carry their own adjustments), cropBounds and route. changed: true keeps only the fields that differ from an unedited import, plus those that depend on the camera.",
                    Arguments.cropPixels, Arguments.queue]
        case .selection:
            return ["Reads the ids of the variants selected in Capture One's browser."]
        case .set:
            return ["Values are named as get reports them and are absolute targets. Geometry (orientation, flip, keystone, rotation, lens geometry) moves cropBounds, so a crop cannot be set with it; a positive rotation turns the photo clockwise, and Capture One shrinks the crop to fit: set the geometry, read cropBounds with get, then set a crop inside it. Curves are set whole under adjustments.curves.<channel> as 2–18 [x, y] points within 0–100, more than 1.5 apart on x. Basic color corrections are named (red … all) under adjustments.colorEditor.basic; advanced ones are addressed by index under colorEditor.advanced and added with action color.create. Mask pixels cannot be read, so no snapshot holds them.",
                    Arguments.writes, Arguments.cropPixels, Arguments.queue]
        case .action:
            return ["c1 tags the layers it creates with \" [c1:<tag>]\". layer.delete, the mask actions that overwrite pixels and luma.clear run only on those layers, because revert cannot restore mask pixels or a luma range; variant.reset is refused while the variant has a layer that is not c1's, because Capture One then deletes every layer. A layer renamed in Capture One without its tag becomes the photographer's. reset applies defaults; it is not an undo: revert is.",
                    Arguments.writes, Arguments.queue]
        case .revert:
            return ["Restores the snapshot c1 took before its first write to each variant: deletes the tagged layers created since, and restores every other layer and the background. Later edits in Capture One to that variant are overwritten. A snapshot layer that no longer exists is reported as not restored. After a complete revert of scope all, the snapshot is deleted and the next write takes a fresh one; a revert with errors, warnings or notRestored entries keeps it, so revert can run again. Scopes: adjustments (tone, color, curves, lens), geometry (rotation, keystone, orientation, flip, crop), metadata (rating, color tag), layers.",
                    Arguments.queue]
        case .preview:
            return ["The default is the variant's crop at a long edge of size px (1.1–2 s). fullFrame renders the default crop instead (Capture One's largest centred rectangle) and maps it: mapping {scale, left, top} turns crop pixels into render pixels as x' = (x − left) × scale, y' = (top − y) × scale, and currentCrop and cropBounds are given in render pixels. region renders a part of the cropped preview at scale × full resolution, for judging detail; the result gives the region in crop pixels. The variant is not written: c1 exports through its c1-preview recipe.",
                    Arguments.outputFolder, Arguments.previewFiles, Arguments.queue]
        case .cropPreview:
            return ["Candidates are rectangles in crop pixels, each checked against cropBounds. They are cut from a full-frame render that is cached until a setting other than the crop or metadata changes (about 0.5 s from cache). The render shows only the default crop, Capture One's largest centred rectangle, so a candidate beyond it fails: try it with set, preview and revert instead.",
                    Arguments.cropPixels, Arguments.outputFolder, Arguments.previewFiles]
        case .contactSheet:
            return ["Scope comes from list's filters or ids, paged by perPage. Tiles are justified rows at most 1536 px wide, labelled id · ★rating · name. Capture One builds thumbnails only for photos its browser has shown, so a sheet has gaps for the rest; fillMissing exports each gap at 1024 px, about 2.4 s per gap, and reuses an export until a setting other than rating or color tag changes. Ratings may lag by up to a minute.",
                    Arguments.outputFolder]
        case .thumb:
            return ["The camera's embedded JPEG, or a JPEG original itself, read from the original file in about 0.05 s. It shows no Capture One adjustments, crop or rotation: use preview to see edits."]
        }
    }

    public var arguments: [Argument] {
        switch self {
        case .doctor, .collections, .selection:
            return []
        case .list:
            return Arguments.filters + [Argument("limit", .integer(1...ListQuery.maxLimit), "Variants per page (default \(ListQuery.defaultLimit)).")]
        case .get:
            return [Arguments.ids, Argument("changed", .boolean, "Report only fields that differ from an unedited import (default false).")]
        case .set:
            return [Arguments.ids,
                    Argument("variant", .fields, "rating, color tag and crop."),
                    Argument("adjustments", .fields, "The variant's adjustments, with curves and colorEditor; see the field table."),
                    Argument("lensCorrection", .fields, "Lens correction fields; see the field table."),
                    Argument("layers", .list(.object(Arguments.layerPatch), count: nil), "Patches for existing layers. c1 never renames layers.")]
        case .action:
            return [Arguments.ids,
                    Argument("action", .enumeration(Action.allCases.map(\.rawValue)), required: true, "The action; the action table gives each one's arguments."),
                    Argument("arguments", .fields, "The action's arguments.")]
        case .revert:
            return [Arguments.ids, Argument("scope", .enumeration(RevertScope.allCases.map(\.rawValue)), "What to restore (default all).")]
        case .preview:
            return [Arguments.id,
                    Argument("size", .integer(Preview.sizes), "Long edge in px (default \(Preview.defaultSize)); not with region."),
                    Argument("fullFrame", .boolean, "Render the default crop with a pixel mapping (default false)."),
                    Argument("region", .object(Arguments.region), "A part of the cropped preview, as fractions from its top left."),
                    Argument("scale", .number(Preview.scales), "With region: the render's scale of full resolution (default 1)."),
                    Arguments.timeout]
        case .cropPreview:
            return [Arguments.id,
                    Argument("candidates", .list(.object(Arguments.canvasRect), count: Preview.candidates), required: true, "Candidate crops in crop pixels, numbered 1… in the image."),
                    Argument("size", .integer(Preview.sizes), "Long edge of the side-by-side image in px (default \(Preview.defaultSize))."),
                    Arguments.timeout]
        case .contactSheet:
            return Arguments.filters + [
                Argument("perPage", .integer(SheetLayout.perPageRange), "Tiles per page (default 20)."),
                Argument("rowHeight", .integer(SheetLayout.rowHeightRange), "Target row height in px (default 220)."),
                Argument("fillMissing", .boolean, "Export the photos the thumbnail cache lacks (default false)."),
                Argument("timeout", .number(Preview.timeouts), "With fillMissing: seconds to wait for each export (default \(Int(Preview.defaultTimeout))).")]
        case .thumb:
            return [Arguments.id, Argument("maxSize", .integer(Service.thumbSizes), "Long edge cap in px (default \(Preview.defaultSize)).")]
        }
    }

    /// Changes no variant. preview, crop_preview and contact_sheet with fillMissing still configure c1's app-wide
    /// c1-preview recipe, and set an unusable Catalog output folder to c1's preview folder.
    public var readOnly: Bool { ![.set, .action, .revert].contains(self) }

    /// Commands that can read a database file without Capture One.
    public var acceptsDocumentPath: Bool { [.list, .collections, .contactSheet, .thumb].contains(self) }

    /// Codes of a failed call. A failure with outcome unknown may have run in Capture One.
    public var failures: [C1Failure.Code] {
        let database: [C1Failure.Code] = [.invalidArguments, .database, .schemaMismatch]
        let live: [C1Failure.Code] = [.notRunning, .noDocument, .permissionDenied, .timeout, .busy, .documentChanged, .scriptError]
        switch self {
        case .doctor: return [.notRunning, .permissionDenied, .timeout, .busy, .scriptError, .database, .schemaMismatch]
        case .selection: return [.notRunning, .noDocument, .permissionDenied, .timeout, .busy, .scriptError]
        case .list, .collections, .contactSheet: return database + live
        case .thumb: return database + [.notFound] + live
        case .get, .set, .action, .revert: return [.invalidArguments] + live + [.database, .schemaMismatch]
        case .preview, .cropPreview: return [.invalidArguments, .notFound] + live + [.database, .schemaMismatch]
        }
    }

    /// Codes of one variant's failure inside a result whose other variants may have succeeded.
    public var variantErrors: [String] {
        switch self {
        case .get: return ["not-found", "read-failed"]
        case .set, .action, .revert: return ["refused", "not-found", "read-failed", "write-failed"]
        default: return []
        }
    }

    /// Arguments for `--help`'s example and the reference's recorded result.
    public var example: String {
        switch self {
        case .doctor, .collections, .selection: return "{}"
        case .list: return #"{"minRating":4,"limit":2}"#
        case .get: return #"{"ids":["1"],"changed":true}"#
        case .set: return #"{"ids":["1"],"adjustments":{"exposure":0.4,"curves":{"luma":[[0,0],[25,20],[100,100]]}},"variant":{"rating":4}}"#
        case .action: return #"{"ids":["1"],"action":"layer.create","arguments":{"kind":"adjustment","name":"Sky"}}"#
        case .revert: return #"{"ids":["1"],"scope":"adjustments"}"#
        case .preview: return #"{"id":"1","size":800}"#
        case .cropPreview: return #"{"id":"1","candidates":[{"centerX":3000,"centerY":2000,"width":6000,"height":4000},{"centerX":3000,"centerY":2000,"width":4500,"height":3000}],"size":800}"#
        case .contactSheet: return #"{"minRating":0,"perPage":2}"#
        case .thumb: return #"{"id":"1","maxSize":400}"#
        }
    }

    public func run(_ service: Service, arguments json: Data, document: String? = nil) throws -> JSONValue {
        if document != nil, !acceptsDocumentPath {
            throw C1Failure(.invalidArguments, "\(rawValue) reads Capture One's open document and takes no document path.")
        }
        switch self {
        case .list:
            return try service.list(try decode(ListQuery.self, json), document: document)
        case .collections:
            _ = try decode(Empty.self, json)
            return try service.collections(document: document)
        case .get:
            let arguments = try decode(GetArguments.self, json)
            return try service.get(ids: arguments.ids, changed: arguments.changed ?? false)
        case .selection:
            _ = try decode(Empty.self, json)
            return try service.selection()
        case .doctor:
            _ = try decode(Empty.self, json)
            return try service.doctor()
        case .set:
            return try service.set(try decode(SetArguments.self, json))
        case .action:
            let arguments = try decode(ActionArguments.self, json)
            return try service.action(arguments.action, ids: arguments.ids, arguments: arguments.arguments ?? [:])
        case .revert:
            let arguments = try decode(RevertArguments.self, json)
            return try service.revert(ids: arguments.ids, scope: arguments.scope ?? .all)
        case .preview:
            return try service.preview(try decode(PreviewArguments.self, json))
        case .cropPreview:
            return try service.cropPreview(try decode(CropPreviewArguments.self, json))
        case .contactSheet:
            return try service.contactSheet(try decode(ContactSheetArguments.self, json), document: document)
        case .thumb:
            return try service.thumb(try decode(ThumbArguments.self, json), document: document)
        }
    }

    /// The Codable struct that decodes the arguments.
    public var argumentsType: Decodable.Type {
        switch self {
        case .doctor, .collections, .selection: return Empty.self
        case .list: return ListQuery.self
        case .get: return GetArguments.self
        case .set: return SetArguments.self
        case .action: return ActionArguments.self
        case .revert: return RevertArguments.self
        case .preview: return PreviewArguments.self
        case .cropPreview: return CropPreviewArguments.self
        case .contactSheet: return ContactSheetArguments.self
        case .thumb: return ThumbArguments.self
        }
    }

    /// Decodes arguments as `run` does, without running the command.
    public func decodeArguments(_ json: Data) throws -> Any {
        func open<T: Decodable>(_ type: T.Type) throws -> Any { try decode(type, json) }
        return try open(argumentsType)
    }

    public struct Empty: Decodable {}
    public struct GetArguments: Decodable { public let ids: [VariantID]; public let changed: Bool? }
    public struct ActionArguments: Decodable { public let ids: [VariantID]; public let action: String; public let arguments: [String: JSONValue]? }
    public struct RevertArguments: Decodable { public let ids: [VariantID]; public let scope: RevertScope? }

    private func decode<T: Decodable>(_ type: T.Type, _ json: Data) throws -> T {
        let data = json.isEmpty ? Data("{}".utf8) : json
        guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw C1Failure(.invalidArguments, "\(rawValue) takes a JSON object of arguments.")
        }
        let names = arguments.map(\.name)
        let unknown = object.keys.filter { !names.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw C1Failure(.invalidArguments, "\(rawValue) does not take \(unknown.joined(separator: ", ")); it takes \(names.isEmpty ? "no arguments" : names.joined(separator: ", ")).")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let failure as C1Failure {
            throw failure
        } catch let DecodingError.keyNotFound(key, _) {
            throw C1Failure(.invalidArguments, "\(rawValue) needs \(key.stringValue).")
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.dataCorrupted(context), let DecodingError.valueNotFound(_, context) {
            let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            throw C1Failure(.invalidArguments, "\(rawValue): bad value at \(path.isEmpty ? "top level" : path): \(context.debugDescription)")
        }
    }
}
