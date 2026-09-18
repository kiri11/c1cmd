import Foundation
import CaptureOneCore

struct MetadataTests {
    static func run() {
        print("Running MetadataTests...")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeScript(directory: directory)
        fake.ratings["1"] = 3; fake.colorTags["1"] = 2
        let core = SessionController(executor: fake, appInstance: { fake.generation }, databaseIdentity: { _ in "db-1" })
        let journal = OperationJournal(sessionDirectory: directory)
        XCTAssertNoThrowBlock {
            let doc = try core.getDocumentInfo(), initial = try core.get(ref: "1")
            let baseline = VariantMetadata(rating: 3, colorTag: 2)
            XCTAssertEqual(initial.metadataStateHash, baseline.stateHash)
            XCTAssertTrue(baseline.stateHash != VariantMetadata(rating: 4, colorTag: 2).stateHash)
            XCTAssertTrue(baseline.stateHash != VariantMetadata(rating: 3, colorTag: 4).stateHash)
            let edit = try core.editVariant(sourceRef: "1", ifState: initial.stateHash, ifDocument: doc.openToken)
            XCTAssertEqual(edit.baselineMetadata, baseline)
            var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edit)) as! [String: Any]
            legacy.removeValue(forKey: "baselineMetadata")
            let legacyEdit = try JSONDecoder().decode(EditingRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
            XCTAssertEqual(legacyEdit.baselineMetadata, nil, "Older saved editing references remain readable")
            let ref = edit.workingRef
            XCTAssertThrowsError(try core.metadataSet(workingRef: "1", ifMetadataState: baseline.stateHash, rating: 5))
            XCTAssertThrowsError(try core.metadataSet(workingRef: ref, ifMetadataState: "stale", rating: 5))
            XCTAssertThrowsError(try core.metadataSet(workingRef: ref, ifMetadataState: baseline.stateHash))
            XCTAssertThrowsError(try core.metadataSet(workingRef: ref, ifMetadataState: baseline.stateHash, rating: 6))
            XCTAssertThrowsError(try core.metadataSet(workingRef: ref, ifMetadataState: baseline.stateHash, colorTag: 8))
            let dry = try core.metadataSet(workingRef: ref, ifMetadataState: baseline.stateHash, rating: 5, colorTag: 7, dryRun: true)
            XCTAssertEqual(dry.after, VariantMetadata(rating: 5, colorTag: 7))
            XCTAssertEqual(dry.metadataStateHash, baseline.stateHash)
            XCTAssertEqual(fake.ratings["1"], 3)
            XCTAssertTrue(journal.loadEntries().isEmpty)
            XCTAssertFalse(fake.calls.contains("applyMetadata"))
            let rated = try core.metadataSet(workingRef: ref, ifMetadataState: baseline.stateHash, rating: 5)
            XCTAssertEqual(rated.after, VariantMetadata(rating: 5, colorTag: 2))
            XCTAssertEqual(Set(rated.diff.keys), ["rating"])
            let checkedState = try core.get(ref: ref)
            XCTAssertEqual(checkedState.stateHash, initial.stateHash)
            XCTAssertTrue(fake.preparedBeforeDispatch)
            XCTAssertEqual(journal.find(operationId: rated.operationId)?.beforeMetadata, baseline)
            XCTAssertEqual(journal.find(operationId: rated.operationId)?.intendedMetadata, rated.after)
            XCTAssertEqual(journal.find(operationId: rated.operationId)?.afterMetadata, rated.after)
            let diff = try core.diff(ref1: ref)
            XCTAssertEqual(diff.metadataDiff?["rating"]?.after, 5)
            XCTAssertTrue(OutputFormatter.renderDiffResult(diff, format: .human).contains("Rating / color tag differences"))
            let picks = try core.listVariants(rating: 5)
            XCTAssertEqual(picks.map(\.id), ["1"])
            XCTAssertThrowsError(try core.metadataSet(workingRef: ref, ifMetadataState: baseline.stateHash, colorTag: 1))
            let tagged = try core.metadataSet(workingRef: ref, ifMetadataState: rated.metadataStateHash, colorTag: 7)
            XCTAssertEqual(tagged.after, VariantMetadata(rating: 5, colorTag: 7))
            let clear = try core.metadataSet(workingRef: ref, ifMetadataState: tagged.metadataStateHash, rating: 0, colorTag: 0)
            XCTAssertEqual(clear.after, VariantMetadata(rating: 0, colorTag: 0))
            let clearedState = try core.get(ref: ref)
            XCTAssertEqual(clearedState.stateHash, initial.stateHash)
            fake.version = "16.8.5.31"
            XCTAssertThrowsError(try core.metadataSet(workingRef: ref, ifMetadataState: clear.metadataStateHash, rating: 2))
            fake.version = "16.8.5.30"
            fake.isSession = false
            XCTAssertThrowsError(try core.metadataSet(workingRef: ref, ifMetadataState: clear.metadataStateHash, rating: 2))
            fake.isSession = true
            fake.documentCount = 2
            XCTAssertThrowsError(try core.metadataSet(workingRef: ref, ifMetadataState: clear.metadataStateHash, rating: 2))
            fake.documentCount = 1
            // A photographer changes the tag between our read and the native write.
            fake.beforeApply = { fake.colorTags["1"] = 1 }
            var operation = ""
            do { _ = try core.metadataSet(workingRef: ref, ifMetadataState: clear.metadataStateHash, rating: 4) }
            catch let failure as OperationFailure { operation = failure.operationId }
            XCTAssertFalse(operation.isEmpty)
            XCTAssertEqual(fake.ratings["1"], 0)
            XCTAssertEqual(fake.colorTags["1"], 1)
            XCTAssertEqual(journal.find(operationId: operation)?.status, "outcome-unknown")
            XCTAssertThrowsError(try core.metadataSet(workingRef: ref, ifMetadataState: clear.metadataStateHash, rating: 4))
            fake.beforeApply = nil
            fake.generation = "app-2"
            let observed = try core.operationStatus(operationId: operation)
            XCTAssertEqual(observed.status, "reconciled")
            XCTAssertEqual(observed.afterMetadata, VariantMetadata(rating: 0, colorTag: 1))
            XCTAssertThrowsError(try core.get(ref: ref))
            // Mock partial writes and unexpected readback, with no real fault injection.
            for fault in ["partial", "mismatch", "tone"] {
                let doc = try core.getDocumentInfo(), source = try core.get(ref: "1")
                let edit = try core.editVariant(sourceRef: "1", ifState: source.stateHash, ifDocument: doc.openToken)
                fake.metadataFault = fault
                var id = ""
                do { _ = try core.metadataSet(workingRef: edit.workingRef, ifMetadataState: source.metadataStateHash!, rating: 4, colorTag: 7) }
                catch let failure as OperationFailure { id = failure.operationId }
                XCTAssertFalse(id.isEmpty)
                XCTAssertTrue(OperationJournal.isUnresolved(journal.find(operationId: id)!))
                XCTAssertEqual(journal.find(operationId: id)?.beforeMetadata, VariantMetadata.from(source.metadata))
                fake.metadataFault = nil
                fake.generation += "-next"
                let recovered = try core.operationStatus(operationId: id)
                XCTAssertEqual(recovered.status, "reconciled")
            }
            XCTAssertEqual(fake.values.count, 1)
            XCTAssertFalse(fake.calls.contains("cloneVariant"))
            XCTAssertFalse(fake.calls.contains("deleteVariant"))
        }
    }
}
