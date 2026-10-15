import Foundation
import CoreGraphics

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

package enum MissingReason: String {
    case notCached = "not-cached"
    /// Live in Capture One but not yet in the saved database, such as a clone before the save tick.
    case notStored = "not-stored"
}

package enum UnreadableReason: String {
    case undecodable
    /// The cache stores oriented pixels, so an orientation tag means an unknown format.
    case orientationTag = "orientation-tag"
    case changedDuringRead = "changed-during-read"
    case tooLarge = "too-large"
    case notRegularFile = "not-regular-file"
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
