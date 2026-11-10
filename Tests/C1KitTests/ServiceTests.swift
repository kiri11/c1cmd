import C1Kit
import Foundation

enum ServiceTests {
    static func run() {
        catalogRoutesAndFallback()
        staleFolderFallsBack()
        documentReadIsFolded()
        sessionFallsBackToFavorites()
        changedFiltering()
        timeoutReporting()
        commandArguments()
        liveCallsShareTheQueue()
        databasePaths()
        catalogDatabaseDiscovery()
    }

    static func databasePaths() {
        checkEqual(try! LiveDocument(id: "/s/Shoot", kind: .session, name: "Shoot.cosessiondb", folder: "/s/Shoot", appVersion: "").databasePath,
                   "/s/Shoot/Shoot.cosessiondb", "a Session's name already carries the extension")
        checkEqual(try! LiveDocument(id: "/c/Main.cocatalog", kind: .catalog, name: "Main", folder: "/c/Main.cocatalog", appVersion: "").databasePath,
                   "/c/Main.cocatalog/Main.cocatalogdb")
        checkEqual(try! LiveDocument(id: "/c/Main.cocatalogdb", kind: .catalog, name: "Main", folder: "/c/Main.cocatalogdb", appVersion: "").databasePath,
                   "/c/Main.cocatalogdb", "an unpackaged Catalog")
    }

    static func catalogDatabaseDiscovery() {
        let source = URL(fileURLWithPath: Fixture.make("catalog-discovery-source"))
        for folderName in ["C1", "Renamed.cocatalog"] {
            let folder = scratchDirectory("catalog-discovery-\(folderName)")
            let database = folder.appendingPathComponent("Catalog2.cocatalogdb")
            try! FileManager.default.copyItem(at: source, to: database)
            // Backups and directories with the same extension are not database candidates.
            try! FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("Catalog2.cocatalogdb.backup"))
            try! FileManager.default.createDirectory(at: folder.appendingPathComponent("Ignored.cocatalogdb"), withIntermediateDirectories: true)
            let fake = FakeCaptureOne()
            fake.liveDocument = LiveDocument(id: folder.path, kind: .catalog, name: "C1", folder: folder.path, appVersion: "16.8.5.30")
            fake.variants = [.collection(cid("10")): [id("1"): FakeCaptureOne.state("1")]]
            let service = Service(captureOne: fake, queue: CaptureOneQueue(directory: scratchDirectory("\(folderName)-discovery-queue")),
                                  home: scratchDirectory("\(folderName)-discovery-home"), liveTerms: { .snapshot })
            checkEqual(try? fake.liveDocument.databasePath, database.path, "Catalog discovery ignores the document name")
            checkEqual(try? service.doctor()["document"]?["uuid"], .string(Fixture.uuid), "doctor opens the discovered database")
            checkEqual(try? ids(service.list(ListQuery(limit: 1), document: nil)), ["1"])
            checkEqual(try? ids(service.get(ids: [id("1")])), ["1"], "live reads use the discovered database")
            checkEqual(try? ids(service.list(ListQuery(limit: 1), document: database.path)), ["1"], "explicit database paths still work")
            if folder.pathExtension == "cocatalog" {
                checkEqual(try? ids(service.list(ListQuery(limit: 1), document: folder.path)), ["1"], "explicit Catalog packages also discover the database")
            }
            try! FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("Other.cocatalogdb"))
            checkFailure(.database, containing: "Multiple Catalog databases") { _ = try service.doctor() }
            if folder.pathExtension == "cocatalog" {
                checkFailure(.database, containing: "Multiple Catalog databases") { _ = try service.list(ListQuery(), document: folder.path) }
            }
            checkEqual(try? ids(service.list(ListQuery(limit: 1), document: database.path)), ["1"], "an explicit database resolves ambiguity")
            let named = folder.appendingPathComponent("C1.cocatalogdb")
            try! FileManager.default.copyItem(at: source, to: named)
            checkEqual(try? fake.liveDocument.databasePath, named.path, "the database named after the document wins over the others")
            checkEqual(try? service.doctor()["document"]?["uuid"], .string(Fixture.uuid), "doctor opens the named database beside others")
            if folder.pathExtension == "cocatalog" {
                try! FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(folder.deletingPathExtension().lastPathComponent + ".cocatalogdb"))
                checkEqual(try? ids(service.list(ListQuery(limit: 1), document: folder.path)), ["1"], "an explicit package opens the database named after it")
            }
        }
    }

    static func liveCallsShareTheQueue() {
        let fake = FakeCaptureOne()
        fake.delay = 0.02
        let directory = scratchDirectory("shared-queue")
        let path = Fixture.make("shared-queue-db")
        fake.variants = [.collection(cid("10")): [id("1"): FakeCaptureOne.state("1")]]
        let group = DispatchGroup()
        for index in 0..<6 {
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }
                let service = Service(captureOne: fake, queue: CaptureOneQueue(directory: directory, pollInterval: 0.002),
                                      home: scratchDirectory("shared-queue-home-\(index)"), openDatabase: { _ in try Database(path: path) }, defaults: { defaults })
                _ = index.isMultiple(of: 2) ? try? service.selection() : try? service.get(ids: [id("1")])
            }
        }
        group.wait()
        checkEqual(fake.maxConcurrent, 1, "Capture One sees one call at a time across services")
        checkEqual(fake.calls.count, 9, "three selections, and three gets of a document and a read each")
    }

    static let defaults = Defaults(
        alwaysReported: ["variant": ["id"], "adjustments": ["temperature"], "lensCorrection": [], "layer": ["kind", "name"]],
        defaults: ["variant": ["rating": .int(0), "color tag": .int(0), "crop": .array([.int(3000), .int(2000), .int(6000), .int(4000)])],
                   "adjustments": ["exposure": .double(0), "contrast": .double(0), "rotation": .double(0)],
                   "lensCorrection": ["distortion": .double(0)], "layer": ["opacity": .int(100), "enabled": .bool(true)]])

    static func service(_ fake: FakeCaptureOne, _ name: String, documentType: Int = 1, extraSQL: String = "",
                        now: @escaping () -> Date = Date.init, liveTerms: @escaping () throws -> Terminology = { .snapshot }) -> Service {
        let path = Fixture.make(name, documentType: documentType, extraSQL: extraSQL)
        return Service(captureOne: fake, queue: CaptureOneQueue(directory: scratchDirectory("\(name)-queue")),
                       home: scratchDirectory("\(name)-home"), openDatabase: { _ in try Database(path: path) },
                       defaults: { defaults }, schema: { WriteTests.schema }, now: now, liveTerms: liveTerms)
    }

    static func catalogRoutesAndFallback() {
        let fake = FakeCaptureOne()
        fake.variants = [.collection(cid("10")): [id("1"): FakeCaptureOne.state("1")],
                         .collection(cid("11")): [id("3"): FakeCaptureOne.state("3")],
                         .allImages(cid("2")): [id("4"): FakeCaptureOne.state("4")]]
        let result = try! service(fake, "routes").get(ids: [id("1"), id("3"), id("4"), id("99"), id("1")])
        checkEqual(fake.calls, [.document, .read([ReadTarget(id("1"), .collection(cid("10"))), ReadTarget(id("3"), .collection(cid("11"))),
                                                   ReadTarget(id("4"), .allImages(cid("2"))), ReadTarget(id("99"), .allImages(cid("2")))])],
                   "folder routes, All Images when SQLite has no folder, one read for the batch")
        checkEqual(ids(result), ["1", "3", "4", "99"], "results keep request order without duplicates")
        guard case .array(let items)? = result["variants"] else { return check(false, "no variants") }
        checkEqual(items[0]["route"], .string("collection 10"))
        checkEqual(items[2]["route"], .string("all images 2"))
        checkEqual(items[3]["error"]?["code"], .string("not-found"), "a missing id fails alone")
        checkEqual(items[0]["adjustments"]?["temperature"], .double(5000), "full state without changed")
        checkEqual(items[0]["cropBounds"]?["source"], .string("image"), "get reports cropBounds")
    }

    static func documentReadIsFolded() {
        let fake = FakeCaptureOne()
        fake.variants = [.collection(cid("10")): [id("1"): FakeCaptureOne.state("1")]]
        let service = service(fake, "folded")
        _ = try! service.get(ids: [id("1")])
        _ = try! service.get(ids: [id("1")])
        let read = FakeCaptureOne.Call.read([ReadTarget(id("1"), .collection(cid("10")))])
        checkEqual(fake.calls, [.document, read, read], "after the first call, a get is one read that also reports the document")

        fake.liveDocument = LiveDocument(id: "/other.cocatalog", kind: .catalog, name: "other", folder: "/other.cocatalog", appVersion: "16.8.5.30")
        _ = try! service.get(ids: [id("1")])
        checkEqual(fake.calls.count, 5, "a different live document makes c1 plan the read again")
    }

    static func staleFolderFallsBack() {
        let fake = FakeCaptureOne()
        fake.variants = [.allImages(cid("2")): [id("1"): FakeCaptureOne.state("1")]]
        fake.notFoundRoutes = [.collection(cid("10"))]
        let result = try! service(fake, "stale").get(ids: [id("1")])
        checkEqual(fake.calls, [.document, .read([ReadTarget(id("1"), .collection(cid("10")))]), .read([ReadTarget(id("1"), .allImages(cid("2")))])],
                   "not found in the folder retries through All Images")
        guard case .array(let items)? = result["variants"] else { return check(false, "no variants") }
        checkEqual(items[0]["route"], .string("all images 2"))
    }

    static func sessionFallsBackToFavorites() {
        let fake = FakeCaptureOne()
        fake.liveDocument = LiveDocument(id: "/s", kind: .session, name: "s", folder: "/s", appVersion: "16.8.5.30")
        fake.variants = [.collection(cid("11")): [id("3"): FakeCaptureOne.state("3"), id("4"): FakeCaptureOne.state("4")]]
        let result = try! service(fake, "session", documentType: 0).get(ids: [id("3"), id("4")])
        checkEqual(fake.calls, [.document, .read([ReadTarget(id("3"), .collection(cid("11"))), ReadTarget(id("4"), .favoritesScan)])],
                   "a Session falls back to scanning favorites")
        checkEqual(ids(result), ["3", "4"])

        let mismatch = FakeCaptureOne()
        checkFailure(.database, containing: "session") { _ = try service(mismatch, "kind-mismatch", documentType: 0).get(ids: [id("3")]) }
    }

    static func changedFiltering() {
        var state = FakeCaptureOne.state("1", adjustments: ["exposure": .double(0.5), "contrast": .double(1e-9)])
        state.layers.append(["kind": .string("adjustment"), "name": .string("Sky"), "opacity": .int(100),
                             "adjustments": .object(["exposure": .double(0), "temperature": .double(5000), "contrast": .double(-20)])])
        let changed = defaults.changed(state)
        checkEqual(changed["adjustments"], .object(["exposure": .double(0.5), "temperature": .double(5000)]),
                   "changed keeps differing and always-reported fields; floats compare with tolerance")
        checkEqual(changed["variant"], .object(["id": .string("1")]))
        checkEqual(changed["lensCorrection"], .object([:]))
        checkEqual(changed["layers"], .array([
            .object(["kind": .string("background"), "name": .string("Background")]),
            .object(["kind": .string("adjustment"), "name": .string("Sky"), "adjustments": .object(["contrast": .double(-20)])]),
        ]), "a layer's camera-dependent adjustments compare against the Image layer")

        let fake = FakeCaptureOne()
        fake.variants = [.collection(cid("10")): [id("1"): state]]
        let result = try! service(fake, "changed").get(ids: [id("1")], changed: true)
        guard case .array(let items)? = result["variants"] else { return check(false, "no variants") }
        checkEqual(items[0]["adjustments"], changed["adjustments"], "get applies changed")
    }

    static func timeoutReporting() {
        let mapped = AppleScriptCaptureOne.failure(message: "AppleEvent timed out.", number: -1712)
        checkEqual(mapped.code, .timeout)
        check(mapped.outcomeUnknown, "a timeout's outcome is unknown")
        check(mapped.hint?.contains("Automation") == true && mapped.hint?.contains("get again") == true, "the hint names the consent dialog and get")
        checkEqual(mapped.json["error"]?["outcome"], .string("unknown"))
        checkEqual(AppleScriptCaptureOne.failure(message: "", number: -1743).code, .permissionDenied)
        checkEqual(AppleScriptCaptureOne.failure(message: "", number: -600).code, .notRunning)

        let fake = FakeCaptureOne()
        fake.failure = mapped
        checkFailure(.timeout) { _ = try service(fake, "timeout").get(ids: [id("1")]) }
        checkEqual(fake.calls, [.document], "no retry after a timeout")

        let script = AppleScriptCaptureOne.readScript([ReadTarget(id("1"), .collection(cid("14")))], timeoutSeconds: 30, layerFields: ["CVex"])
        check(!script.contains("properties of adjustments of every layer"), "Capture One refuses properties of a non-background layer's adjustments")
        check(script.contains("«property CVex» of a"), "non-background layers are read field by field")
        check(script.contains("with timeout of 30 seconds"), "the read runs under a timeout")
        check(script.contains("if n is in {-1712"), "a per-variant try rethrows a timeout instead of recording it")
        check(script.contains("variant id \"1\" of collection id \"14\" of d)"), "the read names its route")
        check(script.contains("set info to {version, kind of d, name of d, folder of d, id of d}"), "the read reports the open document")
    }

    static func commandArguments() {
        let fake = FakeCaptureOne()
        fake.selected = [id("5")]
        let service = service(fake, "commands")
        checkEqual(try? Command.selection.run(service, arguments: Data()), .object(["ids": .array([.string("5")])]))
        checkFailure(.invalidArguments, containing: "does not take bogus") { _ = try Command.get.run(service, arguments: Data(#"{"ids":["1"],"bogus":1}"#.utf8)) }
        checkFailure(.invalidArguments, containing: "positive integer") { _ = try Command.get.run(service, arguments: Data(#"{"ids":["1;quit"]}"#.utf8)) }
        checkFailure(.invalidArguments, containing: "needs ids") { _ = try Command.get.run(service, arguments: Data("{}".utf8)) }
        checkFailure(.invalidArguments, containing: "1–100") { _ = try Command.get.run(service, arguments: Data(#"{"ids":[]}"#.utf8)) }
        checkFailure(.invalidArguments, containing: "takes no document path") { _ = try Command.get.run(service, arguments: Data(#"{"ids":["1"]}"#.utf8), document: "/x") }
        let listed = try? Command.list.run(service, arguments: Data(#"{"minRating":5,"limit":1}"#.utf8))
        checkEqual(listed.map { ids($0) }, ["1"]); checkEqual(listed?["next"], .string("1"))
    }
}
