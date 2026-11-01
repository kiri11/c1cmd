import Foundation

if CommandLine.arguments.dropFirst().first == "--generate" {
    Generated.run(write: true)
    exit(failures.isEmpty ? 0 : 1)
}
Generated.run(write: false)
TerminologyTests.run()
SpecTests.run()
CLITests.run()
DatabaseTests.run()
ServiceTests.run()
QueueTests.run()
WriteTests.run()
EditorTests.run()
ViewingTests.run()

try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("c1kit-tests-\(getpid())"))
for failure in failures { print("FAIL \(failure)") }
print("\(checks - failures.count)/\(checks) checks passed")
exit(failures.isEmpty ? 0 : 1)
