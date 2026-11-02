import C1Kit
import CoreGraphics
import Foundation
import ImageIO

enum ViewingTests {
    static func run() {
        argumentsFailBeforeDispatch()
        cropPreview()
        fullFrameMapping()
        regionMapping()
        timeoutIsUnknownAndReleasesTheQueue()
        pruning()
        sheetLayout()
        contactSheet()
        contactSheetFillsGaps()
        thumbOfAJPEG()
        commandTable()
    }

    static func service(_ fake: FakeCaptureOne, _ name: String, queue: CaptureOneQueue? = nil, extraSQL: String = "") -> (Service, URL) {
        let path = Fixture.make(name, extraSQL: extraSQL)
        let caches = scratchDirectory("\(name)-caches")
        return (Service(captureOne: fake, queue: queue ?? CaptureOneQueue(directory: scratchDirectory("\(name)-queue")),
                        home: scratchDirectory("\(name)-home"), caches: caches, openDatabase: { _ in try Database(path: path) },
                        defaults: { ServiceTests.defaults }, schema: { WriteTests.schema }), caches)
    }

    static func small(_ id: String, canvas: [Double] = [600, 400], crop: [Double] = [300, 200, 600, 400], rotation: Double = 0) -> VariantState {
        var state = FakeCaptureOne.state(id, adjustments: ["rotation": .double(rotation)])
        state.variant["crop"] = .array(crop.map(JSONValue.double))
        state.canvasSize = canvas
        state.maximumCrop = [canvas[0] / 2, canvas[1] / 2, canvas[0], canvas[1]]
        return state
    }

    static func fake(_ states: VariantState...) -> FakeCaptureOne {
        let fake = FakeCaptureOne()
        fake.variants = [.collection(cid("10")): Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) })]
        return fake
    }

    static func exports(_ fake: FakeCaptureOne) -> [ExportRequest] {
        fake.calls.compactMap { if case .export(let request) = $0 { return request }; return nil }
    }

    /// The canvas point a gradient pixel shows, from its red and green.
    static func canvasPoint(_ image: CGImage, x: Int, y: Int, canvas: [Double]) -> (x: Double, y: Double) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return (Double(pixel[0]) / 255 * canvas[0], Double(pixel[1]) / 255 * canvas[1])
    }

    static func image(_ result: JSONValue) -> CGImage? {
        guard case .string(let path)? = result["path"], let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func argumentsFailBeforeDispatch() {
        let fake = fake(small("1"))
        let (service, _) = service(fake, "viewing-arguments")
        let region = Region(x: 0.5, y: 0, width: 0.6, height: 0.2)
        for (arguments, text) in [(PreviewArguments(id: id("1"), size: 199), "size must be 200–3000"),
                                  (PreviewArguments(id: id("1"), size: 3001), "size must be 200–3000"),
                                  (PreviewArguments(id: id("1"), region: region), "x + width"),
                                  (PreviewArguments(id: id("1"), region: Region(x: 0, y: 0, width: 0, height: 1)), "width, height > 0"),
                                  (PreviewArguments(id: id("1"), region: Region(x: 0, y: 0, width: 1, height: 1), scale: 1.5), "scale must be"),
                                  (PreviewArguments(id: id("1"), size: 800, region: Region(x: 0, y: 0, width: 1, height: 1)), "region takes scale"),
                                  (PreviewArguments(id: id("1"), fullFrame: true, region: Region(x: 0, y: 0, width: 1, height: 1)), "region takes scale"),
                                  (PreviewArguments(id: id("1"), scale: 0.5), "scale goes with region"),
                                  (PreviewArguments(id: id("1"), timeout: 0.5), "timeout must be")] {
            checkFailure(.invalidArguments, containing: text) { _ = try service.preview(arguments) }
        }
        checkFailure(.invalidArguments, containing: "1–6 candidates") { _ = try service.cropPreview(CropPreviewArguments(id: id("1"), candidates: [])) }
        let seven = Array(repeating: CanvasRect(centerX: 300, centerY: 200, width: 100, height: 100), count: 7)
        checkFailure(.invalidArguments, containing: "1–6 candidates") { _ = try service.cropPreview(CropPreviewArguments(id: id("1"), candidates: seven)) }
        for candidate in [CanvasRect(centerX: 300, centerY: 200, width: 1e100, height: 100), CanvasRect(centerX: 300, centerY: 200, width: 100, height: 1e-320),
                          CanvasRect(centerX: 300, centerY: 200, width: 100, height: 0.5), CanvasRect(centerX: -2e6, centerY: 200, width: 100, height: 100)] {
            checkFailure(.invalidArguments, containing: "Candidate 1 needs") { _ = try service.cropPreview(CropPreviewArguments(id: id("1"), candidates: [candidate])) }
        }
        checkEqual(fake.calls, [], "invalid arguments fail before any Apple Event")

        let outside = CanvasRect(centerX: 580, centerY: 200, width: 100, height: 100)
        checkFailure(.invalidArguments, containing: "Candidate 2 lies outside cropBounds (image): the top right corner by 30 px") {
            _ = try service.cropPreview(CropPreviewArguments(id: id("1"), candidates: [CanvasRect(centerX: 300, centerY: 200, width: 100, height: 100), outside]))
        }
        checkEqual(exports(fake), [], "a candidate outside cropBounds fails before the export")
        checkFailure(.notFound) { _ = try service.preview(PreviewArguments(id: id("9"))) }
    }

    static func cropPreview() {
        let fake = fake(small("1"))
        let (service, caches) = service(fake, "viewing-crop")
        let candidates = [CanvasRect(centerX: 300, centerY: 200, width: 300, height: 200),
                          CanvasRect(centerX: 150, centerY: 300, width: 150, height: 100),
                          CanvasRect(centerX: 450, centerY: 120, width: 120, height: 160)]
        guard let first = try? service.cropPreview(CropPreviewArguments(id: id("1"), candidates: candidates, size: 900)) else {
            return check(false, "crop_preview failed")
        }
        checkEqual(exports(fake).map(\.fullFrame), [true], "one full-frame export")
        checkEqual(exports(fake).first?.longEdge, 1500, "the cached frame is at least 1500 px")
        checkEqual(first["cached"], .bool(false))
        guard let composite = image(first), case .array(let items)? = first["candidates"], items.count == 3 else { return check(false, "no composite") }
        check(abs(max(composite.width, composite.height) - 900) <= 2, "the composite's long edge is size: \(composite.width)×\(composite.height)")
        for (candidate, item) in zip(candidates, items) {
            guard let x = item["rect"]?["x"]?.number, let y = item["rect"]?["y"]?.number,
                  let w = item["rect"]?["width"]?.number, let h = item["rect"]?["height"]?.number else { return check(false, "no rect") }
            check(abs(w / h - candidate.width / candidate.height) < 0.02, "tile keeps the candidate's proportions: \(w)×\(h)")
            // Away from the number badge in the top left corner.
            let point = canvasPoint(composite, x: Int(x + w * 0.7), y: Int(y + h * 0.7), canvas: [600, 400])
            let expected = (candidate.centerX + 0.2 * candidate.width, candidate.centerY - 0.2 * candidate.height)
            check(abs(point.x - expected.0) < 6 && abs(point.y - expected.1) < 6,
                  "tile shows its candidate's canvas point \(expected), got \(point)")
        }
        checkEqual(items[1]["crop"], .object(["centerX": .double(150), "centerY": .double(300), "width": .double(150), "height": .double(100)]))

        let again = try? service.cropPreview(CropPreviewArguments(id: id("1"), candidates: [candidates[0]], size: 900))
        checkEqual(again?["cached"], .bool(true), "the same state reuses the frame")
        fake.variants[.collection(cid("10"))]![id("1")]!.variant["crop"] = .array([.double(200), .double(200), .double(300), .double(300)])
        fake.variants[.collection(cid("10"))]![id("1")]!.variant["rating"] = .int(4)
        let cropped = try? service.cropPreview(CropPreviewArguments(id: id("1"), candidates: [candidates[0]], size: 900))
        checkEqual(cropped?["cached"], .bool(true), "a crop or rating change keeps the frame")
        fake.variants[.collection(cid("10"))]![id("1")]!.adjustments["exposure"] = .double(1)
        let edited = try? service.cropPreview(CropPreviewArguments(id: id("1"), candidates: [candidates[0]], size: 900))
        checkEqual(edited?["cached"], .bool(false), "another setting renders again")
        checkEqual(exports(fake).count, 2)
        let frames = (try? FileManager.default.subpathsOfDirectory(atPath: caches.path))?.filter { $0.contains("frame-1-") } ?? []
        checkEqual(frames.count, 2, "one cached frame per render state: \(frames)")
        checkEqual(fake.state(id("1"))?.variant["crop"], .array([.double(200), .double(200), .double(300), .double(300)]), "crop_preview writes nothing")
        check(!fake.calls.contains { if case .write = $0 { return true }; return false }, "no write reaches Capture One")
        let refreshed = try? service.cropPreview(CropPreviewArguments(id: id("1"), candidates: [candidates[0]], size: 900, refresh: true))
        checkEqual(refreshed?["cached"], .bool(false), "refresh renders again, for a mask painted in Capture One")
        let tag = (try? service.action("layer.create", ids: [id("1")], arguments: [:]))?["variants"]?.arrayValue?.first?["layer"]?.stringValue ?? ""
        _ = try? service.cropPreview(CropPreviewArguments(id: id("1"), candidates: [candidates[0]], size: 900))
        let masked = try? service.action("mask.invert", ids: [id("1")], arguments: ["layer": .string(tag)])
        checkEqual(masked?["variants"]?.arrayValue?.first?["outcome"], .string("ok"))
        let afterMask = try? service.cropPreview(CropPreviewArguments(id: id("1"), candidates: [candidates[0]], size: 900))
        checkEqual(afterMask?["cached"], .bool(false), "an action drops the cached frame, whose key cannot see mask pixels")
    }

    /// Measured on 16.8.5.30 at rotation 5: canvas 6325 × 4507, default crop {3162, 2253, 5324, 3549}.
    static func fullFrameMapping() {
        var state = small("1", canvas: [6325, 4507], crop: [2900, 2100, 2400, 1600], rotation: 5)
        state.maximumCrop = nil
        let fake = fake(state)
        fake.defaultCrops[id("1")] = [3162.5, 2253.5, 5324.1, 3549.4]
        let (service, _) = service(fake, "viewing-full")
        guard let result = try? service.preview(PreviewArguments(id: id("1"), size: 800, fullFrame: true)),
              let mapping = result["fullFrame"]?["mapping"], let scale = mapping["scale"]?.number,
              let left = mapping["left"]?.number, let top = mapping["top"]?.number else { return check(false, "no mapping") }
        checkEqual(result["width"], .int(800))
        check(abs(left - (3162.5 - 5324.1 / 2)) < 1 && abs(top - (2253.5 + 3549.4 / 2)) < 1 && abs(scale - 800 / 5324.1) < 1e-3,
              "the full frame is the default crop, computed from canvas and rotation: \(mapping.encoded())")
        guard let crop = result["fullFrame"]?["currentCrop"], let x = crop["x"]?.number, let y = crop["y"]?.number else { return check(false, "no currentCrop") }
        check(abs(x - (1700 - left) * scale) < 0.1 && abs(y - (top - 2900) * scale) < 0.1, "currentCrop in preview pixels: \(crop.encoded())")
        if let rendered = image(result) {
            let point = canvasPoint(rendered, x: Int(x) + 40, y: Int(y) + 40, canvas: [6325, 4507])
            check(abs(point.x - (1700 + 40 / scale)) < 60 && abs(point.y - (2900 - 40 / scale)) < 60, "the mapping finds the canvas point: \(point)")
        }
        checkEqual(exports(fake).map(\.fullFrame), [true])

        let outside = CanvasRect(centerX: 1500, centerY: 4200, width: 400, height: 200)
        checkFailure(.invalidArguments, containing: "Candidate 1 reaches past the full-frame render") {
            _ = try service.cropPreview(CropPreviewArguments(id: id("1"), candidates: [outside]))
        }
    }

    static func regionMapping() {
        let fake = fake(small("1", canvas: [800, 600], crop: [500, 300, 600, 400]))
        let (service, caches) = service(fake, "viewing-region")
        guard let result = try? service.preview(PreviewArguments(id: id("1"), region: Region(x: 0.25, y: 0.5, width: 0.5, height: 0.25))),
              let rendered = image(result) else { return check(false, "region failed") }
        checkEqual(exports(fake).first?.longEdge, 600, "scale 1 renders the crop at full resolution")
        checkEqual([rendered.width, rendered.height], [300, 100], "the region's pixels at scale 1")
        checkEqual(result["region"]?["crop"], .object(["centerX": .double(500), "centerY": .double(250), "width": .double(300), "height": .double(100)]),
                   "the region in full-resolution canvas pixels, as set takes a crop")
        let point = canvasPoint(rendered, x: 150, y: 50, canvas: [800, 600])
        check(abs(point.x - 500) < 6 && abs(point.y - 250) < 6, "the region shows its canvas area: \(point)")
        let files = (try? FileManager.default.subpathsOfDirectory(atPath: caches.path))?.filter { $0.hasSuffix(".jpg") } ?? []
        checkEqual(files.count, 1, "the intermediate render is deleted: \(files)")
        for tiny in [Region(x: 0, y: 0, width: 1e-320, height: 0.5), Region(x: 0, y: 0, width: 0.5, height: 0.001)] {
            checkFailure(.invalidArguments, containing: "at least 1 px") { _ = try service.preview(PreviewArguments(id: id("1"), region: tiny)) }
        }
        checkEqual(exports(fake).count, 1, "a region under 1 px fails before Capture One renders")

        let big = Self.fake(small("1", canvas: [3000, 2000], crop: [1500, 1000, 3000, 2000]))
        let (bigService, _) = Self.service(big, "viewing-region-cap")
        let capped = try? bigService.preview(PreviewArguments(id: id("1"), region: Region(x: 0, y: 0, width: 1, height: 1)))
        checkEqual([capped?["width"], capped?["height"]], [JSONValue.int(2048), .int(1365)] as [JSONValue?], "the result is capped at 2048 px")
        check(abs((capped?["region"]?["scale"]?.number ?? 0) - 2048.0 / 3000) < 1e-3, "the scale reports the cap")
    }

    static func timeoutIsUnknownAndReleasesTheQueue() {
        let fake = fake(small("1"))
        fake.exportDelay = nil
        let directory = scratchDirectory("viewing-timeout-queue")
        let (service, _) = service(fake, "viewing-timeout", queue: CaptureOneQueue(directory: directory))
        var other: Result<JSONValue, Error>?
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.5)
            let quick = Service(captureOne: fake, queue: CaptureOneQueue(directory: directory, maxWait: 0.3), home: scratchDirectory("viewing-timeout-other"))
            other = Result { try quick.selection() }
        }
        do {
            _ = try service.preview(PreviewArguments(id: id("1"), size: 400, timeout: 2))
            check(false, "expected a timeout")
        } catch let failure as C1Failure {
            check(failure.code == .timeout && failure.outcomeUnknown && failure.message.contains("previews/\(Fixture.uuid)/1-crop-400-"),
                  "a timeout is unknown and names where the file will land: \(failure)")
        } catch {
            check(false, "\(error)")
        }
        check((try? other?.get()) != nil, "another call ran while the export was pending: \(String(describing: other))")
    }

    static func pruning() {
        let fake = fake(small("1"))
        let (service, caches) = service(fake, "viewing-prune")
        let manager = FileManager.default
        func make(_ file: URL, age days: Double) {
            try! manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            manager.createFile(atPath: file.path, contents: Data("x".utf8))
            try! manager.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86400)], ofItemAtPath: file.path)
        }
        let folder = caches.appendingPathComponent("previews/OLD-DOC")
        for name in ["5-full-800-89abcdef.jpg", "5-crop-800-89abcdef.jpg", "5-region-640-89abcdef.jpg", "5-candidates-800-89abcdef.jpg",
                     "5-render-1200-89abcdef.jpg", "frame-5-0123456789abcdef.jpg", "tile-5-0123456789abcdef.jpg", "thumb-5-400.jpg",
                     "sheet-1-9-89abcdef.jpg"] { make(folder.appendingPathComponent(name), age: 8) }
        let current = caches.appendingPathComponent("previews/\(Fixture.uuid)")
        let recent = current.appendingPathComponent("1-crop-1500-0123abcd.jpg")
        let exports = ["IMG_0001.jpg", "5-crop-800-89abcdef_1.jpg"].map(current.appendingPathComponent)
        make(recent, age: 6)
        for file in exports { make(file, age: 8) }
        fake.outputFolderMissing = true
        let result = try? service.preview(PreviewArguments(id: id("1"), size: 300))
        check(result?["warnings"]?.arrayValue?.first?.stringValue?.contains("output folder was unset or missing") == true,
              "a result says when c1 set the Catalog's output folder: \(String(describing: result))")
        check(!manager.fileExists(atPath: folder.path), "every kind of c1 file older than 7 days goes, with its emptied folder")
        check(manager.fileExists(atPath: recent.path), "younger files stay")
        for file in exports {
            check(manager.fileExists(atPath: file.path), "\(file.lastPathComponent), not named by c1, stays however old: the output folder may point here")
        }
    }

    static func rows(_ cells: [CGRect]) -> [[CGRect]] { Dictionary(grouping: cells, by: \.minY).sorted { $0.key < $1.key }.map(\.value) }

    /// v1's layout facts, kept for v2.
    static func sheetLayout() {
        let standard = try! SheetLayout()
        checkFailure(.invalidArguments) { _ = try SheetLayout(perPage: 49) }
        checkFailure(.invalidArguments) { _ = try SheetLayout(rowHeight: 119) }
        let full = standard.arrange(Array(repeating: 1.5, count: 20))
        checkEqual(rows(full.cells).map(\.count), [5, 5, 5, 5], "a fifth 330 px image overflows; taking it gives 202 px rows, nearer 220 than 253")
        checkEqual(rows(full.cells).map { Int($0.last!.maxX) }, [1532, 1532, 1532, 1532], "closed rows fill the width")
        checkEqual(full.cells[0], CGRect(x: 4, y: 28, width: 302, height: 202))
        checkEqual(full.height, 28 + 4 * (202 + 20))
        let partial = standard.arrange(Array(repeating: 1.5, count: 7))
        checkEqual(Array(partial.cells[5...]), [CGRect(x: 4, y: 250, width: 330, height: 220), CGRect(x: 338, y: 250, width: 330, height: 220)],
                   "the last row keeps rowHeight, left-aligned")
        let single = standard.arrange([1.5])
        checkEqual([single.width, single.height], [480, 268], "a one-image page keeps the minimum width")
        checkEqual(standard.arrange([4, 30]).cells, [CGRect(x: 4, y: 28, width: 1320, height: 330), CGRect(x: 4, y: 378, width: 1528, height: 51)],
                   "a row stretches at most 1.5 × rowHeight")
        let tall = try! SheetLayout(perPage: 48, rowHeight: 450)
        let lowered = tall.arrange(Array(repeating: 1.5, count: 48))
        check(lowered.width == 1536 && lowered.height <= 2400 && lowered.height > 2200, "a tall page gets lower rows: \(lowered.width)×\(lowered.height)")
    }

    static func writeCot(_ url: URL, width: Int, height: Int, comment: String?) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let image = FakeCaptureOne.gradient(area: [Double(width) / 2, Double(height) / 2, Double(width), Double(height)],
                                            canvas: [Double(width), Double(height)], longEdge: max(width, height))
        let temporary = url.appendingPathExtension("jpg")
        FakeCaptureOne.writeJPEG(image, to: temporary, properties: comment.map { [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: $0]] } ?? [:])
        try? FileManager.default.removeItem(at: url)
        try! FileManager.default.moveItem(at: temporary, to: url)
    }

    static func contactSheet() {
        let fake = FakeCaptureOne()
        let (service, caches) = service(fake, "viewing-sheet")
        let thumbnails = scratchURL("viewing-sheet").appendingPathComponent("Cache/Thumbnails")
        writeCot(thumbnails.appendingPathComponent("00000001.cot"), width: 300, height: 200, comment: "3|0;0;0|30;180;270;20|0")
        writeCot(thumbnails.appendingPathComponent("00000002.cot"), width: 300, height: 200, comment: "2|0;0;0|30;180;270;20|0")
        guard let result = try? service.contactSheet(ContactSheetArguments(perPage: 3), document: scratchURL("viewing-sheet").appendingPathComponent("viewing-sheet.cocatalogdb").path),
              case .array(let tiles)? = result["tiles"] else { return check(false, "contact_sheet failed") }
        checkEqual(fake.calls, [], "contact_sheet makes no Apple Events")
        checkEqual(tiles.map { $0["id"] }, [.string("1"), .string("2"), .string("3")])
        checkEqual(tiles.map { $0["status"] }, [.string("shown"), .string("shown"), .string("missing")])
        checkEqual(tiles.map { $0["crop"] ?? .null }, [.string("applied"), .string("not-applied"), .null], "a version 3 crop applies; version 2 does not")
        checkEqual(result["next"], .string("3"), "pages continue after the last id")
        if let first = tiles.first?["cell"], let w = first["width"]?.number, let h = first["height"]?.number {
            check(abs(w / h - 1.5) < 0.02, "the tile shows the 240 × 160 crop: \(w)×\(h)")
        }
        check(result["path"]?.stringValue?.hasPrefix(caches.appendingPathComponent("previews/\(Fixture.uuid)/sheet-1-3-").path) == true, "the sheet lands in the cache")
        checkEqual(CotCropProbe.parse("3|0;0;0|0;200;300;0|0"), "full-frame")
        let next = try? service.contactSheet(ContactSheetArguments(after: id("3"), perPage: 3),
                                             document: scratchURL("viewing-sheet").appendingPathComponent("viewing-sheet.cocatalogdb").path)
        checkEqual(next?["tiles"]?.arrayValue?.count, 1)
        checkEqual(next?["next"], nil)
    }

    /// Variant 3 lives in the fixture's subfolder, collection 11.
    static func subfolderFake() -> FakeCaptureOne {
        let fake = FakeCaptureOne()
        fake.variants = [.collection(cid("11")): [id("3"): small("3")]]
        return fake
    }

    static func contactSheetFillsGaps() {
        let fake = subfolderFake()
        let (service, _) = service(fake, "viewing-fill")
        let document = scratchURL("viewing-fill").appendingPathComponent("viewing-fill.cocatalogdb").path
        writeCot(scratchURL("viewing-fill").appendingPathComponent("Cache/Thumbnails/00000001.cot"), width: 300, height: 200, comment: "3|0;0;0|0;200;300;0|0")
        for arguments in [ContactSheetArguments(perPage: 3, timeout: 30), ContactSheetArguments(perPage: 3, refresh: true)] {
            checkFailure(.invalidArguments, containing: "go with fillMissing") { _ = try service.contactSheet(arguments, document: document) }
        }
        func sheet(refresh: Bool? = nil) -> [JSONValue] {
            (try? service.contactSheet(ContactSheetArguments(perPage: 3, fillMissing: true, refresh: refresh), document: document))?["tiles"]?.arrayValue ?? []
        }
        let first = sheet()
        checkEqual(first.map { $0["status"] }, [.string("shown"), .string("missing"), .string("exported")],
                   "a cached tile stays; a gap Capture One has is exported; one it lacks stays missing")
        check(first.count == 3 && first[1]["fillError"]?.stringValue?.contains("no variant 2") == true, "the unfilled gap says why")
        checkEqual(first.last?["reused"], .bool(false))
        checkEqual(exports(fake).map { [$0.target.id.description, "\($0.longEdge)", "\($0.fullFrame)"] }, [["3", "1024", "false"]],
                   "only the gap is exported, cropped, at the tile edge")
        if let cell = first.last?["cell"], let w = cell["width"]?.number, let h = cell["height"]?.number {
            check(abs(w / h - 1.5) < 0.02, "the exported tile keeps the crop's proportions: \(w)×\(h)")
        }

        fake.variants[.collection(cid("11"))]![id("3")]!.variant["rating"] = .int(5)
        checkEqual(sheet().last?["reused"], .bool(true), "a rating change reuses the export")
        checkEqual(exports(fake).count, 1)

        fake.variants[.collection(cid("11"))]![id("3")]!.variant["crop"] = .array([300, 200, 400, 400].map(JSONValue.double))
        checkEqual(sheet().last?["reused"], .bool(false), "a crop change exports again")
        checkEqual(exports(fake).count, 2)
        checkEqual(sheet(refresh: true).last?["reused"], .bool(false), "refresh exports again")
        checkEqual(exports(fake).count, 3)
        let tag = (try? service.action("layer.create", ids: [id("3")], arguments: [:]))?["variants"]?.arrayValue?.first?["layer"]?.stringValue ?? ""
        _ = sheet()
        _ = try? service.action("mask.fill", ids: [id("3")], arguments: ["layer": .string(tag)])
        checkEqual(sheet().last?["reused"], .bool(false), "an action drops the variant's exported tile")

        let late = subfolderFake()
        late.exportDelay = 5
        let (slow, _) = ViewingTests.service(late, "viewing-fill-late")
        let slowDocument = scratchURL("viewing-fill-late").appendingPathComponent("viewing-fill-late.cocatalogdb").path
        let tiles = (try? slow.contactSheet(ContactSheetArguments(perPage: 3, fillMissing: true, timeout: 1), document: slowDocument))?["tiles"]?.arrayValue ?? []
        check(tiles.count == 3 && tiles[2]["status"] == JSONValue.string("missing") && tiles[2]["fillError"]?.stringValue?.contains("may still land") == true,
              "a late export leaves its tile missing and says where it may land, without failing the sheet")
    }

    static func thumbOfAJPEG() {
        let folder = scratchDirectory("viewing-thumb-originals")
        let original = folder.appendingPathComponent("photo.jpg")
        let pixels = FakeCaptureOne.gradient(area: [1000, 750, 2000, 1500], canvas: [2000, 1500], longEdge: 2000)
        FakeCaptureOne.writeJPEG(pixels, to: original, properties: [kCGImagePropertyOrientation: 6])
        let sql = """
            INSERT INTO ZPATHLOCATION VALUES (103,'/','\(folder.path.dropFirst())',0);
            INSERT INTO ZIMAGE VALUES (5,'photo','photo.jpg',103,0,0);
            INSERT INTO ZVARIANT VALUES (6,5,41,42,NULL);
            """
        let (service, _) = service(FakeCaptureOne(), "viewing-thumb", extraSQL: sql)
        let document = scratchURL("viewing-thumb").appendingPathComponent("viewing-thumb.cocatalogdb").path
        let result = try? service.thumb(ThumbArguments(id: id("6"), maxSize: 800), document: document)
        checkEqual([result?["width"], result?["height"], result?["source"]], [JSONValue.int(600), .int(800), .string("file")] as [JSONValue?],
                   "a JPEG original is read itself, turned upright and fitted to maxSize")
        checkFailure(.notFound, containing: "not readable") { _ = try service.thumb(ThumbArguments(id: id("1")), document: document) }
        checkFailure(.invalidArguments) { _ = try service.thumb(ThumbArguments(id: id("6"), maxSize: 100), document: document) }
    }

    static func commandTable() {
        checkFailure(.invalidArguments, containing: "does not take size") {
            _ = try Command.thumb.run(Service(captureOne: FakeCaptureOne(), queue: CaptureOneQueue(directory: scratchDirectory("viewing-command"))),
                                      arguments: Data(#"{"id":"1","size":3}"#.utf8))
        }
        check(Command.contactSheet.acceptsDocumentPath && Command.thumb.acceptsDocumentPath && !Command.preview.acceptsDocumentPath,
              "SQLite-only commands take a document path")
    }
}

/// `CotCrop` is internal; this reads its verdict through a one-tile sheet.
enum CotCropProbe {
    static func parse(_ comment: String) -> String {
        let name = "viewing-cot-\(abs(comment.hashValue))"
        let path = Fixture.make(name)
        writeCot(scratchURL(name).appendingPathComponent("Cache/Thumbnails/00000001.cot"), comment: comment)
        let service = Service(captureOne: FakeCaptureOne(), queue: CaptureOneQueue(directory: scratchDirectory("\(name)-queue")),
                              home: scratchDirectory("\(name)-home"), caches: scratchDirectory("\(name)-caches"))
        let result = try? service.contactSheet(ContactSheetArguments(ids: [id("1")]), document: path)
        return result?["tiles"]?.arrayValue?.first?["crop"]?.stringValue ?? "none"
    }

    static func writeCot(_ url: URL, comment: String) { ViewingTests.writeCot(url, width: 300, height: 200, comment: comment) }
}
