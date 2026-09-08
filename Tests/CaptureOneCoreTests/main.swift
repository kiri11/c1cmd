import Foundation

print("=== Starting CaptureOneCore Unit Test Suite ===")

FieldSpecTests.run()
StateHashTests.run()
WorkingReferenceTests.run()
ProvenanceStoreTests.run()
OperationJournalTests.run()
LockTests.run()
ResetTests.run()
DiffTests.run()
DumpTests.run()
CatalogGuardTests.run()
VersionCompatibilityTests.run()
ReleaseSafetyTests.run()

print("\n=== Test Results ===")
print("Total Assertions : \(totalTestCount)")
print("Passed           : \(passedTestCount)")
print("Failed           : \(failedTestCount)")

if failedTestCount > 0 {
    print("FAILED: Some tests failed!")
    exit(1)
} else {
    print("SUCCESS: All unit tests passed!")
    exit(0)
}
