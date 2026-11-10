import CoreGraphics
import Foundation
import ImageIO

/// The crop Capture One stored in a `.cot` thumbnail's EXIF UserComment. The cached pixels are uncropped,
/// so only a crop in the verified format is applied.
enum CotCrop: Equatable {
    /// Top-left-origin rectangle in thumbnail pixels.
    case applied(CGRect)
    case fullFrame
    /// Absent, format version 2 (origin unverified) or another format.
    case notApplied(String?)

    /// Version 3 is `3|i;i;i|left;top;right;bottom|0` in bottom-left-origin thumbnail pixels (16.8.5.30).
    static func parse(_ comment: String?, width: Int, height: Int) -> CotCrop {
        guard let comment, !comment.isEmpty else { return .notApplied(nil) }
        let fields = comment.split(separator: "|", omittingEmptySubsequences: false)
        let middle = fields.count == 4 ? fields[1].split(separator: ";", omittingEmptySubsequences: false) : []
        let edges = fields.count == 4 ? fields[2].split(separator: ";", omittingEmptySubsequences: false).compactMap { Double($0) }.filter(\.isFinite) : []
        guard fields.first == "3", fields.count == 4, fields[3] == "0", middle.count == 3, middle.allSatisfy({ Int($0) != nil }), edges.count == 4 else {
            return .notApplied(comment)
        }
        let (left, top, right, bottom) = (edges[0], edges[1], edges[2], edges[3])
        let w = Double(width), h = Double(height)
        guard 0 <= left, left < right, right <= w, 0 <= bottom, bottom < top, top <= h else { return .notApplied(comment) }
        if left == 0, top == h, right == w, bottom == 0 { return .fullFrame }
        return .applied(CGRect(x: left, y: h - top, width: right - left, height: top - bottom))
    }
}

enum Tile {
    case shown(CGImage, crop: CotCrop)
    case missing
    case unreadable

    static let placeholderAspect = 3.0 / 2.0

    /// Reads a `.cot` file: a JPEG of oriented, uncropped pixels.
    static func read(_ url: URL?) -> Tile {
        guard let url, let data = FileManager.default.contents(atPath: url.path) else { return .missing }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return .unreadable }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        // The cache stores oriented pixels, so an orientation tag means an unknown format.
        if let orientation = properties[kCGImagePropertyOrientation] as? NSNumber, orientation.intValue != 1 { return .unreadable }
        let comment = (properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] as? String
        return .shown(image, crop: CotCrop.parse(comment, width: image.width, height: image.height))
    }

    var visible: CGRect? {
        guard case .shown(let image, let crop) = self else { return nil }
        if case .applied(let rect) = crop {
            let left = rect.minX.rounded(), top = rect.minY.rounded()
            return CGRect(x: left, y: top, width: rect.maxX.rounded() - left, height: rect.maxY.rounded() - top)
        }
        return CGRect(x: 0, y: 0, width: image.width, height: image.height)
    }

    var aspect: Double { visible.map { $0.width / $0.height } ?? Self.placeholderAspect }
}

/// Justified rows of photos on a sheet at most 1536 px wide, below the edge at which clients downscale an image.
public struct SheetLayout: Equatable {
    public static let perPageRange = 1...48, rowHeightRange = 120...450
    public static let width = 1536, maximumHeight = 2400
    static let minimumWidth = 480, headerHeight = 24, gutter = 4, labelHeight = 16
    static let maximumStretch = 1.5

    public let perPage: Int
    public let rowHeight: Int

    public init(perPage: Int? = nil, rowHeight: Int? = nil) throws {
        self.perPage = perPage ?? 20
        self.rowHeight = rowHeight ?? 220
        guard Self.perPageRange.contains(self.perPage), Self.rowHeightRange.contains(self.rowHeight) else {
            throw C1Failure(.invalidArguments, "perPage must be \(Self.perPageRange.lowerBound)–\(Self.perPageRange.upperBound) and rowHeight \(Self.rowHeightRange.lowerBound)–\(Self.rowHeightRange.upperBound).")
        }
    }

    public struct Arrangement: Equatable {
        public let cells: [CGRect]
        public let width: Int
        public let height: Int
        var imageArea: Double { cells.reduce(0) { $0 + $1.width * $1.height } }
    }

    /// Rows near `rowHeight`; a page taller than the maximum gets lower rows or uniformly scaled rows, whichever shows more photo.
    public func arrange(_ aspects: [Double]) -> Arrangement {
        let requested = Self.rows(aspects, target: Double(rowHeight))
        if Self.unscaledHeight(requested) <= Self.maximumHeight { return Self.place(aspects, requested) }
        return (1...rowHeight).reversed().map { Self.place(aspects, Self.rows(aspects, target: Double($0))) }.max { $0.imageArea < $1.imageArea }!
    }

    private typealias Row = (range: Range<Int>, height: Double)

    /// A row takes photos until the next would overflow, then takes it and gets lower or leaves it and gets taller,
    /// whichever lands nearer the target, filling the width; growth stops at 1.5 × target. The last row keeps the target.
    private static func rows(_ aspects: [Double], target: Double) -> [Row] {
        func available(_ count: Int) -> Double { Double(width - (count + 1) * gutter) }
        var rows: [Row] = []
        var start = 0
        while start < aspects.count {
            var end = start + 1, sum = aspects[start]
            while end < aspects.count, (sum + aspects[end]) * target <= available(end + 1 - start) {
                sum += aspects[end]
                end += 1
            }
            let fill = available(end - start) / sum
            if fill < target || end == aspects.count {
                rows.append((start..<end, min(target, fill)))
            } else {
                let shrink = available(end + 1 - start) / (sum + aspects[end])
                if abs(shrink - target) < abs(fill - target) {
                    end += 1
                    rows.append((start..<end, shrink))
                } else {
                    rows.append((start..<end, min(fill, target * maximumStretch)))
                }
            }
            start = end
        }
        return rows
    }

    private static func unscaledHeight(_ rows: [Row]) -> Int {
        rows.reduce(headerHeight + gutter) { $0 + Int($1.height.rounded()) + labelHeight + gutter }
    }

    private static func place(_ aspects: [Double], _ rows: [Row]) -> Arrangement {
        let strips = headerHeight + gutter + rows.count * (labelHeight + gutter)
        let scale = unscaledHeight(rows) <= maximumHeight ? 1 : Double(maximumHeight - strips) / rows.reduce(0) { $0 + $1.height }
        var cells: [CGRect] = []
        var y = headerHeight + gutter
        for row in rows {
            let exactHeight = scale == 1 ? row.height : (row.height * scale).rounded(.down)
            let height = max(1, Int(exactHeight.rounded()))
            var offset = 0.0, x = gutter
            for index in row.range {
                offset += aspects[index] * exactHeight
                let right = gutter * (index - row.range.lowerBound + 1) + Int(offset.rounded())
                cells.append(CGRect(x: x, y: y, width: max(1, right - x), height: height))
                x = right + gutter
            }
            y += height + labelHeight + gutter
        }
        let sheetWidth = max(minimumWidth, cells.map { Int($0.maxX) + gutter }.max() ?? 0)
        return Arrangement(cells: cells, width: sheetWidth, height: y)
    }
}

public struct ContactSheetArguments: Decodable {
    public var rating, minRating, colorTag: Int?
    public var collection: CollectionID?
    public var ids: [VariantID]?
    public var edited: Bool?
    public var after: VariantID?
    public var perPage, rowHeight: Int?
    /// Exports the photos the cache lacks through Capture One, and reuses those exports until a setting changes.
    public var fillMissing: Bool?
    /// Exports every photo again: Capture One's thumbnails lag edits and crops, and c1's exports cannot see mask pixels.
    public var refresh: Bool?
    public var timeout: Double?

    public init(ids: [VariantID]? = nil, minRating: Int? = nil, after: VariantID? = nil, perPage: Int? = nil, rowHeight: Int? = nil,
                fillMissing: Bool? = nil, refresh: Bool? = nil, timeout: Double? = nil) {
        self.ids = ids; self.minRating = minRating; self.after = after; self.perPage = perPage; self.rowHeight = rowHeight
        self.fillMissing = fillMissing; self.refresh = refresh; self.timeout = timeout
    }
}

enum TileFill {
    case exported(CGImage, reused: Bool)
    case failed(String)
}

extension Service {
    static let tileEdge = 1024

    /// Starts an export for each id in one queue slot, reusing a tile exported from the same settings, then waits
    /// for the files outside the queue. A variant Capture One lacks or a late file fails its tile, not the sheet.
    func exportTiles(_ ids: [VariantID], documentUUID: String, refresh: Bool, timeout: Double) throws -> (fills: [VariantID: TileFill], outputSet: Bool) {
        var fills: [VariantID: TileFill] = [:]
        var pending: [(VariantID, URL)] = []
        var outputSet = false
        try queue.run {
            let read = try liveRead(ids)
            guard read.database.documentUUID == documentUUID else {
                throw C1Failure(.documentChanged, "fillMissing exports through Capture One, whose open document is not this sheet's.",
                                hint: "Open that document in Capture One, or leave out fillMissing.")
            }
            let folder = previewsRoot.appendingPathComponent(documentUUID)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for id in ids {
                let state: VariantState
                switch read.results[id] ?? .notFound {
                case .state(let found): state = found
                case .notFound: fills[id] = .failed("Capture One has no variant \(id) in this document."); continue
                case .failed(let reason): fills[id] = .failed(reason); continue
                }
                let file = folder.appendingPathComponent("tile-\(id)-\(Preview.cacheKey(state, longEdge: Self.tileEdge, cropped: true)).jpg")
                if !refresh, let image = Images.decodeJPEG(file) {
                    try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: file.path)
                    fills[id] = .exported(image, reused: true)
                    continue
                }
                let request = ExportRequest(target: ReadTarget(id, read.routes[id]!), longEdge: Self.tileEdge, fullFrame: false, file: file)
                do {
                    if try captureOne.export(request, in: read.document) { outputSet = true }
                    pending.append((id, file))
                } catch let failure as C1Failure where failure.code == .notFound {
                    fills[id] = .failed(failure.message)
                }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        for (id, file) in pending {
            do {
                fills[id] = .exported(try Preview.waitForJPEG(file, timeout: max(0.1, deadline.timeIntervalSinceNow)), reused: false)
            } catch let failure as C1Failure {
                fills[id] = .failed(failure.message)
            }
        }
        return (fills, outputSet)
    }

    /// Tiles Capture One's cached thumbnails for one page of `list`'s scope, from SQLite and the cache only, unless
    /// `fillMissing` exports the gaps, or with `refresh` every tile.
    public func contactSheet(_ arguments: ContactSheetArguments, document: String? = nil) throws -> JSONValue {
        let layout = try SheetLayout(perPage: arguments.perPage, rowHeight: arguments.rowHeight)
        let fillMissing = arguments.fillMissing ?? false
        guard fillMissing || (arguments.timeout == nil && arguments.refresh == nil) else {
            throw C1Failure(.invalidArguments, "timeout and refresh go with fillMissing.")
        }
        let timeout = try Preview.timeout(arguments.timeout)
        let database = try self.database(document)
        let query = ListQuery(rating: arguments.rating, minRating: arguments.minRating, colorTag: arguments.colorTag, collection: arguments.collection,
                              ids: arguments.ids, edited: arguments.edited, after: arguments.after, limit: layout.perPage)
        let (rows, next) = try database.list(query)
        var output: [String: JSONValue] = [:]
        if let next { output["next"] = .string(next.description) }
        guard !rows.isEmpty else { return .object(output.merging(["tiles": .array([])]) { $1 }) }
        let originals = try database.originals(rows.map(\.id))
        let databaseFolder = URL(fileURLWithPath: database.path).deletingLastPathComponent()
        var tiles = rows.map { row -> Tile in
            let original = originals[row.id]
            let location: URL?
            switch database.kind {
            case .catalog:
                let digits = row.id.description
                location = databaseFolder.appendingPathComponent("Cache/Thumbnails")
                    .appendingPathComponent(String(repeating: "0", count: max(0, 8 - digits.count)) + digits + ".cot")
            case .session:
                location = original.flatMap { original in
                    guard let path = original.path, let name = original.fileName, let uuid = original.variantUUID else { return nil }
                    return URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("CaptureOne/Cache/Thumbnails")
                        .appendingPathComponent("\(name).[\(uuid.lowercased())].cot")
                }
            }
            return Tile.read(location)
        }
        var fills: [VariantID: TileFill] = [:]
        var warnings: [String] = []
        let refresh = arguments.refresh ?? false
        let wanted = rows.indices.filter { if !refresh, case .shown = tiles[$0] { return false }; return true }
        if fillMissing, !wanted.isEmpty {
            let exported = try exportTiles(wanted.map { rows[$0].id }, documentUUID: database.documentUUID, refresh: refresh, timeout: timeout)
            fills = exported.fills
            for index in wanted {
                // An export already carries the variant's crop.
                if case .exported(let image, _)? = fills[rows[index].id] { tiles[index] = .shown(image, crop: .fullFrame) }
            }
            if exported.outputSet {
                warnings.append("The Catalog's output folder was unset or missing, and Capture One refuses every export then, so c1 set it to \(previewsRoot.appendingPathComponent(database.documentUUID).path). Choose another in Capture One's Output tool if you like.")
            }
        }
        let arrangement = layout.arrange(tiles.map(\.aspect))
        let canvas = Images.Canvas(width: arrangement.width, height: arrangement.height, background: Images.background)
        let exportedCount = fills.values.filter { if case .exported = $0 { return true }; return false }.count
        let source = exportedCount > 0 ? "Capture One thumbnail cache + \(exportedCount) exported" : "Capture One thumbnail cache"
        let header = "\(database.kind.rawValue) · \(rows.first!.id)–\(rows.last!.id) · \(source) · \(ISO8601DateFormatter().string(from: now()))"
        canvas.text(header, in: CGRect(x: SheetLayout.gutter, y: 0, width: arrangement.width - 2 * SheetLayout.gutter, height: SheetLayout.headerHeight),
                    size: 12, color: Images.text)
        var items: [JSONValue] = []
        for (row, (tile, cell)) in zip(rows, zip(tiles, arrangement.cells)) {
            var item: [String: JSONValue] = ["id": .string(row.id.description), "name": row.name.map(JSONValue.string) ?? .null,
                                             "rating": .int(Int64(row.rating)), "cell": Self.pixelJSON(cell)]
            if case .failed(let reason)? = fills[row.id] { item["fillError"] = .string(reason) }
            switch (tile, fills[row.id]) {
            case (.shown(let image, _), .exported(_, let reused)?):
                canvas.draw(image, from: tile.visible, in: cell)
                item["status"] = .string("exported")
                item["reused"] = .bool(reused)
            case (.shown(let image, let crop), _):
                canvas.draw(image, from: tile.visible, in: cell)
                switch crop {
                case .applied: item["crop"] = .string("applied")
                case .fullFrame: item["crop"] = .string("full-frame")
                case .notApplied:
                    item["crop"] = .string("not-applied")
                    let badge = CGRect(x: cell.minX, y: cell.minY, width: min(cell.width, 72), height: min(cell.height, 16))
                    canvas.fill(badge, Images.amber)
                    canvas.text("UNCROPPED", in: badge, size: 10, color: Images.darkText, centered: true)
                }
                item["status"] = .string("shown")
            case (.missing, _), (.unreadable, _):
                let missing: Bool = { if case .missing = tile { return true }; return false }()
                canvas.fill(cell, Images.placeholder)
                canvas.text(missing ? "NO CACHE" : "UNREADABLE", in: cell.insetBy(dx: 4, dy: 0), size: 15, color: Images.dimText, centered: true)
                item["status"] = .string(missing ? "missing" : "unreadable")
            }
            canvas.text("\(row.id) · ★\(row.rating) · \(row.name ?? "")",
                        in: CGRect(x: cell.minX, y: cell.maxY, width: cell.width, height: CGFloat(SheetLayout.labelHeight)), size: 11, color: Images.text)
            items.append(.object(item))
        }
        Preview.prune(previewsRoot, now: now())
        let file = previewsRoot.appendingPathComponent(database.documentUUID)
            .appendingPathComponent("sheet-\(rows.first!.id)-\(rows.last!.id)-\(UUID().uuidString.prefix(8).lowercased()).jpg")
        try Images.writeJPEG(canvas.image(), to: file, quality: 0.85)
        output["path"] = .string(file.path)
        output["width"] = .int(Int64(arrangement.width))
        output["height"] = .int(Int64(arrangement.height))
        output["tiles"] = .array(items)
        if !warnings.isEmpty { output["warnings"] = .array(warnings.map(JSONValue.string)) }
        return .object(output)
    }
}
