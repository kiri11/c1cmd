import C1Kit
import Foundation

/// Curves and the color editor in get, set and revert.
enum EditorTests {
    static func run() {
        validation()
        setWritesByChannelNameAndIndex()
        readBackWarning()
        changedFiltering()
        revertRestoresEverything()
        revertMatchesAdvancedCountBySameCount()
        revertScopes()
        scripts()
    }

    static func points(_ pairs: [[Double]]) -> JSONValue { .array(pairs.map { .array($0.map(JSONValue.double)) }) }

    static func advanced(_ hue: Double, red: Int64 = 200) -> JSONValue {
        var fields = FakeCaptureOne.newAdvancedColor
        fields["red"] = .int(red); fields["hue start"] = .double(-hue); fields["hue end"] = .double(hue); fields["hue change"] = .double(hue / 2)
        return .object(fields)
    }

    static func withAdvanced(_ editor: [String: JSONValue], _ corrections: [JSONValue]) -> [String: JSONValue] {
        var editor = editor
        editor["colorEditor"] = .object(["basic": editor["colorEditor"]!["basic"]!, "advanced": .array(corrections)])
        return editor
    }

    /// A background with two advanced corrections, a photographer's layer with its own curve, and a layer of c1's.
    static func editedState() -> VariantState {
        var state = FakeCaptureOne.state("1")
        state.adjustments.merge(withAdvanced(FakeCaptureOne.editor, [advanced(20), advanced(40, red: 10)])) { $1 }
        var photographer = FakeCaptureOne.editor
        photographer["curves"]!.set("rgb", points([[0, 10], [50, 60], [100, 90]]))
        state.layers.append(["kind": .string("adjustment"), "name": .string("Sky"), "opacity": .int(100), "enabled": .bool(true),
                             "adjustments": .object(photographer)])
        state.layers.append(["kind": .string("adjustment"), "name": .string("Dodge [c1:abcdef]"), "opacity": .int(100), "enabled": .bool(true),
                             "adjustments": .object(withAdvanced(FakeCaptureOne.editor, [advanced(30)]))])
        return state
    }

    static func validation() {
        let (fake, service, _) = WriteTests.fixture("editor-validation", state: editedState())
        let cases: [(String, String)] = [
            (#""curves":{"rgb":[[0,0]]}"#, "adjustments.curves.rgb must be 2–18 [x, y] points within 0–100, x increasing by more than 1.5"),
            (#""curves":{"rgb":[\#((0..<19).map { "[\($0 * 5),0]" }.joined(separator: ","))]}"#, "2–18"),
            (#""curves":{"luma":[[0,0],[50,50],[40,60]]}"#, "adjustments.curves.luma must be"),
            (#""curves":{"red":[[0,0],[1.5,1],[100,100]]}"#, "more than 1.5"),
            (#""curves":{"rgb":[[0,0],[100,101]]}"#, "within 0–100"),
            (#""curves":{"rgb":[[0,0,0],[100,100]]}"#, "[x, y] points"),
            (#""curves":{"alpha":[[0,0],[100,100]]}"#, "no channel \"alpha\""),
            (#""rgb curve":[[0,0],[100,100]]"#, "adjustments.rgb curve is set under curves, as adjustments.curves.rgb."),
            (#""colorEditor":{"skin":[]}"#, "has no \"skin\""),
            (#""colorEditor":{"basic":[{"hue change":5}]}"#, "needs its name"),
            (#""colorEditor":{"basic":[{"name":"red"}]}"#, "red sets nothing"),
            (#""colorEditor":{"basic":[{"name":"red","hue change":1},{"name":"red","hue change":2}]}"#, "twice"),
            (#""colorEditor":{"basic":[{"name":"red","hue change":40}]}"#, "adjustments.colorEditor.basic.red.hue change must be within -30…30"),
            (#""colorEditor":{"basic":[{"name":"red","name2":1}]}"#, "no writable field \"name2\""),
            (#""colorEditor":{"basic":[{"name":"all","lightness change":-6}]}"#, "all.lightness change must be 0"),
            (#""colorEditor":{"advanced":[{"index":-1,"hue change":1}]}"#, "needs its index"),
            (#""colorEditor":{"advanced":[{"index":0,"red":256}]}"#, "advanced.0.red must be within 0…255"),
        ]
        for (patch, message) in cases {
            checkFailure(.invalidArguments, containing: message) { _ = try WriteTests.run(.set, service, #"{"ids":["1"],"adjustments":{\#(patch)}}"#) }
        }
        checkFailure(.invalidArguments, containing: "a layer's adjustments.curves.rgb must be") {
            _ = try WriteTests.run(.set, service, #"{"ids":["1"],"layers":[{"layer":2,"adjustments":{"curves":{"rgb":[[0,0]]}}}]}"#)
        }
        checkFailure(.invalidArguments, containing: "a layer's adjustments.luma curve is set under curves, as a layer's adjustments.curves.luma.") {
            _ = try WriteTests.run(.set, service, #"{"ids":["1"],"layers":[{"layer":2,"adjustments":{"luma curve":[[0,0],[100,100]]}}]}"#)
        }
        checkEqual(fake.calls, [], "invalid curves and corrections never reach Capture One")
        let gap = WriteTests.first(try! WriteTests.run(.set, service, #"{"ids":["1"],"adjustments":{"curves":{"red":[[0,0],[1.55,1],[100,100]]}}}"#))
        checkEqual(gap?["outcome"], .string("ok"), "points 1.55 apart are accepted, as Capture One accepts them")
    }

    static func setWritesByChannelNameAndIndex() {
        let (fake, service, _) = WriteTests.fixture("editor-set", state: editedState())
        let curve = #"[[0,5],[40,50],[100,95]]"#
        let result = WriteTests.first(try! WriteTests.run(.set, service, #"""
            {"ids":["1"],"adjustments":{"curves":{"rgb":\#(curve)},"colorEditor":{"basic":[{"name":"red","hue change":10}],"advanced":[{"index":1,"hue change":-5,"red":30}]}},
             "layers":[{"layer":"c1:abcdef","adjustments":{"curves":{"luma":\#(curve)},"colorEditor":{"basic":[{"name":"all","saturation change":-20}],"advanced":[{"index":0,"enabled":false}]}}}]}
            """#))
        checkEqual(result?["outcome"], .string("ok"))
        let expected = JSONValue.object([
            "adjustments": .object(["curves": .object(["rgb": points([[0, 5], [40, 50], [100, 95]])]),
                                    "colorEditor": .object(["basic": .object(["red": .object(["hue change": .double(10)])]),
                                                            "advanced": .object(["1": .object(["red": .int(30), "hue change": .double(-5)])])])]),
            "layers": .object(["2": .object(["adjustments": .object([
                "curves": .object(["luma": points([[0, 5], [40, 50], [100, 95]])]),
                "colorEditor": .object(["basic": .object(["all": .object(["saturation change": .double(-20)])]),
                                        "advanced": .object(["0": .object(["enabled": .bool(false)])])])])])]),
        ])
        checkSame(result?["after"], expected, "after nests curves by channel, basic corrections by name and advanced ones by position")
        checkSame(result?["before"]?["adjustments"]?["curves"]?["rgb"], FakeCaptureOne.identity, "before holds the curve it replaced")
        let state = fake.state(id("1"))!
        checkSame(state.adjustments["colorEditor"]?["advanced"]?.arrayValue?[1]["red"], .int(30))
        checkSame(state.layers[2]["adjustments"]?["curves"]?["luma"], points([[0, 5], [40, 50], [100, 95]]))
        checkSame(state.layers[1]["adjustments"]?["curves"]?["rgb"], points([[0, 10], [50, 60], [100, 90]]), "the photographer's curve is untouched")
        guard case .write(let writes)? = fake.calls.last else { return check(false, "no write call") }
        let advancedFields = writes[0].steps.compactMap { step -> String? in
            if case .write(let write) = step, case .advancedColor(0, 1) = write.owner { return write.field.spec.name }
            return nil
        }
        checkEqual(advancedFields, ["red", "hue change"], "an advanced correction's color is written before its changes")

        let unknown = WriteTests.first(try! WriteTests.run(.set, service, #"{"ids":["1"],"adjustments":{"colorEditor":{"basic":[{"name":"teal","hue change":1}]}}}"#))
        check(unknown?["error"]?["message"]?.stringValue?.contains("no basic color correction \"teal\"; it has red, orange") == true, "an unknown name is refused")
        let missing = WriteTests.first(try! WriteTests.run(.set, service, #"{"ids":["1"],"layers":[{"layer":2,"adjustments":{"colorEditor":{"advanced":[{"index":1,"hue change":1}]}}}]}"#))
        checkEqual(missing?["error"]?["message"]?.stringValue, "Layer 2 has 1 advanced color correction, so none at index 1; add one with color.create.")
    }

    static func readBackWarning() {
        let (fake, service, _) = WriteTests.fixture("editor-readback", state: editedState())
        fake.substitutes = ["luma curve": points([[0, 0], [50, 40], [100, 100]]), "rgb curve": points([[0, 0], [30.000001907, 40], [100, 100]])]
        let item = WriteTests.first(try! WriteTests.run(.set, service, #"{"ids":["1"],"adjustments":{"curves":{"rgb":[[0,0],[30,40],[100,100]],"luma":[[0,0],[50,50],[100,100]]}}}"#))
        checkEqual(item?["warnings"], .array([.object(["field": .string("adjustments.curves.luma"), "sent": points([[0, 0], [50, 50], [100, 100]]),
                                                       "stored": points([[0, 0], [50, 40], [100, 100]])])]),
                   "a curve compares point by point; float noise in a stored point is no warning")
    }

    static func changedFiltering() {
        var background = FakeCaptureOne.editor
        background["curves"]!.set("rgb", points([[0, 0], [50, 60], [100, 100]]))
        background["colorEditor"] = .object(["basic": .array(background["colorEditor"]!["basic"]!.arrayValue!.map { correction in
            guard correction["name"] == .string("red") else { return correction }
            var fields = correction.objectValue!; fields["hue change"] = .double(10); return .object(fields)
        }), "advanced": .array([])])
        var state = FakeCaptureOne.state("1", adjustments: background)
        state.layers.append(["kind": .string("adjustment"), "name": .string("Dodge"), "opacity": .int(100), "enabled": .bool(true),
                             "adjustments": .object(withAdvanced(FakeCaptureOne.editor, [advanced(30)]))])
        var defaults = ServiceTests.defaults.defaults
        defaults["adjustments"]!.merge(FakeCaptureOne.editor) { $1 }
        let changed = Defaults(alwaysReported: ServiceTests.defaults.alwaysReported, defaults: defaults).changed(state)
        checkEqual(changed["adjustments"]?["curves"], .object(["rgb": points([[0, 0], [50, 60], [100, 100]])]), "changed drops identity curves")
        checkEqual(changed["adjustments"]?["colorEditor"]?["basic"]?.arrayValue?.compactMap { $0["name"] }, [.string("red")],
                   "changed keeps only basic corrections that differ, whole")
        checkEqual(changed["adjustments"]?["colorEditor"]?["advanced"], nil, "changed drops an empty advanced list")
        let layer = changed["layers"]?.arrayValue?[1]["adjustments"]
        checkEqual(layer?["curves"], nil, "a layer with identity curves reports none")
        checkEqual(layer?["colorEditor"], .object(["advanced": .array([advanced(30)])]), "a layer's advanced corrections are reported")
    }

    /// Changes all five curves, basic and advanced corrections on the background and a c1 layer, adds advanced
    /// corrections to one and deletes one from the other, then reverts.
    static func revertRestoresEverything() {
        let saved = editedState()
        let (fake, service, _) = WriteTests.fixture("editor-revert", state: saved)
        let curve = #"[[0,5],[40,50],[100,95]]"#
        let curves = "{" + ["rgb", "luma", "red", "green", "blue"].map { #""\#($0)":\#(curve)"# }.joined(separator: ",") + "}"
        let editor = #"{"curves":\#(curves),"colorEditor":{"basic":[{"name":"red","hue change":10},{"name":"all","saturation change":-30}],"advanced":[{"index":0,"red":5,"hue end":90}]}}"#
        let set = WriteTests.first(try! WriteTests.run(.set, service, #"{"ids":["1"],"adjustments":\#(editor),"layers":[{"layer":2,"adjustments":\#(editor)}]}"#))
        checkEqual(set?["outcome"], .string("ok"))
        for arguments in [#"{}"#, #"{}"#] {
            _ = try! WriteTests.run(.action, service, #"{"ids":["1"],"action":"color.create","arguments":\#(arguments)}"#)
        }
        _ = try! WriteTests.run(.action, service, #"{"ids":["1"],"action":"color.delete","arguments":{"layer":2,"color":0}}"#)
        let changed = fake.state(id("1"))!
        checkEqual(changed.adjustments["colorEditor"]?["advanced"]?.arrayValue?.count, 4)
        checkEqual(changed.layers[2]["adjustments"]?["colorEditor"]?["advanced"]?.arrayValue?.count, 0)

        let reverted = WriteTests.first(try! WriteTests.run(.revert, service, #"{"ids":["1"]}"#))
        checkEqual(reverted?["outcome"], .string("ok"))
        checkEqual(reverted?["notRestored"], nil)
        let state = fake.state(id("1"))!
        checkSame(.object(state.adjustments), .object(saved.adjustments), "the background's curves and corrections equal the snapshot")
        checkSame(.array(state.layers.map(JSONValue.object)), .array(saved.layers.map(JSONValue.object)), "every layer equals the snapshot")
        guard case .write(let writes)? = fake.calls.last else { return check(false, "no write call") }
        let actions = writes[0].steps.compactMap { step -> ActionStep? in if case .action(let action) = step { return action }; return nil }
        checkEqual(actions, [.deleteColor(layer: 0, index: 3), .deleteColor(layer: 0, index: 2), .createColor(layer: 2)],
                   "revert deletes extra advanced corrections from the end and creates missing ones")
        let created = writes[0].steps.compactMap { step -> String? in
            if case .write(let write) = step, case .advancedColor(2, 0) = write.owner { return write.field.spec.name }
            return nil
        }
        checkEqual(created, WriteSchema.advancedColorOrder, "a created correction gets every field, color first")
        check(!writes[0].steps.contains { step in
            if case .write(let write) = step { return write.owner == .layerAdjustments(1) || write.owner == .basicColor(layer: 1, name: "red") }
            return false
        }, "revert writes nothing to the photographer's layer, which c1 did not change")
    }

    static func revertMatchesAdvancedCountBySameCount() {
        let saved = editedState()
        let (fake, service, _) = WriteTests.fixture("editor-revert-same", state: saved)
        _ = try! WriteTests.run(.action, service, #"{"ids":["1"],"action":"color.delete","arguments":{"color":0}}"#)
        _ = try! WriteTests.run(.action, service, #"{"ids":["1"],"action":"color.create"}"#)
        _ = try! WriteTests.run(.revert, service, #"{"ids":["1"]}"#)
        checkSame(fake.state(id("1"))!.adjustments["colorEditor"], saved.adjustments["colorEditor"]!,
                  "a deleted and a created correction at the same count are rewritten in place")
    }

    static func revertScopes() {
        let saved = editedState()
        let (fake, service, _) = WriteTests.fixture("editor-revert-scopes", state: saved)
        let editor = #"{"curves":{"rgb":[[0,5],[100,95]]},"colorEditor":{"basic":[{"name":"red","hue change":10}]}}"#
        _ = try! WriteTests.run(.set, service, #"{"ids":["1"],"adjustments":\#(editor),"layers":[{"layer":2,"adjustments":\#(editor)}]}"#)
        _ = try! WriteTests.run(.revert, service, #"{"ids":["1"],"scope":"adjustments"}"#)
        var state = fake.state(id("1"))!
        checkSame(.object(state.adjustments), .object(saved.adjustments), "adjustments restores the background's curves and corrections")
        checkSame(state.layers[2]["adjustments"]?["curves"]?["rgb"], points([[0, 5], [100, 95]]), "and leaves the layers'")
        _ = try! WriteTests.run(.revert, service, #"{"ids":["1"],"scope":"layers"}"#)
        state = fake.state(id("1"))!
        checkSame(.object(state.layers[2]), .object(saved.layers[2]), "layers restores a layer's curves and corrections")
    }

    static func scripts() {
        let curve = WriteTests.schema.fields[.adjustments]!["rgb curve"]!, hue = WriteTests.schema.fields[.basicColor]!["hue change"]!
        let red = WriteTests.schema.fields[.advancedColor]!["red"]!
        let write = VariantWrite(target: ReadTarget(id("7"), .collection(cid("14"))),
                                 steps: [.write(FieldWrite(.layerAdjustments(2), FieldValue(curve, points([[10, 5], [50, 60], [90, 95]])))),
                                         .write(FieldWrite(.basicColor(layer: 0, name: "red"), FieldValue(hue, .double(4)))),
                                         .write(FieldWrite(.advancedColor(layer: 1, index: 0), FieldValue(red, .int(9))))],
                                 readBack: [FieldRead(.layerAdjustments(2), curve)])
        let script = AppleScriptCaptureOne.writeScript([write], document: LiveDocument(id: "/c", kind: .catalog, name: "c", folder: "/c", appVersion: ""), timeoutSeconds: 60)
        check(script.contains("""
            tell «property CVac» of «property vset» of layer 3 of v
            repeat while (count of curve points) > 2
            delete curve point 2
            end repeat
            set brightness of first curve point to 0
            set brightness of last curve point to 100
            set brightness of first curve point to 10
            set brightness of last curve point to 90
            set amount of first curve point to 5
            set amount of last curve point to 95
            make new curve point with properties {brightness:50, amount:60}
            end tell
            """), "a curve is replaced: interior points deleted, endpoints moved out then into place, the rest added")
        check(script.contains("set «property Chuc» of basic color correction \"red\" of «property CCEs» of «property vset» of v to 4"), "basic corrections by name")
        check(script.contains("set «property CRrd» of advanced color correction 1 of «property CCEs» of «property vset» of layer 2 of v to 9"), "advanced ones by position")
        check(script.contains("set end of rb to properties of every curve point of «property CVac» of «property vset» of layer 3 of v"), "a curve reads back its points")
        let read = AppleScriptCaptureOne.readScript([ReadTarget(id("7"), .collection(cid("14")))], timeoutSeconds: 60, layerFields: [])
        check(read.contains("set end of out to {fields, my editor(a)}"), "every layer's curves and corrections are read, the background's included")
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }

    mutating func set(_ key: String, _ value: JSONValue) {
        guard case .object(var object) = self else { return }
        object[key] = value
        self = .object(object)
    }
}
