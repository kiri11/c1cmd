import C1Kit
import Foundation

// c1 <command> '<json>' [--document <path>] [--pretty]; ships as c1, built as c1next until the cutover.

func usageError(_ message: String) -> Never {
    FileHandle.standardError.write(Data("c1: \(message)\n\(Command.usage)\n".utf8))
    exit(2)
}

func emit(_ value: JSONValue, pretty: Bool) {
    print(value.droppingNulls().encoded(pretty: pretty))
}

var arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case nil: usageError("give a command, or --help.")
case "--help", "-h", "help": print(Command.overview); exit(0)
case "--version": print(C1Version.current); exit(0)
default: break
}
guard let command = Command(rawValue: arguments.removeFirst()) else {
    usageError("no command \"\(CommandLine.arguments[1])\"; commands: \(Command.allCases.map(\.rawValue).joined(separator: ", ")).")
}
var pretty = false
var document: String?
var json: String?
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--help", "-h": print(command.help); exit(0)
    case "--pretty": pretty = true
    case "--document":
        guard command.acceptsDocumentPath else { usageError("\(command.rawValue) reads Capture One's open document and takes no --document.") }
        guard !arguments.isEmpty else { usageError("--document needs a path.") }
        document = arguments.removeFirst()
    case _ where argument.hasPrefix("--"):
        usageError("unknown option \(argument).")
    default:
        guard json == nil else { usageError("pass the arguments as one JSON object.") }
        json = argument
    }
}
let input = json == "-" ? FileHandle.standardInput.readDataToEndOfFile() : Data((json ?? "").utf8)

do {
    let terminology = Terminology.snapshot
    let captureOne = AppleScriptCaptureOne(terminology: terminology)
    if ProcessInfo.processInfo.environment["C1_TRACE"] != nil {
        captureOne.trace = { FileHandle.standardError.write(Data("[c1] \($0)\n".utf8)) }
    }
    let service = Service(captureOne: captureOne, queue: CaptureOneQueue(),
                          schema: { WriteSchema(terminology: terminology, bounds: try BoundsTable.bundled()) })
    emit(try command.run(service, arguments: input, document: document), pretty: pretty)
} catch let failure as C1Failure {
    emit(failure.json, pretty: pretty)
    exit(failure.outcomeUnknown ? 0 : 1)
} catch {
    emit(C1Failure(.internal, "\(error)").json, pretty: pretty)
    exit(1)
}
