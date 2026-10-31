import C1Kit
import Foundation

var checks = 0
var failures: [String] = []

func check(_ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #fileID, line: UInt = #line) {
    checks += 1
    if !condition { failures.append("\(file):\(line): \(message())") }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) {
    check(actual == expected, "\(message) expected \(expected), got \(actual)", file: file, line: line)
}

func checkFailure(_ code: C1Failure.Code, containing text: String = "", file: StaticString = #fileID, line: UInt = #line, _ body: () throws -> Void) {
    do {
        try body()
        check(false, "expected \(code.rawValue), got success", file: file, line: line)
    } catch let failure as C1Failure {
        check(failure.code == code && (text.isEmpty || failure.message.contains(text)),
              "expected \(code.rawValue) containing \"\(text)\", got \(failure)", file: file, line: line)
    } catch {
        check(false, "expected \(code.rawValue), got \(error)", file: file, line: line)
    }
}

func scratchDirectory(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("c1kit-tests-\(getpid())").appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func id(_ text: String) -> VariantID { VariantID(text)! }
func cid(_ text: String) -> CollectionID { CollectionID(text)! }

func ids(_ value: JSONValue, key: String = "variants") -> [String] {
    guard case .array(let items)? = value[key] else { return [] }
    return items.compactMap { if case .string(let id)? = $0["id"] { return id }; return nil }
}
