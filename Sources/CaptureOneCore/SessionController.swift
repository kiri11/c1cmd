import Foundation
import AppleScriptBridge
import AppKit

public struct DoctorReport: Codable, Equatable {
    public let appRunning: Bool
    public let appVersion: String
    public let exactBuildMatched: Bool
    public let pinnedBuild: String
    public let hasDocument: Bool
    public let docName: String?
    public let docPath: String?
    public let isSession: Bool
    public let lockAcquired: Bool
    public let unresolvedOperationsCount: Int
    public let allChecksPassed: Bool
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
    public static let pinnedBuild = "16.8.5.30"

    private let executor = AppleScriptExecutor.shared
    private let lock = CaptureOneLock.shared
    private let registry = FieldRegistry.shared
    private let previewMgr = PreviewManager.shared

    private init() {}

    // MARK: - Doctor
    public func doctor() throws -> DoctorReport {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.captureone.captureone16")
        let appRunning = !apps.isEmpty

        var appVersion = "unknown"
        var hasDoc = false
        var docName: String?
        var docPath: String?
        var isSession = false

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
            } catch {
                appVersion = "error"
            }
        }

        let buildMatched = (appVersion == Self.pinnedBuild)

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
            unresolvedCount = journal.unresolvedEntries().count
        }

        let allPassed = appRunning && buildMatched && hasDoc && lockOk && (unresolvedCount == 0)

        return DoctorReport(
            appRunning: appRunning,
            appVersion: appVersion,
            exactBuildMatched: buildMatched,
            pinnedBuild: Self.pinnedBuild,
            hasDocument: hasDoc,
            docName: docName,
            docPath: docPath,
            isSession: isSession,
            lockAcquired: lockOk,
            unresolvedOperationsCount: unresolvedCount,
            allChecksPassed: allPassed
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

        let isBuildAllowed = allowUntestedBuild
            || ProcessInfo.processInfo.environment["C1_ALLOW_UNTESTED_BUILD"] == "1"
            || info.appVersion == Self.pinnedBuild

        guard isBuildAllowed else {
            throw C1Error.unsupportedVersion(
                "Running Capture One build '\(info.appVersion)' is not verified (pinned: '\(Self.pinnedBuild)'). Set C1_ALLOW_UNTESTED_BUILD=1 to override."
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

        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.captureone.captureone16")
        let pid = apps.first?.processIdentifier ?? 0
        let openToken = "\(name):\(pid):\(path)"

        return DocumentInfo(
            documentId: path,
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
        let isBuildAllowed = ProcessInfo.processInfo.environment["C1_ALLOW_UNTESTED_BUILD"] == "1"
            || docInfo.appVersion == Self.pinnedBuild
        guard isBuildAllowed else {
            throw C1Error.unsupportedVersion(
                "Running Capture One build '\(docInfo.appVersion)' is not verified (pinned: '\(Self.pinnedBuild)'). Set C1_ALLOW_UNTESTED_BUILD=1 to override."
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
            args: [colDesc, selDesc]
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
        let docInfo = try getDocumentInfo()
        try assertSessionWritable(docInfo: docInfo, operation: "clone")

        let sessUrl = URL(fileURLWithPath: docInfo.documentPath)
        let provenance = ProvenanceStore(sessionDirectory: sessUrl)
        let journal = OperationJournal(sessionDirectory: sessUrl)

        return try lock.withLock {
            // Read source baseline
            let getRes = try self.get(ref: sourceRef)
            let workingRef = WorkingRef()
            let opId = UUID().uuidString.lowercased()

            let docNameDesc = NSAppleEventDescriptor(string: docInfo.documentName)
            let sourceIdDesc = NSAppleEventDescriptor(string: getRes.id)

            let cloneRes: CloneVariantResult = try self.executor.executeAndDecode(
                handler: "cloneVariant",
                args: [docNameDesc, sourceIdDesc]
            )

            let rec = ProvenanceRecord(
                workingRef: workingRef.rawValue,
                sourceVariantId: getRes.id,
                cloneVariantId: cloneRes.cloneId,
                documentPath: docInfo.documentPath,
                documentName: docInfo.documentName,
                parentImagePath: nil,
                creationOperationId: opId,
                baselineAdjustments: getRes.adjustments,
                baselineStateHash: getRes.stateHash
            )
            try provenance.register(record: rec)

            let opEntry = OperationRecord(
                operationId: opId,
                operationType: "clone",
                workingRef: workingRef.rawValue,
                documentPath: docInfo.documentPath,
                preconditionStateHash: nil,
                intendedAdjustments: nil,
                beforeAdjustments: getRes.adjustments,
                afterAdjustments: getRes.adjustments,
                status: "succeeded"
            )
            try journal.append(entry: opEntry)

            return CloneResult(
                workingRef: workingRef.rawValue,
                cloneVariantId: cloneRes.cloneId,
                sourceVariantId: getRes.id,
                documentPath: docInfo.documentPath,
                baselineStateHash: getRes.stateHash
            )
        }
    }

    // MARK: - Delete Variant
    public func deleteVariant(workingRefString: String) throws -> DeleteResult {
        let docInfo = try getDocumentInfo()
        try assertSessionWritable(docInfo: docInfo, operation: "delete")

        let sessUrl = URL(fileURLWithPath: docInfo.documentPath)
        let provenance = ProvenanceStore(sessionDirectory: sessUrl)
        let journal = OperationJournal(sessionDirectory: sessUrl)

        let record = try provenance.resolveManagedWorkingReference(
            workingRefString,
            currentDocumentPath: docInfo.documentPath
        )

        return try lock.withLock {
            let docNameDesc = NSAppleEventDescriptor(string: docInfo.documentName)
            let varIdDesc = NSAppleEventDescriptor(string: record.cloneVariantId)

            let delRes: DeleteVariantResult = try self.executor.executeAndDecode(
                handler: "deleteVariant",
                args: [docNameDesc, varIdDesc]
            )

            try provenance.remove(workingRef: record.workingRef)

            let opEntry = OperationRecord(
                operationId: UUID().uuidString.lowercased(),
                operationType: "delete",
                workingRef: record.workingRef,
                documentPath: docInfo.documentPath,
                status: delRes.deleted ? "succeeded" : "failed"
            )
            try journal.append(entry: opEntry)

            return DeleteResult(
                deleted: delRes.deleted,
                workingRef: record.workingRef,
                cloneVariantId: record.cloneVariantId
            )
        }
    }

    // MARK: - Get
    public func get(ref: String) throws -> GetResult {
        let docInfo = try getDocumentInfo()
        var nativeId = ref
        var workingRefStr: String?

        if docInfo.isSession && WorkingRef.isWorkingRefString(ref) {
            let sessUrl = URL(fileURLWithPath: docInfo.documentPath)
            let provenance = ProvenanceStore(sessionDirectory: sessUrl)
            let record = try provenance.resolveManagedWorkingReference(
                ref,
                currentDocumentPath: docInfo.documentPath
            )
            nativeId = record.cloneVariantId
            workingRefStr = record.workingRef
        }

        let docNameDesc = NSAppleEventDescriptor(string: docInfo.documentName)
        let idListDesc = NSAppleEventDescriptor(list: [NSAppleEventDescriptor(string: nativeId)])

        let results: [AdjustmentBatchItemRecord] = try executor.executeAndDecode(
            handler: "getAdjustmentsBatch",
            args: [docNameDesc, idListDesc]
        )

        guard let first = results.first else {
            throw C1Error.variantNotFound("Variant '\(ref)' (native ID '\(nativeId)') not found in current document.")
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
            stateHash: hash.hex
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

            // Calculate predicted diff
            var diff: [String: DoubleDiff] = [:]
            if let b = current.adjustments.exposure, let a = target.exposure, b != a {
                diff["exposure"] = DoubleDiff(before: b, after: a)
            }
            if let b = current.adjustments.contrast, let a = target.contrast, b != a {
                diff["contrast"] = DoubleDiff(before: b, after: a)
            }
            if let b = current.adjustments.saturation, let a = target.saturation, b != a {
                diff["saturation"] = DoubleDiff(before: b, after: a)
            }
            if let b = current.adjustments.temperature, let a = target.temperature, b != a {
                diff["temperature"] = DoubleDiff(before: b, after: a)
            }
            if let b = current.adjustments.tint, let a = target.tint, b != a {
                diff["tint"] = DoubleDiff(before: b, after: a)
            }

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
            let journalEntry = OperationRecord(
                operationId: opId,
                operationType: resolvedOpType,
                workingRef: record.workingRef,
                documentPath: docInfo.documentPath,
                preconditionStateHash: expectedHash,
                intendedAdjustments: target,
                beforeAdjustments: current.adjustments,
                status: "pending"
            )
            try journal.append(entry: journalEntry)

            // 4. Dispatch write
            let docNameDesc = NSAppleEventDescriptor(string: docInfo.documentName)
            let varIdDesc = NSAppleEventDescriptor(string: record.cloneVariantId)
            let expDesc = target.exposure != nil ? NSAppleEventDescriptor(double: target.exposure!) : NSAppleEventDescriptor.missingValue()
            let contDesc = target.contrast != nil ? NSAppleEventDescriptor(double: target.contrast!) : NSAppleEventDescriptor.missingValue()
            let satDesc = target.saturation != nil ? NSAppleEventDescriptor(double: target.saturation!) : NSAppleEventDescriptor.missingValue()
            let tempDesc = target.temperature != nil ? NSAppleEventDescriptor(double: target.temperature!) : NSAppleEventDescriptor.missingValue()
            let tintDesc = target.tint != nil ? NSAppleEventDescriptor(double: target.tint!) : NSAppleEventDescriptor.missingValue()

            let applyRes: ApplyAdjustmentsResult
            do {
                applyRes = try self.executor.executeAndDecode(
                    handler: "applyAdjustments",
                    args: [docNameDesc, varIdDesc, expDesc, contDesc, satDesc, tempDesc, tintDesc]
                )
            } catch {
                try? journal.update(operationId: opId, status: "outcome-unknown", error: error.localizedDescription)
                throw error
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
                throw C1Error.readbackMismatch(errStr)
            }

            // 6. Compute actual diff & stateHash
            let actualHash = StateHash.compute(for: after).hex
            var actualDiff: [String: DoubleDiff] = [:]
            if let b = current.adjustments.exposure, let a = after.exposure, b != a {
                actualDiff["exposure"] = DoubleDiff(before: b, after: a)
            }
            if let b = current.adjustments.contrast, let a = after.contrast, b != a {
                actualDiff["contrast"] = DoubleDiff(before: b, after: a)
            }
            if let b = current.adjustments.saturation, let a = after.saturation, b != a {
                actualDiff["saturation"] = DoubleDiff(before: b, after: a)
            }
            if let b = current.adjustments.temperature, let a = after.temperature, b != a {
                actualDiff["temperature"] = DoubleDiff(before: b, after: a)
            }
            if let b = current.adjustments.tint, let a = after.tint, b != a {
                actualDiff["tint"] = DoubleDiff(before: b, after: a)
            }

            try journal.update(
                operationId: opId,
                status: "succeeded",
                afterAdjustments: after,
                diff: actualDiff
            )

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
        let docInfo = try getDocumentInfo()
        try assertSessionWritable(docInfo: docInfo, operation: "baseline")

        let sessUrl = URL(fileURLWithPath: docInfo.documentPath)
        let provenance = ProvenanceStore(sessionDirectory: sessUrl)
        let journal = OperationJournal(sessionDirectory: sessUrl)

        return try lock.withLock {
            let sourceRes = try self.get(ref: sourceRef)
            let workingRef = WorkingRef()
            let opId = UUID().uuidString.lowercased()

            let docNameDesc = NSAppleEventDescriptor(string: docInfo.documentName)
            let sourceIdDesc = NSAppleEventDescriptor(string: sourceRes.id)

            let baselineRes: CreateBaselineVariantResult = try self.executor.executeAndDecode(
                handler: "createBaselineVariant",
                args: [docNameDesc, sourceIdDesc]
            )

            var baselineVarResOpt: GetResult?
            for attempt in 1...5 {
                do {
                    baselineVarResOpt = try self.get(ref: baselineRes.baselineId)
                    break
                } catch {
                    if attempt == 5 { throw error }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            guard let baselineVarRes = baselineVarResOpt else {
                throw C1Error.variantNotFound("Failed to resolve baseline variant '\(baselineRes.baselineId)'.")
            }

            let rec = ProvenanceRecord(
                workingRef: workingRef.rawValue,
                sourceVariantId: sourceRes.id,
                cloneVariantId: baselineRes.baselineId,
                documentPath: docInfo.documentPath,
                documentName: docInfo.documentName,
                parentImagePath: nil,
                creationOperationId: opId,
                baselineAdjustments: baselineVarRes.adjustments,
                baselineStateHash: baselineVarRes.stateHash
            )
            try provenance.register(record: rec)

            let opEntry = OperationRecord(
                operationId: opId,
                operationType: "baseline",
                workingRef: workingRef.rawValue,
                documentPath: docInfo.documentPath,
                preconditionStateHash: nil,
                intendedAdjustments: nil,
                beforeAdjustments: baselineVarRes.adjustments,
                afterAdjustments: baselineVarRes.adjustments,
                status: "succeeded"
            )
            try journal.append(entry: opEntry)

            return CloneResult(
                workingRef: workingRef.rawValue,
                cloneVariantId: baselineRes.baselineId,
                sourceVariantId: sourceRes.id,
                documentPath: docInfo.documentPath,
                baselineStateHash: baselineVarRes.stateHash
            )
        }
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
        let docInfo = try getDocumentInfo()
        let variants = try listVariants(collectionName: collectionName, selectedOnly: selectedOnly)
        guard !variants.isEmpty else { return [] }

        var records: [DumpRecord] = []
        let docNameDesc = NSAppleEventDescriptor(string: docInfo.documentName)

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
        let docInfo = try getDocumentInfo()
        var nativeId = ref
        var workingRefStr: String?

        if docInfo.isSession {
            let sessUrl = URL(fileURLWithPath: docInfo.documentPath)
            let provenance = ProvenanceStore(sessionDirectory: sessUrl)
            if WorkingRef.isWorkingRefString(ref) {
                let record = try provenance.resolveManagedWorkingReference(
                    ref,
                    currentDocumentPath: docInfo.documentPath
                )
                nativeId = record.cloneVariantId
                workingRefStr = record.workingRef
            }
        }

        return try lock.withLock {
            let opId = UUID().uuidString.lowercased()
            let jobOutputDir: URL
            if let custom = outputDirOverride {
                jobOutputDir = URL(fileURLWithPath: custom)
            } else if docInfo.isSession {
                jobOutputDir = URL(fileURLWithPath: docInfo.documentPath).appendingPathComponent("Output/c1-previews/\(opId)", isDirectory: true)
            } else {
                jobOutputDir = URL(fileURLWithPath: "/private/tmp/c1-previews/\(opId)", isDirectory: true)
            }
            try FileManager.default.createDirectory(at: jobOutputDir, withIntermediateDirectories: true)

            let recipeOutputFolder = docInfo.isSession ? docInfo.outputFolder : jobOutputDir.path

            // Configure recipe
            let docNameDesc = NSAppleEventDescriptor(string: docInfo.documentName)
            let recipeDesc = NSAppleEventDescriptor(string: PreviewManager.defaultRecipeName)
            let outputFolderDesc = NSAppleEventDescriptor(string: recipeOutputFolder)

            let _: PreviewRecipeResult = try self.executor.executeAndDecode(
                handler: "ensurePreviewRecipe",
                args: [docNameDesc, recipeDesc, outputFolderDesc]
            )

            var journal: OperationJournal?
            if docInfo.isSession {
                let sessUrl = URL(fileURLWithPath: docInfo.documentPath)
                let j = OperationJournal(sessionDirectory: sessUrl)
                journal = j
                let opRecord = OperationRecord(
                    operationId: opId,
                    operationType: "preview",
                    workingRef: workingRefStr ?? nativeId,
                    documentPath: docInfo.documentPath,
                    status: "pending",
                    previewOutputPath: jobOutputDir.path
                )
                try? j.append(entry: opRecord)
            }

            // Dispatch processPreview
            let varIdDesc = NSAppleEventDescriptor(string: nativeId)
            let subfolderDesc = NSAppleEventDescriptor(string: docInfo.isSession ? "c1-previews/\(opId)" : "")
            let filenameDesc = NSAppleEventDescriptor(string: "preview")

            do {
                let _: ProcessPreviewResult = try self.executor.executeAndDecode(
                    handler: "processPreview",
                    args: [docNameDesc, varIdDesc, recipeDesc, outputFolderDesc, subfolderDesc, filenameDesc]
                )
            } catch {
                try? journal?.update(operationId: opId, status: "outcome-unknown", error: error.localizedDescription)
                throw error
            }

            // Poll for output file
            let outputFile: URL
            do {
                outputFile = try self.previewMgr.pollForOutputFile(inDirectory: jobOutputDir, timeout: timeout)
            } catch {
                try? journal?.update(operationId: opId, status: "failed", error: error.localizedDescription)
                throw error
            }

            // Verify and decode image
            let imgAttrs = try self.previewMgr.verifyAndDecodeImage(atPath: outputFile.path)
            let fileAttrs = try FileManager.default.attributesOfItem(atPath: outputFile.path)
            let size = (fileAttrs[.size] as? NSNumber)?.int64Value ?? 0

            try journal?.update(
                operationId: opId,
                status: "succeeded",
                previewOutputPath: outputFile.path
            )

            return PreviewResult(
                operationId: opId,
                workingRef: workingRefStr,
                outputPath: outputFile.path,
                fileSizeBytes: size,
                width: imgAttrs.width,
                height: imgAttrs.height,
                pixelSha256: imgAttrs.pixelSha256
            )
        }
    }

    // MARK: - Operation Status & Reconciliation
    public func operationStatus(operationId: String) throws -> OperationRecord {
        let docInfo = try getDocumentInfo()
        guard docInfo.isSession else {
            throw C1Error.invalidRequest("Operation status is only available for Sessions.")
        }
        let sessUrl = URL(fileURLWithPath: docInfo.documentPath)
        let journal = OperationJournal(sessionDirectory: sessUrl)

        guard let entry = journal.find(operationId: operationId) else {
            throw C1Error.invalidRequest("Operation ID '\(operationId)' not found in journal.")
        }
        return entry
    }

    // MARK: - Capabilities
    public func capabilities() -> [String: Any] {
        [
            "pinnedBuild": Self.pinnedBuild,
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
