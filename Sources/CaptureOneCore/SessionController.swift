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
    public var writesEnabled: Bool = false
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
    public var writesEnabled: Bool = false
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
    public var nativeSnapshots: [NativeSnapshot]? = nil
    public var openToken: String? = nil
    public var metadataStateHash: String? = nil
    public var geometry: Geometry? = nil
    public var geometryStateHash: String? = nil
    public var geometryUsableBounds: CropRect? = nil
    public var geometryUnavailableReason: String? = nil
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
    public var metadataBefore: VariantMetadata? = nil
    public var metadataAfter: VariantMetadata? = nil
    public var metadataDiff: [String: DoubleDiff]? = nil
    public var geometryBefore: Geometry? = nil
    public var geometryAfter: Geometry? = nil
    public var geometryDiff: [String: DoubleDiff]? = nil
    public let ref1: String
    public let ref2: String
    public let stateHash1: String
    public let stateHash2: String
    public let diff: [String: DoubleDiff]

    public init(ref1: String, ref2: String, stateHash1: String, stateHash2: String, diff: [String: DoubleDiff], geometryBefore: Geometry? = nil, geometryAfter: Geometry? = nil, metadataBefore: VariantMetadata? = nil, metadataAfter: VariantMetadata? = nil) {
        self.metadataBefore = metadataBefore; self.metadataAfter = metadataAfter
        if let before = metadataBefore, let after = metadataAfter { self.metadataDiff = after.changes(from: before) }
        self.geometryBefore = geometryBefore; self.geometryAfter = geometryAfter
        if let before = geometryBefore, let after = geometryAfter { self.geometryDiff = after.changes(from: before) }
        self.ref1 = ref1
        self.ref2 = ref2
        self.stateHash1 = stateHash1
        self.stateHash2 = stateHash2
        self.diff = diff
    }
}

public struct DumpRecord: Codable, Equatable {
    public var geometry: Geometry? = nil
    public var geometryStateHash: String? = nil
    public var geometryUnavailableReason: String? = nil
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
        stateHash: String,
        geometry: Geometry? = nil,
        geometryUnavailableReason: String? = nil
    ) {
        self.geometry = geometry
        self.geometryStateHash = geometry?.stateHash(tonalHash: stateHash)
        self.geometryUnavailableReason = geometryUnavailableReason
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

    private let nativeInventoryEnabled: Bool
    private let executor: ScriptExecuting
    private let appInstance: () throws -> String
    private let databaseIdentity: (String) throws -> String
    private let catalogWritePath: String?
    private let imageDimensions: (String) -> [Double]?
    private let lock = CaptureOneLock.shared
    private let registry = FieldRegistry.shared
    private let previewMgr = PreviewManager.shared

    public init(executor: ScriptExecuting = AppleScriptExecutor.shared,
                appInstance: @escaping () throws -> String = DocumentIdentity.appInstance,
                databaseIdentity: @escaping (String) throws -> String = DocumentIdentity.fileIdentity,
                catalogWritePath: String? = ProcessInfo.processInfo.environment["C1_CATALOG_WRITE_PATH"],
                imageDimensions: @escaping (String) -> [Double]? = ImageDimensions.read,
                nativeInventoryEnabled: Bool = ProcessInfo.processInfo.environment["C1_INVENTORY_STRATEGY"] != "scan") {
        self.nativeInventoryEnabled = nativeInventoryEnabled
        self.executor = executor
        self.appInstance = appInstance
        self.databaseIdentity = databaseIdentity
        self.catalogWritePath = catalogWritePath
        self.imageDimensions = imageDimensions
    }

    private func databasePath(_ doc: DocumentInfo) throws -> String {
        if !doc.isSession { return try CatalogLocation(nativeID: doc.documentId).database.path }
        return doc.isSession && !doc.documentId.hasSuffix(".cosessiondb")
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

    private func assertWritableImage(doc: DocumentInfo, source: GetResult?) throws {
        if !doc.isSession {
            guard let path = source?.parentImagePath, FileManager.default.isReadableFile(atPath: path) else {
                throw C1Error.invalidRequest("Catalog writes require the original image to be online and readable.")
            }
            let package = try CatalogLocation(nativeID: doc.documentId).package
            let image = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard !image.path.hasPrefix(package.path + "/") else {
                throw C1Error.invalidRequest("Experimental Catalog editing supports referenced originals only. Originals stored inside the Catalog are not yet qualified.")
            }
        }
    }

    private func prepare(_ entry: OperationRecord, doc: DocumentInfo, source: GetResult? = nil) throws -> OperationRecord {
        try assertWritableImage(doc: doc, source: source)
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
        var writesEnabled = false
        var identityOK = false
        if hasDoc {
            do {
                let doc = try getDocumentInfo()
                identityOK = true
                docPath = doc.documentPath
                writesEnabled = doc.writesEnabled
                let journal = OperationJournal(sessionDirectory: URL(fileURLWithPath: doc.documentPath))
                unresolvedCount = try journal.validatedEntries().filter(OperationJournal.isUnresolved).count
            } catch { unresolvedCount = 1 }
        }

        let allPassed = appRunning && compat.isAllowed && hasDoc && identityOK && documentCount == 1 && lockOk && (unresolvedCount == 0)

        var report = DoctorReport(
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
        report.writesEnabled = writesEnabled && allPassed
        return report
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
            let location = try CatalogLocation(nativeID: info.docId ?? path, readOnly: true)
            docDir = location.package.path
            outputDir = location.package.deletingLastPathComponent()
                .appendingPathComponent(location.package.lastPathComponent + ".c1-output").path
        }

        let nativeId = info.docId ?? path
        let database: String
        if info.isSession {
            database = nativeId.hasSuffix(".cosessiondb") ? nativeId : URL(fileURLWithPath: docDir).appendingPathComponent(name).path
        } else {
            database = try CatalogLocation(nativeID: nativeId, readOnly: true).database.path
        }
        let openToken = try "\(appInstance())|\(databaseIdentity(database))"

        var document = DocumentInfo(
            documentId: nativeId,
            documentName: name,
            documentPath: docDir,
            isSession: info.isSession,
            openToken: openToken,
            captureFolder: captureDir,
            outputFolder: outputDir,
            appVersion: info.appVersion
        )
        document.writesEnabled = (try? assertSessionWritable(docInfo: document, operation: "edit")) != nil
        RequestContext.current?.document(document.openToken)
        return document
    }

    // MARK: - Mutation Guard
    public func assertSessionWritable(docInfo: DocumentInfo, operation: String) throws {
        let compat = Self.evaluateVersionCompatibility(docInfo.appVersion)
        guard compat.isAllowed else {
            throw C1Error.unsupportedVersion(
                "Running Capture One build '\(docInfo.appVersion)' is not supported (supported: 16.4+ through 16.x; tested: \(Self.testedBuilds.joined(separator: ", "))). Set C1_ALLOW_UNTESTED_BUILD=1 to override."
            )
        }
        if !docInfo.isSession {
            guard let location = try? CatalogLocation(nativeID: docInfo.documentId),
                  location.isAuthorized(by: catalogWritePath) else {
                throw C1Error.invalidRequest("Catalogs are strictly read-only unless C1_CATALOG_WRITE_PATH names this exact Catalog package. Operation '\(operation)' is blocked for '\(docInfo.documentName)'.")
            }
            guard docInfo.appVersion == Self.pinnedBuild else {
                throw C1Error.unsupportedVersion("Catalog writes require Capture One \(Self.pinnedBuild); the untested-build override does not enable Catalog writes.")
            }
        }
    }

    // MARK: - Variants List
    public func listVariants(collectionName: String? = nil, selectedOnly: Bool = false, rating: Int? = nil, minRating: Int? = nil,
                             batchSize: Int = 32, deadlineSeconds: Double? = nil) throws -> [VariantSummary] {
        var filters: [String: Any] = ["batchSize": batchSize]
        if let rating { filters["rating"] = rating }
        if let minRating { filters["minRating"] = minRating }
        if let deadlineSeconds { filters["deadlineSeconds"] = deadlineSeconds }
        try ContractSchema.validate(tool: "variants_list", arguments: filters)
        let started = ProcessInfo.processInfo.systemUptime
        let context = RequestContext.current
        context?.inventoryScope(collection: collectionName, selected: selectedOnly, rating: rating, minRating: minRating)
        func checkpoint() throws {
            try context?.checkReadCancellation()
            if let deadlineSeconds, ProcessInfo.processInfo.systemUptime - started >= deadlineSeconds {
                throw C1Error.deadlineExceeded("Inventory deadline reached between Apple Events; no partial inventory was returned. An outstanding event cannot be interrupted.")
            }
        }
        try checkpoint()
        return try lock.withLock(checkpoint: checkpoint) {
            try checkpoint()
            context?.update(phase: "validating-document")
            let docInfo = try getDocumentInfo()
            context?.document(docInfo.openToken)
            // Native predicates/bulk IDs are qualified only for Sessions on this exact build.
            let native = nativeInventoryEnabled && docInfo.isSession && docInfo.appVersion == Self.pinnedBuild
            context?.inventoryStrategy(native ? "native-filter" : "rating-scan")
            func validateDocument() throws {
                try checkpoint()
                let current = try getDocumentInfo()
                guard current.openToken == docInfo.openToken, current.documentId == docInfo.documentId else {
                    throw C1Error.documentChanged("Document identity changed during inventory; discard this inventory.")
                }
                try checkpoint()
            }
            let doc = NSAppleEventDescriptor(string: docInfo.documentId)
            let col = collectionName.map(NSAppleEventDescriptor.init(string:)) ?? NSAppleEventDescriptor.missingValue()
            func discover() throws -> [String] {
                try checkpoint()
                var args = [doc, col, NSAppleEventDescriptor(boolean: selectedOnly)]
                if native {
                    args += [rating.map { NSAppleEventDescriptor(int32: Int32($0)) } ?? .missingValue(),
                             minRating.map { NSAppleEventDescriptor(int32: Int32($0)) } ?? .missingValue()]
                }
                let ids: [String] = try executor.executeAndDecode(handler: native ? "discoverFilteredVariantIDs" : "discoverVariantIDs", args: args)
                guard Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty }) else {
                    throw C1Error.identityAmbiguous("Inventory returned empty or duplicate native IDs.")
                }
                try checkpoint()
                return ids
            }
            context?.update(phase: "discovering")
            let ids = try discover()
            context?.update(phase: native ? "metadata" : "ratings", matches: native ? ids.count : 0, total: ids.count)
            var records: [VariantSummaryRecord] = []
            var scanned = 0
            var matched = 0
            struct RatingRecord: Decodable { let variantId: String; let starRating: Int }
            for offset in stride(from: 0, to: ids.count, by: batchSize) {
                try validateDocument()
                let batch = Array(ids[offset..<min(offset + batchSize, ids.count)])
                if native {
                    context?.update(phase: "metadata")
                    let summaries: [VariantSummaryRecord] = try executor.executeAndDecode(handler: "readVariantSummaries", args: [doc, NSAppleEventDescriptor(list: batch.map(NSAppleEventDescriptor.init(string:)))])
                    guard summaries.map(\.variantId) == batch, summaries.allSatisfy({ item in
                        (0...5).contains(item.starRating) &&
                        (rating.map { item.starRating == $0 } ?? true) &&
                        (minRating.map { item.starRating >= $0 } ?? true) && (!selectedOnly || item.isSelected)
                    }) else {
                        throw C1Error.stateChanged("Native inventory membership or metadata changed; no partial inventory was returned.")
                    }
                    records.append(contentsOf: summaries)
                    scanned += batch.count
                    context?.update(phase: "metadata", scanned: scanned, completed: records.count)
                    try checkpoint()
                    continue
                }
                context?.update(phase: "ratings")
                let ratings: [RatingRecord] = try executor.executeAndDecode(handler: "readVariantRatings", args: [doc, NSAppleEventDescriptor(list: batch.map(NSAppleEventDescriptor.init(string:)))])
                guard ratings.map(\.variantId) == batch, ratings.allSatisfy({ (0...5).contains($0.starRating) }) else {
                    throw C1Error.stateChanged("Inventory rating IDs or values changed; no partial inventory was returned.")
                }
                let matches = ratings.filter { item in
                    (rating.map { item.starRating == $0 } ?? true) && (minRating.map { item.starRating >= $0 } ?? true)
                }
                scanned += batch.count; matched += matches.count
                context?.update(phase: "ratings", scanned: scanned, matches: matched)
                try checkpoint()
                if !matches.isEmpty {
                    context?.update(phase: "metadata")
                    let summaries: [VariantSummaryRecord] = try executor.executeAndDecode(handler: "readVariantSummaries", args: [doc, NSAppleEventDescriptor(list: matches.map { NSAppleEventDescriptor(string: $0.variantId) })])
                    guard summaries.map(\.variantId) == matches.map(\.variantId),
                          summaries.map(\.starRating) == matches.map(\.starRating),
                          !selectedOnly || summaries.allSatisfy(\.isSelected) else {
                        throw C1Error.stateChanged("Inventory changed while reading metadata; no partial inventory was returned.")
                    }
                    records.append(contentsOf: summaries)
                    context?.update(phase: "metadata", completed: records.count)
                }
                try checkpoint()
            }
            context?.update(phase: "validating-inventory")
            try validateDocument()
            guard Set(try discover()) == Set(ids) else {
                throw C1Error.stateChanged("Inventory scope membership changed; no partial inventory was returned.")
            }
            try validateDocument()
            let provenance = ProvenanceStore(sessionDirectory: URL(fileURLWithPath: docInfo.documentPath))
            let byClone = Dictionary(grouping: provenance.loadRecords().values, by: \.cloneVariantId)
            return records.map { rec in
                let matches = byClone[rec.variantId] ?? []
                let candidate = matches.count == 1 ? matches.first : nil
                let prov = candidate.flatMap { record in
                    (try? DocumentIdentity.validate(record: record, document: docInfo, parentImagePath: rec.parentImagePath)) != nil ? record : nil
                }
                return VariantSummary(id: rec.variantId, name: rec.variantName, parentImagePath: rec.parentImagePath,
                    isSelected: rec.isSelected, rating: rec.starRating, colorTag: rec.colorTagVal,
                    isManagedWorkingClone: prov != nil, workingRef: prov?.workingRef)
            }
        }
    }

    // MARK: - Edit an existing variant
    public func editVariant(sourceRef: String, ifState expected: String, ifDocument: String, ifGeometryState: String? = nil) throws -> EditingRecord {
        try lock.withLock {
            let doc = try getDocumentInfo()
            try assertSessionWritable(docInfo: doc, operation: "variant_edit")
            guard doc.openToken == ifDocument else { throw C1Error.documentChanged("Document changed since the editing targets were selected.") }
            guard doc.appVersion == "16.8.5.30" else { throw C1Error.unsupportedVersion("Existing-variant editing requires Capture One 16.8.5.30.") }
            try checkedDocument(doc)
            let source = try get(ref: sourceRef)
            guard let parent = source.parentImagePath, !parent.isEmpty else {
                throw C1Error.identityAmbiguous("Existing-variant editing requires an identifiable parent image.")
            }
            guard source.stateHash == expected, ifGeometryState == nil || source.geometryStateHash == ifGeometryState else {
                throw C1Error.stateChanged("Variant changed since inspection; read get again.")
            }
            try assertWritableImage(doc: doc, source: source)
            let record = EditingRecord(source: source, document: doc)
            try checkedDocument(doc)
            try EditingStore(document: doc).register(record)
            return record
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
                    baselineAdjustments: created.adjustments, baselineStateHash: created.stateHash, documentToken: doc.openToken, baselineGeometry: created.geometry, baselineMetadata: VariantMetadata.from(created.metadata)))
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
                    NSAppleEventDescriptor(string: record.parentImagePath!), NSAppleEventDescriptor(string: record.sourceVariantId)])
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

    private func normalizedGeometry(_ item: AdjustmentBatchItemRecord) -> Geometry? {
        guard var geometry = item.geometryRecord?.geometry,
              let path = item.parentImagePath, let dimensions = imageDimensions(path), dimensions.count == 2,
              dimensions.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        geometry.imageWidth = dimensions[0]; geometry.imageHeight = dimensions[1]
        return geometry
    }

    // MARK: - Get
    public func get(ref: String) throws -> GetResult {
        let docInfo = try getDocumentInfo()
        var nativeId = ref
        var workingRefStr: String?
        var managedRecord: ProvenanceRecord?
        var editingRecord: EditingRecord?
        if EditingRecord.isEditingReference(ref) {
            let record = try EditingStore(document: docInfo).resolve(ref, document: docInfo)
            editingRecord = record
            nativeId = record.variantId
            workingRefStr = record.workingRef
        }

        if WorkingRef.isWorkingRefString(ref) {
            let sessUrl = URL(fileURLWithPath: docInfo.documentPath)
            let provenance = ProvenanceStore(sessionDirectory: sessUrl)
            let record = try provenance.resolveManagedWorkingReference(
                ref,
                currentDocumentPath: docInfo.documentPath
            )
            // Reject expired references before a native ID lookup: IDs can be
            // absent or reassigned after restart. Validate the live parent below.
            try DocumentIdentity.validate(record: record, document: docInfo, parentImagePath: record.parentImagePath ?? "")
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
        if let record = editingRecord {
            try record.validate(document: docInfo, parent: first.parentImagePath ?? "")
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

        let geometry = normalizedGeometry(first)
        return GetResult(
            metadataStateHash: VariantMetadata.from(metadata)?.stateHash,
            geometry: geometry,
            geometryStateHash: geometry?.stateHash(tonalHash: hash.hex),
            geometryUsableBounds: geometry?.unsupportedReason == nil ? try geometry?.safeBounds(rotation: geometry?.rotation ?? 0) : nil,
            geometryUnavailableReason: geometry?.unsupportedReason ?? first.geometryUnavailableReason ?? (geometry == nil ? "Geometry unavailable: native geometry or intrinsic source-file dimensions could not be read." : nil),
            id: nativeId,
            workingRef: workingRefStr,
            adjustments: adjustments,
            metadata: metadata,
            stateHash: hash.hex,
            parentImagePath: first.parentImagePath
        )
    }

    private func adjustmentTarget(_ ref: String, document: DocumentInfo) throws -> (workingRef: String, variantId: String, baselineAdjustments: Adjustments) {
        if EditingRecord.isEditingReference(ref) {
            let record = try EditingStore(document: document).resolve(ref, document: document)
            return (record.workingRef, record.variantId, record.baselineAdjustments)
        }
        let record = try ProvenanceStore(sessionDirectory: URL(fileURLWithPath: document.documentPath))
            .resolveManagedWorkingReference(ref, currentDocumentPath: document.documentPath)
        return (record.workingRef, record.cloneVariantId, record.baselineAdjustments)
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
        let journal = OperationJournal(sessionDirectory: sessUrl)

        let record = try adjustmentTarget(workingRefString, document: docInfo)

        return try lock.withLock {
            try checkedDocument(docInfo, writes: !isDryRun)
            // 1. Read current state
            let current = try self.get(ref: record.workingRef)
            guard current.stateHash == expectedHash else {
                throw C1Error.stateChanged("Optimistic concurrency conflict for '\(workingRefString)'. Expected stateHash '\(expectedHash)', but actual is '\(current.stateHash)'.")
            }

            try assertWritableImage(doc: docInfo, source: current)
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
            let varIdDesc = NSAppleEventDescriptor(string: record.variantId)
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

    // MARK: - Crop, rotation, and keystone
    public func geometrySet(workingRef: String, ifGeometryState expected: String, crop: CropRect? = nil,
                            rotation: Double? = nil, aspectRatio: Double? = nil, keystone: KeystoneAdjustments? = nil, dryRun: Bool = false) throws -> GeometryMutationResult {
        try mutateGeometry(workingRef: workingRef, expected: expected, crop: crop, rotation: rotation, aspectRatio: aspectRatio, keystone: keystone, dryRun: dryRun, restore: false)
    }

    public func geometryRestore(workingRef: String, ifGeometryState expected: String, dryRun: Bool = false) throws -> GeometryMutationResult {
        try mutateGeometry(workingRef: workingRef, expected: expected, crop: nil, rotation: nil, aspectRatio: nil, keystone: nil, dryRun: dryRun, restore: true)
    }

    private func mutateGeometry(workingRef: String, expected: String, crop: CropRect?, rotation: Double?, aspectRatio: Double?, keystone: KeystoneAdjustments?, dryRun: Bool, restore: Bool) throws -> GeometryMutationResult {
        return try lock.withLock {
            let doc = try getDocumentInfo()
            let operation = restore ? "geometry_restore" : "geometry_set"
            try assertSessionWritable(docInfo: doc, operation: operation)
            guard doc.appVersion == "16.8.5.30" else { throw C1Error.unsupportedVersion("Geometry requires Capture One 16.8.5.30.") }
            let store = ProvenanceStore(sessionDirectory: URL(fileURLWithPath: doc.documentPath))
            let baseline: Geometry?
            if EditingRecord.isEditingReference(workingRef) {
                baseline = try EditingStore(document: doc).resolve(workingRef, document: doc).baselineGeometry
            } else {
                baseline = try store.resolveManagedWorkingReference(workingRef, currentDocumentPath: doc.documentPath).baselineGeometry
            }
            try checkedDocument(doc, writes: !dryRun)
            let current = try get(ref: workingRef)
            guard let before = current.geometry, let state = current.geometryStateHash else {
                throw C1Error.invalidRequest(current.geometryUnavailableReason ?? "Geometry unavailable.")
            }
            guard state == expected else { throw C1Error.stateChanged("Geometry precondition no longer matches; read get again.") }
            var requestedContext = before
            if let keystone { requestedContext.keystone = try keystone.applying(to: before.keystone) }
            let keystoneChanged = requestedContext.keystone != before.keystone
            var target: Geometry?
            var nativeRequest: GeometryRequest?
            if restore {
                guard let baseline, baseline.unsupportedReason == nil, before.unsupportedReason == nil,
                      before.sameContext(as: baseline, includingKeystone: false) else {
                    throw C1Error.stateChanged("Geometry context changed since the baseline; review before restoring crop/rotation/keystone.")
                }
                // This exact crop was observed on this image with the same lens/orientation
                // context. It may legitimately exceed the conservative bounds for NEW crops.
                var restored = before
                restored.crop = baseline.crop; restored.rotation = baseline.rotation; restored.keystone = baseline.keystone
                target = restored
            } else if before.requiresNativeBounds || keystone != nil {
                if let reason = before.unsupportedReason { throw C1Error.invalidRequest(reason) }
                guard crop != nil || rotation != nil || aspectRatio != nil || keystone != nil else { throw C1Error.invalidRequest("Provide crop, rotation, or aspectRatio.") }
                if dryRun && keystoneChanged {
                    throw C1Error.invalidRequest("Keystone changes require native execution; dry runs cannot predict the final crop.")
                }
                if dryRun && before.hasPerspectiveOrMovements && aspectRatio != nil {
                    throw C1Error.invalidRequest("Perspective and movement ratio fits require native crop normalization; dry runs cannot predict the final crop.")
                }
                nativeRequest = try GeometryRequest(crop: crop, rotation: rotation ?? before.rotation, aspectRatio: aspectRatio, keystone: keystone)
                // Validate all knowable bounds before dispatch. At a new rotation,
                // Capture One supplies bounds after its rotation setter executes.
                if !keystoneChanged && (nativeRequest!.rotation == before.rotation || dryRun) {
                    target = try before.target(crop: crop, rotation: rotation ?? before.rotation, aspectRatio: aspectRatio)
                }
            } else {
                target = try before.target(crop: crop, rotation: rotation, aspectRatio: aspectRatio)
            }
            try assertWritableImage(doc: doc, source: current)
            if dryRun {
                return GeometryMutationResult(operationId: "dry-run", workingRef: workingRef, before: before, after: target!,
                    diff: target!.changes(from: before), geometryStateHash: state, isDryRun: true)
            }
            let journal = OperationJournal(sessionDirectory: store.sessionDirectory)
            var entry = try prepare(OperationRecord(operationType: operation, workingRef: workingRef,
                documentPath: doc.documentPath, preconditionStateHash: expected, beforeAdjustments: current.adjustments,
                beforeGeometry: before, intendedGeometry: target, requestedGeometry: nativeRequest), doc: doc, source: current)
            try journal.append(entry: entry)
            do {
                let arguments = [
                    NSAppleEventDescriptor(string: doc.documentId), NSAppleEventDescriptor(string: current.id),
                    NSAppleEventDescriptor(string: current.parentImagePath ?? ""), before.eventSnapshot,
                    NSAppleEventDescriptor(list: registry.supportedAdjustmentFields.map { NSAppleEventDescriptor(double: current.adjustments.value(for: $0.name)!) })]
                if let request = nativeRequest {
                    let applied: CorrectedGeometryResult = try executor.executeAndDecode(handler: "applyCorrectedGeometry", args: arguments + [
                        request.crop.map { NSAppleEventDescriptor(list: $0.values.map { NSAppleEventDescriptor(double: $0) }) } ?? .missingValue(),
                        NSAppleEventDescriptor(double: request.rotation), request.aspectRatio.map { NSAppleEventDescriptor(double: $0) } ?? .missingValue(),
                        NSAppleEventDescriptor(list: requestedContext.keystone.map { NSAppleEventDescriptor(double: $0) })])
                    guard applied.targetCropValues.count == 4, applied.boundsValues.count == 4,
                          applied.targetCropValues.allSatisfy({ $0.isFinite }), applied.boundsValues.allSatisfy({ $0.isFinite }) else {
                        throw C1Error.readbackMismatch("Corrected geometry native target or bounds are malformed.")
                    }
                    let c = applied.targetCropValues, b = applied.boundsValues
                    let nativeCropUnchangedByCaller = request.crop == nil && request.aspectRatio == nil
                    guard c[2] >= 1, c[3] >= 1, b[2] > 0, b[3] > 0,
                          nativeCropUnchangedByCaller || (abs(c[0]-b[0])+c[2]/2 <= b[2]/2+2 && abs(c[1]-b[1])+c[3]/2 <= b[3]/2+2) else {
                        throw C1Error.readbackMismatch("Corrected geometry target exceeds the native bounds.")
                    }
                    var resolved = requestedContext
                    resolved.rotation = request.rotation
                    resolved.crop = CropRect(centerX: c[0], centerY: c[1], width: c[2], height: c[3])
                    if let crop = request.crop, resolved.crop != crop { throw C1Error.readbackMismatch("Native crop differs from the explicit request.") }
                    if let ratio = request.aspectRatio, abs(c[2] - c[3]*ratio) > max(2, ratio*2) {
                        throw C1Error.readbackMismatch("Native crop does not match the requested aspect ratio.")
                    }
                    if (before.hasPerspectiveOrMovements || requestedContext.hasPerspectiveOrMovements || keystoneChanged), let ratio = request.aspectRatio {
                        guard let fit = applied.fittedCropValues, fit.count == 4,
                              fit.allSatisfy({ $0.isFinite }), fit[2] >= 1, fit[3] >= 1,
                              abs(fit[0]-c[0])+fit[2]/2 <= c[2]/2+2,
                              abs(fit[1]-c[1])+fit[3]/2 <= c[3]/2+2,
                              abs(fit[2]-fit[3]*ratio) <= max(2,ratio*2) else {
                            throw C1Error.readbackMismatch("Native perspective fit must preserve the requested ratio inside the target rectangle.")
                        }
                        resolved.crop = CropRect(centerX:fit[0],centerY:fit[1],width:fit[2],height:fit[3])
                    }
                    target = resolved
                    // Preserve the concrete target once native bounds are known;
                    // the original pending record already contains the user's request.
                    entry.intendedGeometry = resolved
                    try journal.append(entry: entry)
                } else {
                    let _: GeometryRecord = try executor.executeAndDecode(handler: "applyGeometry", args: arguments + [
                        NSAppleEventDescriptor(list: target!.crop.values.map { NSAppleEventDescriptor(double: $0) }), NSAppleEventDescriptor(double: target!.rotation),
                        NSAppleEventDescriptor(list: target!.keystone.map { NSAppleEventDescriptor(double: $0) })])
                }
                let readback = try get(ref: workingRef)
                guard let after = readback.geometry else { throw C1Error.readbackMismatch("Geometry missing after write.") }
                guard after.matchesTarget(target!), after.sameContext(as: before, includingKeystone: false), readback.stateHash == current.stateHash else {
                    try journal.update(operationId: entry.operationId, status: "partial-failure", afterAdjustments: readback.adjustments, afterGeometry: after)
                    throw C1Error.readbackMismatch("Crop/rotation/keystone or preserved settings did not match; inspect operation status.")
                }
                let diff = after.changes(from: before)
                try journal.update(operationId: entry.operationId, status: "succeeded", afterAdjustments: readback.adjustments, diff: diff, afterGeometry: after)
                return GeometryMutationResult(operationId: entry.operationId, workingRef: workingRef, before: before, after: after,
                    diff: diff, geometryStateHash: after.stateHash(tonalHash: readback.stateHash), isDryRun: false)
            } catch {
                if journal.find(operationId: entry.operationId)?.status != "partial-failure" {
                    try? journal.update(operationId: entry.operationId, status: "outcome-unknown", error: String(describing: error))
                }
                throw OperationFailure(operationId: entry.operationId, cause: error)
            }
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

        let record = try adjustmentTarget(workingRefString, document: docInfo)

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
                diff: diffDict, geometryBefore: get1.geometry, geometryAfter: get2.geometry,
                metadataBefore: VariantMetadata.from(get1.metadata), metadataAfter: VariantMetadata.from(get2.metadata)
            )
        } else {
            if EditingRecord.isEditingReference(ref1) {
                let record = try EditingStore(document: docInfo).resolve(ref1, document: docInfo)
                return DiffResult(ref1: "baseline", ref2: ref1, stateHash1: record.baselineStateHash, stateHash2: get1.stateHash,
                    diff: computeDiff(before: record.baselineAdjustments, after: get1.adjustments),
                    geometryBefore: record.baselineGeometry, geometryAfter: get1.geometry,
                    metadataBefore: record.baselineMetadata, metadataAfter: VariantMetadata.from(get1.metadata))
            }
            guard WorkingRef.isWorkingRefString(ref1) else {
                throw C1Error.invalidRequest("Single-reference diff requires an editing reference (c1_edit_<uuid>) or managed clone (c1_wrk_<uuid>). To compare native variants, provide two references: c1 diff <ref1> <ref2>")
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
                diff: diffDict, geometryBefore: record.baselineGeometry, geometryAfter: get1.geometry,
                    metadataBefore: record.baselineMetadata, metadataAfter: VariantMetadata.from(get1.metadata)
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
                let geometry = normalizedGeometry(item)
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
                    stateHash: stateHash, geometry: geometry,
                    geometryUnavailableReason: geometry?.unsupportedReason ?? item.geometryUnavailableReason ?? (geometry == nil ? "Geometry or intrinsic source-file dimensions unavailable." : nil)
                ))
            }
        }

        return records
    }

    // MARK: - Preview
    public func preview(workingRefString: String, outputDirOverride: String? = nil, timeout: TimeInterval = 30.0) throws -> PreviewResult {
        try preview(ref: workingRefString, outputDirOverride: outputDirOverride, timeout: timeout)
    }

    public func preview(ref: String, outputDirOverride: String? = nil, timeout: TimeInterval = 30.0, fullFrame: Bool = false) throws -> PreviewResult {
        guard timeout.isFinite && timeout > 0 && timeout <= 300 else { throw C1Error.invalidRequest("timeout must be in (0, 300] seconds.") }
        if fullFrame {
            let source = try get(ref: ref)
            guard let geometry = source.geometry, geometry.unsupportedReason == nil else { throw C1Error.invalidRequest("Full-frame mapping is unavailable for this geometry.") }
            let clone = try cloneVariant(sourceRef: ref)
            let current = try get(ref: clone.workingRef)
            guard let cloneState = current.geometryStateHash, cloneState == source.geometryStateHash else { throw C1Error.stateChanged("Context clone differs from source; inspect managed clone \(clone.workingRef).") }
            let bounds = try geometry.safeBounds(rotation: geometry.rotation)
            if geometry.hasPerspectiveOrMovements {
                _ = try geometrySet(workingRef: clone.workingRef, ifGeometryState: cloneState, aspectRatio: bounds.aspectRatio)
            } else {
                _ = try geometrySet(workingRef: clone.workingRef, ifGeometryState: cloneState, crop: bounds)
            }
            var result = try preview(ref: clone.workingRef, outputDirOverride: outputDirOverride, timeout: timeout)
            guard try get(ref: ref).geometryStateHash == source.geometryStateHash else { throw C1Error.stateChanged("Source changed during context preview; discard preview.") }
            _ = try deleteVariant(workingRefString: clone.workingRef)
            result.contextSourceRef = ref
            return result
        }
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
                beforeAdjustments: current.adjustments, previewOutputPath: jobDir.path, beforeGeometry: current.geometry), doc: doc, source: current)
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
                guard after.stateHash == current.stateHash, after.geometryStateHash == current.geometryStateHash else { throw C1Error.stateChanged("Adjustments changed while preview rendered; discard this preview.") }
                if let geometry = current.geometry {
                    let ratio = geometry.crop.aspectRatio
                    guard abs(Double(image.width) - Double(image.height)*ratio) <= max(2,ratio*2) else {
                        throw C1Error.readbackMismatch("Preview dimensions do not match the crop aspect ratio.")
                    }
                }
                let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
                try journal.update(operationId: opId, status: "succeeded", previewOutputPath: file.path)
                return PreviewResult(operationId: opId, workingRef: current.workingRef, outputPath: file.path,
                    fileSizeBytes: size, width: image.width, height: image.height, pixelSha256: image.pixelSha256,
                    stateHash: current.stateHash, nativeVariantId: current.id, geometry: current.geometry, geometryStateHash: current.geometryStateHash)
            } catch {
                try? journal.update(operationId: opId, status: "outcome-unknown", error: String(describing: error))
                throw OperationFailure(operationId: opId, cause: error)
            }
        }
    }

    // MARK: - Rating and color tag writes
    public func metadataSet(workingRef: String, ifMetadataState: String, rating: Int? = nil,
                            colorTag: Int? = nil, dryRun: Bool = false) throws -> MetadataMutationResult {
        var arguments: [String: Any] = ["workingRef": workingRef, "ifMetadataState": ifMetadataState, "dryRun": dryRun]
        if let rating { arguments["rating"] = rating }
        if let colorTag { arguments["colorTag"] = colorTag }
        try ContractSchema.validate(tool: "metadata_set", arguments: arguments)
        return try lock.withLock {
            let doc = try getDocumentInfo()
            try assertSessionWritable(docInfo: doc, operation: "metadata_set")
            guard doc.appVersion == Self.pinnedBuild else { throw C1Error.unsupportedVersion("Metadata writes require Capture One \(Self.pinnedBuild).") }
            try checkedDocument(doc, writes: !dryRun)
            let target = try adjustmentTarget(workingRef, document: doc)
            let current = try get(ref: workingRef)
            try assertWritableImage(doc: doc, source: current)
            guard let before = VariantMetadata.from(current.metadata), before.stateHash == ifMetadataState else {
                throw C1Error.stateChanged("Rating or color tag changed or is unavailable; read get again.")
            }
            let intended = VariantMetadata(rating: rating ?? before.rating, colorTag: colorTag ?? before.colorTag)
            if dryRun {
                return MetadataMutationResult(operationId: "dry-run", workingRef: workingRef, before: before,
                    after: intended, diff: intended.changes(from: before), metadataStateHash: before.stateHash, isDryRun: true)
            }
            let journal = OperationJournal(sessionDirectory: URL(fileURLWithPath: doc.documentPath))
            var entry = try prepare(OperationRecord(operationType: "metadata_set", workingRef: workingRef,
                documentPath: doc.documentPath, preconditionStateHash: ifMetadataState,
                beforeAdjustments: current.adjustments, beforeGeometry: current.geometry), doc: doc, source: current)
            entry.beforeMetadata = before
            entry.intendedMetadata = intended
            try journal.append(entry: entry)
            do {
                struct NativeResult: Decodable { let variantId: String; let ratingVal: Int; let colorTagVal: Int }
                let native: NativeResult = try executor.executeAndDecode(handler: "applyMetadata", args: [
                    NSAppleEventDescriptor(string: doc.documentId), NSAppleEventDescriptor(string: target.variantId),
                    rating.map { NSAppleEventDescriptor(int32: Int32($0)) } ?? .missingValue(),
                    colorTag.map { NSAppleEventDescriptor(int32: Int32($0)) } ?? .missingValue(),
                    NSAppleEventDescriptor(int32: Int32(before.rating)), NSAppleEventDescriptor(int32: Int32(before.colorTag)),
                    NSAppleEventDescriptor(string: current.parentImagePath ?? "")])
                try checkedDocument(doc, writes: false)
                let readback = try get(ref: workingRef)
                let after = VariantMetadata.from(readback.metadata)
                entry.afterMetadata = after
                entry.afterAdjustments = readback.adjustments
                entry.afterGeometry = readback.geometry
                guard native.variantId == target.variantId, readback.id == target.variantId,
                      native.ratingVal == intended.rating, native.colorTagVal == intended.colorTag, after == intended,
                      readback.stateHash == current.stateHash, readback.geometryStateHash == current.geometryStateHash else {
                    throw C1Error.readbackMismatch("Metadata readback did not match, or tone/geometry changed during the operation.")
                }
                entry.diff = intended.changes(from: before)
                entry.status = "succeeded"
                try journal.append(entry: entry)
                return MetadataMutationResult(operationId: entry.operationId, workingRef: workingRef, before: before,
                    after: intended, diff: intended.changes(from: before), metadataStateHash: intended.stateHash, isDryRun: false)
            } catch {
                entry.status = "outcome-unknown"
                entry.error = error.localizedDescription
                try? journal.append(entry: entry)
                throw OperationFailure(operationId: entry.operationId, cause: error)
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
                    entry.afterGeometry = current.geometry
                    entry.afterMetadata = VariantMetadata.from(current.metadata)
                    if entry.beforeNative != nil {
                        let target = ["layer.delete", "color.delete"].contains(entry.nativeAction ?? "") ? NativeTarget() : entry.beforeNative!.target
                        entry.afterNative = try nativeGet(ref: id, target: target)
                    }
                    entry.status = "reconciled"
                    entry.error = "Previous app instance ended. Observed current adjustments, geometry, and metadata are recorded; they do not prove historical completion. Review before creating a fresh editing reference."
                } else {
                    entry.status = "reconciled"
                    entry.error = "Previous app instance ended; the target variant is absent. No retry was performed."
                }
            } else { throw C1Error.identityAmbiguous("Operation lacks a native variant recovery identity.") }
            try journal.append(entry: entry)
            return entry
        }
    }

    // MARK: - Expanded native editing
    private func nativeGet(ref: String, target: NativeTarget) throws -> NativeSnapshot {
        try readNative(ref: ref, target: target).nativeSnapshots![0]
    }

    private func readNative(ref: String, target: NativeTarget) throws -> GetResult {
        try target.validate()
        return try lock.withLock {
            let doc = try getDocumentInfo()
            guard doc.appVersion == Self.pinnedBuild else { throw C1Error.invalidRequest("Native editing requires Capture One " + Self.pinnedBuild) }
            let source = try get(ref: ref)
            let wire: NativeWireSnapshot = try executor.executeAndDecode(handler: "nativeRead", args:
                [.init(string: doc.documentId), .init(string: source.id)] + target.descriptors + [.init(string: source.parentImagePath ?? "")])
            try checkedDocument(doc, writes: false)
            let revision = try OperationJournal(sessionDirectory: URL(fileURLWithPath:doc.documentPath)).validatedEntries().last(where: { $0.nativeVariantId == source.id })?.operationId
            var result = source
            result.openToken = doc.openToken
            result.nativeSnapshots = [try nativeSnapshot(ref: ref, target: target, doc: doc, source: source, wire: wire, revision: revision)]
            return result
        }
    }

    /// Sequential observations under one application lock; never a multi-scope atomic snapshot.
    public func get(ref: String, nativeTargets targets: [NativeTarget]) throws -> GetResult {
        guard !ref.isEmpty, (1...16).contains(targets.count) else {
            throw C1Error.invalidRequest("Provide a variant reference and 1...16 native targets.")
        }
        for target in targets { try target.validate() }
        if targets.count == 1 { return try readNative(ref: ref, target: targets[0]) }
        return try lock.withLock {
            let doc = try getDocumentInfo()
            guard doc.appVersion == Self.pinnedBuild else { throw C1Error.invalidRequest("Native editing requires Capture One " + Self.pinnedBuild) }
            let source = try get(ref: ref)
            try checkedDocument(doc, writes: false)
            let journal = OperationJournal(sessionDirectory: URL(fileURLWithPath: doc.documentPath))
            let revision = try journal.validatedEntries().last(where: { $0.nativeVariantId == source.id })?.operationId
            var snapshots: [NativeSnapshot] = []
            for target in targets {
                if let prior = snapshots.first(where: { $0.target == target }) {
                    snapshots.append(prior)
                    continue
                }
                let wire: NativeWireSnapshot = try executor.executeAndDecode(handler: "nativeRead", args:
                    [.init(string: doc.documentId), .init(string: source.id)] + target.descriptors + [.init(string: source.parentImagePath ?? "")])
                snapshots.append(try nativeSnapshot(ref: ref, target: target, doc: doc, source: source, wire: wire, revision: revision))
            }
            // Reject observable source drift instead of returning a partial/mixed bundle.
            let after = try get(ref: ref)
            try checkedDocument(doc, writes: false)
            guard source == after,
                  revision == (try journal.validatedEntries()).last(where: { $0.nativeVariantId == source.id })?.operationId else {
                throw C1Error.stateChanged("Variant changed during native reads; no bundle was returned.")
            }
            var result = source
            result.openToken = doc.openToken
            result.nativeSnapshots = snapshots
            return result
        }
    }

    private func nativeSnapshot(ref: String, target: NativeTarget, doc: DocumentInfo, source: GetResult,
                                wire: NativeWireSnapshot, revision: String?) throws -> NativeSnapshot {
        var values: [String: NativeValue] = [:], unavailable: [String: String] = [:]
        for row in wire.nativeRows {
            if let error = row.unavailable { unavailable[row.fieldName] = error; continue }
            if let flag = row.boolVal { values[row.fieldName] = .boolean(flag) }
            else if let text = row.textVal { values[row.fieldName] = .text(text) }
            else if let numbers = row.numbersVal {
                let field = NativeEditing.fields[target.scope]?.first { $0.name == row.fieldName }
                if field?.type == "curve" || field?.type == "RGB color" { values[row.fieldName] = .numbers(numbers) }
                else if numbers.count == 1 { values[row.fieldName] = .number(numbers[0]) }
                else { throw C1Error.invalidRequest("Malformed native field readback.") }
            } else { values[row.fieldName] = .unset }
        }
        struct Token: Encodable { let document: String; let variant: String; let parent: String?; let target: NativeTarget; let values: [String:NativeValue]; let layers: [NativeLayer]; let tonal: String; let geometry: String?; let metadata: String?; let basicCount: Int; let advancedCount: Int; let journalRevision: String? }
        let token = try NativeEditing.hash(Token(document: doc.openToken, variant: source.id, parent: source.parentImagePath, target: target,
            values: values, layers: wire.nativeLayers, tonal: source.stateHash, geometry: source.geometryStateHash, metadata: source.metadataStateHash, basicCount:wire.basicColorCount, advancedCount:wire.advancedColorCount, journalRevision:revision))
        return NativeSnapshot(ref: ref, target: target, values: values, unavailable: unavailable, layers: wire.nativeLayers,
            basicColorCount: wire.basicColorCount, advancedColorCount: wire.advancedColorCount, nativeStateHash: token)
    }

    public func nativeSet(workingRef: String, target: NativeTarget, ifNativeState: String,
                          patch: [String:NativeValue], dryRun: Bool = false) throws -> NativeMutationResult {
        try NativeEditing.validate(patch, target: target)
        return try nativeMutate(workingRef: workingRef, target: target, expected: ifNativeState, patch: patch, action: nil, arguments: [:], dryRun: dryRun)
    }

    public func nativeAction(workingRef: String, target: NativeTarget, ifNativeState: String,
                             action: String, arguments: [String:NativeValue] = [:], dryRun: Bool = false) throws -> NativeMutationResult {
        try NativeEditing.validateAction(action, target: target, arguments: arguments)
        return try nativeMutate(workingRef: workingRef, target: target, expected: ifNativeState, patch: [:], action: action, arguments: arguments, dryRun: dryRun)
    }

    private func nativeMutate(workingRef: String, target: NativeTarget, expected: String, patch: [String:NativeValue],
                              action: String?, arguments: [String:NativeValue], dryRun: Bool) throws -> NativeMutationResult {
        return try lock.withLock {
            let doc = try getDocumentInfo()
            try assertSessionWritable(docInfo: doc, operation: "native editing")
            _ = try adjustmentTarget(workingRef, document: doc)
            try checkedDocument(doc, writes: !dryRun)
            let current = try get(ref: workingRef)
            try assertWritableImage(doc: doc, source: current)
            let before = try nativeGet(ref: workingRef, target: target)
            guard before.nativeStateHash == expected else { throw C1Error.stateChanged("Native editing state changed. Read get with nativeTargets again.") }
            for key in patch.keys where before.values[key] == nil { throw C1Error.invalidRequest("Native field unavailable on this target: " + key) }
            if target.layer > before.layers.count { throw C1Error.invalidRequest("Layer no longer exists.") }
            if (action?.hasPrefix("mask.") == true && action != "mask.people") || action == "layer.delete" {
                guard target.layer > 0, before.layers[target.layer-1].nativeKind != "background" else { throw C1Error.invalidRequest("The image layer cannot be deleted or masked.") }
            }
            if case .number(let sourceLayer) = arguments["sourceLayer"], Int(sourceLayer) > before.layers.count { throw C1Error.invalidRequest("Source mask layer does not exist.") }
            if dryRun { return NativeMutationResult(operationId: "dry-run", before: before, after: before, dryRun: true) }
            let journal = OperationJournal(sessionDirectory: URL(fileURLWithPath: doc.documentPath))
            var entry = try prepare(OperationRecord(operationType: "native", workingRef: workingRef, documentPath: doc.documentPath,
                preconditionStateHash: expected, beforeAdjustments: current.adjustments, beforeGeometry: current.geometry), doc: doc, source: current)
            entry.beforeNative = before; entry.nativePatch = action == nil ? patch : arguments; entry.nativeAction = action
            try journal.append(entry: entry)
            let fields = before.values.keys.sorted(), keys = (action == nil ? patch : arguments).keys.sorted()
            var args = [NSAppleEventDescriptor(string: doc.documentId), .init(string: current.id)] + target.descriptors + [
                .init(string: current.parentImagePath ?? ""), .init(list: fields.map { .init(string: $0) }),
                .init(list: fields.map { before.values[$0]!.descriptor }), .init(list: before.layers.map { .init(list:[.init(string:$0.nativeName), .init(string:$0.nativeKind), .init(int32:Int32($0.nativeOpacity)), .init(boolean:$0.nativeEnabled)]) })]
            if let action { args.append(.init(string: action)) }
            args += [.init(list: keys.map { .init(string: $0) }), .init(list: keys.map { (action == nil ? patch : arguments)[$0]!.descriptor })]
            do {
                let _: Bool = try executor.executeAndDecode(handler: action == nil ? "nativeApply" : "nativeAction", args: args)
                try checkedDocument(doc, writes: false)
                // Deleted targets no longer exist; inspect the image scope and layer inventory instead.
                let afterTarget = ["layer.delete", "color.delete"].contains(action ?? "") ? NativeTarget() : target
                let after = try nativeGet(ref: workingRef, target: afterTarget)
                entry.afterNative = after
                if let action {
                    let change = after.layers.count - before.layers.count
                    if action == "layer.create", change != 1 { throw C1Error.readbackMismatch("Layer creation did not add exactly one layer.") }
                    if action == "layer.delete", change != -1 { throw C1Error.readbackMismatch("Layer deletion did not remove exactly one layer.") }
                    if action == "color.create", after.advancedColorCount != before.advancedColorCount + 1 { throw C1Error.readbackMismatch("Color correction creation readback differs.") }
                }
                for (key, value) in patch {
                    let tolerance = key == "temperature" ? 0.1 : key == "tint" ? 0.01 : 0.0001
                    guard let actual = after.values[key], value.matches(actual, tolerance: tolerance) else {
                        entry.status = "partial-failure"; entry.error = "Native readback mismatch: " + key
                        try journal.append(entry: entry)
                        throw C1Error.readbackMismatch(entry.error!)
                    }
                }
                entry.status = "succeeded"
                try journal.append(entry: entry)
                return NativeMutationResult(operationId: entry.operationId, before: before, after: after, dryRun: false)
            } catch {
                if entry.status == "pending" { entry.status = "outcome-unknown"; entry.error = error.localizedDescription; try? journal.append(entry: entry) }
                throw OperationFailure(operationId: entry.operationId, cause: error)
            }
        }
    }

    // MARK: - Capabilities
    public func capabilities() -> [String: Any] {
        [
            "nativeEditing": ["fields": NativeEditing.fields.mapValues { $0.map { ["name":$0.name, "type":$0.type, "writable":$0.writable, "values":$0.values, "route":$0.route] as [String:Any] } }, "actions":NativeEditing.actions, "status":"experimental", "precondition":"nativeStateHash", "maskPixelsReadable":false] as [String:Any],
            "pinnedBuild": Self.pinnedBuild,
            "testedBuilds": Self.testedBuilds,
            "supportedVersionRange": "16.4+ through 16.x",
            "documentScope": "sessions-and-catalogs",
            "catalogReadOnly": catalogWritePath == nil,
            "catalogWrites": ["optInEnvironment": "C1_CATALOG_WRITE_PATH", "requiresExactPath": true,
                              "requiredBuild": Self.pinnedBuild, "configuredPath": catalogWritePath ?? "",
                              "status": "experimental", "imageStorage": "referenced-originals-only", "activeDocumentPermission": "doc_info.writesEnabled"],
            "geometry": ["testedBuilds": ["16.8.5.30"], "fields": ["crop", "rotation", "keystone"], "coordinateSpace": "oriented-rotated-canvas-bottom-left-pixels", "precondition": "geometry-v1", "rotationRange": [-45, 45], "bounds": "native maximum crop for lens and keystone corrections; conservative centered rectangle otherwise", "lensDistortionRange": [0, 100], "correctedLensRotationDryRun": false, "correctedGeometryRotationDryRun": false, "perspectiveRatioDryRun": false, "existingKeystoneSupported": true, "existingLensMovementsSupported": true, "keystoneWrites": true, "keystoneChangeDryRun": false, "keystoneControls": ContractSchema.keystoneSchema],
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
            "writableMetadataFields": ["rating": ["type": "integer", "minimum": 0, "maximum": 5], "colorTag": ["type": "integer", "minimum": 0, "maximum": 7]],
            "metadataWrites": ["tool": "metadata_set", "precondition": "metadataStateHash", "requiredBuild": Self.pinnedBuild],
            "readOnlyMetadataFields": registry.supportedMetadataFields.filter { !$0.operations.contains(.set) }.map { spec in
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
            "workingVariantEnforced": true,
            "existingVariantEditing": ["beginTool": "variant_edit", "referencePrefix": "c1_edit_", "fields": ["rating", "colorTag", "crop", "rotation", "keystone", "exposure", "contrast", "saturation", "temperature", "tint"],
                                       "restoreTool": "geometry_restore", "createsVariant": false, "tonalWrites": true, "deletion": false]
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
