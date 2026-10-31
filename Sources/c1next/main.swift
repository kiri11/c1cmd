import C1Kit
import Foundation

// c1next <command> [--document <path>] ['<json arguments>']
// Temporary CLI until step 4 generates the real one from the command table.

func fail(_ failure: C1Failure) -> Never {
    print(failure.json.encoded(pretty: true))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let name = arguments.first, let command = Command(rawValue: name) else {
    let usage = Command.allCases.map { "  \($0.rawValue)\(String(repeating: " ", count: 12 - $0.rawValue.count))\($0.summary)" }
    FileHandle.standardError.write(Data(("usage: c1next <command> [--document <path>] ['<json arguments>']\n" + usage.joined(separator: "\n") + "\n").utf8))
    exit(2)
}
arguments.removeFirst()
var document: String?
if let index = arguments.firstIndex(of: "--document") {
    guard index + 1 < arguments.count else { fail(C1Failure(.invalidArguments, "--document needs a path.")) }
    document = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
}
guard arguments.count <= 1 else { fail(C1Failure(.invalidArguments, "Pass the arguments as one JSON object.")) }

do {
    // A database read with --document must work where Capture One is not installed.
    let terminology = document == nil ? try Terminology.load() : try Terminology(sdef: Data("<dictionary/>".utf8))
    let captureOne = AppleScriptCaptureOne(terminology: terminology)
    if ProcessInfo.processInfo.environment["C1_TRACE"] != nil {
        captureOne.trace = { FileHandle.standardError.write(Data("[c1next] \($0)\n".utf8)) }
    }
    let service = Service(captureOne: captureOne, queue: CaptureOneQueue())
    let result = try command.run(service, arguments: Data((arguments.first ?? "").utf8), document: document)
    print(result.encoded(pretty: true))
} catch let failure as C1Failure {
    fail(failure)
} catch {
    fail(C1Failure(.internal, "\(error)"))
}
