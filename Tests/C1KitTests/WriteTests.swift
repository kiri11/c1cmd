import C1Kit
import Foundation

enum WriteTests {
    static let sdef = """
        <dictionary><suite name="S" code="Cap1">
          <enumeration name="flip type" code="CFlt"><enumerator name="none" code="Cfln"/><enumerator name="horizontal" code="Cflh"/></enumeration>
          <class name="variant" code="cvar">
            <property name="id" code="ID  " type="text" access="r"/>
            <property name="rating" code="vcrt" type="integer"/>
            <property name="color tag" code="vctg" type="integer"/>
            <property name="pick" code="vpck" type="boolean"/>
            <property name="crop" code="vcrp" type="rectangle"/>
          </class>
          <class name="layer" code="clyr">
            <property name="name" code="pnam" type="text"/>
            <property name="enabled" code="CRen" type="boolean"/>
            <property name="opacity" code="CRwo" type="integer"/>
          </class>
          <class name="adjustment settings" code="CVas">
            <property name="rotation" code="CVro" type="real"/>
            <property name="flip" code="CVfl" type="flip type"/>
            <property name="exposure" code="CVex" type="real"/>
            <property name="temperature" code="CVwk" type="real"/>
            <property name="contrast" code="CVco" type="real"/>
            <property name="dehaze color" code="CVdc" type="RGB color"/>
            <property name="rgb curve" code="CVac" type="curve"/>
            <property name="luma curve" code="CVlc" type="curve"/>
            <property name="red curve" code="CVrc" type="curve"/>
            <property name="green curve" code="CVgc" type="curve"/>
            <property name="blue curve" code="CVbc" type="curve"/>
            <property name="color editor settings" code="CCEs" type="color editor options"/>
          </class>
          <class name="basic color correction" code="CCba">
            <property name="name" code="pnam" type="text" access="r"/>
            <property name="hue change" code="Chuc" type="real"/>
            <property name="saturation change" code="Csac" type="real"/>
            <property name="lightness change" code="Clic" type="real"/>
          </class>
          <class name="advanced color correction" code="CCad">
            <property name="enabled" code="CRen" type="boolean"/>
            <property name="red" code="CRrd" type="integer"/>
            <property name="green" code="CRgn" type="integer"/>
            <property name="blue" code="CRbl" type="integer"/>
            <property name="hue start" code="Chus" type="real"/>
            <property name="hue end" code="Chue" type="real"/>
            <property name="saturation start" code="Csas" type="real"/>
            <property name="saturation end" code="Csae" type="real"/>
            <property name="smoothness" code="Csmo" type="real"/>
            <property name="hue change" code="Chuc" type="real"/>
            <property name="saturation change" code="Csac" type="real"/>
            <property name="lightness change" code="Clic" type="real"/>
          </class>
          <class name="lens correction settings" code="Clco">
            <property name="distortion" code="CLdv" type="real"/>
          </class>
        </suite></dictionary>
        """

    static let bounds = BoundsTable(build: "16.8.5.30", fields: [
        "variant": ["rating": Bound(min: 0, max: 5), "color tag": Bound(min: 0, max: 7)],
        "layer": ["opacity": Bound(min: 0, max: 100)],
        "adjustments": ["rotation": Bound(min: -45, max: 45), "exposure": Bound(min: -4, max: 4), "temperature": Bound(min: 800, max: 14000),
                        "dehaze color": Bound(min: 0, max: 65535)],
        "lensCorrection": ["distortion": Bound(min: 0, max: 120)],
        "basicColor": ["hue change": Bound(min: -30, max: 30), "saturation change": Bound(min: -100, max: 100), "lightness change": Bound(min: -100, max: 100)],
        "advancedColor": ["red": Bound(min: 0, max: 255), "green": Bound(min: 0, max: 255), "blue": Bound(min: 0, max: 255),
                          "hue start": Bound(max: 0), "hue end": Bound(min: 0), "saturation start": Bound(min: 0, max: 100), "saturation end": Bound(min: 0, max: 100),
                          "smoothness": Bound(min: 1, max: 100), "hue change": Bound(min: -30, max: 30), "saturation change": Bound(min: -100, max: 100),
                          "lightness change": Bound(min: -100, max: 100)],
    ])

    static let schema = WriteSchema(terminology: try! Terminology(sdef: Data(sdef.utf8)), bounds: bounds)

    static func run() {
        schemaFields()
        validation()
        setWritesAndReadsBack()
        readBackWarnings()
        cropBoundsChecks()
        tagRule()
        snapshotOnFirstWrite()
        revertScopes()
        revertLayers()
        timeoutIsUnknown()
        documentChangeWritesNothing()
        healthWarnings()
        writeScript()
    }

    static func fixture(_ name: String, extraSQL: String = "", now: @escaping () -> Date = Date.init,
                        state: VariantState = FakeCaptureOne.state("1")) -> (FakeCaptureOne, Service, DocumentStore) {
        let fake = FakeCaptureOne()
        fake.variants = [.collection(cid("10")): [id("1"): state]]
        let service = ServiceTests.service(fake, name, extraSQL: extraSQL, now: now)
        return (fake, service, DocumentStore(home: scratchURL("\(name)-home"), documentUUID: Fixture.uuid))
    }

    static func run(_ command: Command, _ service: Service, _ json: String) throws -> JSONValue {
        try command.run(service, arguments: Data(json.utf8))
    }

    static func first(_ result: JSONValue?) -> JSONValue? { result?["variants"]?.arrayValue?.first }

    static func logLines(_ store: DocumentStore) -> [JSONValue] {
        let text = (try? String(contentsOf: store.directory.appendingPathComponent("log.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }

    static func schemaFields() {
        checkEqual(schema.fields[.variant].map { Set($0.keys) }, ["rating", "color tag", "crop"], "variant fields are the allowed list; pick and id are not")
        checkEqual(schema.fields[.adjustments]?["rgb curve"]?.kind, .curve, "curves are written whole")
        checkEqual(schema.fields[.basicColor].map { Set($0.keys) }, ["hue change", "saturation change", "lightness change"], "a basic correction's name is read-only")
        checkEqual(schema.fields[.advancedColor]?.count, 12)
        check(schema.unmeasured[.adjustments]?.contains("contrast") == true, "a numeric field without bounds is unmeasured")
        checkEqual(schema.fields[.adjustments]?["flip"]?.kind, .enumeration(["none": "Cfln", "horizontal": "Cflh"]))
    }

    static func validation() {
        let (fake, service, _) = fixture("validation")
        checkFailure(.invalidArguments, containing: "within -4…4") { _ = try run(.set, service, #"{"ids":["1"],"adjustments":{"exposure":5}}"#) }
        checkFailure(.invalidArguments, containing: "no measured bounds") { _ = try run(.set, service, #"{"ids":["1"],"adjustments":{"contrast":5}}"#) }
        checkFailure(.invalidArguments, containing: "no writable field \"bogus\"") { _ = try run(.set, service, #"{"ids":["1"],"adjustments":{"bogus":1}}"#) }
        checkFailure(.invalidArguments, containing: "an integer") { _ = try run(.set, service, #"{"ids":["1"],"variant":{"rating":2.5}}"#) }
        checkFailure(.invalidArguments, containing: "one of horizontal, none") { _ = try run(.set, service, #"{"ids":["1"],"adjustments":{"flip":"diagonal"}}"#) }
        checkFailure(.invalidArguments, containing: "true or false") { _ = try run(.set, service, #"{"ids":["1"],"layers":[{"layer":1,"enabled":1}]}"#) }
        checkFailure(.invalidArguments, containing: "geometry") { _ = try run(.set, service, #"{"ids":["1"],"layers":[{"layer":1,"adjustments":{"rotation":1}}]}"#) }
        checkFailure(.invalidArguments, containing: "move its bounds") {
            _ = try run(.set, service, #"{"ids":["1"],"adjustments":{"rotation":2},"variant":{"crop":[3000,2000,100,100]}}"#)
        }
        checkFailure(.invalidArguments, containing: "whole pixels") { _ = try run(.set, service, #"{"ids":["1"],"variant":{"crop":[1,2,3]}}"#) }
        checkFailure(.invalidArguments, containing: "never renames") { _ = try run(.set, service, #"{"ids":["1"],"layers":[{"layer":1,"name":"Sky"}]}"#) }
        checkFailure(.invalidArguments, containing: "at least one value") { _ = try run(.set, service, #"{"ids":["1"]}"#) }
        checkFailure(.invalidArguments, containing: "No action") { _ = try run(.action, service, #"{"ids":["1"],"action":"mask.paint"}"#) }
        checkFailure(.invalidArguments, containing: "amount") { _ = try run(.action, service, #"{"ids":["1"],"action":"mask.feather","arguments":{"layer":1,"amount":101}}"#) }
        checkEqual(fake.calls, [], "invalid arguments never reach Capture One")
    }

    static func setWritesAndReadsBack() {
        let (fake, service, store) = fixture("set")
        fake.variants[.collection(cid("20"))] = [id("2"): FakeCaptureOne.state("2")]
        let result = try! run(.set, service, #"{"ids":["1","2","9"],"adjustments":{"exposure":0.5},"variant":{"rating":4}}"#)
        let items = result["variants"]!.arrayValue!
        checkEqual(items.count, 3, "a result per variant")
        checkEqual(items[0]["outcome"], .string("ok"))
        checkEqual(items[0]["before"], .object(["adjustments": .object(["exposure": .double(0)]), "variant": .object(["rating": .int(0)])]))
        checkEqual(items[0]["after"], .object(["adjustments": .object(["exposure": .double(0.5)]), "variant": .object(["rating": .int(4)])]))
        checkEqual(items[2]["error"]?["code"], .string("not-found"), "a missing variant fails alone")
        checkEqual(fake.state(id("2"))?.adjustments["exposure"], .double(0.5), "one patch for several variants")
        guard case .write(let writes)? = fake.calls.last else { return check(false, "no write call") }
        checkEqual(writes.count, 2, "one script for every found variant")
        let lines = logLines(store)
        checkEqual(lines.count, 1, "one log line per write call")
        checkEqual(lines.first?["command"], .string("set"))
        checkEqual(lines.first?["outcome"], .string("ok"))
        checkEqual(lines.first?["document"], .string(Fixture.uuid))
        checkSame(lines.first?["variants"]?.arrayValue?.first?["before"], items[0]["before"] ?? .null, "the log keeps before and after values")
        checkEqual(lines.first?["arguments"]?["adjustments"], .object(["exposure": .double(0.5)]))
        check(lines.first?["time"]?.stringValue != nil, "the log line has a time")
    }

    static func readBackWarnings() {
        let (fake, service, _) = fixture("readback")
        fake.clamps = ["temperature": 2000...10000]
        fake.refused = ["exposure"]
        let item = first(try! run(.set, service, #"{"ids":["1"],"adjustments":{"temperature":12000,"exposure":1}}"#))
        checkEqual(item?["warnings"], .array([.object(["field": .string("adjustments.exposure"), "sent": .double(1), "stored": .double(0)]),
                                              .object(["field": .string("adjustments.temperature"), "sent": .double(12000), "stored": .double(10000)])]),
                   "a stored value that differs is a warning with sent and stored")
        checkEqual(item?["outcome"], .string("failed"), "a refused step fails the variant")
        checkEqual(item?["errors"]?.arrayValue?.first?["step"], .string("set adjustments.exposure"))
    }

    static func cropBoundsChecks() {
        let image = VariantState(id: id("1"), variant: [:], adjustments: ["rotation": .double(5)], lensCorrection: [:], layers: [],
                                 canvasSize: [6325, 4507], maximumCrop: [3162, 2253, 5324, 3549])
        let bounds = image.cropBounds!
        checkEqual(bounds.source, .image)
        let expected: [[Double]] = [[348.6, 4507.6], [6324.8, 3984.8], [5976.2, 0], [0, 522.8]]
        check(zip(bounds.corners, expected).allSatisfy { abs($0[0] - $1[0]) < 1 && abs($0[1] - $1[1]) < 1 },
              "the image turned 5° clockwise inside its bounding canvas: \(bounds.corners)")
        checkEqual(bounds.crossings([3162, 2254, 5324, 3549]).count, 0, "Capture One's own fit lies inside")
        let outside = bounds.crossings([3162, 2254, 5500, 3549])
        checkEqual(outside.map(\.corner), ["top right", "bottom left"], "a wider crop crosses two corners")
        let keystoned = VariantState(id: id("1"), variant: [:], adjustments: ["keystone vertical": .double(20)], lensCorrection: [:], layers: [],
                                     canvasSize: [5999, 4000], maximumCrop: [3177, 2313, 5466, 3644])
        checkEqual(keystoned.cropBounds?.source, .maximumCrop, "keystone uses Capture One's maximum crop")
        checkEqual(keystoned.cropBounds?.crossings([3177, 2313, 5466, 3644]).count, 0)

        var state = FakeCaptureOne.state("1")
        state.adjustments["rotation"] = .double(5)
        state.canvasSize = [6325, 4507]
        let (fake, service, _) = fixture("crop", state: state)
        let refused = first(try! run(.set, service, #"{"ids":["1"],"variant":{"crop":[3162,2254,5500,3549]}}"#))
        checkEqual(refused?["error"]?["code"], .string("refused"))
        check(refused?["error"]?["message"]?.stringValue?.contains("the top right corner by ") == true, "the refusal names the crossed corner")
        check(!fake.calls.contains { if case .write = $0 { return true }; return false }, "a crop outside is never sent")
        let accepted = first(try! run(.set, service, #"{"ids":["1"],"variant":{"crop":[3162,2254,5000,3300]}}"#))
        checkEqual(accepted?["outcome"], .string("ok"))
    }

    static func tagRule() {
        var state = FakeCaptureOne.state("1")
        state.layers.append(["kind": .string("adjustment"), "name": .string("Sky"), "opacity": .int(100), "enabled": .bool(true), "adjustments": .object([:])])
        let (fake, service, _) = fixture("tags", state: state)
        let created = first(try! run(.action, service, #"{"ids":["1"],"action":"layer.create","arguments":{"name":"Dodge"}}"#))
        guard let tag = created?["layer"]?.stringValue else { return check(false, "layer.create returns the tag") }
        check(LayerTag.isTag(tag), "the tag looks like c1:xxxxxx")
        checkEqual(fake.state(id("1"))?.layers.last?["name"], .string("Dodge [\(tag)]"), "the new layer's name carries the tag")
        checkEqual(created?["layers"]?["after"], .array([.string("Background"), .string("Sky"), .string("Dodge [\(tag)]")]))

        for (action, arguments) in [("layer.delete", #"{"layer":"Sky"}"#), ("mask.clear", #"{"layer":1}"#), ("mask.feather", #"{"layer":1,"amount":5}"#),
                                    ("mask.copy", #"{"layer":"Sky","source":"\#(tag)"}"#)] {
            let refused = first(try! run(.action, service, #"{"ids":["1"],"action":"\#(action)","arguments":\#(arguments)}"#))
            check(refused?["error"]?["message"]?.stringValue?.contains("photographer's") == true, "\(action) is refused on an untagged layer")
        }
        let copied = first(try! run(.action, service, #"{"ids":["1"],"action":"mask.copy","arguments":{"layer":"\#(tag)","source":"Sky"}}"#))
        checkEqual(copied?["outcome"], .string("ok"), "mask.copy onto a tagged layer may read an untagged source")
        let reset = first(try! run(.action, service, #"{"ids":["1"],"action":"variant.reset"}"#))
        check(reset?["error"]?["message"]?.stringValue?.contains("\"Sky\" is the photographer's") == true, "variant.reset is refused while an untagged layer exists")
        let style = first(try! run(.action, service, #"{"ids":["1"],"action":"style.apply","arguments":{"name":"Warm"}}"#))
        checkEqual(style?["outcome"], .string("ok"), "a non-destructive action runs on the background by default")
        let deleted = first(try! run(.action, service, #"{"ids":["1"],"action":"layer.delete","arguments":{"layer":"\#(tag)"}}"#))
        checkEqual(deleted?["outcome"], .string("ok"))
        checkEqual(fake.state(id("1"))?.layers.count, 2, "a tagged layer can be deleted")

        var renamed = FakeCaptureOne.state("1")
        renamed.layers.append(["kind": .string("adjustment"), "name": .string("Dodge c1:abcdef"), "opacity": .int(100)])
        let (_, other, _) = fixture("renamed", state: renamed)
        let refused = first(try! run(.action, other, #"{"ids":["1"],"action":"layer.delete","arguments":{"layer":1}}"#))
        checkEqual(refused?["error"]?["code"], .string("refused"), "a layer renamed without its bracketed tag is the photographer's")

        let (onlyTagged, taggedService, _) = fixture("reset-tagged")
        _ = try! run(.action, taggedService, #"{"ids":["1"],"action":"layer.create"}"#)
        let allowed = first(try! run(.action, taggedService, #"{"ids":["1"],"action":"variant.reset"}"#))
        checkEqual(allowed?["outcome"], .string("ok"), "variant.reset runs when every layer is c1's")
        checkEqual(onlyTagged.state(id("1"))?.layers.count, 1)
    }

    static func snapshotOnFirstWrite() {
        let (fake, service, store) = fixture("snapshot")
        check((try? store.snapshot(id("1"))) ?? nil == nil, "no snapshot before a write")
        _ = try! run(.set, service, #"{"ids":["1"],"adjustments":{"exposure":1}}"#)
        let snapshot = try! store.snapshot(id("1"))
        checkSame(snapshot.flatMap { VariantState(json: $0.state) }?.adjustments["exposure"], .double(0), "the snapshot holds the state before the first write")
        check(snapshot?.masks.contains("Mask pixels") == true, "the snapshot says it lacks mask pixels")
        _ = try! run(.set, service, #"{"ids":["1"],"adjustments":{"exposure":2}}"#)
        checkEqual(try! store.snapshot(id("1")), snapshot, "a later write keeps the first snapshot")
        _ = try! run(.revert, service, #"{"ids":["1"]}"#)
        checkSame(fake.state(id("1"))?.adjustments["exposure"], .double(0), "revert restores the snapshot")
        check((try? store.snapshot(id("1"))) ?? nil == nil, "a successful revert of everything drops the snapshot")
        _ = try! run(.set, service, #"{"ids":["1"],"adjustments":{"exposure":3}}"#)
        checkSame((try! store.snapshot(id("1"))).flatMap { VariantState(json: $0.state) }?.adjustments["exposure"], .double(0),
                   "the next write takes a fresh snapshot")
        let (_, untouched, _) = fixture("snapshot-none")
        let noSnapshot = first(try! run(.revert, untouched, #"{"ids":["1"]}"#))
        check(noSnapshot?["error"]?["message"]?.stringValue?.contains("no snapshot") == true, "revert without a snapshot is refused")
        checkEqual(logLines(store).map { $0["command"]?.stringValue ?? "" }, ["set", "set", "revert", "set"], "revert is logged too")
    }

    static func revertScopes() {
        let (fake, service, store) = fixture("scopes")
        _ = try! run(.set, service, #"{"ids":["1"],"adjustments":{"exposure":1,"rotation":3},"variant":{"rating":5},"lensCorrection":{"distortion":50}}"#)
        let metadata = first(try! run(.revert, service, #"{"ids":["1"],"scope":"metadata"}"#))
        checkEqual(metadata?["after"], .object(["variant": .object(["rating": .int(0)])]), "metadata restores only rating and color tag")
        checkEqual(fake.state(id("1"))?.adjustments["exposure"], .double(1))
        check((try? store.snapshot(id("1"))) ?? nil != nil, "a scoped revert keeps the snapshot")
        _ = try! run(.revert, service, #"{"ids":["1"],"scope":"geometry"}"#)
        checkSame(fake.state(id("1"))?.adjustments["rotation"], .double(0), "geometry restores rotation")
        checkEqual(fake.state(id("1"))?.adjustments["exposure"], .double(1), "geometry leaves exposure")
        _ = try! run(.revert, service, #"{"ids":["1"],"scope":"adjustments"}"#)
        checkSame(fake.state(id("1"))?.adjustments["exposure"], .double(0))
        checkSame(fake.state(id("1"))?.lensCorrection["distortion"], .double(0), "adjustments covers lens correction")
        checkFailure(.invalidArguments, containing: "scope") { _ = try run(.revert, service, #"{"ids":["1"],"scope":"pixels"}"#) }
    }

    static func revertLayers() {
        var state = FakeCaptureOne.state("1")
        state.layers.append(["kind": .string("adjustment"), "name": .string("Sky"), "opacity": .int(100), "enabled": .bool(true),
                             "adjustments": .object(["exposure": .double(0)])])
        state.layers.append(["kind": .string("adjustment"), "name": .string("Gone"), "opacity": .int(100), "enabled": .bool(true),
                             "adjustments": .object([:])])
        let (fake, service, _) = fixture("revert-layers", state: state)
        let created = first(try! run(.action, service, #"{"ids":["1"],"action":"layer.create"}"#))
        let tag = created!["layer"]!.stringValue!
        _ = try! run(.set, service, #"{"ids":["1"],"layers":[{"layer":"\#(tag)","opacity":40,"adjustments":{"exposure":1}},{"layer":"Sky","opacity":70,"adjustments":{"exposure":-1}}]}"#)
        // The photographer deletes a layer in Capture One.
        fake.variants[.collection(cid("10"))]![id("1")]!.layers.remove(at: 2)
        let reverted = first(try! run(.revert, service, #"{"ids":["1"],"scope":"layers"}"#))
        let layers = fake.state(id("1"))!.layers
        checkEqual(layers.map { $0["name"] }, [.string("Background"), .string("Sky")], "revert deletes c1's layer created since the snapshot")
        checkEqual(layers[1]["opacity"], .int(100), "and restores the photographer's layer")
        checkSame(layers[1]["adjustments"]?["exposure"], .double(0))
        checkEqual(reverted?["notRestored"], .array([.string("layer \"Gone\", which no longer exists")]), "a vanished layer is reported")
        checkEqual(reverted?["outcome"], .string("ok"))
    }

    static func timeoutIsUnknown() {
        let (fake, service, store) = fixture("timeout")
        fake.writeFailure = AppleScriptCaptureOne.failure(message: "AppleEvent timed out.", number: -1712)
        do {
            _ = try run(.set, service, #"{"ids":["1"],"adjustments":{"exposure":1}}"#)
            check(false, "a write timeout fails the call")
        } catch let failure as C1Failure {
            checkEqual(failure.json["error"]?["outcome"], .string("unknown"), "a write timeout's outcome is unknown")
            check(failure.hint?.contains("get again") == true, "the hint says to call get")
        } catch { check(false, "\(error)") }
        let line = logLines(store).last
        checkEqual(line?["outcome"], .string("unknown"), "the log records the unknown outcome")
        checkSame(line?["variants"]?.arrayValue?.first?["before"], .object(["adjustments": .object(["exposure": .double(0)])]))
        let writes = fake.calls.filter { if case .write = $0 { return true }; return false }
        checkEqual(writes.count, 1, "c1 does not retry")
    }

    static func documentChangeWritesNothing() {
        let script = AppleScriptCaptureOne.writeScript([], document: LiveDocument(id: "/a \"b\".cocatalog", kind: .catalog, name: "a", folder: "/a", appVersion: ""), timeoutSeconds: 5)
        check(script.contains(#"if (id of d as text) is not "/a \"b\".cocatalog" then error"#), "a write script checks the document first, quoting its id")
        checkEqual(AppleScriptCaptureOne.failure(message: "x", number: 9001).code, .documentChanged)
    }

    static func healthWarnings() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (_, never, _) = fixture("health-never", now: { now })
        let doctor = try! run(.doctor, never, "")
        checkEqual(doctor["warnings"], .array([.string("The Catalog has never been backed up. Make File > Backup Catalog before editing.")]))
        checkEqual(doctor["document"]?["uuid"], .string(Fixture.uuid))
        let (_, stale, _) = fixture("health-stale", extraSQL: "UPDATE ZDOCUMENTCONTENT SET ZLASTBACKUPDATE=\(now.timeIntervalSince1970 - 3 * 86400);", now: { now })
        let set = try! run(.set, stale, #"{"ids":["1"],"variant":{"rating":1}}"#)
        checkEqual(set["warnings"], .array([.string("The Catalog was last backed up 3 days ago. Make File > Backup Catalog before editing.")]),
                   "set repeats the backup warning")
        let (_, fresh, _) = fixture("health-fresh", extraSQL: "UPDATE ZDOCUMENTCONTENT SET ZLASTBACKUPDATE=\(now.timeIntervalSince1970 - 3600);", now: { now })
        checkEqual(try! run(.doctor, fresh, "")["warnings"], .array([]), "a backup within a day warns nothing")

        let sessionFake = FakeCaptureOne()
        sessionFake.liveDocument = LiveDocument(id: "/s", kind: .session, name: "s", folder: "/s", appVersion: "16.9.0.1")
        sessionFake.variants = [.collection(cid("10")): [id("1"): FakeCaptureOne.state("1")]]
        let session = ServiceTests.service(sessionFake, "health-session", documentType: 0, now: { now })
        let action = try! run(.action, session, #"{"ids":["1"],"action":"lens.reset"}"#)
        checkEqual(action["warnings"], .array([.string("Capture One 16.9.0.1 is untested; c1 is tested on 16.8.5.30. Check each result closely.")]),
                   "a Session gets no backup warning; action repeats the build warning")
    }

    static func writeScript() {
        let exposure = schema.fields[.adjustments]!["exposure"]!, flip = schema.fields[.adjustments]!["flip"]!
        let write = VariantWrite(target: ReadTarget(id("7"), .collection(cid("14"))),
                                 steps: [.write(FieldWrite(.adjustments, FieldValue(flip, .string("horizontal")))),
                                         .write(FieldWrite(.layerAdjustments(2), FieldValue(exposure, .double(-0.3)))),
                                         .action(.createLayer(kind: "adjustment", name: "x [c1:abcdef]"))],
                                 readBack: [FieldRead(.layerAdjustments(2), exposure)])
        let script = AppleScriptCaptureOne.writeScript([write], document: LiveDocument(id: "/c", kind: .catalog, name: "c", folder: "/c", appVersion: ""), timeoutSeconds: 60)
        check(script.contains("set «property CVfl» of «property vset» of v to «constant ****Cflh»"), "enumerations are written by code")
        check(script.contains("set «property CVex» of «property vset» of layer 3 of v to -0.3"), "a layer's fields are written one by one, by code")
        check(script.contains("make new layer at v with properties {name:\"x [c1:abcdef]\", kind:«constant ****CLnm»}"), "layer kinds are written by code")
        check(script.contains("set end of errs to {2, n, e}"), "each step has its own try")
        check(script.contains("get id of v"), "a missing variant fails before any step")
        checkEqual(AppleScriptCaptureOne.number(0.1 + 0.2), "0.3", "numbers print without float noise")
    }
}

extension JSONValue {
    var arrayValue: [JSONValue]? { if case .array(let items) = self { return items }; return nil }
    var stringValue: String? { if case .string(let text) = self { return text }; return nil }
}
