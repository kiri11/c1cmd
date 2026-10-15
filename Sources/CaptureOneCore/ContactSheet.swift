import Foundation
import CoreGraphics
import CoreText
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

public struct SheetScope: Equatable {
    public let collection: String?
    public let selected: Bool
    public let ids: [String]?
    public let rating: Int?
    public let minRating: Int?

    public init(collection: String? = nil, selected: Bool = false, ids: [String]? = nil, rating: Int? = nil, minRating: Int? = nil) {
        self.collection = collection
        self.selected = selected
        self.ids = ids
        self.rating = rating
        self.minRating = minRating
    }

    var canonical: String {
        var fields: [String: Any] = ["selected": selected]
        fields["collection"] = collection; fields["ids"] = ids; fields["rating"] = rating; fields["minRating"] = minRating
        return String(decoding: try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }
}

/// A top-left-origin rectangle in sheet pixels.
public struct PixelRect: Equatable, Encodable {
    public let x: Int, y: Int, width: Int, height: Int

    package init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct SheetLayout: Equatable {
    public static let perPageRange = 1...48, rowHeightRange = 120...450
    /// Below the 1568 px edge at which clients downscale an image.
    public static let width = 1536
    public static let maximumHeight = 2400
    static let minimumWidth = 480
    public static let standard = try! SheetLayout(perPage: 20, rowHeight: 220)
    static let headerHeight = 24, gutter = 4, labelHeight = 16
    static let maximumStretch = 1.5

    public let perPage: Int
    public let rowHeight: Int

    public init(perPage: Int, rowHeight: Int) throws {
        guard Self.perPageRange.contains(perPage), Self.rowHeightRange.contains(rowHeight) else {
            throw C1Error.invalidRequest("perPage must be \(Self.perPageRange.lowerBound)–\(Self.perPageRange.upperBound) and rowHeight \(Self.rowHeightRange.lowerBound)–\(Self.rowHeightRange.upperBound).")
        }
        self.perPage = perPage
        self.rowHeight = rowHeight
    }

    package static func label(below image: PixelRect) -> PixelRect {
        PixelRect(x: image.x, y: image.y + image.height, width: image.width, height: labelHeight)
    }

    package func arrange(_ aspects: [Double]) -> SheetArrangement {
        let requested = Self.rows(aspects, target: Double(rowHeight))
        if Self.unscaledHeight(requested) <= Self.maximumHeight { return Self.place(aspects, requested) }
        return Self.largestImageArea(aspects, rowHeight: rowHeight)
    }

    private static func largestImageArea(_ aspects: [Double], rowHeight: Int) -> SheetArrangement {
        (1...rowHeight).reversed().map { place(aspects, rows(aspects, target: Double($0))) }
            .max { $0.imageArea < $1.imageArea }!
    }

    private typealias Row = (range: Range<Int>, height: Double)

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

    private static func place(_ aspects: [Double], _ rows: [Row]) -> SheetArrangement {
        let strips = headerHeight + gutter + rows.count * (labelHeight + gutter)
        let scale = unscaledHeight(rows) <= maximumHeight ? 1 : Double(maximumHeight - strips) / rows.reduce(0) { $0 + $1.height }
        var cells: [PixelRect] = []
        var y = headerHeight + gutter
        for row in rows {
            let exactHeight = scale == 1 ? row.height : (row.height * scale).rounded(.down)
            let height = max(1, Int(exactHeight.rounded()))
            var offset = 0.0, x = gutter
            for index in row.range {
                offset += aspects[index] * exactHeight
                let right = gutter * (index - row.range.lowerBound + 1) + Int(offset.rounded())
                cells.append(PixelRect(x: x, y: y, width: max(1, right - x), height: height))
                x = right + gutter
            }
            y += height + labelHeight + gutter
        }
        let sheetWidth = max(minimumWidth, cells.map { $0.x + $0.width + gutter }.max() ?? 0)
        return SheetArrangement(cells: cells, width: sheetWidth, height: y)
    }
}

package struct SheetArrangement: Equatable {
    package let cells: [PixelRect]
    package let width: Int
    package let height: Int

    var imageArea: Int { cells.reduce(0) { $0 + $1.width * $1.height } }
}

package struct SheetMember: Equatable {
    package let id: String
    package let name: String
    package let rating: Int
    package let parentImagePath: String

    package init(id: String, name: String, rating: Int, parentImagePath: String) {
        self.id = id
        self.name = name
        self.rating = rating
        self.parentImagePath = parentImagePath
    }
}

package enum MissingReason: String, CaseIterable {
    case notCached = "not-cached"
    /// Live in Capture One but not yet in the saved database, such as a clone before the save tick.
    case notStored = "not-stored"
}

package enum UnreadableReason: String, CaseIterable {
    case undecodable
    /// The cache stores oriented pixels, so an orientation tag means an unknown format.
    case orientationTag = "orientation-tag"
    case changedDuringRead = "changed-during-read"
    case tooLarge = "too-large"
    case notRegularFile = "not-regular-file"
    case inaccessible
}

package struct CachedThumbnail {
    package let image: CGImage
    package let modifiedAt: Date
    package let crop: CotCrop

    package init(image: CGImage, modifiedAt: Date, crop: CotCrop) {
        self.image = image
        self.modifiedAt = modifiedAt
        self.crop = crop
    }

    package var visibleRect: CGRect {
        guard case .applied(let x, let y, let width, let height) = crop else { return CGRect(x: 0, y: 0, width: image.width, height: image.height) }
        let left = x.rounded(), top = y.rounded()
        return CGRect(x: left, y: top, width: (x + width).rounded() - left, height: (y + height).rounded() - top)
    }
}

package enum TileContent {
    case shown(CachedThumbnail)
    case missing(MissingReason)
    case unreadable(UnreadableReason)

    static let placeholderAspect = 3.0 / 2.0

    package var aspect: Double {
        guard case .shown(let thumbnail) = self else { return Self.placeholderAspect }
        let visible = thumbnail.visibleRect
        return visible.width / visible.height
    }
}

public struct ContactSheetTile: Encodable {
    package let member: SheetMember
    public let cell: PixelRect
    package let content: TileContent

    package init(member: SheetMember, cell: PixelRect, content: TileContent) {
        self.member = member
        self.cell = cell
        self.content = content
    }

    package var uncropped: Bool {
        if case .shown(let thumbnail) = content, case .notApplied = thumbnail.crop { return true }
        return false
    }

    private enum Keys: String, CodingKey { case id, name, rating, status, reason, cell, cachedSize, cacheModifiedAt, crop }
    private enum SizeKeys: String, CodingKey { case width, height }
    private enum CropKeys: String, CodingKey { case status, reason, userComment }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(member.id, forKey: .id)
        try container.encode(member.name, forKey: .name)
        try container.encode(member.rating, forKey: .rating)
        try container.encode(cell, forKey: .cell)
        switch content {
        case .missing(let reason):
            try container.encode("missing", forKey: .status)
            try container.encode(reason.rawValue, forKey: .reason)
        case .unreadable(let reason):
            try container.encode("unreadable", forKey: .status)
            try container.encode(reason.rawValue, forKey: .reason)
        case .shown(let thumbnail):
            try container.encode("shown", forKey: .status)
            var size = container.nestedContainer(keyedBy: SizeKeys.self, forKey: .cachedSize)
            try size.encode(Int(thumbnail.visibleRect.width), forKey: .width)
            try size.encode(Int(thumbnail.visibleRect.height), forKey: .height)
            try container.encode(ISO8601DateFormatter().string(from: thumbnail.modifiedAt), forKey: .cacheModifiedAt)
            var crop = container.nestedContainer(keyedBy: CropKeys.self, forKey: .crop)
            switch thumbnail.crop {
            case .applied: try crop.encode("applied", forKey: .status)
            case .fullFrame: try crop.encode("full-frame", forKey: .status)
            case .notApplied(let reason, let userComment):
                try crop.encode("not-applied", forKey: .status)
                try crop.encode(reason.rawValue, forKey: .reason)
                try crop.encodeIfPresent(userComment, forKey: .userComment)
            }
        }
    }
}

public struct SheetImage: Encodable, Equatable {
    public let path: String
    public let width: Int
    public let height: Int

    package init(path: String, width: Int, height: Int) {
        self.path = path
        self.width = width
        self.height = height
    }
}

public struct ContactSheetResult: Encodable {
    public static let source = "capture-one-thumbnail-cache"
    public static let limitation = "Capture One's own cached thumbnails, at most 450 px on the long edge before crop and scaled to their row, so cachedSize gives a tile's real detail. A thumbnail can lag an edit Capture One has not processed yet; after a c1 orientation change on a cropped, rotated variant, it lagged until the next tonal edit. A variant Capture One has not yet saved shows as NOT SAVED until its next save. A triage aid, never review evidence for an edit; review edits with preview. UNCROPPED tiles show the full frame because their stored crop could not be applied. Missing thumbnails are reported, never replaced by an export."

    public let documentKind: String
    public let documentName: String
    public let page: Int
    public let pages: Int
    public let total: Int
    public let nextPage: Int?
    public let sheet: SheetImage?
    public let tiles: [ContactSheetTile]
    public let renderedAt: String

    package init(documentKind: String, documentName: String, page: Int, pages: Int, total: Int, nextPage: Int?,
                 sheet: SheetImage?, tiles: [ContactSheetTile], renderedAt: String) {
        self.documentKind = documentKind
        self.documentName = documentName
        self.page = page
        self.pages = pages
        self.total = total
        self.nextPage = nextPage
        self.sheet = sheet
        self.tiles = tiles
        self.renderedAt = renderedAt
    }

    package var counts: [String: Int] {
        var counts = ["shown": 0, "missing": 0, "unreadable": 0, "uncropped": 0]
        for tile in tiles {
            switch tile.content {
            case .shown: counts["shown"]! += 1
            case .missing: counts["missing"]! += 1
            case .unreadable: counts["unreadable"]! += 1
            }
            if tile.uncropped { counts["uncropped"]! += 1 }
        }
        return counts
    }

    private enum Keys: String, CodingKey {
        case source, documentKind, documentName, page, pages, total, nextPage, sheet, tiles, counts, renderedAt, limitation
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(Self.source, forKey: .source)
        try container.encode(documentKind, forKey: .documentKind)
        try container.encode(documentName, forKey: .documentName)
        try container.encode(page, forKey: .page)
        try container.encode(pages, forKey: .pages)
        try container.encode(total, forKey: .total)
        try container.encodeIfPresent(nextPage, forKey: .nextPage)
        try container.encodeIfPresent(sheet, forKey: .sheet)
        try container.encode(tiles, forKey: .tiles)
        try container.encode(counts, forKey: .counts)
        try container.encode(renderedAt, forKey: .renderedAt)
        try container.encode(Self.limitation, forKey: .limitation)
    }
}

public enum ContactSheet {
    /// Outside the document: writing near a read-only document would be a write the photographer did not enable.
    public static var defaultDirectory: URL {
        CacheFolder.contactSheets.url
    }
    static let retainedSheets = 50

    package static func fileName(documentName: String, documentId: String, scope: SheetScope, layout: SheetLayout, page: Int) -> String {
        let key = [documentId, scope.canonical, "\(layout.perPage)x\(layout.rowHeight)"].joined(separator: "|")
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let stem = URL(fileURLWithPath: documentName).deletingPathExtension().lastPathComponent
        let number = String(page)
        return "\(stem)-\(digest)-p\(String(repeating: "0", count: max(0, 3 - number.count)) + number).jpg"
    }

    static let background = CGColor(srgbRed: 0x26 / 255, green: 0x26 / 255, blue: 0x26 / 255, alpha: 1)
    static let placeholder = CGColor(srgbRed: 0x3a / 255, green: 0x3a / 255, blue: 0x3a / 255, alpha: 1)
    static let amber = CGColor(srgbRed: 0xf2 / 255, green: 0xa3 / 255, blue: 0x1b / 255, alpha: 1)
    static let text = CGColor(srgbRed: 0.88, green: 0.88, blue: 0.88, alpha: 1)
    static let dimText = CGColor(srgbRed: 0.7, green: 0.7, blue: 0.7, alpha: 1)
    static let darkText = CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)

    package static func render(tiles: [ContactSheetTile], width: Int, height: Int, header: String) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        func flipped(_ r: PixelRect) -> CGRect { CGRect(x: r.x, y: height - r.y - r.height, width: r.width, height: r.height) }
        func fill(_ r: PixelRect, _ color: CGColor) { context.setFillColor(color); context.fill(flipped(r)) }
        func line(_ string: String, size: CGFloat, color: CGColor = text) -> (line: CTLine, font: CTFont, width: CGFloat) {
            let font = CTFontCreateUIFontForLanguage(.system, size, nil)!
            let attributes: [NSAttributedString.Key: Any] = [kCTFontAttributeName as NSAttributedString.Key: font, kCTForegroundColorAttributeName as NSAttributedString.Key: color]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
            return (line, font, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        }
        func fitted(_ string: String, size: CGFloat, width: Int, height: Int) -> CGFloat {
            max(1, min(size, size * CGFloat(width) / line(string, size: size).width, CGFloat(height) * 0.6))
        }
        func draw(_ string: String, in r: PixelRect, size: CGFloat, color: CGColor, centered: Bool = false) {
            let full = line(string, size: size, color: color)
            let truncated = CTLineCreateTruncatedLine(full.line, Double(r.width), .end, line("…", size: size, color: color).line) ?? full.line
            let lineWidth = CTLineGetTypographicBounds(truncated, nil, nil, nil)
            let box = flipped(r)
            context.textPosition = CGPoint(x: centered ? box.midX - lineWidth / 2 : box.minX,
                                           y: box.midY - (CTFontGetAscent(full.font) - CTFontGetDescent(full.font)) / 2)
            CTLineDraw(truncated, context)
        }
        fill(PixelRect(x: 0, y: 0, width: width, height: height), background)
        draw(header, in: PixelRect(x: SheetLayout.gutter, y: 0, width: width - 2 * SheetLayout.gutter, height: SheetLayout.headerHeight),
             size: 12, color: text)
        context.interpolationQuality = .high
        for tile in tiles {
            let cell = tile.cell
            switch tile.content {
            case .shown(let thumbnail):
                context.draw(thumbnail.image.cropping(to: thumbnail.visibleRect) ?? thumbnail.image, in: flipped(cell))
                if tile.uncropped {
                    let size = fitted("UNCROPPED", size: 11, width: cell.width - 6, height: cell.height)
                    let badge = PixelRect(x: cell.x, y: cell.y, width: min(cell.width, Int(line("UNCROPPED", size: size).width.rounded(.up)) + 6),
                                          height: min(cell.height, Int((size * 1.6).rounded(.up))))
                    fill(badge, amber)
                    draw("UNCROPPED", in: badge, size: size, color: darkText, centered: true)
                }
            case .missing(let reason):
                fill(cell, placeholder)
                let text = reason == .notStored ? "NOT SAVED" : "NO CACHE"
                draw(text, in: cell, size: fitted(text, size: 15, width: cell.width - 8, height: cell.height), color: dimText, centered: true)
            case .unreadable:
                fill(cell, placeholder)
                draw("UNREADABLE", in: cell, size: fitted("UNREADABLE", size: 15, width: cell.width - 8, height: cell.height), color: dimText, centered: true)
            }
            let member = tile.member
            draw("\(member.id) · ★\(member.rating) · \(member.name)", in: SheetLayout.label(below: cell), size: 11, color: text)
        }
        return context.makeImage()!
    }

    package static func write(_ image: CGImage, to directory: URL, fileName: String) throws -> SheetImage {
        let jpeg = NSMutableData()
        let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw C1Error.invalidRequest("The contact sheet could not be encoded.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(fileName)
        try (jpeg as Data).write(to: file, options: .atomic)
        prune(directory, keeping: file)
        return SheetImage(path: file.path, width: image.width, height: image.height)
    }

    private static func prune(_ directory: URL, keeping current: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let sheets = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? [])
            .filter { $0.pathExtension == "jpg" && $0.lastPathComponent != current.lastPathComponent }
            .compactMap { url -> (url: URL, modified: Date)? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
                return (url, values.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.modified > $1.modified }
        for sheet in sheets.dropFirst(retainedSheets - 1) { try? FileManager.default.removeItem(at: sheet.url) }
    }
}

extension SessionController {
    public func contactSheet(scope: SheetScope, page: Int = 1, layout: SheetLayout = .standard,
                             directory: URL = ContactSheet.defaultDirectory) throws -> ContactSheetResult {
        guard page >= 1 else { throw C1Error.invalidRequest("page must be at least 1.") }
        let context = RequestContext.current
        let (document, total, shown, contents) = try lock.withLock(checkpoint: { try context?.checkReadCancellation() }) {
            () throws -> (DocumentInfo, Int, [SheetMember], [TileContent]) in
            let document = try getDocumentInfo()
            guard document.appVersion == Self.pinnedBuild else {
                throw C1Error.unsupportedVersion("contact_sheet reads Capture One's thumbnail cache, whose layout is qualified only on \(Self.pinnedBuild); C1_ALLOW_UNTESTED_BUILD does not enable it.")
            }
            let members = try sheetMembers(scope)
            let first = (page - 1) * layout.perPage
            guard members.isEmpty || first < members.count else {
                throw C1Error.invalidRequest("page \(page) is past the last page; the scope has \(members.count) variants in \((members.count + layout.perPage - 1) / layout.perPage) pages.")
            }
            let shown = Array(members.dropFirst(first).prefix(layout.perPage))
            context?.update(phase: "thumbnails", total: shown.count)
            let contents = try thumbnails(shown, document: document)
            let after = try getDocumentInfo()
            guard after.openToken == document.openToken, after.documentId == document.documentId else {
                throw C1Error.documentChanged("The document changed while thumbnails were read; no sheet was made.")
            }
            return (document, members.count, shown, contents)
        }
        let arrangement = layout.arrange(contents.map(\.aspect))
        let tiles = zip(shown, zip(arrangement.cells, contents)).map { ContactSheetTile(member: $0, cell: $1.0, content: $1.1) }
        let pages = (total + layout.perPage - 1) / layout.perPage
        let renderedAt = ISO8601DateFormatter().string(from: now())
        var sheet: SheetImage?
        if !tiles.isEmpty {
            let first = (page - 1) * layout.perPage
            let header = "\(document.documentName) · page \(page)/\(pages) · \(first + 1)–\(first + tiles.count) of \(total) · Capture One thumbnail cache · \(renderedAt)"
            sheet = try ContactSheet.write(ContactSheet.render(tiles: tiles, width: arrangement.width, height: arrangement.height, header: header), to: directory,
                                           fileName: ContactSheet.fileName(documentName: document.documentName, documentId: document.documentId,
                                                                           scope: scope, layout: layout, page: page))
        }
        return ContactSheetResult(documentKind: document.isSession ? "session" : "catalog", documentName: document.documentName,
                                  page: page, pages: pages, total: total, nextPage: page < pages ? page + 1 : nil,
                                  sheet: sheet, tiles: tiles, renderedAt: renderedAt)
    }

    private func sheetMembers(_ scope: SheetScope) throws -> [SheetMember] {
        if let ids = scope.ids {
            return try listVariantSubset(ids: ids, collection: scope.collection, selected: scope.selected, rating: scope.rating,
                                         minRating: scope.minRating, fields: "summary").map { row in
                SheetMember(id: row["id"] as! String, name: row["name"] as! String, rating: row["rating"] as! Int,
                            parentImagePath: row["parentImagePath"] as! String)
            }
        }
        return try listVariants(collectionName: scope.collection, selectedOnly: scope.selected, rating: scope.rating, minRating: scope.minRating)
            .map { SheetMember(id: $0.id, name: $0.name, rating: $0.rating, parentImagePath: $0.parentImagePath) }
    }

    private func thumbnails(_ members: [SheetMember], document: DocumentInfo) throws -> [TileContent] {
        guard !members.isEmpty else { return [] }
        let database = try databasePath(document)
        let ids = try members.map { try ThumbnailCache.storedID($0.id) }
        let locations: [URL?]
        if document.isSession {
            let keys = try CatalogReader(sessionDatabase: database).sessionThumbnailKeys(variantIDs: ids)
            locations = try zip(members, ids).map { member, id in
                try keys[id].map { try ThumbnailCache.sessionThumbnail(parentImagePath: member.parentImagePath, key: $0) }
            }
        } else {
            locations = ids.map { ThumbnailCache.catalogThumbnail(databasePath: database, variantID: $0) }
        }
        return locations.map { $0.map { ThumbnailCache.read($0) } ?? .missing(.notStored) }
    }
}
