import C1Kit
import Foundation

/// A small Catalog database with only the columns c1 reads.
enum Fixture {
    static let uuid = "0A1B2C3D-0000-4000-8000-000000000001"

    static let schema = """
        CREATE TABLE ZDOCUMENTCONTENT (Z_PK INTEGER PRIMARY KEY, ZDOCUMENTTYPE INTEGER, ZROOTCOLLECTION INTEGER, ZDOCUMENTUUID VARCHAR, ZLASTBACKUPDATE TIMESTAMP);
        CREATE TABLE ZENTITIES (Z_ENT INTEGER PRIMARY KEY, ZNAME VARCHAR);
        CREATE TABLE ZCOLLECTION (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZNAME VARCHAR, ZPARENT INTEGER, ZFOLDERLOCATION INTEGER, ZSMARTCRITERIA VARCHAR, ZALLIMAGESCOLLECTION INTEGER);
        CREATE TABLE ZPATHLOCATION (Z_PK INTEGER PRIMARY KEY, ZMACROOT VARCHAR, ZRELATIVEPATH VARCHAR, ZISRELATIVE BOOLEAN);
        CREATE TABLE ZIMAGE (Z_PK INTEGER PRIMARY KEY, ZDISPLAYNAME VARCHAR, ZIMAGEFILENAME VARCHAR, ZIMAGELOCATION INTEGER, ZISINSIDECATALOG BOOLEAN, ZISTRASHED BOOLEAN);
        CREATE TABLE ZVARIANT (Z_PK INTEGER PRIMARY KEY, ZIMAGE INTEGER, ZDEFAULTLAYER INTEGER, ZCOMBINEDSETTINGS INTEGER, ZVARIANTUUID VARCHAR);
        CREATE TABLE ZVARIANTLAYER (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZINDEX INTEGER, ZVARIANT INTEGER, ZMETADATA INTEGER, ZEXPOSURE FLOAT, ZCALCULATEDDEHAZECOLOR VARCHAR);
        CREATE TABLE ZVARIANTMETADATA (Z_PK INTEGER PRIMARY KEY, ZBASIC_RATING INTEGER, ZCOLOR_TAG_INDEX INTEGER);
        CREATE TABLE ZVARIANTINCOLLECTION (Z_PK INTEGER PRIMARY KEY, ZCOLLECTION INTEGER, ZVARIANT INTEGER);
        CREATE TABLE ZIMAGEINCOLLECTION (Z_PK INTEGER PRIMARY KEY, ZCOLLECTION INTEGER, ZIMAGE INTEGER);
        """

    static func data(documentType: Int) -> String {
        """
        INSERT INTO ZDOCUMENTCONTENT VALUES (1, \(documentType), 1, '\(uuid)', NULL);
        INSERT INTO ZENTITIES VALUES (2,'AlbumCollection'),(5,'SmartCollection'),(7,'ProjectCollection'),
            (36,'CatalogFolderCollection'),(40,'CatalogAllImagesCollection'),(52,'SessionFolderCollection');
        INSERT INTO ZCOLLECTION VALUES
            (1,7,'root',NULL,NULL,NULL,2),
            (2,40,'All Images',1,NULL,NULL,NULL),
            (10,\(documentType == 1 ? 36 : 52),NULL,99,100,NULL,NULL),
            (11,\(documentType == 1 ? 36 : 52),NULL,10,101,NULL,NULL),
            (20,2,'Picks',1,NULL,NULL,NULL),
            (21,5,'Smart',1,NULL,'rating>3',NULL),
            (22,2,'Ruled album',1,NULL,'x',NULL);
        INSERT INTO ZPATHLOCATION VALUES (100,'/','photos',0),(101,'/','photos/sub',0),(102,'/','elsewhere',0);
        INSERT INTO ZIMAGE VALUES (1,'a','a.CR3',100,0,0),(2,'b','b.CR3',101,0,0),(3,'c','c.CR3',102,0,0),(4,'t','t.CR3',100,0,1);
        INSERT INTO ZVARIANT VALUES (1,1,11,12,'AAAAAAAA-0000-4000-8000-000000000001'),(2,1,21,22,'AAAAAAAA-0000-4000-8000-000000000002'),
            (3,2,31,32,'AAAAAAAA-0000-4000-8000-000000000003'),(4,3,41,42,'AAAAAAAA-0000-4000-8000-000000000004'),(5,4,41,42,NULL);
        INSERT INTO ZVARIANTLAYER VALUES
            (11,1,0,1,NULL,0,'0;0;0'),(12,1,0,1,1,0.5,'0;0;0'),
            (21,1,0,2,NULL,0,'0;0;0'),(22,1,0,2,2,0,'0.1;0.2;0.3'),
            (31,1,0,3,NULL,0,NULL),(32,1,0,3,3,0,NULL),
            (41,1,0,4,NULL,0,NULL),(42,1,0,4,4,-1,NULL);
        INSERT INTO ZVARIANTMETADATA VALUES (1,5,1),(2,3,0),(3,0,NULL),(4,5,2);
        INSERT INTO ZVARIANTINCOLLECTION VALUES (1,20,2),(2,22,1);
        INSERT INTO ZIMAGEINCOLLECTION VALUES (1,20,1);
        """
    }

    /// Writes the database with the sqlite3 tool; c1 itself only ever opens databases read-only.
    static func make(_ name: String, documentType: Int = 1, extraSQL: String = "") -> String {
        let path = scratchDirectory(name).appendingPathComponent("\(name).cocatalogdb").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path, schema + data(documentType: documentType) + extraSQL]
        try! process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "sqlite3 failed building \(path)")
        return path
    }
}

enum DatabaseTests {
    static func run() {
        let database = try! Database(path: Fixture.make("catalog"))
        listing(database)
        membership(database)
        routes(database)
        collections(database)
        schemaFailure()
    }

    static func page(_ database: Database, _ query: ListQuery) -> [String] {
        (try? database.list(query).rows.map(\.id.description)) ?? ["error"]
    }

    static func listing(_ database: Database) {
        checkEqual(database.kind, .catalog)
        let first = try! database.list(ListQuery(limit: 2))
        checkEqual(first.rows.map(\.id.description), ["1", "2"], "first page")
        checkEqual(first.next, id("2"), "next cursor")
        let second = try! database.list(ListQuery(after: first.next, limit: 2))
        checkEqual(second.rows.map(\.id.description), ["3", "4"], "second page")
        checkEqual(second.next, nil, "no cursor after the last page")

        checkEqual(page(database, ListQuery(minRating: 5)), ["1", "4"], "minRating")
        checkEqual(page(database, ListQuery(rating: 3)), ["2"], "rating")
        checkEqual(page(database, ListQuery(colorTag: 2)), ["4"], "colorTag")
        checkEqual(page(database, ListQuery(colorTag: 0)), ["2", "3"], "colorTag 0 includes a missing tag")
        checkEqual(page(database, ListQuery(ids: [id("4"), id("1"), id("99")])), ["1", "4"], "ids")
        checkEqual(page(database, ListQuery(edited: true)), ["1", "4"], "edited ignores the computed dehaze color")
        checkEqual(page(database, ListQuery(edited: false)), ["2", "3"], "unedited")

        let rows = try! database.list(ListQuery()).rows
        checkEqual(rows[0].path, "/photos/a.CR3", "referenced original path")
        checkEqual(rows.map { $0.folder?.description ?? "-" }, ["10", "10", "11", "-"], "folder per variant")
        checkEqual(rows[0].rating, 5); checkEqual(rows[0].colorTag, 1)
        checkFailure(.invalidArguments, containing: "limit") { _ = try database.list(ListQuery(limit: 1001)) }
        checkFailure(.invalidArguments, containing: "rating") { _ = try database.list(ListQuery(rating: 6)) }
    }

    static func membership(_ database: Database) {
        checkEqual(page(database, ListQuery(collection: cid("20"))), ["2"], "album membership uses variant rows only (#44)")
        checkEqual(page(database, ListQuery(collection: cid("10"))), ["1", "2", "3"], "a folder includes its subfolders")
        checkEqual(page(database, ListQuery(collection: cid("11"))), ["3"], "subfolder")
        checkEqual(page(database, ListQuery(collection: cid("2"))), ["1", "2", "3", "4"], "All Images")
        checkEqual(page(database, ListQuery(minRating: 5, collection: cid("10"))), ["1"], "filters combine")
        checkFailure(.invalidArguments, containing: "smart album") { _ = try database.list(ListQuery(collection: cid("21"))) }
        checkFailure(.invalidArguments, containing: "smart album") { _ = try database.list(ListQuery(collection: cid("22"))) }
        checkFailure(.invalidArguments, containing: "No collection") { _ = try database.list(ListQuery(collection: cid("77"))) }
    }

    static func routes(_ database: Database) {
        let routes = try! database.routes(for: [id("1"), id("2"), id("3"), id("4"), id("99")])
        checkEqual(routes, [id("1"): cid("10"), id("2"): cid("20"), id("3"): cid("11")],
                   "the smallest collection: an album of 1 beats a folder tree of 3, a smart album never counts; none without a collection")
        checkEqual(database.documentUUID, Fixture.uuid)
        checkEqual(database.lastBackup, nil, "never backed up")
        let backedUp = try! Database(path: Fixture.make("backed-up", extraSQL: "UPDATE ZDOCUMENTCONTENT SET ZLASTBACKUPDATE=1793494313.94;"))
        checkEqual(backedUp.lastBackup, Date(timeIntervalSince1970: 1793494313.94), "ZLASTBACKUPDATE counts Unix seconds")
        checkEqual(try! database.allImagesCollection(), cid("2"))

        let session = try! Database(path: Fixture.make("session", documentType: 0))
        checkEqual(session.kind, .session)
        checkEqual(try! session.routes(for: [id("3")]), [id("3"): cid("11")], "Session favorite route")
    }

    static func collections(_ database: Database) {
        let rows = try! database.collections()
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id.description, $0) })
        check(byID["1"] == nil, "the document root is not listed")
        checkEqual(byID["2"]?.kind, .allImages); checkEqual(byID["2"]?.variantCount, 4)
        checkEqual(byID["10"]?.kind, .folder); checkEqual(byID["10"]?.variantCount, 3)
        checkEqual(byID["10"]?.name, "photos", "a folder is named after its directory")
        checkEqual(byID["10"]?.parent, nil, "a parent outside the table is dropped")
        checkEqual(byID["11"]?.parent, cid("10")); checkEqual(byID["11"]?.variantCount, 1)
        checkEqual(byID["20"]?.kind, .album); checkEqual(byID["20"]?.variantCount, 1)
        checkEqual(byID["20"]?.parent, nil, "children of the root have no parent")
        checkEqual(byID["21"]?.kind, .smartAlbum); checkEqual(byID["21"]?.variantCount, nil)
        checkEqual(byID["22"]?.kind, .smartAlbum, "an album with rules is a smart album")
    }

    static func schemaFailure() {
        let path = Fixture.make("old-schema", extraSQL: "ALTER TABLE ZVARIANTMETADATA DROP COLUMN ZCOLOR_TAG_INDEX; DROP TABLE ZVARIANTINCOLLECTION;")
        checkFailure(.schemaMismatch, containing: "ZVARIANTINCOLLECTION, ZVARIANTMETADATA.ZCOLOR_TAG_INDEX") { _ = try Database(path: path) }
    }
}
