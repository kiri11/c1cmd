import Foundation

TerminologyTests.run()
DatabaseTests.run()
ServiceTests.run()
QueueTests.run()

try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("c1kit-tests-\(getpid())"))
for failure in failures { print("FAIL \(failure)") }
print("\(checks - failures.count)/\(checks) checks passed")
exit(failures.isEmpty ? 0 : 1)
