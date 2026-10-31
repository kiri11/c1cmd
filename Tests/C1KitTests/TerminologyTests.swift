import C1Kit
import Foundation

enum TerminologyTests {
    static let sdef = """
        <dictionary><suite name="S" code="Cap1">
          <enumeration name="layer type" code="CLty"><enumerator name="background" code="CLbg"/></enumeration>
          <enumeration name="collectionType" code="COce"><enumerator name="album" code="CCal"/></enumeration>
          <class name="layer" code="clyr">
            <property name="name" code="pnam" type="text"/>
            <property name="kind" code="COdk" type="layer type"/>
            <property name="opacity" code="CRwo" type="integer"/>
            <property name="luma range" code="LuRa" type="luma range settings"/>
          </class>
          <class name="collection" code="COcl">
            <property name="kind" code="COdk" type="collectionType"/>
            <property name="folder" code="COdf"><type type="text"/><type type="file"/></property>
          </class>
          <class name="adjustment settings" code="CVas">
            <property name="exposure" code="CRex" type="real"/>
            <property name="black and white" code="CVbw" type="boolean"/>
            <property name="dehaze color" code="CRdc"><type type="integer" list="yes"/></property>
            <property name="color profile" code="CVcp" type="text"/>
            <property name="rgb curve" code="CVrc" type="curve"/>
          </class>
        </suite></dictionary>
        """

    static func run() {
        let terminology = try! Terminology(sdef: Data(sdef.utf8))
        record(terminology)
        perClassCodes(terminology)
        scalars(terminology)
        specifiers()
    }

    static func code(_ text: String) -> FourCharCode { text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }

    static func typeValue(_ text: String) -> NSAppleEventDescriptor {
        var value = code(text)
        return NSAppleEventDescriptor(descriptorType: code("type"), bytes: &value, length: 4)!
    }

    static func reference() -> NSAppleEventDescriptor {
        let specifier = NSAppleEventDescriptor.record().coerce(toDescriptorType: code("obj "))!
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: code("cvar")), forKeyword: code("want"))
        specifier.setDescriptor(NSAppleEventDescriptor(enumCode: code("ID  ")), forKeyword: code("form"))
        specifier.setDescriptor(NSAppleEventDescriptor(string: "42"), forKeyword: code("seld"))
        specifier.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: code("from"))
        return specifier
    }

    static func record(_ terminology: Terminology) {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(typeValue("CVas"), forKeyword: code("pcls"))
        record.setDescriptor(NSAppleEventDescriptor(double: 0.5), forKeyword: code("CRex"))
        record.setDescriptor(NSAppleEventDescriptor(boolean: false), forKeyword: code("CVbw"))
        let list = NSAppleEventDescriptor.list()
        for (index, value) in [0, 2227, 1679].enumerated() { list.insert(NSAppleEventDescriptor(int32: Int32(value)), at: index + 1) }
        record.setDescriptor(list, forKeyword: code("CRdc"))
        record.setDescriptor(NSAppleEventDescriptor(string: "Canon ProStandard"), forKeyword: code("CVcp"))
        record.setDescriptor(reference(), forKeyword: code("CVrc"))
        record.setDescriptor(NSAppleEventDescriptor(int32: 7), forKeyword: code("Zzzz"))
        checkEqual(terminology.record(record), [
            "exposure": .double(0.5), "black and white": .bool(false),
            "dehaze color": .array([.int(0), .int(2227), .int(1679)]), "color profile": .string("Canon ProStandard"),
            "Zzzz": .int(7),
        ], "record keys become names, references are dropped, unknown codes stay codes")
    }

    static func perClassCodes(_ terminology: Terminology) {
        let layer = NSAppleEventDescriptor.record()
        layer.setDescriptor(typeValue("clyr"), forKeyword: code("pcls"))
        layer.setDescriptor(NSAppleEventDescriptor(enumCode: code("CLbg")), forKeyword: code("COdk"))
        layer.setDescriptor(NSAppleEventDescriptor(int32: 100), forKeyword: code("CRwo"))
        layer.setDescriptor(typeValue("msng"), forKeyword: code("LuRa"))
        checkEqual(terminology.record(layer), ["kind": .string("background"), "opacity": .int(100), "luma range": .null],
                   "enumerators resolve through the property's enumeration; missing value is null")

        let collection = NSAppleEventDescriptor.record()
        collection.setDescriptor(typeValue("COcl"), forKeyword: code("pcls"))
        collection.setDescriptor(NSAppleEventDescriptor(enumCode: code("CCal")), forKeyword: code("COdk"))
        collection.setDescriptor(NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: "/tmp/photos")), forKeyword: code("COdf"))
        checkEqual(terminology.record(collection), ["kind": .string("album"), "folder": .string("/tmp/photos")],
                   "one code resolves per class; files become paths")
    }

    static func scalars(_ terminology: Terminology) {
        checkEqual(terminology.decode(NSAppleEventDescriptor(int32: -3)), .int(-3))
        checkEqual(terminology.decode(NSAppleEventDescriptor(double: 6777.77)), .double(6777.77))
        checkEqual(terminology.decode(NSAppleEventDescriptor(boolean: true)), .bool(true))
        checkEqual(terminology.decode(NSAppleEventDescriptor(string: "Auto")), .string("Auto"))
        checkEqual(terminology.decode(NSAppleEventDescriptor.list()), .array([]))
        checkEqual(terminology.decode(typeValue("msng")), .null)
        checkEqual(terminology.decode(reference()), nil, "a reference is dropped")
        let mixed = NSAppleEventDescriptor.list()
        mixed.insert(NSAppleEventDescriptor(string: "Square"), at: 1)
        mixed.insert(reference(), at: 2)
        checkEqual(terminology.decode(mixed), .array([.string("Square")]), "references inside lists are dropped")
    }

    static func specifiers() {
    }
}
