import Foundation
import CryptoKit
import CSQLite

/// Stored observations only. Never produces native references or concurrency tokens.
/// Use one reader per concurrent task; each operation owns a bounded read transaction.
public final class CatalogReader {
    private var db: OpaquePointer?
    private var deadline = ProcessInfo.processInfo.systemUptime + 10
    private var bytesRead = 0
    private let path: String
    private var fingerprint = ""
    private var documentUUID = ""
    private var observationStartedAt = ""
    private let fileIdentity: String
    public init(database: String) throws {
        guard database.hasPrefix("/"), !database.contains("\0") else { throw C1Error.invalidRequest("database must be an absolute filesystem path.") }
        let url = URL(fileURLWithPath: database).standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathExtension == "cocatalogdb", (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw C1Error.invalidRequest("An explicit regular .cocatalogdb file is required; Sessions are unsupported.")
        }
        path = url.path
        fileIdentity = try Self.identity(path)
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil
            throw C1Error.invalidRequest("Cannot open Catalog read-only.")
        }
        sqlite3_busy_timeout(db, 250)
        sqlite3_progress_handler(db, 1000, { context in
            let reader = Unmanaged<CatalogReader>.fromOpaque(context!).takeUnretainedValue()
            return ProcessInfo.processInfo.systemUptime > reader.deadline ? 1 : 0
        }, Unmanaged.passUnretained(self).toOpaque())
        do {
            try execute("PRAGMA query_only=ON")
            try execute("PRAGMA trusted_schema=OFF")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    private static func identity(_ path: String) throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        guard let device = attrs[.systemNumber] as? NSNumber, let inode = attrs[.systemFileNumber] as? NSNumber else {
            throw C1Error.invalidRequest("Cannot identify Catalog file.")
        }
        return "\(device):\(inode)"
    }
    private func execute(_ sql: String) throws { _ = try rows(sql) }
    private func endObservation() { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
    private func beginObservation() throws {
        guard try Self.identity(path) == fileIdentity else { throw C1Error.invalidRequest("Catalog file was replaced; open a new reader.") }
        deadline = ProcessInfo.processInfo.systemUptime + 10; bytesRead = 0
        observationStartedAt = ISO8601DateFormatter().string(from: Date())
        try execute("BEGIN")
        do { try validateSchema() } catch { endObservation(); throw error }
    }
    // Preserve quoted text and token boundaries; normalize only ASCII whitespace
    // and spacing around unambiguous DDL separators. Comments fail closed.
    private static func ddlTokens(_ sql: String) -> [String]? {
        let chars = Array(sql)
        var tokens: [String] = []
        var i = 0
        func whitespace(_ c: Character) -> Bool {
            c == " " || c == "\t" || c == "\r" || c == "\n" || c == "\r\n" || c == "\u{000B}" || c == "\u{000C}"
        }
        while i < chars.count {
            if whitespace(chars[i]) {
                let start = i
                while i < chars.count, whitespace(chars[i]) { i += 1 }
                // Preserve separation next to quotes too (e.g. X'AB' is a blob
                // literal whereas X 'AB' is two tokens).
                if start > 0, i < chars.count,
                   !"(),".contains(chars[start - 1]), !"(),".contains(chars[i]) { tokens.append(" ") }
                continue
            }
            let start = i
            let c = chars[i]
            if c == "'" || c == "\"" || c == "`" || c == "[" {
                let end: Character = c == "[" ? "]" : c
                i += 1
                var closed = false
                while i < chars.count {
                    if chars[i] == end {
                        i += 1
                        if c != "[", i < chars.count, chars[i] == end { i += 1; continue }
                        closed = true; break
                    }
                    i += 1
                }
                guard closed else { return nil }
            } else if "(),".contains(c) {
                i += 1
            } else {
                while i < chars.count, !whitespace(chars[i]), !"(),'\"`[".contains(chars[i]) {
                    if i + 1 < chars.count,
                       (chars[i] == "-" && chars[i + 1] == "-") || (chars[i] == "/" && chars[i + 1] == "*") { return nil }
                    i += 1
                }
            }
            tokens.append(String(chars[start..<i]))
        }
        return tokens
    }
    private static func compatibleSchema(_ schema: [[String: Any]], retained: String) -> Bool {
        var expected: [String: [String]] = [:]
        for line in retained.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 3).map(String.init)
            guard parts.count == 4, let tokens = ddlTokens(parts[3]) else { return false }
            expected[parts[0...2].joined(separator: "|")] = tokens
        }
        let statistics = ["sqlite_stat1": "CREATE TABLE sqlite_stat1(tbl,idx,stat)",
                          "sqlite_stat4": "CREATE TABLE sqlite_stat4(tbl,idx,neq,nlt,ndlt,sample)"]
        for row in schema {
            guard let type = row["type"] as? String, let name = row["name"] as? String,
                  let table = row["tbl_name"] as? String, let sql = row["sql"] as? String,
                  let tokens = ddlTokens(sql) else { return false }
            // Exempt only these exact SQLite-owned statistics definitions.
            if type == "table", table == name, let definition = statistics[name],
               tokens == ddlTokens(definition) { continue }
            guard expected.removeValue(forKey: [type, name, table].joined(separator: "|")) == tokens else { return false }
        }
        return expected.isEmpty
    }
    private func validateSchema() throws {
        let schema = try rows("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY type,name")
        let canonical = schema.map { row in ["type", "name", "tbl_name", "sql"].map { row[$0] as! String }.joined(separator: "|") }.joined(separator: "\n")
        fingerprint = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        var matchingHistories: [[[String: Any]]] = []
        for name in ["catalog-schema-16.8.5", "catalog-schema-upgraded-16.8.5"] {
            guard let resource = Bundle.module.url(forResource: name, withExtension: "json"),
                  let supported = try JSONSerialization.jsonObject(with: Data(contentsOf: resource)) as? [String: Any],
                  let retained = supported["schema"] as? String,
                  let history = supported["versionHistory"] as? [[String: Any]], !history.isEmpty else {
                throw C1Error.invalidRequest("The packaged Catalog schema manifest is unavailable or invalid.")
            }
            if Self.compatibleSchema(schema, retained: retained) { matchingHistories.append(history) }
        }
        guard !matchingHistories.isEmpty else {
            throw C1Error.invalidRequest("Unsupported Catalog schema: \(fingerprint).")
        }
        // Qualify the entire ordered history for the matching schema. Never select
        // MAX(version), ignore older rows, or mix a history with another manifest.
        let versions = try rows("SELECT ZVERSION,ZCOMPATIBLEVERSION,ZFORMAT FROM ZVERSIONINFO ORDER BY Z_PK")
        guard matchingHistories.contains(where: { NSArray(array: versions).isEqual(to: $0) }),
              try rows("SELECT ZDOCUMENTTYPE FROM ZDOCUMENTCONTENT").first?["ZDOCUMENTTYPE"] as? Int64 == 1 else {
            throw C1Error.invalidRequest("Unsupported Catalog schema: \(fingerprint).")
        }
        let documents = try rows("SELECT ZDOCUMENTUUID FROM ZDOCUMENTCONTENT")
        guard documents.count == 1, let uuid = documents.first?["ZDOCUMENTUUID"] as? String, !uuid.isEmpty else {
            throw C1Error.invalidRequest("Catalog requires exactly one stored document UUID.")
        }
        documentUUID = uuid
    }
    private func rows(_ sql: String) throws -> [[String: Any]] {
        guard ProcessInfo.processInfo.systemUptime <= deadline else { throw C1Error.invalidRequest("Catalog observation exceeded 10 seconds.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw C1Error.invalidRequest("Catalog SQL prepare failed.") }
        defer { sqlite3_finalize(statement) }
        var result: [[String: Any]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw C1Error.invalidRequest("Catalog read failed or timed out (SQLite \(status)).") }
            guard result.count < 10000 else { throw C1Error.invalidRequest("Catalog result exceeds 10000 records; no partial result returned.") }
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, i))
                let type = sqlite3_column_type(statement, i)
                let byteCount = Int(sqlite3_column_bytes(statement, i))
                bytesRead += byteCount
                guard bytesRead <= 64 * 1024 * 1024 else { throw C1Error.invalidRequest("Catalog result exceeds 64 MiB; no partial result returned.") }
                switch type {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, i)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, i)
                case SQLITE_TEXT:
                    let data = Data(bytes: sqlite3_column_text(statement, i), count: byteCount)
                    guard let text = String(data: data, encoding: .utf8) else { throw C1Error.invalidRequest("Catalog contains invalid UTF-8 text.") }
                    row[name] = text
                case SQLITE_BLOB:
                    row[name] = ["base64": Data(bytes: sqlite3_column_blob(statement, i), count: Int(sqlite3_column_bytes(statement, i))).base64EncodedString()]
                default: row[name] = NSNull()
                }
            }
            result.append(row)
        }
    }
    private func provenance() -> [String: Any] {
        ["databasePath": path, "databaseFileIdentity": fileIdentity, "databaseDocumentUUID": documentUUID, "schemaFingerprint": fingerprint, "readerVersion": 1,
         "observationStartedAt": observationStartedAt, "backend": "sqlite",
         "observedAt": ISO8601DateFormatter().string(from: Date()), "storedStateOnly": true,
         "limitation": "May lag Capture One. Database IDs are not native references. No live mutation tokens. Settings are raw stored layers; masks and originals are not embedded in snapshots."]
    }
    public func inspect() throws -> [String: Any] {
        try beginObservation()
        defer { endObservation() }
        var output = provenance()
        for (key, table) in [("document", "ZDOCUMENTCONTENT"), ("version", "ZVERSIONINFO"),
            ("collections", "ZCOLLECTION"), ("images", "ZIMAGE"), ("variants", "ZVARIANT"),
            ("imageMembership", "ZIMAGEINCOLLECTION"), ("variantMembership", "ZVARIANTINCOLLECTION"),
            ("pathLocations", "ZPATHLOCATION"), ("storedSettings", "ZVARIANTLAYER"), ("storedMetadata", "ZVARIANTMETADATA"),
            ("storedRetouching", "ZRETOUCHINGLAYER"), ("documentSettings", "ZDOCUMENTSETTING")] {
            output[key] = try rows("SELECT * FROM \(table) ORDER BY Z_PK")
        }
        guard try Self.identity(path) == fileIdentity else { throw C1Error.invalidRequest("Catalog file was replaced during observation.") }
        output.merge(provenance()) { _, fresh in fresh }
        return output
    }

    public func variants(collectionID: Int? = nil, rating: Int? = nil, minRating: Int? = nil) throws -> [String: Any] {
        var filters: [String: Any] = [:]
        if let rating { filters["rating"] = rating }; if let minRating { filters["minRating"] = minRating }
        try ContractSchema.validate(tool: "variants_list", arguments: filters)
        if let collectionID, collectionID <= 0 { throw C1Error.invalidRequest("collectionID must be positive.") }
        try beginObservation()
        defer { endObservation() }
        if let collectionID {
            let collections = try rows("SELECT Z_PK FROM ZCOLLECTION WHERE Z_PK=\(collectionID)")
            guard collections.count == 1 else { throw C1Error.invalidRequest("Unknown stored collection ID.") }
        }
        var predicates = ["1=1"]
        if let collectionID {
            predicates.append("(EXISTS(SELECT 1 FROM ZIMAGEINCOLLECTION ic WHERE ic.ZCOLLECTION=\(collectionID) AND ic.ZIMAGE=i.Z_PK) OR EXISTS(SELECT 1 FROM ZVARIANTINCOLLECTION vc WHERE vc.ZCOLLECTION=\(collectionID) AND vc.ZVARIANT=v.Z_PK))")
        }
        if let rating { predicates.append("m.ZBASIC_RATING=\(rating)") }
        if let minRating { predicates.append("m.ZBASIC_RATING>=\(minRating)") }
        var records = try rows("""
            SELECT v.Z_PK AS variantDatabaseID,v.ZVARIANTUUID AS variantUUID,
                   i.Z_PK AS imageDatabaseID,i.ZIMAGEUUID AS imageUUID,i.ZDISPLAYNAME AS name,
                   i.ZIMAGEFILENAME AS originalFilename,i.ZISINSIDECATALOG AS insideCatalog,
                   i.ZISTRASHED AS trashed,p.ZMACROOT AS macRoot,p.ZRELATIVEPATH AS relativePath,
                   p.ZISRELATIVE AS isRelative,m.ZBASIC_RATING AS rating,
                   COALESCE(m.ZCOLOR_TAG_INDEX,0) AS colorTag,v.ZCOMBINEDSETTINGS AS combinedSettingsID
            FROM ZVARIANT v JOIN ZIMAGE i ON i.Z_PK=v.ZIMAGE
            LEFT JOIN ZPATHLOCATION p ON p.Z_PK=i.ZIMAGELOCATION
            LEFT JOIN ZVARIANTLAYER l ON l.Z_PK=v.ZCOMBINEDSETTINGS
            LEFT JOIN ZVARIANTMETADATA m ON m.Z_PK=l.ZMETADATA
            WHERE \(predicates.joined(separator: " AND ")) ORDER BY v.Z_PK
            """)
        for index in records.indices {
            let record = records[index]
            records[index]["originalPath"] = NSNull()
            if record["insideCatalog"] as? Int64 == 0, record["isRelative"] as? Int64 == 0,
               let root = record["macRoot"] as? String, root.hasPrefix("/"),
               let relative = record["relativePath"] as? String, let filename = record["originalFilename"] as? String {
                records[index]["originalPath"] = URL(fileURLWithPath: root).appendingPathComponent(relative).appendingPathComponent(filename).standardizedFileURL.path
            }
        }
        guard try Self.identity(path) == fileIdentity else { throw C1Error.invalidRequest("Catalog file was replaced during observation.") }
        var output = provenance(); output["variants"] = records
        output["membershipSemantics"] = "Explicit stored image membership expands to all image variants; explicit variant membership includes only that variant. Virtual/smart collection rules are not evaluated. Unscoped reads include stored trashed records."
        if let collectionID { output["collectionID"] = collectionID }
        return output
    }

    struct Projection: Decodable {
        let id: Int64
        let name: String?
        let path: String?
        let rating: Int?
        let colorTag: Int?
        let exposure: Double?
        let contrast: Double?
        let saturation: Double?
    }
    func readProjection() throws -> [Projection] {
        try beginObservation(); defer { endObservation() }
        let records = try rows("""
            SELECT v.Z_PK AS id,i.ZDISPLAYNAME AS name,
            CASE WHEN i.ZISINSIDECATALOG=0 AND p.ZISRELATIVE=0 AND p.ZMACROOT='/'
                 THEN '/' || trim(p.ZRELATIVEPATH,'/') || '/' || i.ZIMAGEFILENAME ELSE NULL END AS path,
            m.ZBASIC_RATING AS rating,COALESCE(m.ZCOLOR_TAG_INDEX,0) AS colorTag,
            l.ZEXPOSURE AS exposure,l.ZCONTRAST AS contrast,l.ZSATURATION AS saturation
            FROM ZVARIANT v JOIN ZIMAGE i ON i.Z_PK=v.ZIMAGE
            LEFT JOIN ZPATHLOCATION p ON p.Z_PK=i.ZIMAGELOCATION
            LEFT JOIN ZVARIANTLAYER l ON l.Z_PK=v.ZCOMBINEDSETTINGS
            LEFT JOIN ZVARIANTMETADATA m ON m.Z_PK=l.ZMETADATA ORDER BY v.Z_PK
            """)
        guard try Self.identity(path) == fileIdentity else { throw C1Error.invalidRequest("Catalog replaced during observation.") }
        return try JSONDecoder().decode([Projection].self, from: JSONSerialization.data(withJSONObject: records))
    }

    /// Offline inspection: no Capture One lookup, native token, or warm-up required.
    public func get(variantID: Int) throws -> [String: Any] {
        guard variantID > 0 else { throw C1Error.invalidRequest("variantID must be positive.") }
        try beginObservation(); defer { endObservation() }
        guard let variant = try rows("SELECT * FROM ZVARIANT WHERE Z_PK=\(variantID)").first,
              let imageID = variant["ZIMAGE"] as? Int64 else { throw C1Error.variantNotFound("Stored variant not found.") }
        var result = provenance(); result["variant"] = variant
        result["image"] = try rows("SELECT * FROM ZIMAGE WHERE Z_PK=\(imageID)").first
        result["storedSettings"] = try rows("SELECT * FROM ZVARIANTLAYER WHERE ZVARIANT=\(variantID) ORDER BY Z_PK")
        result["storedMetadata"] = try rows("SELECT m.* FROM ZVARIANTMETADATA m JOIN ZVARIANTLAYER l ON l.ZMETADATA=m.Z_PK WHERE l.ZVARIANT=\(variantID) ORDER BY m.Z_PK")
        result["storedRetouching"] = try rows("SELECT * FROM ZRETOUCHINGLAYER WHERE ZVARIANT=\(variantID) ORDER BY Z_PK")
        guard try Self.identity(path) == fileIdentity else { throw C1Error.invalidRequest("Catalog replaced during observation.") }
        return result
    }

    public func snapshot(destination: String) throws -> [String: Any] {
        try beginObservation()
        defer { endObservation() }
        guard destination.hasPrefix("/"), !destination.contains("\0") else { throw C1Error.invalidRequest("destination must be an absolute filesystem path.") }
        let target = URL(fileURLWithPath: destination).standardizedFileURL
        guard !target.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents.contains(where: { $0.hasSuffix(".cocatalog") }) else {
            throw C1Error.invalidRequest("Store snapshots outside Catalog packages.")
        }
        guard target.pathExtension == "cocatalogdb" else { throw C1Error.invalidRequest("Snapshot must end in .cocatalogdb.") }
        // Reserve exclusively: never overwrite a database or a symlink.
        let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw C1Error.invalidRequest("Snapshot destination must be a new file.") }
        close(fd)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: target) } }
        var destinationDB: OpaquePointer?
        guard sqlite3_open_v2(target.path, &destinationDB, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(destinationDB); throw C1Error.invalidRequest("Cannot open snapshot destination.")
        }
        defer { sqlite3_close(destinationDB) }
        guard let backup = sqlite3_backup_init(destinationDB, "main", db, "main") else { throw C1Error.invalidRequest("Cannot initialize SQLite backup.") }
        var status: Int32 = SQLITE_OK
        repeat { status = sqlite3_backup_step(backup, 128) } while status == SQLITE_OK && ProcessInfo.processInfo.systemUptime <= deadline
        let finish = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE && finish == SQLITE_OK else { throw C1Error.invalidRequest("SQLite backup failed or exceeded deadline; no snapshot retained.") }
        endObservation()
        guard try Self.identity(path) == fileIdentity else { throw C1Error.invalidRequest("Catalog file was replaced during backup.") }
        complete = true
        var output = provenance(); output["snapshotPath"] = target.path
        return output
    }
}
