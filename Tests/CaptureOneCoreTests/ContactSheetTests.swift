import Foundation
import CoreGraphics
import CaptureOneCore

struct ContactSheetTests {
    static func run() {
        print("Running ContactSheetTests...")
        testCropParsing()
        testCachePaths()
        testLayout()
        testResultEncoding()
    }

    static func errorCode(_ body: () throws -> Any) -> String? {
        do { _ = try body(); return nil } catch let error as C1Error { return error.errorCode } catch { return "\(error)" }
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
}
