import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CaptureOneCore

struct ContactSheetTests {
    static func run() {
        print("Running ContactSheetTests...")
        testCropParsing()
        testCachePaths()
        testLayout()
        testResultEncoding()
        testSessionKeyReader()
        testCacheRead()
        testRenderer()
        testSheetFiles()
        testSessionSheet()
        testSessionIdentityFailures()
        testDocumentChangeAndBuildGate()
        testCatalogSheet()
    }

    static func errorCode(_ body: () throws -> Any) -> String? {
        do { _ = try body(); return nil }
        catch let error as C1Error { return error.errorCode }
        catch let error as VariantsNotFound { return error.cause.errorCode }
        catch { return "\(error)" }
    }

    static let measuredCropComment = "3|0;2;3|60;334;279;115|0"
    static let measuredThumbnailSize = (width: 339, height: 450)
    static let measuredCrop = CotCrop.applied(x: 60, y: 116, width: 219, height: 219)

    private static func testCropParsing() {
        XCTAssertEqual(CotCrop.parse(userComment: measuredCropComment, width: measuredThumbnailSize.width, height: measuredThumbnailSize.height),
                       measuredCrop, "Measured cropped v3 thumbnail")
        XCTAssertEqual(CotCrop.parse(userComment: "3|1;3;1|0;450;300;0|0", width: 300, height: 450), .fullFrame,
                       "Measured uncropped v3 thumbnail")
        XCTAssertEqual(CotCrop.parse(userComment: "2|1;1;1|13;45;292;416", width: 305, height: 450),
                       .notApplied(reason: .formatVersion2, userComment: "2|1;1;1|13;45;292;416"), "Measured v2 thumbnail")
        XCTAssertEqual(CotCrop.parse(userComment: "3|7;-2;100|10.5;400;200.25;50|0", width: 300, height: 450),
                       .applied(x: 10.5, y: 50, width: 189.75, height: 350), "Any three middle integers; fractional edges stay exact")
        XCTAssertEqual(CotCrop.parse(userComment: nil, width: 300, height: 450), .notApplied(reason: .absent, userComment: nil))
        XCTAssertEqual(CotCrop.parse(userComment: "", width: 300, height: 450), .notApplied(reason: .absent, userComment: nil))
        let unsupported = [
            "4|1;1;1|0;450;300;0|0", "ASCII\0\0\03|1;1;1|0;450;300;0|0", " 3|1;1;1|0;450;300;0|0",
            "3|1;1;1|0;450;300;0", "3|1;1;1|0;450;300;0|0|0", "3|1;1;1|0;450;300;0|1", "3|1;1;1|0;450;300;0|",
            "3|1;1|0;450;300;0|0", "3|1;1;1;1|0;450;300;0|0", "3|1;x;1|0;450;300;0|0", "3|1;1.5;1|0;450;300;0|0",
            "3|1;1;1|0;450;300|0", "3|1;1;1|0;450;300;0;0|0", "3|1;1;1|0;nan;300;0|0", "3|1;1;1|0;inf;300;0|0", "3|1;1;1|0; 450;300;0|0",
            "3|1;1;1|-1;450;300;0|0", "3|1;1;1|0;451;300;0|0", "3|1;1;1|0;450;301;0|0", "3|1;1;1|0;450;300;-1|0",
            "3|1;1;1|100;450;100;0|0", "3|1;1;1|0;200;300;200|0", "3|1;1;1|200;450;100;0|0", "3|1;1;1|0;100;300;200|0",
        ]
        for comment in unsupported {
            XCTAssertEqual(CotCrop.parse(userComment: comment, width: 300, height: 450),
                           .notApplied(reason: .unsupportedFormat, userComment: comment), "Fails closed: \(comment)")
        }
    }

    private static func testCachePaths() {
        XCTAssertEqual(ThumbnailCache.catalogThumbnail(databasePath: "/shoots/Wedding.cocatalog/Wedding.cocatalogdb", variantID: 10).path,
                       "/shoots/Wedding.cocatalog/Cache/Thumbnails/00000010.cot")
        XCTAssertEqual(ThumbnailCache.catalogThumbnail(databasePath: "/shoots/Plain/Plain.cocatalogdb", variantID: 123456789).path,
                       "/shoots/Plain/Cache/Thumbnails/123456789.cot", "Unpackaged Catalogs keep the cache beside the database; no truncation")
        let uuid = UUID(uuidString: "A1B2C3D4-0000-4000-8000-00000000ABCD")!
        XCTAssertNoThrowBlock {
            let url = try ThumbnailCache.sessionThumbnail(parentImagePath: "/shoots/Day 1/Capture/TK7A7230.CR3",
                                                          key: SessionThumbnailKey(variantUUID: uuid, imageFileName: "TK7A7230.CR3"))
            XCTAssertEqual(url.path, "/shoots/Day 1/Capture/CaptureOne/Cache/Thumbnails/TK7A7230.CR3.[a1b2c3d4-0000-4000-8000-00000000abcd].cot")
        }
        for (parent, stored) in [("/a/TK7A7230.CR3", "TK7A7231.CR3"), ("/a/TK7A7230.CR3", "tk7a7230.cr3"), ("relative/TK7A7230.CR3", "TK7A7230.CR3")] {
            XCTAssertEqual(errorCode { try ThumbnailCache.sessionThumbnail(parentImagePath: parent, key: SessionThumbnailKey(variantUUID: uuid, imageFileName: stored)) },
                           "identity-ambiguous", "\(stored) never maps a thumbnail for \(parent)")
        }
        XCTAssertEqual(try? ThumbnailCache.storedID("1"), 1)
        XCTAssertEqual(try? ThumbnailCache.storedID("4096"), 4096)
        for id in ["", "0", "007", "-1", "+1", "1.0", " 1", "1 ", "abc", "\u{0661}", "99999999999999999999", "A1B2C3D4-0000-4000-8000-00000000ABCD"] {
            XCTAssertEqual(errorCode { try ThumbnailCache.storedID(id) }, "identity-ambiguous", "'\(id)' is not a stored database ID")
        }
    }

    static func rows(_ arrangement: SheetArrangement) -> [[PixelRect]] {
        Dictionary(grouping: arrangement.cells, by: \.y).sorted { $0.key < $1.key }.map(\.value)
    }

    static func checkRows(_ arrangement: SheetArrangement, _ aspects: [Double], _ name: String) {
        XCTAssertEqual(arrangement.cells.count, aspects.count, name)
        XCTAssertTrue(arrangement.width <= 1536 && arrangement.height <= 2400, "\(name): \(arrangement.width)×\(arrangement.height)")
        XCTAssertTrue(arrangement.cells.allSatisfy { $0.x + $0.width + 4 <= arrangement.width }, "\(name): every image is inside the sheet")
        var y = 28
        for row in rows(arrangement) {
            XCTAssertEqual(row.first?.y, y, "\(name): rows stack below the header with a label strip and gutter")
            XCTAssertEqual(row.first?.x, 4, name)
            XCTAssertEqual(Set(row.map(\.height)).count, 1, "\(name): one height per row")
            for (left, right) in zip(row, row.dropFirst()) { XCTAssertEqual(right.x, left.x + left.width + 4, name) }
            y += row[0].height + 16 + 4
        }
        XCTAssertEqual(arrangement.height, y, name)
        for (cell, aspect) in zip(arrangement.cells, aspects) {
            XCTAssertTrue(abs(Double(cell.width) - aspect * Double(cell.height)) <= 1 + aspect / 2, "\(name): \(cell) keeps aspect \(aspect)")
        }
    }

    static func rightEdge(_ row: [PixelRect]) -> Int { row.last!.x + row.last!.width }

    private static func testLayout() {
        let standard = SheetLayout.standard
        XCTAssertEqual([standard.perPage, standard.rowHeight, SheetLayout.width], [20, 220, 1536],
                       "The sheet stays below the 1568 px client downscale edge")
        for (perPage, rowHeight) in [(0, 220), (49, 220), (20, 119), (20, 451)] {
            XCTAssertEqual(errorCode { try SheetLayout(perPage: perPage, rowHeight: rowHeight) }, "invalid-request", "\(perPage) at \(rowHeight) px")
        }
        XCTAssertNoThrowBlock {
            _ = try SheetLayout(perPage: 1, rowHeight: 120)
            _ = try SheetLayout(perPage: 48, rowHeight: 450)
        }

        let landscapes = [Double](repeating: 1.5, count: 20)
        let full = standard.arrange(landscapes)
        checkRows(full, landscapes, "20 landscapes")
        XCTAssertEqual(rows(full).map(\.count), [5, 5, 5, 5], "A fifth 330 px image overflows; taking it gives 202 px rows, closer to 220 than 253")
        XCTAssertEqual(rows(full).map(rightEdge), [1532, 1532, 1532, 1532], "Every closed row fills the width exactly")
        XCTAssertEqual(full.cells[0], PixelRect(x: 4, y: 28, width: 302, height: 202))
        XCTAssertEqual(full.height, 28 + 4 * (202 + 20))

        let seven = [Double](repeating: 1.5, count: 7), partial = standard.arrange(seven)
        checkRows(partial, seven, "7 landscapes")
        XCTAssertEqual(Array(partial.cells[5...]), [PixelRect(x: 4, y: 250, width: 330, height: 220), PixelRect(x: 338, y: 250, width: 330, height: 220)],
                       "The last row keeps rowHeight, left-aligned and not stretched")

        let mixed = [1.5, 0.667, 1.5, 0.75, 1.5, 1.5, 0.667, 1, 1.333, 0.8, 1.5, 2.4, 0.667]
        let mix = standard.arrange(mixed)
        checkRows(mix, mixed, "portraits and landscapes")
        let mixRows = rows(mix)
        XCTAssertTrue(mixRows.count > 1)
        XCTAssertEqual(mixRows.dropLast().map(rightEdge), [Int](repeating: 1532, count: mixRows.count - 1), "Closed rows fill the width exactly")
        XCTAssertTrue(mixRows.dropLast().allSatisfy { (147...330).contains($0[0].height) }, "Closed rows stay within the 1.5× stretch")
        XCTAssertTrue(rightEdge(mixRows.last!) <= 1532 && mixRows.last![0].height == 220, "The last row is not stretched")

        let single = standard.arrange([1.5])
        XCTAssertEqual(single.cells, [PixelRect(x: 4, y: 28, width: 330, height: 220)], "A single image keeps rowHeight")
        XCTAssertEqual([single.width, single.height], [480, 268], "A one-image page keeps only the minimum width")
        XCTAssertEqual(standard.arrange([1.5, 1.5, 1.5]).width, 1006, "A short page narrows to its widest row")
        XCTAssertEqual(standard.arrange([10]).cells, [PixelRect(x: 4, y: 28, width: 1528, height: 153)], "An image wider than the sheet shrinks to fit")
        XCTAssertEqual(standard.arrange([4, 30]).cells, [PixelRect(x: 4, y: 28, width: 1320, height: 330), PixelRect(x: 4, y: 378, width: 1528, height: 51)],
                       "Stretching a lone 4:1 image to the width would need 382 px rows; the stretch stops at 1.5× rowHeight")

        let tall = try! SheetLayout(perPage: 48, rowHeight: 450)
        let landscapes48 = [Double](repeating: 1.5, count: 48), lowered = tall.arrange(landscapes48)
        checkRows(lowered, landscapes48, "48 landscapes at 450 px")
        XCTAssertEqual(lowered.width, 1536, "Two 675 px images a row scaled to 2400 px would be a strip about 250 px wide; lower rows fill the width instead")
        XCTAssertTrue(lowered.height > 2200 && rows(lowered).allSatisfy { $0[0].height < 450 }, "Lowered rows use most of the 2400 px: \(lowered.height)")
        XCTAssertEqual(rows(lowered).dropLast().map(rightEdge), [Int](repeating: 1532, count: rows(lowered).count - 1), "Lowered rows still fill the width")

        let mixed48 = (0..<48).map { $0 % 3 == 0 ? 0.667 : 1.5 }, scaled = tall.arrange(mixed48)
        checkRows(scaled, mixed48, "48 mixed tiles at 450 px")
        XCTAssertTrue(scaled.height > 2200, "Where lower rows would jump from 2703 to 1836 px, scaling rows down uniformly fills the height: \(scaled.height)")
        XCTAssertTrue(scaled.width < 1536 && rows(scaled).allSatisfy { rightEdge($0) + 4 <= scaled.width }, "A scaled page narrows to its rows: \(scaled.width)")
        XCTAssertEqual(tall.arrange(mixed48), scaled, "The arrangement is deterministic")
    }

    static func solidImage(width: Int, height: Int, red: CGFloat = 1, green: CGFloat = 0, blue: CGFloat = 0) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private static func testResultEncoding() {
        func member(_ id: String) -> SheetMember { SheetMember(id: id, name: "IMG_\(id)", rating: 3, parentImagePath: "/a/IMG_\(id).CR3") }
        func cell(_ index: Int) -> PixelRect { PixelRect(x: 4 + index * 100, y: 28, width: 96, height: 64) }
        let image = solidImage(width: 4, height: 6)
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let tiles = [
            ContactSheetTile(member: member("1"), cell: cell(0), content: .shown(CachedThumbnail(image: image, modifiedAt: date, crop: .fullFrame))),
            ContactSheetTile(member: member("2"), cell: cell(1), content: .shown(CachedThumbnail(image: image, modifiedAt: date,
                crop: .notApplied(reason: .formatVersion2, userComment: "2|1;1;1|0;0;4;6")))),
            ContactSheetTile(member: member("3"), cell: cell(2), content: .missing(.notStored)),
            ContactSheetTile(member: member("4"), cell: cell(3), content: .unreadable(.orientationTag)),
            ContactSheetTile(member: member("5"), cell: cell(4), content: .shown(CachedThumbnail(image: image, modifiedAt: date,
                crop: .applied(x: 0, y: 0, width: 2, height: 2)))),
        ]
        let result = ContactSheetResult(documentKind: "session", documentName: "Shoot.cosessiondb", page: 2, pages: 2, total: 25, nextPage: nil,
                                        sheet: SheetImage(path: "/tmp/sheet.jpg", width: 1536, height: 916), tiles: tiles, renderedAt: "2026-10-15T12:00:00Z")
        XCTAssertNoThrowBlock {
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [String: Any]
            XCTAssertEqual(Set(json.keys), ["source", "documentKind", "documentName", "page", "pages", "total", "sheet", "tiles", "counts", "renderedAt", "limitation"],
                           "nextPage is absent on the last page")
            XCTAssertEqual(json["source"] as? String, "capture-one-thumbnail-cache")
            XCTAssertEqual(json["counts"] as? NSDictionary, ["shown": 3, "missing": 1, "unreadable": 1, "uncropped": 1] as NSDictionary)
            let encoded = json["tiles"] as! [[String: Any]]
            XCTAssertEqual(encoded[0] as NSDictionary, ["id": "1", "name": "IMG_1", "rating": 3, "status": "shown",
                "cell": ["x": 4, "y": 28, "width": 96, "height": 64], "cachedSize": ["width": 4, "height": 6],
                "cacheModifiedAt": "2025-10-09T08:53:20Z", "crop": ["status": "full-frame"]] as NSDictionary)
            XCTAssertEqual(encoded[1]["crop"] as? NSDictionary, ["status": "not-applied", "reason": "format-version-2", "userComment": "2|1;1;1|0;0;4;6"] as NSDictionary)
            XCTAssertEqual(encoded[2] as NSDictionary, ["id": "3", "name": "IMG_3", "rating": 3, "status": "missing", "reason": "not-stored",
                "cell": ["x": 204, "y": 28, "width": 96, "height": 64]] as NSDictionary, "A missing tile has no crop, cached size or cache time")
            XCTAssertEqual(encoded[3]["reason"] as? String, "orientation-tag")
            XCTAssertEqual(encoded[4]["crop"] as? NSDictionary, ["status": "applied"] as NSDictionary)
            XCTAssertEqual(encoded[4]["cachedSize"] as? NSDictionary, ["width": 2, "height": 2] as NSDictionary, "cachedSize counts only the cropped pixels")
            XCTAssertEqual(encoded[1]["cachedSize"] as? NSDictionary, ["width": 4, "height": 6] as NSDictionary, "An uncropped tile shows its full frame")
            let empty = ContactSheetResult(documentKind: "catalog", documentName: "Wedding", page: 1, pages: 0, total: 0, nextPage: nil,
                                           sheet: nil, tiles: [], renderedAt: "2026-10-15T12:00:00Z")
            let emptyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(empty)) as! [String: Any]
            XCTAssertNil(emptyJSON["sheet"], "An empty scope has no sheet")
            XCTAssertEqual(emptyJSON["counts"] as? NSDictionary, ["shown": 0, "missing": 0, "unreadable": 0, "uncropped": 0] as NSDictionary)
        }
    }

    static let sessionTables = [
        "CREATE TABLE ZDOCUMENTCONTENT(Z_PK INTEGER PRIMARY KEY, ZDOCUMENTTYPE INTEGER, ZDOCUMENTUUID VARCHAR);",
        "CREATE TABLE ZIMAGE(Z_PK INTEGER PRIMARY KEY, ZIMAGEFILENAME VARCHAR, ZDISPLAYNAME VARCHAR);",
        "CREATE TABLE ZVARIANT(Z_PK INTEGER PRIMARY KEY, ZIMAGE INTEGER, ZVARIANTUUID VARCHAR);",
    ]

    @discardableResult
    static func sessionDatabase(_ path: String, variants: [Int: (uuid: String?, fileName: String?)], documentType: Int = 0,
                                tables: [String] = sessionTables, extra: [String] = []) -> String {
        func literal(_ text: String?) -> String { text.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL" }
        var sql = tables + ["INSERT INTO ZDOCUMENTCONTENT VALUES(1,\(documentType),'5B0D6A3C-1F7E-4C2B-9A55-0D6C1E2F3A4B');"]
        for (id, row) in variants.sorted(by: { $0.key < $1.key }) {
            sql.append("INSERT INTO ZIMAGE(Z_PK,ZIMAGEFILENAME) VALUES(\(id),\(literal(row.fileName)));")
            sql.append("INSERT INTO ZVARIANT VALUES(\(id),\(id),\(literal(row.uuid)));")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path]
        let input = Pipe()
        process.standardInput = input
        try! process.run()
        input.fileHandleForWriting.write(Data((sql + extra).joined(separator: "\n").utf8))
        try! input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Session fixture database")
        return path
    }

    private static func testSessionKeyReader() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func path(_ name: String) -> String { directory.appendingPathComponent(name).path }
        let first = "0F8E2D1C-AAAA-4BBB-8CCC-123456789ABC", second = "9d1e2f3a-bbbb-4ccc-8ddd-abcdef012345"
        let database = sessionDatabase(path("Shoot.cosessiondb"), variants: [1: (first, "IMG_1.CR3"), 2: (second, "IMG_2.CR3"), 40: (first, "IMG_40.CR3")])
        XCTAssertNoThrowBlock {
            let before = try Data(contentsOf: URL(fileURLWithPath: database))
            let keys = try CatalogReader(sessionDatabase: database).sessionThumbnailKeys(variantIDs: [1, 2, 99])
            XCTAssertEqual(keys, [1: SessionThumbnailKey(variantUUID: UUID(uuidString: first)!, imageFileName: "IMG_1.CR3"),
                                  2: SessionThumbnailKey(variantUUID: UUID(uuidString: second)!, imageFileName: "IMG_2.CR3")],
                           "Z_PK maps to its own UUID and file name; an unsaved variant is absent")
            let none = try CatalogReader(sessionDatabase: database).sessionThumbnailKeys(variantIDs: [])
            XCTAssertTrue(none.isEmpty)
            let after = try Data(contentsOf: URL(fileURLWithPath: database))
            XCTAssertEqual(after, before, "The read leaves the database bytes unchanged")
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertEqual(files, ["Shoot.cosessiondb"], "No journal, WAL or shm file appears")
        }
        XCTAssertEqual(errorCode { try CatalogReader(database: database) }, "invalid-request", "catalog_* tools still refuse Sessions")
        XCTAssertEqual(errorCode { try CatalogReader(sessionDatabase: "Shoot.cosessiondb") }, "invalid-request")
        try! Data().write(to: URL(fileURLWithPath: path("Wedding.cocatalogdb")))
        XCTAssertEqual(errorCode { try CatalogReader(sessionDatabase: path("Wedding.cocatalogdb")) }, "invalid-request")
        try! FileManager.default.createDirectory(atPath: path("Folder.cosessiondb"), withIntermediateDirectories: true)
        XCTAssertEqual(errorCode { try CatalogReader(sessionDatabase: path("Folder.cosessiondb")) }, "invalid-request")

        let refused: [(String, String, String)] = [
            (sessionDatabase(path("catalog.cosessiondb"), variants: [1: (first, "IMG_1.CR3")], documentType: 1), "invalid-request", "a Catalog document type"),
            (sessionDatabase(path("wal.cosessiondb"), variants: [1: (first, "IMG_1.CR3")], extra: ["PRAGMA journal_mode=WAL;"]), "invalid-request", "a WAL database"),
            (sessionDatabase(path("two.cosessiondb"), variants: [1: (first, "IMG_1.CR3")],
                             extra: ["INSERT INTO ZDOCUMENTCONTENT VALUES(2,0,'second');"]), "invalid-request", "two document records"),
            (sessionDatabase(path("blank.cosessiondb"), variants: [1: (first, "IMG_1.CR3")],
                             extra: ["UPDATE ZDOCUMENTCONTENT SET ZDOCUMENTUUID='';"]), "invalid-request", "an empty document UUID"),
            (sessionDatabase(path("column.cosessiondb"), variants: [:], tables: [sessionTables[0], "CREATE TABLE ZIMAGE(Z_PK INTEGER PRIMARY KEY, ZDISPLAYNAME VARCHAR);", sessionTables[2]]),
             "invalid-request", "a missing ZIMAGEFILENAME column"),
            (sessionDatabase(path("uuid.cosessiondb"), variants: [1: ("not-a-uuid", "IMG_1.CR3")]), "identity-ambiguous", "a stored UUID that does not parse"),
            (sessionDatabase(path("null.cosessiondb"), variants: [1: (nil, "IMG_1.CR3")]), "identity-ambiguous", "a NULL stored UUID"),
            (sessionDatabase(path("name.cosessiondb"), variants: [1: (first, nil)]), "identity-ambiguous", "a NULL image file name"),
        ]
        for (database, code, reason) in refused {
            XCTAssertEqual(errorCode { try CatalogReader(sessionDatabase: database).sessionThumbnailKeys(variantIDs: [1]) }, code, "Refuses \(reason)")
        }
    }

    static func cot(_ image: CGImage, comment: String? = nil, orientation: Int? = nil, type: UTType = .jpeg) -> Data {
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
        if let comment { properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifUserComment: comment] }
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Blue, with a red square at a top-left-origin rectangle: the measured cropped thumbnail's framing.
    static func croppedMarker() -> CGImage {
        let (width, height) = measuredThumbnailSize
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 60, y: height - 116 - 219, width: 219, height: 219))
        return context.makeImage()!
    }

    private static func testCacheRead() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func file(_ name: String, _ data: Data) -> URL {
            let url = directory.appendingPathComponent(name)
            try! data.write(to: url)
            return url
        }
        func status(_ content: TileContent) -> String {
            switch content {
            case .shown: return "shown"
            case .missing(let reason): return "missing:\(reason.rawValue)"
            case .unreadable(let reason): return "unreadable:\(reason.rawValue)"
            }
        }
        let cropped = file("cropped.cot", cot(croppedMarker(), comment: measuredCropComment))
        if case .shown(let thumbnail) = ThumbnailCache.read(cropped) {
            XCTAssertEqual(thumbnail.crop, measuredCrop, "UserComment round-trips through ImageIO without a prefix")
            XCTAssertEqual([thumbnail.image.width, thumbnail.image.height], [measuredThumbnailSize.width, measuredThumbnailSize.height])
            let modified = try! FileManager.default.attributesOfItem(atPath: cropped.path)[.modificationDate] as! Date
            XCTAssertEqual(thumbnail.modifiedAt.timeIntervalSince1970, modified.timeIntervalSince1970, accuracy: 0.001)
        } else {
            XCTFail("A valid thumbnail is shown")
        }
        if case .shown(let thumbnail) = ThumbnailCache.read(file("plain.cot", cot(solidImage(width: 30, height: 20), orientation: 1))) {
            XCTAssertEqual(thumbnail.crop, .notApplied(reason: .absent, userComment: nil), "Orientation 1 is accepted; no comment means no crop")
        } else {
            XCTFail("An orientation-1 thumbnail is shown")
        }
        let large = Data(count: 4 * 1024 * 1024 + 1)
        try! FileManager.default.createDirectory(at: directory.appendingPathComponent("folder.cot"), withIntermediateDirectories: true)
        try! FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link.cot"), withDestinationURL: cropped)
        let cases: [(URL, String)] = [
            (directory.appendingPathComponent("absent.cot"), "missing:not-cached"),
            (directory.appendingPathComponent("no-folder/absent.cot"), "missing:not-cached"),
            (cropped.appendingPathComponent("child.cot"), "missing:not-cached"),
            (file("png.cot", cot(solidImage(width: 30, height: 20), type: .png)), "unreadable:undecodable"),
            (file("text.cot", Data("not an image".utf8)), "unreadable:undecodable"),
            (file("empty.cot", Data()), "unreadable:undecodable"),
            (file("rotated.cot", cot(solidImage(width: 30, height: 20), orientation: 6)), "unreadable:orientation-tag"),
            (directory.appendingPathComponent("folder.cot"), "unreadable:not-regular-file"),
            (directory.appendingPathComponent("link.cot"), "unreadable:not-regular-file"),
            (file("large.cot", large), "unreadable:too-large"),
        ]
        for (url, expected) in cases {
            XCTAssertEqual(status(ThumbnailCache.read(url)), expected, url.lastPathComponent)
        }

        let replaced = file("replaced.cot", cot(solidImage(width: 30, height: 20)))
        var replacements = 0
        let once = ThumbnailCache.read(replaced, testHookAfterStat: {
            guard replacements == 0 else { return }
            replacements += 1
            try! cot(solidImage(width: 40, height: 20)).write(to: replaced, options: .atomic)
        })
        if case .shown(let thumbnail) = once {
            XCTAssertEqual(thumbnail.image.width, 40, "A thumbnail replaced during the read is read again")
        } else {
            XCTFail("One replacement is retried")
        }
        let always = ThumbnailCache.read(replaced, testHookAfterStat: { try! cot(solidImage(width: 40, height: 20)).write(to: replaced, options: .atomic) })
        XCTAssertEqual(status(always), "unreadable:changed-during-read", "Never a mix of two files")
    }

    static func pixels(_ image: CGImage) -> (Int, Int) -> [UInt8] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                .draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return { x, y in let i = (y * width + x) * 4; return Array(bytes[i..<i + 3]) }
    }

    private static func testRenderer() {
        let date = Date()
        func shown(_ image: CGImage, _ crop: CotCrop) -> TileContent { .shown(CachedThumbnail(image: image, modifiedAt: date, crop: crop)) }
        let red: [UInt8] = [255, 0, 0], green: [UInt8] = [0, 255, 0], blue: [UInt8] = [0, 0, 255]
        let background: [UInt8] = [0x26, 0x26, 0x26], placeholder: [UInt8] = [0x3a, 0x3a, 0x3a]
        let contents = [
            shown(solidImage(width: 450, height: 300), .fullFrame),
            shown(croppedMarker(), measuredCrop),
            shown(solidImage(width: 100, height: 50, red: 0, green: 1), .fullFrame),
            .missing(.notCached),
            .unreadable(.undecodable),
            shown(solidImage(width: 300, height: 200, red: 0, blue: 1), .notApplied(reason: .formatVersion2, userComment: "2|1;1;1|0;0;300;200")),
        ]
        XCTAssertEqual(contents.map(\.aspect), [1.5, 1, 2, 1.5, 1.5, 1.5], "A crop sets the aspect; placeholders are 3:2")
        let arrangement = SheetLayout.standard.arrange(contents.map(\.aspect))
        let tiles = zip(arrangement.cells, contents).enumerated().map { index, item in
            ContactSheetTile(member: SheetMember(id: "\(index + 1)", name: "IMG_\(index + 1)", rating: 2, parentImagePath: "/a/IMG.CR3"),
                             cell: item.0, content: item.1)
        }
        let image = ContactSheet.render(tiles: tiles, width: arrangement.width, height: arrangement.height, header: "Shoot · page 1/1 · 1–6 of 6")
        XCTAssertEqual([image.width, image.height], [arrangement.width, arrangement.height])
        let pixel = pixels(image)
        func centre(_ index: Int) -> [UInt8] { let c = tiles[index].cell; return pixel(c.x + c.width / 2, c.y + c.height / 2) }
        XCTAssertEqual(centre(0), red, "Each image lands in its own reported cell")
        XCTAssertEqual(centre(1), red)
        XCTAssertEqual(centre(2), green)
        XCTAssertEqual(centre(5), blue)

        func count(_ index: Int, _ color: [UInt8]) -> Int {
            let c = tiles[index].cell
            return (c.y..<c.y + c.height).reduce(0) { sum, y in sum + (c.x..<c.x + c.width).filter { pixel($0, y) == color }.count }
        }
        for (index, color) in [(0, red), (1, red), (2, green)] {
            let c = tiles[index].cell
            XCTAssertEqual(count(index, color), c.width * c.height, "Tile \(index + 1) fills exactly its cell")
            XCTAssertEqual(pixel(c.x - 1, c.y + c.height / 2), background, "Tile \(index + 1) draws nothing left of its cell")
            XCTAssertEqual(pixel(c.x + c.width, c.y + c.height / 2), background, "Tile \(index + 1) draws nothing right of its cell")
            XCTAssertEqual(pixel(c.x + c.width / 2, c.y - 1), background, "Tile \(index + 1) draws nothing above its cell")
        }
        XCTAssertEqual(count(1, blue), 0, "Nothing outside the crop is drawn")
        XCTAssertTrue(tiles[2].cell.width > 100, "A small thumbnail is enlarged to its row: \(tiles[2].cell)")
        XCTAssertEqual(pixel(tiles[3].cell.x + 2, tiles[3].cell.y + 2), placeholder, "A missing thumbnail draws a placeholder in its cell")
        XCTAssertEqual(pixel(tiles[4].cell.x + 2, tiles[4].cell.y + 2), placeholder, "An unreadable thumbnail draws a placeholder in its cell")
        let badge = pixel(tiles[5].cell.x + 2, tiles[5].cell.y + 2)
        XCTAssertTrue(badge[0] > 200 && badge[1] > 120 && badge[2] < 60, "An uncropped tile carries an amber badge: \(badge)")
        XCTAssertEqual(pixel(tiles[0].cell.x + 2, tiles[0].cell.y + 2), red, "A tile whose crop is known has no badge")

        let label = SheetLayout.label(below: tiles[0].cell)
        XCTAssertEqual(label, PixelRect(x: tiles[0].cell.x, y: tiles[0].cell.y + tiles[0].cell.height, width: tiles[0].cell.width, height: 16))
        let strip = (label.y..<label.y + label.height).flatMap { y in (label.x..<label.x + label.width).map { pixel($0, y) } }
        XCTAssertTrue(strip.contains { $0 != background }, "The label strip directly below the image carries text")
        XCTAssertTrue((label.y..<label.y + label.height).allSatisfy { pixel(label.x + label.width + 1, $0) == background },
                      "A label stays within its image's width")

        let small = SheetLayout.standard.arrange([0.2])
        let tiny = ContactSheetTile(member: SheetMember(id: "1", name: "IMG_1", rating: 0, parentImagePath: "/a/IMG.CR3"), cell: small.cells[0],
                                    content: shown(solidImage(width: 90, height: 450, red: 0, blue: 1), .notApplied(reason: .absent, userComment: nil)))
        let narrow = pixels(ContactSheet.render(tiles: [tiny], width: small.width, height: small.height, header: "Shoot"))
        let c = small.cells[0]
        XCTAssertEqual(c.width, 44)
        let amber = (c.y..<c.y + c.height).filter { y in let p = narrow(c.x + 1, y); return p[0] > 200 && p[2] < 60 }.count
        XCTAssertTrue((1..<c.height / 4).contains(amber), "The UNCROPPED badge shrinks to fit a narrow tile: \(amber) rows")
        XCTAssertEqual(narrow(c.x + c.width, c.y + 1), background, "The badge stays inside the tile")
    }

    private static func testSheetFiles() {
        let scope = SheetScope(minRating: 3), layout = SheetLayout.standard
        let name = ContactSheet.fileName(documentName: "Shoot.cosessiondb", documentId: "/s/Shoot.cosessiondb", scope: scope, layout: layout, page: 1)
        XCTAssertTrue(name.range(of: "^Shoot-[0-9a-f]{12}-p001\\.jpg$", options: .regularExpression) != nil, name)
        XCTAssertEqual(ContactSheet.fileName(documentName: "Shoot.cosessiondb", documentId: "/s/Shoot.cosessiondb", scope: scope, layout: layout, page: 1), name,
                       "Repeating a request replaces its own file")
        XCTAssertEqual(ContactSheet.fileName(documentName: "Shoot.cosessiondb", documentId: "/s/Shoot.cosessiondb", scope: scope, layout: layout, page: 12),
                       String(name.dropLast(8)) + "p012.jpg")
        let others = [
            ContactSheet.fileName(documentName: "Shoot.cosessiondb", documentId: "/s/Shoot.cosessiondb", scope: SheetScope(rating: 3), layout: layout, page: 1),
            ContactSheet.fileName(documentName: "Shoot.cosessiondb", documentId: "/s/Shoot.cosessiondb", scope: SheetScope(ids: ["1", "2"]), layout: layout, page: 1),
            ContactSheet.fileName(documentName: "Shoot.cosessiondb", documentId: "/other/Shoot.cosessiondb", scope: scope, layout: layout, page: 1),
            ContactSheet.fileName(documentName: "Shoot.cosessiondb", documentId: "/s/Shoot.cosessiondb", scope: scope,
                                  layout: try! SheetLayout(perPage: 12, rowHeight: 400), page: 1),
        ]
        XCTAssertEqual(Set(others + [name]).count, 5, "Scope, document and layout never share a file")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNoThrowBlock {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in 0..<60 {
                let old = directory.appendingPathComponent("old-\(index).jpg")
                try Data("x".utf8).write(to: old)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(-1000 + index))], ofItemAtPath: old.path)
            }
            try Data("keep".utf8).write(to: directory.appendingPathComponent("notes.txt"))
            let sheet = try ContactSheet.write(solidImage(width: 64, height: 32), to: directory, fileName: name)
            XCTAssertEqual(sheet, SheetImage(path: directory.appendingPathComponent(name).path, width: 64, height: 32))
            let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: sheet.path) as CFURL, nil)!
            XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
            let files = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
            XCTAssertEqual(files.filter { $0.hasSuffix(".jpg") }.count, 50, "Only the 50 newest sheets are kept")
            XCTAssertTrue(files.contains(name) && files.contains("notes.txt") && files.contains("old-59.jpg") && !files.contains("old-10.jpg"),
                          "Pruning removes the oldest sheets and nothing else")
        }
    }

    static func variantUUID(_ id: Int) -> String { String(format: "%08X-0000-4000-8000-%012X", id, id) }

    static func tree(_ root: URL) -> [String: String] {
        var files: [String: String] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) ?? FileManager.DirectoryEnumerator() {
            let values = try? url.resourceValues(forKeys: Set(keys))
            files[String(url.path.dropFirst(root.path.count))] = "\(values?.fileSize ?? -1)@\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return files
    }

    static func sessionFixture(_ count: Int) -> (fake: FakeScript, core: SessionController, document: URL, output: URL) {
        let document = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = document.appendingPathComponent("CaptureOne/Cache/Thumbnails")
        try! FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let fake = FakeScript(directory: document)
        fake.values = [:]
        var stored: [Int: (uuid: String?, fileName: String?)] = [:]
        for id in 1...count {
            fake.values[String(id)] = [0, 0, 0, 5000, 0]
            fake.ratings[String(id)] = id % 2 == 0 ? 4 : 2
            stored[id] = (variantUUID(id), "fixture.CR3")
            let shade = CGFloat(id) / CGFloat(count + 1)
            try! cot(solidImage(width: 450, height: 300, red: shade, green: 1 - shade, blue: 0), comment: "3|1;3;1|0;300;450;0|0")
                .write(to: cache.appendingPathComponent("fixture.CR3.[\(variantUUID(id).lowercased())].cot"))
        }
        sessionDatabase(document.appendingPathComponent("fixture.cosessiondb").path, variants: stored)
        FileManager.default.createFile(atPath: fake.parent, contents: Data("raw".utf8))
        let core = SessionController(lock: testLock, executor: fake, appInstance: { fake.generation }, databaseIdentity: { _ in "database-1" })
        return (fake, core, document, output)
    }

    static func violations(_ value: Any, _ schema: [String: Any], _ path: String = "contact_sheet") -> [String] {
        var problems: [String] = []
        if let allowed = schema["enum"] as? [String], !allowed.contains(value as? String ?? "") { problems.append("\(path): \(value) is not in \(allowed)") }
        if let constant = schema["const"] as? String, constant != value as? String { problems.append("\(path): \(value) is not \(constant)") }
        switch schema["type"] as? String {
        case "object":
            guard let object = value as? [String: Any] else { return problems + ["\(path) is not an object"] }
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            problems += (schema["required"] as? [String] ?? []).filter { object[$0] == nil }.map { "\(path).\($0) is missing" }
            for (key, item) in object {
                if let spec = properties[key] { problems += violations(item, spec, "\(path).\(key)") }
                else if schema["additionalProperties"] as? Bool == false { problems.append("\(path).\(key) is not in the schema") }
            }
        case "array":
            guard let items = value as? [Any] else { return problems + ["\(path) is not an array"] }
            for item in items { problems += violations(item, schema["items"] as? [String: Any] ?? [:], "\(path)[]") }
        case "integer":
            if !(value is Int) || CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() { problems.append("\(path) is not an integer") }
        case "string":
            if !(value is String) { problems.append("\(path) is not a string") }
        default: break
        }
        return problems
    }

    static func schemaViolations(_ result: ContactSheetResult) -> [String] {
        let responses = ContractSchema.document()["responses"] as! [String: Any]
        let json = try! JSONSerialization.jsonObject(with: Data(ToolResponse.contactSheet(result).json.utf8))
        return violations(json, responses["contact_sheet"] as! [String: Any])
    }

    static let readHandlers: Set<String> = ["getAppAndDocInfo", "discoverFilteredVariantIDs", "readVariantSummaries", "readVariantSubset"]

    private static func testSessionSheet() {
        let (fake, core, document, output) = sessionFixture(7)
        defer { try? FileManager.default.removeItem(at: document); try? FileManager.default.removeItem(at: output) }
        let layout = try! SheetLayout(perPage: 3, rowHeight: 150)
        let before = tree(document)
        XCTAssertNoThrowBlock {
            let first = try core.contactSheet(scope: SheetScope(), page: 1, layout: layout, directory: output)
            XCTAssertEqual(first.tiles.map(\.member.id), ["1", "2", "3"], "Tiles follow Capture One's order")
            XCTAssertEqual([first.total, first.pages, first.nextPage], [7, 3, 2])
            XCTAssertEqual(first.documentKind, "session")
            let arrangement = layout.arrange([1.5, 1.5, 1.5])
            XCTAssertEqual(first.tiles.map(\.cell), arrangement.cells, "Cells come from the arrangement of each thumbnail's aspect")
            XCTAssertEqual(first.counts, ["shown": 3, "missing": 0, "unreadable": 0, "uncropped": 0])
            let sheet = try XCTUnwrapSheet(first)
            XCTAssertEqual([sheet.width, sheet.height], [arrangement.width, arrangement.height])
            XCTAssertTrue(sheet.path.hasPrefix(output.path + "/") && FileManager.default.fileExists(atPath: sheet.path))
            XCTAssertEqual(ToolResponse.contactSheet(first).imagePath, sheet.path, "MCP attaches the sheet")
            XCTAssertEqual(schemaViolations(first), [], "The result matches the contract's response schema")
            let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: sheet.path) as CFURL, nil)!, 0, nil)!
            let pixel = pixels(image)
            for (index, tile) in first.tiles.enumerated() {
                let shade = Double(index + 1) / 8, centre = pixel(tile.cell.x + tile.cell.width / 2, tile.cell.y + tile.cell.height / 2)
                XCTAssertTrue(abs(Double(centre[0]) - shade * 255) < 12 && abs(Double(centre[1]) - (1 - shade) * 255) < 12,
                              "Variant \(tile.member.id)'s own thumbnail is in its cell: \(centre)")
            }

            let last = try core.contactSheet(scope: SheetScope(), page: 3, layout: layout, directory: output)
            XCTAssertEqual(last.tiles.map(\.member.id), ["7"])
            XCTAssertNil(last.nextPage, "The last page has no nextPage")
            XCTAssertEqual(errorCode { try core.contactSheet(scope: SheetScope(), page: 4, layout: layout, directory: output) }, "invalid-request")

            let rated = try core.contactSheet(scope: SheetScope(minRating: 4), page: 1, layout: layout, directory: output)
            XCTAssertEqual(rated.tiles.map(\.member.id), ["2", "4", "6"])
            XCTAssertEqual(rated.tiles.map(\.member.rating), [4, 4, 4], "Labels carry the live rating")
            let chosen = try core.contactSheet(scope: SheetScope(ids: ["5", "1"]), page: 1, layout: layout, directory: output)
            XCTAssertEqual(chosen.tiles.map(\.member.id), ["5", "1"], "ids keep the requested order")
            XCTAssertEqual(errorCode { try core.contactSheet(scope: SheetScope(ids: ["1", "99"]), layout: layout, directory: output) }, "variant-not-found")

            let sheets = Set(try FileManager.default.contentsOfDirectory(atPath: output.path))
            let empty = try core.contactSheet(scope: SheetScope(rating: 5), page: 1, layout: layout, directory: output)
            XCTAssertEqual([empty.total, empty.pages], [0, 0])
            XCTAssertTrue(empty.sheet == nil && empty.tiles.isEmpty && empty.nextPage == nil, "An empty scope has no sheet")
            XCTAssertEqual(schemaViolations(empty), [])
            XCTAssertNil(ToolResponse.contactSheet(empty).imagePath, "An empty scope attaches no image")
            let after = Set(try FileManager.default.contentsOfDirectory(atPath: output.path))
            XCTAssertEqual(after, sheets, "An empty scope writes nothing")
            XCTAssertEqual(sheets.count, 4, "Each scope and page has its own file")
        }
        XCTAssertTrue(Set(fake.calls).isSubset(of: readHandlers), "Only read handlers: \(Set(fake.calls).subtracting(readHandlers))")
        XCTAssertEqual(tree(document), before, "Nothing in the document folder is created or changed")

        let cache = document.appendingPathComponent("CaptureOne/Cache/Thumbnails")
        try! FileManager.default.removeItem(at: cache.appendingPathComponent("fixture.CR3.[\(variantUUID(2).lowercased())].cot"))
        try! cot(solidImage(width: 300, height: 450), comment: "2|1;1;1|0;0;300;450").write(to: cache.appendingPathComponent("fixture.CR3.[\(variantUUID(3).lowercased())].cot"))
        try! FileManager.default.removeItem(atPath: document.appendingPathComponent("fixture.cosessiondb").path)
        sessionDatabase(document.appendingPathComponent("fixture.cosessiondb").path,
                        variants: [1: (variantUUID(1), "fixture.CR3"), 2: (variantUUID(2), "fixture.CR3"), 3: (variantUUID(3), "fixture.CR3"),
                                   99: (variantUUID(4), "fixture.CR3")])
        XCTAssertNoThrowBlock {
            let result = try core.contactSheet(scope: SheetScope(), page: 1, layout: try SheetLayout(perPage: 8, rowHeight: 150), directory: output)
            let statuses = result.tiles.map { tile -> String in
                switch tile.content {
                case .shown(let thumbnail): return thumbnail.crop == .fullFrame ? "shown" : "uncropped"
                case .missing(let reason): return reason.rawValue
                case .unreadable(let reason): return reason.rawValue
                }
            }
            XCTAssertEqual(statuses, ["shown", "not-cached", "uncropped", "not-stored", "not-stored", "not-stored", "not-stored"],
                           "A deleted thumbnail is not cached; an unsaved variant is never guessed from the directory, even though its file is there")
            XCTAssertEqual(result.counts, ["shown": 2, "missing": 5, "unreadable": 0, "uncropped": 1])
            XCTAssertEqual(schemaViolations(result), [], "Missing and uncropped tiles match the response schema")
        }
    }

    static func XCTUnwrapSheet(_ result: ContactSheetResult) throws -> SheetImage {
        guard let sheet = result.sheet else { throw C1Error.invalidRequest("expected a sheet") }
        return sheet
    }

    private static func testSessionIdentityFailures() {
        let (fake, core, document, output) = sessionFixture(3)
        defer { try? FileManager.default.removeItem(at: document); try? FileManager.default.removeItem(at: output) }
        let database = document.appendingPathComponent("fixture.cosessiondb").path
        func storing(_ variants: [Int: (uuid: String?, fileName: String?)]) {
            try! FileManager.default.removeItem(atPath: database)
            sessionDatabase(database, variants: variants)
        }
        storing([1: (variantUUID(1), "fixture.CR3"), 2: (variantUUID(2), "other.CR3"), 3: (variantUUID(3), "fixture.CR3")])
        XCTAssertEqual(errorCode { try core.contactSheet(scope: SheetScope(), directory: output) }, "identity-ambiguous",
                       "A stored file name other than the live original fails the whole sheet")
        storing([1: (variantUUID(1), "fixture.CR3"), 2: ("not-a-uuid", "fixture.CR3"), 3: (variantUUID(3), "fixture.CR3")])
        XCTAssertEqual(errorCode { try core.contactSheet(scope: SheetScope(), directory: output) }, "identity-ambiguous")
        storing([1: (variantUUID(1), "fixture.CR3"), 2: (variantUUID(2), "fixture.CR3"), 3: (variantUUID(3), "fixture.CR3")])
        fake.values["007"] = [0, 0, 0, 5000, 0]
        XCTAssertEqual(errorCode { try core.contactSheet(scope: SheetScope(), directory: output) }, "identity-ambiguous",
                       "A native ID that is not a canonical stored ID maps to no thumbnail")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "A failed request writes no sheet")
    }

    private static func testDocumentChangeAndBuildGate() {
        let (fake, core, document, output) = sessionFixture(2)
        defer { try? FileManager.default.removeItem(at: document); try? FileManager.default.removeItem(at: output) }
        fake.calls = []
        XCTAssertNoThrow(try core.contactSheet(scope: SheetScope(), directory: output))
        let documentReads = fake.calls.filter { $0 == "getAppAndDocInfo" }.count
        var reads = 0
        fake.beforeHandler = { handler in
            guard handler == "getAppAndDocInfo" else { return }
            reads += 1
            if reads == documentReads { fake.generation = "app-2" }
        }
        XCTAssertEqual(errorCode { try core.contactSheet(scope: SheetScope(), page: 1, layout: .standard, directory: output) }, "document-changed",
                       "A document change after the thumbnails were read discards the sheet")
        fake.beforeHandler = nil
        fake.generation = "app-1"

        for version in ["16.9.0.1", "16.8.5.31"] {
            fake.version = version
            fake.calls = []
            XCTAssertEqual(errorCode { try core.contactSheet(scope: SheetScope(), directory: output) }, "unsupported-version", version)
            XCTAssertEqual(fake.calls, ["getAppAndDocInfo"], "Nothing is read on \(version)")
        }
        fake.version = "15.2.0.4"
        setenv("C1_ALLOW_UNTESTED_BUILD", "1", 1)
        XCTAssertNoThrow(try core.getDocumentInfo(), "The override admits the build for other tools")
        XCTAssertEqual(errorCode { try core.contactSheet(scope: SheetScope(), directory: output) }, "unsupported-version",
                       "The untested-build override does not enable the cache reader")
        unsetenv("C1_ALLOW_UNTESTED_BUILD")
    }

    private static func testCatalogSheet() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = root.appendingPathComponent("Wedding.cocatalog"), output = root.appendingPathComponent("sheets")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = package.appendingPathComponent("Cache/Thumbnails")
        try! FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: package.appendingPathComponent("Wedding.cocatalogdb").path, contents: Data("not sqlite".utf8))
        let fake = FakeScript(directory: package)
        fake.isSession = false
        fake.catalogID = package.path
        fake.values = ["1": [0, 0, 0, 5000, 0], "2": [0, 0, 0, 5000, 0], "10": [0, 0, 0, 5000, 0]]
        try! cot(croppedMarker(), comment: measuredCropComment).write(to: cache.appendingPathComponent("00000001.cot"))
        try! cot(solidImage(width: 300, height: 200)).write(to: cache.appendingPathComponent("00000010.cot"))
        let core = SessionController(lock: testLock, executor: fake, appInstance: { fake.generation }, databaseIdentity: { _ in "database-1" },
                                     allImagesCollection: { _ in nil })
        XCTAssertNoThrowBlock {
            let result = try core.contactSheet(scope: SheetScope(), directory: output)
            XCTAssertEqual(result.documentKind, "catalog")
            XCTAssertEqual(result.tiles.map(\.member.id), ["1", "10", "2"])
            XCTAssertEqual(result.counts, ["shown": 2, "missing": 1, "unreadable": 0, "uncropped": 1],
                           "A Catalog maps IDs to files with no database read; the database here is not even SQLite")
            if case .shown(let thumbnail) = result.tiles[0].content {
                XCTAssertEqual(thumbnail.crop, measuredCrop)
            } else {
                XCTFail("Variant 1's thumbnail is shown")
            }
            XCTAssertNotNil(result.sheet)
        }
    }
}
