import Foundation

public struct ListQuery: Codable, Equatable {
    public var rating: Int?
    public var minRating: Int?
    public var colorTag: Int?
    public var collection: CollectionID?
    public var ids: [VariantID]?
    public var edited: Bool?
    public var after: VariantID?
    public var limit: Int?

    public static let defaultLimit = 100
    public static let maxLimit = 1000

    public init(rating: Int? = nil, minRating: Int? = nil, colorTag: Int? = nil, collection: CollectionID? = nil,
                ids: [VariantID]? = nil, edited: Bool? = nil, after: VariantID? = nil, limit: Int? = nil) {
        self.rating = rating; self.minRating = minRating; self.colorTag = colorTag; self.collection = collection
        self.ids = ids; self.edited = edited; self.after = after; self.limit = limit
    }

    func validate() throws {
        for (name, value) in [("rating", rating), ("minRating", minRating)] {
            if let value, !(0...5).contains(value) { throw C1Failure(.invalidArguments, "\(name) must be 0–5, got \(value).") }
        }
        if let colorTag, !(0...7).contains(colorTag) { throw C1Failure(.invalidArguments, "colorTag must be 0–7, got \(colorTag).") }
        if let limit, !(1...Self.maxLimit).contains(limit) { throw C1Failure(.invalidArguments, "limit must be 1–\(Self.maxLimit), got \(limit).") }
    }
}

public struct VariantRow: Codable, Equatable {
    public let id: VariantID
    public let name: String?
    /// The original's absolute path, when it is a referenced file outside the Catalog.
    public let path: String?
    public let rating: Int
    public let colorTag: Int
    /// nil when a settings layer is missing, so the comparison cannot be made.
    public let edited: Bool?
    public let folder: CollectionID?
}

public struct CollectionRow: Codable, Equatable {
    public enum Kind: String, Codable { case album, smartAlbum, folder, project, group, favorite, allImages, other }
    public let id: CollectionID
    public let name: String?
    public let kind: Kind
    public let parent: CollectionID?
    public let variantCount: Int?
}

/// Capture One's database, read-only. It lags Capture One by about a minute.
public final class Database {
    public let kind: DocumentKind
    private let sql: SQLiteConnection
    private let root: CollectionID?

    /// Every table and column c1 reads. The open fails, naming what is missing, when Capture One changes them.
    static let requiredSchema: [String: [String]] = [
        "ZDOCUMENTCONTENT": ["ZDOCUMENTTYPE", "ZROOTCOLLECTION"],
        "ZVARIANT": ["Z_PK", "ZIMAGE", "ZDEFAULTLAYER", "ZCOMBINEDSETTINGS"],
        "ZIMAGE": ["Z_PK", "ZDISPLAYNAME", "ZIMAGEFILENAME", "ZIMAGELOCATION", "ZISINSIDECATALOG"],
        "ZPATHLOCATION": ["Z_PK", "ZMACROOT", "ZRELATIVEPATH", "ZISRELATIVE"],
        "ZVARIANTLAYER": ["Z_PK", "ZMETADATA"],
        "ZVARIANTMETADATA": ["Z_PK", "ZBASIC_RATING", "ZCOLOR_TAG_INDEX"],
        "ZCOLLECTION": ["Z_PK", "Z_ENT", "ZNAME", "ZPARENT", "ZFOLDERLOCATION", "ZSMARTCRITERIA", "ZALLIMAGESCOLLECTION"],
        "ZENTITIES": ["Z_ENT", "ZNAME"],
        "ZVARIANTINCOLLECTION": ["ZCOLLECTION", "ZVARIANT"],
    ]
    /// Layer columns that are not settings; "edited" compares all others. Capture One fills
    /// ZCALCULATEDDEHAZECOLOR when it first renders a variant, so it differs on unedited variants.
    static let ignoredLayerColumns: Set = ["Z_PK", "Z_ENT", "ZINDEX", "ZVARIANT", "ZMETADATA", "ZCALCULATEDDEHAZECOLOR"]
    static let folderEntities = ["CatalogFolderCollection", "SessionFolderCollection"]

    public init(path: String) throws {
        sql = try SQLiteConnection(readOnly: path)
        try Self.checkSchema(sql)
        let content = try sql.rows("SELECT ZDOCUMENTTYPE AS type, ZROOTCOLLECTION AS root FROM ZDOCUMENTCONTENT")
        guard content.count == 1, let type = content[0]["type"]?.int else {
            throw C1Failure(.database, "Expected one ZDOCUMENTCONTENT row in \(path), found \(content.count).")
        }
        kind = type == 1 ? .catalog : .session
        root = content[0]["root"]?.int.map(CollectionID.init)
    }

    static func checkSchema(_ sql: SQLiteConnection) throws {
        var missing: [String] = []
        for (table, columns) in requiredSchema.sorted(by: { $0.key < $1.key }) {
            let present = Set(try sql.rows("SELECT name FROM pragma_table_info(?)", [.text(table)]).compactMap { $0["name"]?.text })
            if present.isEmpty { missing.append(table); continue }
            missing += columns.filter { !present.contains($0) }.map { "\(table).\($0)" }
        }
        guard missing.isEmpty else {
            throw C1Failure(.schemaMismatch, "This Capture One database lacks what c1 reads: \(missing.joined(separator: ", ")).",
                            hint: "This Capture One version changed its database; c1 needs an update.")
        }
    }

    // MARK: Routes

    /// The folder collection (Catalog) or favorite (Session) holding each variant's image, when one exists.
    public func routes(for ids: [VariantID]) throws -> [VariantID: CollectionID] {
        guard !ids.isEmpty else { return [:] }
        let folders = try folderByLocation()
        let rows = try sql.rows("""
            SELECT v.Z_PK AS id, i.ZIMAGELOCATION AS location FROM ZVARIANT v JOIN ZIMAGE i ON i.Z_PK=v.ZIMAGE
            WHERE v.Z_PK IN (\(ids.map(\.description).joined(separator: ",")))
            """)
        var output: [VariantID: CollectionID] = [:]
        for row in rows {
            if let id = row["id"]?.int, let location = row["location"]?.int, let folder = folders[location] {
                output[VariantID(id)] = folder
            }
        }
        return output
    }

    /// The Catalog's All Images collection.
    public func allImagesCollection() throws -> CollectionID? {
        guard let root else { return nil }
        return try sql.rows("SELECT ZALLIMAGESCOLLECTION AS id FROM ZCOLLECTION WHERE Z_PK=?", [.int(root.value)])
            .first?["id"]?.int.map(CollectionID.init)
    }

    /// Maps each path location to the folder collection that shows it. Locations match by row or by
    /// resolved path, because a Session favorite and the Session's own folders are separate rows.
    private func folderByLocation() throws -> [Int64: CollectionID] {
        let paths = try locationPaths()
        let folders = try sql.rows("""
            SELECT c.Z_PK AS id, c.ZFOLDERLOCATION AS location FROM ZCOLLECTION c JOIN ZENTITIES e ON e.Z_ENT=c.Z_ENT
            WHERE e.ZNAME IN ('\(Self.folderEntities.joined(separator: "','"))') AND c.ZFOLDERLOCATION IS NOT NULL ORDER BY c.Z_PK
            """)
        var byPath: [String: CollectionID] = [:]
        var output: [Int64: CollectionID] = [:]
        for row in folders {
            guard let id = row["id"]?.int, let location = row["location"]?.int else { continue }
            if output[location] == nil { output[location] = CollectionID(id) }
            if let path = paths[location], byPath[path] == nil { byPath[path] = CollectionID(id) }
        }
        for (location, path) in paths where output[location] == nil {
            output[location] = byPath[path]
        }
        return output
    }

    /// Absolute folder paths of path locations; relative ones resolve against the database's folder.
    private func locationPaths() throws -> [Int64: String] {
        let base = URL(fileURLWithPath: sql.path).deletingLastPathComponent()
        var paths: [Int64: String] = [:]
        for row in try sql.rows("SELECT Z_PK AS id, ZMACROOT AS root, ZRELATIVEPATH AS relative, ZISRELATIVE AS isRelative FROM ZPATHLOCATION") {
            guard let id = row["id"]?.int else { continue }
            let relative = row["relative"]?.text ?? ""
            if row["isRelative"]?.int == 1 {
                paths[id] = base.appendingPathComponent(relative).standardizedFileURL.path
            } else if let root = row["root"]?.text, root.hasPrefix("/") {
                paths[id] = URL(fileURLWithPath: root).appendingPathComponent(relative).standardizedFileURL.path
            }
        }
        return paths
    }

    // MARK: List

    public func list(_ query: ListQuery) throws -> (rows: [VariantRow], next: VariantID?) {
        try query.validate()
        var predicates: [String] = []
        if let rating = query.rating { predicates.append("rating=\(rating)") }
        if let minRating = query.minRating { predicates.append("rating>=\(minRating)") }
        if let colorTag = query.colorTag { predicates.append("colorTag=\(colorTag)") }
        if let ids = query.ids {
            guard !ids.isEmpty else { return ([], nil) }
            predicates.append("id IN (\(ids.map(\.description).joined(separator: ",")))")
        }
        if let edited = query.edited { predicates.append("edited=\(edited ? 1 : 0)") }
        if let after = query.after { predicates.append("id>\(after)") }
        if let collection = query.collection { predicates.append(try membership(collection)) }

        let settingColumns = try sql.rows("SELECT name FROM pragma_table_info('ZVARIANTLAYER') ORDER BY cid")
            .compactMap { $0["name"]?.text }.filter { !Self.ignoredLayerColumns.contains($0) }
        let differs = settingColumns.map { "d.\"\($0)\" IS NOT l.\"\($0)\"" }.joined(separator: " OR ")
        let limit = query.limit ?? ListQuery.defaultLimit
        let rows = try sql.rows("""
            SELECT * FROM (
                SELECT v.Z_PK AS id, i.ZDISPLAYNAME AS name, i.ZIMAGEFILENAME AS filename, i.ZIMAGELOCATION AS location,
                       i.ZISINSIDECATALOG AS inside, p.ZMACROOT AS root, p.ZRELATIVEPATH AS relative, p.ZISRELATIVE AS isRelative,
                       COALESCE(m.ZBASIC_RATING,0) AS rating, COALESCE(m.ZCOLOR_TAG_INDEX,0) AS colorTag,
                       CASE WHEN d.Z_PK IS NULL OR l.Z_PK IS NULL THEN NULL WHEN \(differs.isEmpty ? "0" : differs) THEN 1 ELSE 0 END AS edited
                FROM ZVARIANT v JOIN ZIMAGE i ON i.Z_PK=v.ZIMAGE
                LEFT JOIN ZPATHLOCATION p ON p.Z_PK=i.ZIMAGELOCATION
                LEFT JOIN ZVARIANTLAYER l ON l.Z_PK=v.ZCOMBINEDSETTINGS
                LEFT JOIN ZVARIANTLAYER d ON d.Z_PK=v.ZDEFAULTLAYER
                LEFT JOIN ZVARIANTMETADATA m ON m.Z_PK=l.ZMETADATA)
            \(predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND "))
            ORDER BY id LIMIT \(limit + 1)
            """)
        let folders = try folderByLocation()
        let page = rows.prefix(limit).map { row -> VariantRow in
            var path: String?
            if row["inside"]?.int == 0, row["isRelative"]?.int == 0, let root = row["root"]?.text, root.hasPrefix("/"),
               let relative = row["relative"]?.text, let filename = row["filename"]?.text {
                path = URL(fileURLWithPath: root).appendingPathComponent(relative).appendingPathComponent(filename).standardizedFileURL.path
            }
            return VariantRow(id: VariantID(row["id"]!.int!), name: row["name"]?.text, path: path,
                              rating: Int(row["rating"]?.int ?? 0), colorTag: Int(row["colorTag"]?.int ?? 0),
                              edited: row["edited"]?.int.map { $0 == 1 }, folder: row["location"]?.int.flatMap { folders[$0] })
        }
        return (Array(page), rows.count > limit ? page.last?.id : nil)
    }

    /// The SQL predicate for membership in a collection. Albums use variant rows only (#44):
    /// image rows expand to every variant of the image, which is wrong for albums built with `add inside`.
    private func membership(_ collection: CollectionID) throws -> String {
        let all = try collectionRows()
        guard let row = all.first(where: { $0.id == collection }) else {
            throw C1Failure(.invalidArguments, "No collection \(collection) in this document.")
        }
        switch row.kind {
        case .album:
            return "EXISTS(SELECT 1 FROM ZVARIANTINCOLLECTION vc WHERE vc.ZCOLLECTION=\(collection) AND vc.ZVARIANT=id)"
        case .folder, .favorite:
            let locations = folderLocations(under: collection, in: all, folders: try folderByLocation())
            return locations.isEmpty ? "0" : "location IN (\(locations.map(String.init).joined(separator: ",")))"
        case .allImages:
            return "1"
        case .smartAlbum:
            throw C1Failure(.invalidArguments, "Collection \(collection) is a smart album; c1 does not evaluate smart album rules.",
                            hint: "List an album, folder or All Images instead, and filter with rating, minRating, colorTag or edited.")
        case .project, .group, .other:
            throw C1Failure(.invalidArguments, "Collection \(collection) (\(row.kind.rawValue)) does not hold variants directly.",
                            hint: "Choose an album, folder or favorite inside it.")
        }
    }

    /// Path locations of a folder and, recursively, its subfolders.
    private func folderLocations(under collection: CollectionID, in all: [Collection], folders: [Int64: CollectionID]) -> [Int64] {
        var subtree: Set = [collection]
        var grew = true
        while grew {
            grew = false
            for row in all where row.parent.map(subtree.contains) == true && !subtree.contains(row.id) {
                subtree.insert(row.id); grew = true
            }
        }
        return folders.filter { subtree.contains($0.value) }.map(\.key).sorted()
    }

    // MARK: Collections

    struct Collection { let id: CollectionID; let name: String?; let kind: CollectionRow.Kind; let parent: CollectionID? }

    private func collectionRows() throws -> [Collection] {
        let rows = try sql.rows("""
            SELECT c.Z_PK AS id, c.ZNAME AS name, e.ZNAME AS entity, c.ZPARENT AS parent, c.ZFOLDERLOCATION AS location,
                   COALESCE(c.ZSMARTCRITERIA,'')<>'' AS smart
            FROM ZCOLLECTION c LEFT JOIN ZENTITIES e ON e.Z_ENT=c.Z_ENT ORDER BY c.Z_PK
            """)
        let ids = Set(rows.compactMap { $0["id"]?.int })
        let paths = try locationPaths()
        return rows.compactMap { row in
            guard let id = row["id"]?.int.map(CollectionID.init), id != root else { return nil }
            let parent = row["parent"]?.int.flatMap { ids.contains($0) ? CollectionID($0) : nil }
            // Catalog folder collections have no name; Capture One shows the folder's.
            let folderName = row["location"]?.int.flatMap { paths[$0] }.map { URL(fileURLWithPath: $0).lastPathComponent }
            return Collection(id: id, name: row["name"]?.text ?? folderName,
                              kind: Self.kind(entity: row["entity"]?.text, smart: row["smart"]?.int == 1),
                              parent: parent == root ? nil : parent)
        }
    }

    static func kind(entity: String?, smart: Bool) -> CollectionRow.Kind {
        if smart { return .smartAlbum }
        switch entity {
        case "AlbumCollection": return .album
        case "SmartCollection": return .smartAlbum
        case "CatalogFolderCollection": return .folder
        case "SessionFolderCollection": return .favorite
        case "ProjectCollection": return .project
        case "GroupCollection": return .group
        case "CatalogAllImagesCollection": return .allImages
        default: return .other
        }
    }

    public func collections() throws -> [CollectionRow] {
        let all = try collectionRows()
        var albumCounts: [Int64: Int] = [:]
        for row in try sql.rows("SELECT ZCOLLECTION AS id, COUNT(*) AS n FROM ZVARIANTINCOLLECTION GROUP BY ZCOLLECTION") {
            if let id = row["id"]?.int { albumCounts[id] = Int(row["n"]?.int ?? 0) }
        }
        var locationCounts: [Int64: Int] = [:]
        for row in try sql.rows("SELECT i.ZIMAGELOCATION AS location, COUNT(*) AS n FROM ZVARIANT v JOIN ZIMAGE i ON i.Z_PK=v.ZIMAGE GROUP BY 1") {
            if let location = row["location"]?.int { locationCounts[location] = Int(row["n"]?.int ?? 0) }
        }
        let total = locationCounts.values.reduce(0, +)
        let folders = try folderByLocation()
        return all.map { row in
            let count: Int?
            switch row.kind {
            case .album: count = albumCounts[row.id.value] ?? 0
            case .folder, .favorite: count = folderLocations(under: row.id, in: all, folders: folders).reduce(0) { $0 + (locationCounts[$1] ?? 0) }
            case .allImages: count = total
            default: count = nil
            }
            return CollectionRow(id: row.id, name: row.name, kind: row.kind, parent: row.parent, variantCount: count)
        }
    }
}
