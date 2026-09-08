import Foundation
import AppleScriptBridge
import AppKit

public struct VersionCompatibility: Codable, Equatable {
    public let isTestedMatch: Bool
    public let isAllowed: Bool
    public let warning: String?

    public init(isTestedMatch: Bool, isAllowed: Bool, warning: String? = nil) {
        self.isTestedMatch = isTestedMatch
        self.isAllowed = isAllowed
        self.warning = warning
    }
}

public struct DoctorReport: Codable, Equatable {
    public let appRunning: Bool
    public let appVersion: String
    public let exactBuildMatched: Bool
    public let testedBuilds: [String]
    public let pinnedBuild: String
    public let hasDocument: Bool
    public let docName: String?
    public let docPath: String?
    public let isSession: Bool
    public let lockAcquired: Bool
    public let unresolvedOperationsCount: Int
    public let allChecksPassed: Bool
    public let warning: String?

    public init(
        appRunning: Bool,
        appVersion: String,
        exactBuildMatched: Bool,
        testedBuilds: [String] = SessionController.testedBuilds,
        pinnedBuild: String = SessionController.pinnedBuild,
        hasDocument: Bool,
        docName: String?,
        docPath: String?,
        isSession: Bool,
        lockAcquired: Bool,
        unresolvedOperationsCount: Int,
        allChecksPassed: Bool,
        warning: String? = nil
    ) {
        self.appRunning = appRunning
        self.appVersion = appVersion
        self.exactBuildMatched = exactBuildMatched
        self.testedBuilds = testedBuilds
        self.pinnedBuild = pinnedBuild
        self.hasDocument = hasDocument
        self.docName = docName
        self.docPath = docPath
        self.isSession = isSession
        self.lockAcquired = lockAcquired
        self.unresolvedOperationsCount = unresolvedOperationsCount
        self.allChecksPassed = allChecksPassed
        self.warning = warning
    }
}

public struct DocumentInfo: Codable, Equatable {
    public let documentId: String
    public let documentName: String
    public let documentPath: String
    public let isSession: Bool
    public let openToken: String
    public let captureFolder: String
    public let outputFolder: String
    public let appVersion: String

    public init(
        documentId: String,
        documentName: String,
        documentPath: String,
        isSession: Bool,
        openToken: String,
        captureFolder: String = "",
        outputFolder: String = "",
        appVersion: String = SessionController.pinnedBuild
    ) {
        self.documentId = documentId
        self.documentName = documentName
        self.documentPath = documentPath
        self.isSession = isSession
        self.openToken = openToken
        self.captureFolder = captureFolder
        self.outputFolder = outputFolder
        self.appVersion = appVersion
    }
}

public struct VariantSummary: Codable, Equatable {
    public let id: String
    public let name: String
    public let parentImagePath: String
    public let isSelected: Bool
    public let rating: Int
    public let colorTag: Int
    public let isManagedWorkingClone: Bool
    public let workingRef: String?
}

public struct CloneResult: Codable, Equatable {
    public let workingRef: String
    public let cloneVariantId: String
    public let sourceVariantId: String
    public let documentPath: String
    public let baselineStateHash: String
}

public struct DeleteResult: Codable, Equatable {
    public let deleted: Bool
    public let workingRef: String
    public let cloneVariantId: String
}

public struct GetResult: Codable, Equatable {
    public let id: String
    public let workingRef: String?
    public let adjustments: Adjustments
    public let metadata: Metadata
    public let stateHash: String
    public let parentImagePath: String?
}

public struct MutationResult: Codable, Equatable {
    public let operationId: String
    public let workingRef: String
    public let before: Adjustments
    public let after: Adjustments
    public let diff: [String: DoubleDiff]
    public let stateHash: String
    public let isDryRun: Bool
}

public struct DiffResult: Codable, Equatable {
    public let ref1: String
    public let ref2: String
    public let stateHash1: String
    public let stateHash2: String
    public let diff: [String: DoubleDiff]

    public init(ref1: String, ref2: String, stateHash1: String, stateHash2: String, diff: [String: DoubleDiff]) {
        self.ref1 = ref1
        self.ref2 = ref2
        self.stateHash1 = stateHash1
        self.stateHash2 = stateHash2
        self.diff = diff
    }
}

public struct DumpRecord: Codable, Equatable {
    public let id: String
    public let name: String
    public let parentImagePath: String
    public let isSelected: Bool
    public let rating: Int
    public let colorTag: Int
    public let isManagedWorkingClone: Bool
    public let workingRef: String?
    public let adjustments: Adjustments
    public let metadata: Metadata
    public let stateHash: String

    public init(
        id: String,
        name: String,
        parentImagePath: String = "",
        isSelected: Bool = false,
        rating: Int = 0,
        colorTag: Int = 0,
        isManagedWorkingClone: Bool = false,
        workingRef: String? = nil,
        adjustments: Adjustments,
        metadata: Metadata,
        stateHash: String
    ) {
        self.id = id
        self.name = name
        self.parentImagePath = parentImagePath
        self.isSelected = isSelected
        self.rating = rating
        self.colorTag = colorTag
        self.isManagedWorkingClone = isManagedWorkingClone
        self.workingRef = workingRef
        self.adjustments = adjustments
        self.metadata = metadata
        self.stateHash = stateHash
    }
}

public final class SessionController {
    public static let shared = SessionController()
    public static let testedBuilds: [String] = ["16.8.5.30"]
    public static var pinnedBuild: String { testedBuilds.first ?? "16.8.5.30" }

    // MARK: - Version Compatibility Evaluation
    public static func evaluateVersionCompatibility(
        _ version: String,
        allowUntestedOverride: Bool = false
    ) -> VersionCompatibility {
        let isOverrideActive = allowUntestedOverride
            || ProcessInfo.processInfo.environment["C1_ALLOW_UNTESTED_BUILD"] == "1"

        // 1. Check exact match against tested builds list
        if testedBuilds.contains(version) {
            return VersionCompatibility(isTestedMatch: true, isAllowed: true, warning: nil)
        }

        // 2. Check 16.4+ through 16.x range
        let parts = version.split(separator: ".")
        if parts.count >= 2,
           let major = Int(parts[0]),
           let minor = Int(parts[1]) {
            if major == 16 && minor >= 4 {
                let warningMsg = "Running on unverified Capture One build '\(version)' (tested: \(testedBuilds.joined(separator: ", "))). Compatibility allowed for Capture One 16.4+. Core safety guards and readback checks remain active."
                return VersionCompatibility(isTestedMatch: false, isAllowed: true, warning: warningMsg)
            }
        }

        // 3. Check environment override
        if isOverrideActive {
            let warningMsg = "Running on unverified Capture One build '\(version)' (override C1_ALLOW_UNTESTED_BUILD=1 active; tested: \(testedBuilds.joined(separator: ", ")))."
            return VersionCompatibility(isTestedMatch: false, isAllowed: true, warning: warningMsg)
        }

        return VersionCompatibility(isTestedMatch: false, isAllowed: false, warning: nil)
    }

    private let executor: ScriptExecuting
    private let appInstance: () throws -> String
    private let databaseIdentity: (String) throws -> String
    private let lock = CaptureOneLock.shared
    private let registry = FieldRegistry.shared
    private let previewMgr = PreviewManager.shared

    public init(executor: ScriptExecuting = AppleScriptExecutor.shared,
                appInstance: @escaping () throws -> String = DocumentIdentity.appInstance,
                databaseIdentity: @escaping (String) throws -> String = DocumentIdentity.fileIdentity) {
        self.executor = executor
        self.appInstance = appInstance
        self.databaseIdentity = databaseIdentity
    }

    private func databasePath(_ doc: DocumentInfo) -> String {
        doc.isSession && !doc.documentId.hasSuffix(".cosessiondb")
            ? URL(fileURLWithPath: doc.documentPath).appendingPathComponent(doc.documentName).path
            : doc.documentId
    }

    private func checkedDocument(_ expected: DocumentInfo, writes: Bool = true) throws {
        let actual = try getDocumentInfo()
        guard expected.documentId == actual.documentId, expected.openToken == actual.openToken else {
            throw C1Error.documentChanged("Active database changed before dispatch.")
        }
        if writes { try OperationJournal(sessionDirectory: URL(fileURLWithPath: actual.documentPath)).assertReady() }
    }

    private func prepare(_ entry: OperationRecord, doc: DocumentInfo, source: GetResult? = nil) throws -> OperationRecord {
        var result = entry
        result.appInstance = try appInstance()
        result.documentIdentity = try databaseIdentity(databasePath(doc))
        result.nativeVariantId = source?.id
        result.parentImagePath = source?.parentImagePath
        return result
    }

    // MARK: - Doctor
    public func doctor() throws -> DoctorReport {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.captureone.captureone16")
        let appRunning = !apps.isEmpty

        var appVersion = "unknown"
        var hasDoc = false
        var docName: String?
        var docPath: String?
        var isSession = false
        var documentCount = 0

        if appRunning {
            do {
                let info: AppAndDocInfoResult = try executor.executeAndDecode(
                    handler: "getAppAndDocInfo",
                    args: []
                )
                appVersion = info.appVersion
                hasDoc = info.hasDocument
                docName = info.docName
                docPath = info.docPath
                isSession = info.isSession
                documentCount = info.documentCount ?? 0
            } catch {
                appVersion = "error"
            }
        }

        let compat = Self.evaluateVersionCompatibility(appVersion)
        let buildMatched = compat.isTestedMatch

        var lockOk = false
        do {
            try lock.withLock(timeout: 1.0) {
                lockOk = true
            }
        } catch {
            lockOk = false
        }

        var unresolvedCount = 0
        if let p = docPath, let sessUrl = sessionUrl(forDocPath: p) {
            let journal = OperationJournal(sessionDirectory: sessUrl)
            unresolvedCount = (try? journal.validatedEntries().filter(OperationJournal.isUnresolved).count) ?? 1
        }

        let allPassed = appRunning && compat.isAllowed && hasDoc && documentCount == 1 && lockOk && (unresolvedCount == 0)

        return DoctorReport(
            appRunning: appRunning,
            appVersion: appVersion,
            exactBuildMatched: buildMatched,
            testedBuilds: Self.testedBuilds,
            pinnedBuild: Self.pinnedBuild,
            hasDocument: hasDoc,
            docName: docName,
            docPath: docPath,
            isSession: isSession,
            lockAcquired: lockOk,
            unresolvedOperationsCount: unresolvedCount,
            allChecksPassed: allPassed,
            warning: compat.warning
        )
    }

    // MARK: - Document Info
    public func getDocumentInfo(allowUntestedBuild: Bool = false) throws -> DocumentInfo {
        let info: AppAndDocInfoResult = try executor.executeAndDecode(
            handler: "getAppAndDocInfo",
            args: []
        )
        guard info.hasDocument, let name = info.docName, let path = info.docPath else {
            throw C1Error.noDocument("No document is currently open in Capture One.")
        }

        guard info.documentCount == 1 else {
            throw C1Error.documentChanged("Exactly one open document is supported. Close other documents before continuing.")
        }
        let compat = Self.evaluateVersionCompatibility(info.appVersion, allowUntestedOverride: allowUntestedBuild)
        guard compat.isAllowed else {
            throw C1Error.unsupportedVersion(
                "Running Capture One build '\(info.appVersion)' is not supported (supported: 16.4+ through 16.x; tested: \(Self.testedBuilds.joined(separator: ", "))). Set C1_ALLOW_UNTESTED_BUILD=1 to override."
            )
        }

        var docDir = path
        var captureDir = ""
        var outputDir = ""
        if info.isSession, let sessUrl = sessionUrl(forDocPath: path) {
            docDir = sessUrl.path
            captureDir = (docDir as NSString).appendingPathComponent("Capture")
            outputDir = (docDir as NSString).appendingPathComponent("Output")
        } else {
            if path.hasSuffix(".cocatalog") {
                docDir = (path as NSString).deletingLastPathComponent
            }
        }

        let nativeId = info.docId ?? path
        let database = info.isSession && !nativeId.hasSuffix(".cosessiondb")
            ? URL(fileURLWithPath: docDir).appendingPathComponent(name).path : nativeId
        let openToken = try "\(appInstance())|\(databaseIdentity(database))"

        return DocumentInfo(
            documentId: nativeId,
            documentName: name,
            documentPath: docDir,
            isSession: info.isSession,
            openToken: openToken,
            captureFolder: captureDir,
            outputFolder: outputDir,
            appVersion: info.appVersion
        )
    }

    // MARK: - Mutation Guard
    public func assertSessionWritable(docInfo: DocumentInfo, operation: String) throws {
        let compat = Self.evaluateVersionCompatibility(docInfo.appVersion)
        guard compat.isAllowed else {
            throw C1Error.unsupportedVersion(
                "Running Capture One build '\(docInfo.appVersion)' is not supported (supported: 16.4+ through 16.x; tested: \(Self.testedBuilds.joined(separator: ", "))). Set C1_ALLOW_UNTESTED_BUILD=1 to override."
            )
        }
        guard docInfo.isSession else {
            throw C1Error.invalidRequest("Catalogs are strictly read-only. Mutation operation '\(operation)' cannot be performed on Catalog '\(docInfo.documentName)'. Open a Session to mutate variants.")
        }
    }

    // MARK: - Variants List
    public func listVariants(collectionName: String? = nil, selectedOnly: Bool = false) throws -> [VariantSummary] {
        let docInfo = try getDocumentInfo()
        let provenance: ProvenanceStore?
        if docInfo.isSession {
            let sessUrl = URL(fileURLWithPath: docInfo.documentPath)
            provenance = ProvenanceStore(sessionDirectory: sessUrl)
        } else {
            provenance = nil
        }

        let colDesc = collectionName != nil ? NSAppleEventDescriptor(string: collectionName!) : NSAppleEventDescriptor.missingValue()
        let selDesc = NSAppleEventDescriptor(boolean: selectedOnly)

        let records: [VariantSummaryRecord] = try executor.executeAndDecode(
            handler: "listVariants",
            args: [NSAppleEventDescriptor(string: docInfo.documentId), colDesc, selDesc]
        )

        return records.map { rec in
            let prov = provenance?.find(byCloneId: rec.variantId)
            return VariantSummary(
                id: rec.variantId,
                name: rec.variantName,
                parentImagePath: rec.parentImagePath,
                isSelected: rec.isSelected,
                rating: rec.starRating,
                colorTag: rec.colorTagVal,
                isManagedWorkingClone: prov != nil,
                workingRef: prov?.workingRef
            )
        }
    }

    // MARK: - Clone Variant
    public func cloneVariant(sourceRef: String) throws -> CloneResult {
        try createVariant(sourceRef: sourceRef, baseline: false)
    }

    private func createVariant(sourceRef: String, baseline: Bool) throws -> CloneResult {
        return try lock.withLock {
            let doc = try getDocumentInfo()
            let operation = baseline ? "baseline" : "clone"
            try assertSessionWritable(docInfo: doc, operation: operation)
            try checkedDocument(doc)
            let source = try get(ref: sourceRef)
            guard let parent = source.parentImagePath, !parent.isEmpty else {
                throw C1Error.identityAmbiguous("Source parent image path is unavailable.")
            }
            let store = ProvenanceStore(sessionDirectory: URL(fileURLWithPath: doc.documentPath))
            _ = try store.validatedRecords()
            let journal = OperationJournal(sessionDirectory: store.sessionDirectory)
            let ref = WorkingRef().rawValue
            var entry = try prepare(OperationRecord(operationType: operation, workingRef: ref,
                documentPath: doc.documentPath, beforeAdjustments: source.adjustments), doc: doc, source: source)
            entry.variantIdsBefore = try listVariants().filter { $0.parentImagePath == parent }.map { $0.id }
            try journal.append(entry: entry)
            do {
                let args = [NSAppleEventDescriptor(string: doc.documentId), NSAppleEventDescriptor(string: source.id)]
                let id: String
                if baseline {
                    let result: CreateBaselineVariantResult = try executor.executeAndDecode(handler: "createBaselineVariant", args: args)
                    id = result.baselineId
                } else {
                    let result: CloneVariantResult = try executor.executeAndDecode(handler: "cloneVariant", args: args)
                    id = result.cloneId
                }
                guard id != source.id, !(entry.variantIdsBefore ?? []).contains(id) else {
                    throw C1Error.identityAmbiguous("Creation did not return a new variant ID.")
                }
                let created = try get(ref: id)
                guard created.parentImagePath == parent else { throw C1Error.identityAmbiguous("Created variant has the wrong parent image.") }
                try store.register(record: ProvenanceRecord(workingRef: ref, sourceVariantId: source.id,
                    cloneVariantId: id, documentPath: doc.documentPath, documentName: doc.documentName,
                    parentImagePath: parent, creationOperationId: entry.operationId,
                    baselineAdjustments: created.adjustments, baselineStateHash: created.stateHash, documentToken: doc.openToken))
                try journal.update(operationId: entry.operationId, status: "succeeded", afterAdjustments: created.adjustments)
                return CloneResult(workingRef: ref, cloneVariantId: id, sourceVariantId: source.id,
                                   documentPath: doc.documentPath, baselineStateHash: created.stateHash)
            } catch {
                try? journal.update(operationId: entry.operationId, status: "outcome-unknown", error: String(describing: error))
                throw OperationFailure(operationId: entry.operationId, cause: error)
            }
        }
    }

    // MARK: - Delete Variant
    public func deleteVariant(workingRefString: String) throws -> DeleteResult {
        return try lock.withLock {
            let doc = try getDocumentInfo()
            try assertSessionWritable(docInfo: doc, operation: "delete")
            try checkedDocument(doc)
            let current = try get(ref: workingRefString)
            let store = ProvenanceStore(sessionDirectory: URL(fileURLWithPath: doc.documentPath))
            let record = try store.resolveManagedWorkingReference(workingRefString, currentDocumentPath: doc.documentPath)
            let journal = OperationJournal(sessionDirectory: store.sessionDirectory)
            let entry = try prepare(OperationRecord(operationType: "delete", workingRef: workingRefString,
                documentPath: doc.documentPath, beforeAdjustments: current.adjustments), doc: doc, source: current)
            try journal.append(entry: entry)
            do {
                let result: DeleteVariantResult = try executor.executeAndDecode(handler: "deleteVariant", args: [
                    NSAppleEventDescriptor(string: doc.documentId), NSAppleEventDescriptor(string: record.cloneVariantId),
                    NSAppleEventDescriptor(string: record.parentImagePath!)])
                guard result.deleted && !result.existsNow else { throw C1Error.readbackMismatch("Deleted variant still exists.") }
                try store.remove(workingRef: workingRefString)
                try journal.update(operationId: entry.operationId, status: "succeeded")
                return DeleteResult(deleted: true, workingRef: workingRefString, cloneVariantId: record.cloneVariantId)
            } catch {
                try? journal.update(operationId: entry.operationId, status: "outcome-unknown", error: String(describing: error))
                throw OperationFailure(operationId: entry.operationId, cause: error)
            }
        }
    }

    // MARK: - Get
    public func get(ref: String) throws -> GetResult {
        let docInfo = try getDocumentInfo()
        var nativeId = ref
        var workingRefStr: String?
        var managedRecord: ProvenanceRecord?

        if docInfo.isSession && WorkingRef.isWorkingRefString(ref) {
            let sessUrl = URL(fileURLWithPath: docInfo.documentPath)
            let provenance = ProvenanceStore(sessionDirectory: sessUrl)
            let record = try provenance.resolveManagedWorkingReference(
                ref,
                currentDocumentPath: docInfo.documentPath
            )
            managedRecord = record
            nativeId = record.cloneVariantId
            workingRefStr = record.workingRef
        }

        let docNameDesc = NSAppleEventDescriptor(string: docInfo.documentId)
        let idListDesc = NSAppleEventDescriptor(list: [NSAppleEventDescriptor(string: nativeId)])

        let results: [AdjustmentBatchItemRecord] = try executor.executeAndDecode(
            handler: "getAdjustmentsBatch",
            args: [docNameDesc, idListDesc]
        )

        guard let first = results.first else {
            throw C1Error.variantNotFound("Variant '\(ref)' (native ID '\(nativeId)') not found in current document.")
        }

        if let record = managedRecord {
            try DocumentIdentity.validate(record: record, document: docInfo, parentImagePath: first.parentImagePath ?? "")
        }
        let adjustments = Adjustments(
            exposure: first.exposureVal,
            contrast: first.contrastVal,
            saturation: first.saturationVal,
            temperature: first.temperatureVal,
            tint: first.tintVal
        )
        let metadata = Metadata(
            camera: first.cameraVal,
            lens: first.lensVal,
            iso: first.isoVal,
            shutterSpeed: first.shutterSpeedVal,
            asShotWB: first.asShotWBVal,
            captureDate: first.captureDateVal,
            rating: first.starRating,
            colorTag: first.colorTagVal
        )
        let hash = StateHash.compute(for: adjustments)

        return GetResult(
            id: nativeId,
            workingRef: workingRefStr,
            adjustments: adjustments,
            metadata: metadata,
            stateHash: hash.hex,
            parentImagePath: first.parentImagePath
        )
    }

    // MARK: - Set / Add / Reset Mutations
    public func mutate(
        workingRefString: String,
        ifState expectedHash: String,
        setAdjustments: Adjustments?,
        addAdjustments: Adjustments?,
        isDryRun: Bool = false,
        operationType: String? = nil
    ) throws -> MutationResult {
        guard (setAdjustments != nil) != (addAdjustments != nil), (setAdjustments ?? addAdjustments)?.hasAnyField == true else {
            throw C1Error.invalidRequest("Provide exactly one nonempty set or add adjustment patch.")
        }
        let docInfo = try getDocumentInfo()
        let resolvedOpType = operationType ?? (setAdjustments != nil ? "set" : "add")
        try assertSessionWritable(docInfo: docInfo, operation: resolvedOpType)

        let sessUrl = URL(fileURLWithPath: docInfo.documentPath)
        let provenance = ProvenanceStore(sessionDirectory: sessUrl)
        let journal = OperationJournal(sessionDirectory: sessUrl)

        // Core enforcement: must be a managed working reference
        let record = try provenance.resolveManagedWorkingReference(
            workingRefString,
            currentDocumentPath: docInfo.documentPath
        )

        return try lock.withLock {
            try checkedDocument(docInfo, writes: !isDryRun)
            // 1. Read current state
            let current = try self.get(ref: record.workingRef)
            guard current.stateHash == expectedHash else {
                throw C1Error.stateChanged("Optimistic concurrency conflict for '\(workingRefString)'. Expected stateHash '\(expectedHash)', but actual is '\(current.stateHash)'.")
            }

            // 2. Compute target adjustments
            var target = current.adjustments
            if let s = setAdjustments {
                if let v = s.exposure { target.exposure = v }
                if let v = s.contrast { target.contrast = v }
                if let v = s.saturation { target.saturation = v }
                if let v = s.temperature { target.temperature = v }
                if let v = s.tint { target.tint = v }
            }
            if let a = addAdjustments {
                target = try self.registry.applyDelta(base: target, delta: a)
            }
            try self.registry.validateAdjustments(target)

            let diff = self.computeDiff(before: current.adjustments, after: target)

            let predictedHash = StateHash.compute(for: target).hex

            if isDryRun {
                return MutationResult(
                    operationId: "dry-run",
                    workingRef: record.workingRef,
                    before: current.adjustments,
                    after: target,
                    diff: diff,
                    stateHash: predictedHash,
                    isDryRun: true
                )
            }

            // 3. Pre-dispatch journal entry
            let opId = UUID().uuidString.lowercased()
            let journalEntry = try prepare(OperationRecord(
                operationId: opId,
                operationType: resolvedOpType,
                workingRef: record.workingRef,
                documentPath: docInfo.documentPath,
                preconditionStateHash: expectedHash,
                intendedAdjustments: target,
                beforeAdjustments: current.adjustments,
                status: "pending"
            ), doc: docInfo, source: current)
            try journal.append(entry: journalEntry)

            // 4. Dispatch write
            let docNameDesc = NSAppleEventDescriptor(string: docInfo.documentId)
            let varIdDesc = NSAppleEventDescriptor(string: record.cloneVariantId)
            var patch = Adjustments()
            for field in self.registry.supportedAdjustmentFields {
                if setAdjustments?.value(for: field.name) != nil || addAdjustments?.value(for: field.name) != nil {
                    patch.setValue(target.value(for: field.name), for: field.name)
                }
            }
            // White balance must be written and verified as a pair.
            if patch.temperature != nil || patch.tint != nil { patch.temperature = target.temperature; patch.tint = target.tint }
            let expDesc = patch.exposure != nil ? NSAppleEventDescriptor(double: patch.exposure!) : NSAppleEventDescriptor.missingValue()
            let contDesc = patch.contrast != nil ? NSAppleEventDescriptor(double: patch.contrast!) : NSAppleEventDescriptor.missingValue()
            let satDesc = patch.saturation != nil ? NSAppleEventDescriptor(double: patch.saturation!) : NSAppleEventDescriptor.missingValue()
            let tempDesc = patch.temperature != nil ? NSAppleEventDescriptor(double: patch.temperature!) : NSAppleEventDescriptor.missingValue()
            let tintDesc = patch.tint != nil ? NSAppleEventDescriptor(double: patch.tint!) : NSAppleEventDescriptor.missingValue()

            let applyRes: ApplyAdjustmentsResult
            do {
                applyRes = try self.executor.executeAndDecode(
                    handler: "applyAdjustments",
                    args: [docNameDesc, varIdDesc, expDesc, contDesc, satDesc, tempDesc, tintDesc,
                           NSAppleEventDescriptor(list: self.registry.supportedAdjustmentFields.map { NSAppleEventDescriptor(double: current.adjustments.value(for: $0.name)!) }),
                           NSAppleEventDescriptor(string: current.parentImagePath ?? "")]
                )
            } catch {
                try? journal.update(operationId: opId, status: "outcome-unknown", error: error.localizedDescription)
                throw OperationFailure(operationId: opId, cause: error)
            }

            // 5. Readback verification
            let after = Adjustments(
                exposure: applyRes.afterExposureVal,
                contrast: applyRes.afterContrastVal,
                saturation: applyRes.afterSaturationVal,
                temperature: applyRes.afterTemperatureVal,
                tint: applyRes.afterTintVal
            )

            // Verify readback matches targets within tolerance
            var mismatches: [String] = []
            if let expected = target.exposure, !self.registry.valuesMatchWithinTolerance(field: "exposure", expected: expected, actual: after.exposure ?? 0) {
                mismatches.append("exposure (expected \(expected), got \(after.exposure ?? 0))")
            }
            if let expected = target.contrast, !self.registry.valuesMatchWithinTolerance(field: "contrast", expected: expected, actual: after.contrast ?? 0) {
                mismatches.append("contrast (expected \(expected), got \(after.contrast ?? 0))")
            }
            if let expected = target.saturation, !self.registry.valuesMatchWithinTolerance(field: "saturation", expected: expected, actual: after.saturation ?? 0) {
                mismatches.append("saturation (expected \(expected), got \(after.saturation ?? 0))")
            }
            if let expected = target.temperature, !self.registry.valuesMatchWithinTolerance(field: "temperature", expected: expected, actual: after.temperature ?? 0) {
                mismatches.append("temperature (expected \(expected), got \(after.temperature ?? 0))")
            }
            if let expected = target.tint, !self.registry.valuesMatchWithinTolerance(field: "tint", expected: expected, actual: after.tint ?? 0) {
                mismatches.append("tint (expected \(expected), got \(after.tint ?? 0))")
            }

            if !mismatches.isEmpty {
                let errStr = "Readback mismatch after mutation: " + mismatches.joined(separator: ", ")
                try? journal.update(operationId: opId, status: "partial-failure", afterAdjustments: after, error: errStr)
                throw OperationFailure(operationId: opId, cause: C1Error.readbackMismatch(errStr))
            }

            // 6. Compute actual diff & stateHash
            let actualHash = StateHash.compute(for: after).hex
            let actualDiff = self.computeDiff(before: current.adjustments, after: after)

            do {
                try journal.update(operationId: opId, status: "succeeded", afterAdjustments: after, diff: actualDiff)
            } catch { throw OperationFailure(operationId: opId, cause: error) }

            return MutationResult(
                operationId: opId,
                workingRef: record.workingRef,
                before: current.adjustments,
                after: after,
                diff: actualDiff,
                stateHash: actualHash,
                isDryRun: false
            )
        }
    }

    // MARK: - Reset Mutation
    public func reset(
        workingRefString: String,
        ifState expectedHash: String,
        fields: [String] = [],
        isDryRun: Bool = false
    ) throws -> MutationResult {
        let docInfo = try getDocumentInfo()
        try assertSessionWritable(docInfo: docInfo, operation: "reset")

        let sessUrl = URL(fileURLWithPath: docInfo.documentPath)
        let provenance = ProvenanceStore(sessionDirectory: sessUrl)
        let record = try provenance.resolveManagedWorkingReference(
            workingRefString,
            currentDocumentPath: docInfo.documentPath
        )

        let targetResetAdjustments = try registry.computeResetValues(fields: fields, baseline: record.baselineAdjustments)

        return try mutate(
            workingRefString: workingRefString,
            ifState: expectedHash,
            setAdjustments: targetResetAdjustments,
            addAdjustments: nil,
            isDryRun: isDryRun,
            operationType: "reset"
        )
    }

    // MARK: - Create Baseline Variant (New Variant)
    public func createBaselineVariant(sourceRef: String) throws -> CloneResult {
        try createVariant(sourceRef: sourceRef, baseline: true)
    }

    // MARK: - Diff
    public func diff(ref1: String, ref2: String? = nil) throws -> DiffResult {
        let docInfo = try getDocumentInfo()
        let get1 = try self.get(ref: ref1)

        if let secondRef = ref2 {
            let get2 = try self.get(ref: secondRef)
            let diffDict = computeDiff(before: get1.adjustments, after: get2.adjustments)
            return DiffResult(
                ref1: ref1,
                ref2: secondRef,
                stateHash1: get1.stateHash,
                stateHash2: get2.stateHash,
                diff: diffDict
            )
        } else {
            guard docInfo.isSession else {
                throw C1Error.invalidRequest("Single-reference diff compares a working variant against its baseline, which requires a Session. For Catalogs, provide two variant references: c1 diff <ref1> <ref2>")
            }
            guard WorkingRef.isWorkingRefString(ref1) else {
                throw C1Error.invalidRequest("Single-reference diff requires a managed working reference (c1_wrk_<uuid>). To compare native variants, provide two references: c1 diff <ref1> <ref2>")
            }
            let sessUrl = URL(fileURLWithPath: docInfo.documentPath)
            let provenance = ProvenanceStore(sessionDirectory: sessUrl)
            let record = try provenance.resolveManagedWorkingReference(
                ref1,
                currentDocumentPath: docInfo.documentPath
            )
            let baselineAdj = record.baselineAdjustments
            let baselineHash = record.baselineStateHash
            let diffDict = computeDiff(before: baselineAdj, after: get1.adjustments)
            return DiffResult(
                ref1: "baseline",
                ref2: ref1,
                stateHash1: baselineHash,
                stateHash2: get1.stateHash,
                diff: diffDict
            )
        }
    }

    public func computeDiff(before: Adjustments, after: Adjustments) -> [String: DoubleDiff] {
        var diff: [String: DoubleDiff] = [:]
        if let b = before.exposure, let a = after.exposure, b != a {
            diff["exposure"] = DoubleDiff(before: b, after: a)
        }
        if let b = before.contrast, let a = after.contrast, b != a {
            diff["contrast"] = DoubleDiff(before: b, after: a)
        }
        if let b = before.saturation, let a = after.saturation, b != a {
            diff["saturation"] = DoubleDiff(before: b, after: a)
        }
        if let b = before.temperature, let a = after.temperature, b != a {
            diff["temperature"] = DoubleDiff(before: b, after: a)
        }
        if let b = before.tint, let a = after.tint, b != a {
            diff["tint"] = DoubleDiff(before: b, after: a)
        }
        return diff
    }

    // MARK: - Dump
    public func dump(
        collectionName: String? = nil,
        selectedOnly: Bool = false,
        batchSize: Int = 100
    ) throws -> [DumpRecord] {
        guard (1...1000).contains(batchSize) else { throw C1Error.invalidRequest("batchSize must be between 1 and 1000.") }
        let docInfo = try getDocumentInfo()
        let variants = try listVariants(collectionName: collectionName, selectedOnly: selectedOnly)
        guard !variants.isEmpty else { return [] }

        var records: [DumpRecord] = []
        let docNameDesc = NSAppleEventDescriptor(string: docInfo.documentId)

        for chunkStart in stride(from: 0, to: variants.count, by: max(1, batchSize)) {
            let chunkEnd = min(chunkStart + batchSize, variants.count)
            let chunk = Array(variants[chunkStart..<chunkEnd])
            let idsDesc = NSAppleEventDescriptor(list: chunk.map { NSAppleEventDescriptor(string: $0.id) })

            let batchItems: [AdjustmentBatchItemRecord] = try executor.executeAndDecode(
                handler: "getAdjustmentsBatch",
                args: [docNameDesc, idsDesc]
            )

            var itemMap: [String: AdjustmentBatchItemRecord] = [:]
            for item in batchItems {
                itemMap[item.variantId] = item
            }

            for v in chunk {
                guard let item = itemMap[v.id] else { continue }
                let adjustments = Adjustments(
                    exposure: item.exposureVal,
                    contrast: item.contrastVal,
                    saturation: item.saturationVal,
                    temperature: item.temperatureVal,
                    tint: item.tintVal
                )
                let metadata = Metadata(
                    camera: item.cameraVal,
                    lens: item.lensVal,
                    iso: item.isoVal,
                    shutterSpeed: item.shutterSpeedVal,
                    asShotWB: item.asShotWBVal,
                    captureDate: item.captureDateVal,
                    rating: item.starRating,
                    colorTag: item.colorTagVal
                )
                let stateHash = StateHash.compute(for: adjustments).hex
                records.append(DumpRecord(
                    id: v.id,
                    name: v.name,
                    parentImagePath: v.parentImagePath,
                    isSelected: v.isSelected,
                    rating: v.rating,
                    colorTag: v.colorTag,
                    isManagedWorkingClone: v.isManagedWorkingClone,
                    workingRef: v.workingRef,
                    adjustments: adjustments,
                    metadata: metadata,
                    stateHash: stateHash
                ))
            }
        }

        return records
    }

    // MARK: - Preview
    public func preview(workingRefString: String, outputDirOverride: String? = nil, timeout: TimeInterval = 30.0) throws -> PreviewResult {
        try preview(ref: workingRefString, outputDirOverride: outputDirOverride, timeout: timeout)
    }

    public func preview(ref: String, outputDirOverride: String? = nil, timeout: TimeInterval = 30.0) throws -> PreviewResult {
        guard timeout.isFinite && timeout > 0 && timeout <= 300 else { throw C1Error.invalidRequest("timeout must be in (0, 300] seconds.") }
        return try lock.withLock {
            let doc = try getDocumentInfo()
            try assertSessionWritable(docInfo: doc, operation: "preview")
            try checkedDocument(doc)
            let current = try get(ref: ref)
            let journal = OperationJournal(sessionDirectory: URL(fileURLWithPath: doc.documentPath))
            let opId = UUID().uuidString.lowercased()
            let root = URL(fileURLWithPath: outputDirOverride ?? doc.outputFolder).resolvingSymlinksInPath()
            let subfolder = "c1-previews/\(opId)"
            let jobDir = root.appendingPathComponent(subfolder, isDirectory: true)
            try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
            let entry = try prepare(OperationRecord(operationId: opId, operationType: "preview", workingRef: ref,
                documentPath: doc.documentPath, preconditionStateHash: current.stateHash,
                beforeAdjustments: current.adjustments, previewOutputPath: jobDir.path), doc: doc, source: current)
            try journal.append(entry: entry)
            do {
                let args = [NSAppleEventDescriptor(string: doc.documentId),
                            NSAppleEventDescriptor(string: PreviewManager.defaultRecipeName), NSAppleEventDescriptor(string: root.path)]
                let _: PreviewRecipeResult = try executor.executeAndDecode(handler: "ensurePreviewRecipe", args: args)
                let _: ProcessPreviewResult = try executor.executeAndDecode(handler: "processPreview", args: [
                    args[0], NSAppleEventDescriptor(string: current.id), args[1], args[2],
                    NSAppleEventDescriptor(string: subfolder), NSAppleEventDescriptor(string: "preview")])
                let file = try previewMgr.pollForOutputFile(inDirectory: jobDir, timeout: timeout)
                let image = try previewMgr.verifyAndDecodeImage(atPath: file.path)
                let after = try get(ref: ref)
                guard after.stateHash == current.stateHash else { throw C1Error.stateChanged("Adjustments changed while preview rendered; discard this preview.") }
                let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
                try journal.update(operationId: opId, status: "succeeded", previewOutputPath: file.path)
                return PreviewResult(operationId: opId, workingRef: current.workingRef, outputPath: file.path,
                    fileSizeBytes: size, width: image.width, height: image.height, pixelSha256: image.pixelSha256,
                    stateHash: current.stateHash, nativeVariantId: current.id)
            } catch {
                try? journal.update(operationId: opId, status: "outcome-unknown", error: String(describing: error))
                throw OperationFailure(operationId: opId, cause: error)
            }
        }
    }

    // MARK: - Operation Status & Reconciliation
    /// A restarted app cannot still execute an Apple Event from its previous process.
    /// Reconciliation records observations, never retries an uncertain mutation or rebinds a reference.
    public func operationStatus(operationId: String) throws -> OperationRecord {
        return try lock.withLock {
            let doc = try getDocumentInfo()
            try assertSessionWritable(docInfo: doc, operation: "operation status")
            let journal = OperationJournal(sessionDirectory: URL(fileURLWithPath: doc.documentPath))
            guard var entry = try journal.validatedEntries().first(where: { $0.operationId == operationId }) else {
                throw C1Error.invalidRequest("Operation ID '\(operationId)' not found in journal.")
            }
            guard OperationJournal.isUnresolved(entry) else { return entry }
            guard let originalInstance = entry.appInstance, originalInstance != (try appInstance()) else { return entry }
            guard entry.documentIdentity == (try databaseIdentity(databasePath(doc))) else {
                throw C1Error.documentChanged("Cannot reconcile against a replaced database.")
            }
            let variants = try listVariants()
            if ["clone", "baseline"].contains(entry.operationType) {
                guard let before = entry.variantIdsBefore, let parent = entry.parentImagePath else {
                    throw C1Error.identityAmbiguous("Creation lacks recovery identity evidence.")
                }
                entry.observedVariantIds = variants.filter { $0.parentImagePath == parent && !before.contains($0.id) }.map { $0.id }
                // Other photographer-created variants are indistinguishable; do not adopt or delete them.
                entry.status = "reconciled"
                entry.error = "Previous app instance ended. Review observedVariantIds manually; no variants were adopted, deleted, or recreated."
            } else if let id = entry.nativeVariantId {
                if let variant = variants.first(where: { $0.id == id }) {
                    guard variant.parentImagePath == entry.parentImagePath else { throw C1Error.identityAmbiguous("Recovery variant parent changed.") }
                    let current = try get(ref: id)
                    entry.afterAdjustments = current.adjustments
                    entry.status = "reconciled"
                    entry.error = "Previous app instance ended. Observed current adjustments are recorded; they do not prove historical completion. Review before creating a fresh working clone."
                } else {
                    entry.status = "reconciled"
                    entry.error = "Previous app instance ended; the target variant is absent. No retry was performed."
                }
            } else { throw C1Error.identityAmbiguous("Operation lacks a native variant recovery identity.") }
            try journal.append(entry: entry)
            return entry
        }
    }

    // MARK: - Capabilities
    public func capabilities() -> [String: Any] {
        [
            "pinnedBuild": Self.pinnedBuild,
            "testedBuilds": Self.testedBuilds,
            "supportedVersionRange": "16.4+ through 16.x",
            "documentScope": "sessions-and-catalogs",
            "catalogReadOnly": true,
            "supportedFields": registry.supportedAdjustmentFields.map { spec in
                [
                    "name": spec.name,
                    "aliases": spec.aliases,
                    "type": spec.type,
                    "unit": spec.unit as Any,
                    "minValue": spec.minValue as Any,
                    "maxValue": spec.maxValue as Any,
                    "tolerance": spec.tolerance,
                    "operations": spec.operations.map { $0.rawValue }
                ]
            },
            "readOnlyMetadataFields": registry.supportedMetadataFields.map { spec in
                [
                    "name": spec.name,
                    "aliases": spec.aliases,
                    "type": spec.type,
                    "operations": spec.operations.map { $0.rawValue }
                ]
            },
            "previewRecipe": [
                "name": PreviewManager.defaultRecipeName,
                "format": "JPEG",
                "quality": 80,
                "profile": "sRGB Color Space Profile",
                "scaling": "Long_Edge 1500px"
            ],
            "concurrency": "advisory-lock",
            "workingVariantEnforced": true
        ]
    }

    // MARK: - Helpers
    private func sessionUrl(forDocPath docPath: String) -> URL? {
        let path = (docPath as NSString).standardizingPath
        if path.hasSuffix(".cosessiondb") {
            return URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: path)
    }
}
