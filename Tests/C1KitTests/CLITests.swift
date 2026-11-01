import C1Kit
import Foundation

/// The built c1next, copied alone into an empty folder: help, usage, exit codes and a database read
/// need neither Capture One nor a resource bundle beside the binary.
enum CLITests {
    static let built = ".build/debug/c1next"

    struct Run { let status: Int32; let stdout: String; let stderr: String }

    static func run(_ binary: URL, _ arguments: [String], stdin: String? = nil) -> Run {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = ["HOME": scratchDirectory("cli-home").path, "C1_HOME": scratchDirectory("cli-c1").path, "PATH": "/usr/bin:/bin"]
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out; process.standardError = err; process.standardInput = input
        try! process.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? input.fileHandleForWriting.close()
        let stdout = out.fileHandleForReading.readDataToEndOfFile(), stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self))
    }

    static func run() {
        guard FileManager.default.fileExists(atPath: built) else { return check(false, "build c1next first: \(built) is missing") }
        let folder = scratchDirectory("cli-alone")
        let binary = folder.appendingPathComponent("c1")
        try! FileManager.default.copyItem(atPath: built, toPath: binary.path)
        checkEqual(try! FileManager.default.contentsOfDirectory(atPath: folder.path), ["c1"], "the binary is alone")

        let help = run(binary, ["--help"])
        check(help.status == 0 && help.stdout.contains("crop_preview"), "c1 --help works alone: \(help.status) \(help.stderr)")
        let commandHelp = run(binary, ["set", "--help"])
        check(commandHelp.status == 0 && commandHelp.stdout.contains("adjustments.exposure"), "c1 set --help prints the built-in field table")
        checkEqual(run(binary, ["--version"]).stdout, "dev\n")
        for usage in [[], ["bogus"], ["get", "--bogus"], ["get", "{}", "{}"], ["get", "--document", "/x", "{}"], ["list", "--document"]] {
            let result = run(binary, usage)
            check(result.status == 2 && result.stdout.isEmpty && result.stderr.contains("usage: c1"), "\(usage) is a usage error on stderr, exit 2")
        }

        let database = Fixture.make("cli-db")
        let compact = run(binary, ["list", #"{"ids":["4"]}"#, "--document", database])
        checkEqual(compact.status, 0, "a --document read runs alone")
        checkEqual(compact.stdout, #"{"variants":[{"colorTag":2,"edited":true,"id":"4","name":"c","path":"/elsewhere/c.CR3","rating":5}]}"# + "\n",
                   "compact output leaves out nulls: variant 4 has no folder")
        let pretty = run(binary, ["list", "--pretty", "--document", database, "-"], stdin: #"{"ids":["4"]}"#)
        check(pretty.status == 0 && pretty.stdout.contains("\n  \"variants\" : ["), "--pretty indents, and - reads stdin: \(pretty.stdout)")
        checkEqual(try? JSONDecoder().decode(JSONValue.self, from: Data(pretty.stdout.utf8)), try? JSONDecoder().decode(JSONValue.self, from: Data(compact.stdout.utf8)),
                   "pretty and compact carry the same JSON")
        let failure = run(binary, ["list", #"{"limit":0}"#, "--document", database])
        check(failure.status == 1 && failure.stdout.contains(#""code":"invalid-arguments""#) && failure.stderr.isEmpty,
              "a failure prints its JSON on stdout, exit 1: \(failure.stdout)")
    }
}
