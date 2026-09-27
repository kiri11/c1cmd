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
    public let unresolvedOperationsCount: Int?
    public var diagnosticError: C1Error? = nil
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
        unresolvedOperationsCount: Int?,
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

    private let isAppRunning: () -> Bool
    private let nativeInventoryEnabled: Bool
    let executor: ScriptExecuting
    let appInstance: () throws -> String
    let databaseIdentity: (String) throws -> String
    private let catalogWritePath: String?
    private let imageDimensions: (String) -> [Double]?
    let lock = CaptureOneLock.shared
    private let registry = FieldRegistry.shared
    private let previewMgr = PreviewManager.shared
    /// The parent compound edit that journaled writes through this controller belong to.
    let compoundId: String?

    public init(executor: ScriptExecuting = AppleScriptExecutor.shared,
                appInstance: @escaping () throws -> String = DocumentIdentity.appInstance,
                databaseIdentity: @escaping (String) throws -> String = DocumentIdentity.fileIdentity,
                catalogWritePath: String? = ProcessInfo.processInfo.environment["C1_CATALOG_WRITE_PATH"],
                imageDimensions: @escaping (String) -> [Double]? = ImageDimensions.read,
                nativeInventoryEnabled: Bool = ProcessInfo.processInfo.environment["C1_INVENTORY_STRATEGY"] != "scan",
                isAppRunning: @escaping () -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.captureone.captureone16").isEmpty }) {
        self.isAppRunning = isAppRunning
        self.nativeInventoryEnabled = nativeInventoryEnabled
        self.executor = executor
        self.appInstance = appInstance
        self.databaseIdentity = databaseIdentity
        self.catalogWritePath = catalogWritePath
        self.imageDimensions = imageDimensions
        self.compoundId = nil
    }

    private init(linking base: SessionController, compoundId: String) {
        isAppRunning = base.isAppRunning
        nativeInventoryEnabled = base.nativeInventoryEnabled
        executor = base.executor
        appInstance = base.appInstance
        databaseIdentity = base.databaseIdentity
        catalogWritePath = base.catalogWritePath
        imageDimensions = base.imageDimensions
        self.compoundId = compoundId
    }

    /// A controller whose journaled writes record `compoundId` as their parent compound edit.
    func linked(toCompound compoundId: String) -> SessionController {
        SessionController(linking: self, compoundId: compoundId)
    }

    func databasePath(_ doc: DocumentInfo) throws -> String {
        if !doc.isSession { return try CatalogLocation(nativeID: doc.documentId).database.path }
        return doc.isSession && !doc.documentId.hasSuffix(".cosessiondb")
            ? URL(fileURLWithPath: doc.documentPath).appendingPathComponent(doc.documentName).path
            : doc.documentId
    }

    func checkedDocument(_ expected: DocumentInfo, writes: Bool = true) throws {
        let actual = try getDocumentInfo()
        guard expected.documentId == actual.documentId, expected.openToken == actual.openToken else {
            throw C1Error.documentChanged("Active database changed before dispatch.")
        }
        if writes { try OperationJournal(sessionDirectory: URL(fileURLWithPath: actual.documentPath)).assertReady() }
    }

    func assertWritableImage(doc: DocumentInfo, source: GetResult?) throws {
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

    // MARK: - Doctor
    public func doctor() throws -> DoctorReport {
        let appRunning = isAppRunning()
        var observedInfo: AppAndDocInfoResult?
        var diagnosticError: C1Error?

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
                observedInfo = info
                appVersion = info.appVersion
                hasDoc = info.hasDocument
                docName = info.docName
                docPath = info.docPath
                isSession = info.isSession
                documentCount = info.documentCount ?? 0
            } catch {
                appVersion = "error"
                diagnosticError = (error as? C1Error) ?? .invalidRequest(String(describing: error))
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

        var unresolvedCount: Int?
        var writesEnabled = false
        var identityOK = false
        if hasDoc, let observedInfo {
            do {
                let doc = try documentInfo(from: observedInfo)
                identityOK = true
                docPath = doc.documentPath
                writesEnabled = doc.writesEnabled
                let journal = OperationJournal(sessionDirectory: URL(fileURLWithPath: doc.documentPath))
                unresolvedCount = try journal.validatedEntries().filter(OperationJournal.isUnresolved).count
            } catch {
                diagnosticError = (error as? C1Error) ?? .invalidRequest(String(describing: error))
            }
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
        report.diagnosticError = diagnosticError
        report.writesEnabled = writesEnabled && allPassed
        return report
    }

    // MARK: - Document Info
    public func getDocumentInfo(allowUntestedBuild: Bool = false) throws -> DocumentInfo {
        let info: AppAndDocInfoResult = try executor.executeAndDecode(
            handler: "getAppAndDocInfo",
            args: []
        )
        return try documentInfo(from: info, allowUntestedBuild: allowUntestedBuild)
    }

    private func documentInfo(from info: AppAndDocInfoResult, allowUntestedBuild: Bool = false) throws -> DocumentInfo {
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
            let location = try CatalogLocation(nativeID: info.docId ?? path)
            docDir = location.package.path
            outputDir = location.package.deletingLastPathComponent()
                .appendingPathComponent(location.package.lastPathComponent + ".c1-output").path
        }

        ObservedDocument.note(docDir)
        let nativeId = info.docId ?? path
        let database: String
        if info.isSession {
            database = nativeId.hasSuffix(".cosessiondb") ? nativeId : URL(fileURLWithPath: docDir).appendingPathComponent(name).path
        } else {
            database = try CatalogLocation(nativeID: nativeId).database.path
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
                throw C1Error.invalidRequest("Catalogs are strictly read-only unless C1_CATALOG_WRITE_PATH names this exact Catalog package or database (unpackaged catalogs require the database path). Operation '\(operation)' is blocked for '\(docInfo.documentName)'.")
            }
            guard docInfo.appVersion == Self.pinnedBuild else {
                throw C1Error.unsupportedVersion("Catalog writes require Capture One \(Self.pinnedBuild); the untested-build override does not enable Catalog writes.")
            }
        }
    }

    // MARK: - Variants List
    /// Bounded fresh discovery. No editing permissions or mutation tokens are returned.
    public func listVariantSubset(ids: [String], collection: String? = nil, selected: Bool = false,
                                  rating: Int? = nil, minRating: Int? = nil, parentPath: String? = nil, fields: String = "minimal",
                                  batchSize: Int = 32, deadlineSeconds: Double? = nil) throws -> [[String: Any]] {
        var args: [String: Any] = ["ids": ids, "fields": fields, "batchSize": batchSize]
        if let rating { args["rating"] = rating }
        if let minRating { args["minRating"] = minRating }
        if let deadlineSeconds { args["deadlineSeconds"] = deadlineSeconds }
        try ContractSchema.validate(tool: "variants_list", arguments: args)
        if let parentPath, !parentPath.hasPrefix("/") { throw C1Error.invalidRequest("parentPath must be an absolute parent image path.") }
        let started = ProcessInfo.processInfo.systemUptime
        func checkpoint() throws {
            try RequestContext.current?.checkReadCancellation()
            if let deadlineSeconds, ProcessInfo.processInfo.systemUptime - started >= deadlineSeconds {
                throw C1Error.deadlineExceeded("Subset deadline reached; no partial results returned.")
            }
        }
        return try lock.withLock(checkpoint: checkpoint) {
            try checkpoint()
            let document = try getDocumentInfo()
            RequestContext.current?.inventoryScope(collection: collection, selected: selected, rating: rating, minRating: minRating)
            RequestContext.current?.document(document.openToken)
            RequestContext.current?.inventoryStrategy("id-subset")
            RequestContext.current?.update(phase: "discovering", total: ids.count)
            let doc = NSAppleEventDescriptor(string: document.documentId)
            func validateDocument() throws {
                try checkpoint()
                let current = try getDocumentInfo()
                guard current.openToken == document.openToken, current.documentId == document.documentId else {
                    throw C1Error.documentChanged("Document changed during subset discovery.")
                }
            }
            struct Row: Decodable, Equatable {
                let variantId: String
                let starRating: Int
                let parentImagePath: String
                let inSelection: Bool
            }
            func read() throws -> [Row] {
                var rows: [Row] = []
                for offset in stride(from: 0, to: ids.count, by: batchSize) {
                    try validateDocument()
                    let batch = Array(ids[offset..<min(offset + batchSize, ids.count)])
                    let values: [Row] = try executor.executeAndDecode(handler: "readVariantSubset", args: [doc,
                        collection.map(NSAppleEventDescriptor.init(string:)) ?? .missingValue(),
                        NSAppleEventDescriptor(boolean: selected),
                        NSAppleEventDescriptor(list: batch.map(NSAppleEventDescriptor.init(string:)))])
                    guard values.map(\.variantId) == batch,
                          values.allSatisfy({ VariantMetadata.ratingRange.contains($0.starRating) && $0.parentImagePath.hasPrefix("/") }) else {
                        throw C1Error.stateChanged("Subset identity or metadata mismatch; no partial results returned.")
                    }
                    rows += values
                    try checkpoint()
                }
                return rows
            }
            let baseline = try read()
            let matches = baseline.filter { row in
                (parentPath.map { row.parentImagePath == $0 } ?? true) && (!selected || row.inSelection) && (rating.map { row.starRating == $0 } ?? true) &&
                    (minRating.map { row.starRating >= $0 } ?? true)
            }
            var result: [[String: Any]] = matches.map { ["id": $0.variantId, "rating": $0.starRating, "parentImagePath": $0.parentImagePath] }
            if fields == "summary" {
                result = []
                for offset in stride(from: 0, to: matches.count, by: batchSize) {
                    try validateDocument()
                    let batch = Array(matches[offset..<min(offset + batchSize, matches.count)])
                    let summaries: [VariantSummaryRecord] = try executor.executeAndDecode(handler: "readVariantSummaries", args: [doc,
                        NSAppleEventDescriptor(list: batch.map { NSAppleEventDescriptor(string: $0.variantId) })])
                    guard summaries.map(\.variantId) == batch.map(\.variantId),
                          summaries.map(\.starRating) == batch.map(\.starRating),
                          summaries.map(\.parentImagePath) == batch.map(\.parentImagePath),
                          !selected || summaries.allSatisfy(\.isSelected) else {
                        throw C1Error.stateChanged("Subset changed during summary read.")
                    }
                    result += summaries.map { ["id": $0.variantId, "rating": $0.starRating, "parentImagePath": $0.parentImagePath,
                                                "name": $0.variantName, "isSelected": $0.isSelected, "colorTag": $0.colorTagVal] }
                }
            }
            guard try read() == baseline else { throw C1Error.stateChanged("Subset membership or identity changed; discard results.") }
            try validateDocument()
            return result
        }
    }

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
                        VariantMetadata.ratingRange.contains(item.starRating) &&
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
                guard ratings.map(\.variantId) == batch, ratings.allSatisfy({ VariantMetadata.ratingRange.contains($0.starRating) }) else {
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
        try guarded("variant_edit", pinned: "Existing-variant editing requires Capture One \(Self.pinnedBuild).") { doc in
            guard doc.openToken == ifDocument else { throw C1Error.documentChanged("Document changed since the editing targets were selected.") }
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
        let operation = baseline ? "baseline" : "clone"
        return try guarded(operation) { doc in
            let source = try get(ref: sourceRef)
            guard let parent = source.parentImagePath, !parent.isEmpty else {
                throw C1Error.identityAmbiguous("Source parent image path is unavailable.")
            }
            try assertWritableImage(doc: doc, source: source)
            let store = ProvenanceStore(sessionDirectory: URL(fileURLWithPath: doc.documentPath))
            _ = try store.validatedRecords()
            let ref = WorkingRef().rawValue
            let lookup = VariantLookup(executor: executor)
            let siblings = try lookup.siblings(of: source.id, parent: parent, in: doc)
            var entry = OperationRecord(operationType: operation, workingRef: ref,
                documentPath: doc.documentPath, beforeAdjustments: source.adjustments)
            entry.variantIdsBefore = siblings
            return try journaled(entry, doc: doc, source: source, dispatch: {
                let args = [NSAppleEventDescriptor(string: doc.documentId), NSAppleEventDescriptor(string: source.id)]
                if baseline {
                    let result: CreateBaselineVariantResult = try executor.executeAndDecode(handler: "createBaselineVariant", args: args)
                    return result.baselineId
                }
                let result: CloneVariantResult = try executor.executeAndDecode(handler: "cloneVariant", args: args)
                return result.cloneId
            }, readback: { pending, id in
                guard id != source.id, !siblings.contains(id) else {
                    return .mismatch(.identityAmbiguous("Creation did not return a new variant ID."))
                }
                let created = try get(ref: id)
                guard created.parentImagePath == parent else { return .mismatch(.identityAmbiguous("Created variant has the wrong parent image.")) }
                guard try lookup.siblings(of: source.id, parent: parent, in: doc).contains(id) else {
                    return .mismatch(.identityAmbiguous("Created variant is not a sibling of its source."))
                }
                try store.register(record: ProvenanceRecord(workingRef: ref, sourceVariantId: source.id,
                    cloneVariantId: id, documentPath: doc.documentPath, documentName: doc.documentName,
                    parentImagePath: parent, creationOperationId: pending.entry.operationId,
                    baselineAdjustments: created.adjustments, baselineStateHash: created.stateHash, documentToken: doc.openToken, baselineGeometry: created.geometry, baselineMetadata: VariantMetadata.from(created.metadata)))
                pending.update { $0.afterAdjustments = created.adjustments }
                return .confirmed(CloneResult(workingRef: ref, cloneVariantId: id, sourceVariantId: source.id,
                                              documentPath: doc.documentPath, baselineStateHash: created.stateHash))
            }).value
        }
    }

    // MARK: - Delete Variant
    public func deleteVariant(workingRefString: String) throws -> DeleteResult {
        try guarded("delete") { doc in
            let current = try get(ref: workingRefString)
            try assertWritableImage(doc: doc, source: current)
            let store = ProvenanceStore(sessionDirectory: URL(fileURLWithPath: doc.documentPath))
            let record = try store.resolveManagedWorkingReference(workingRefString, currentDocumentPath: doc.documentPath)
            let entry = OperationRecord(operationType: "delete", workingRef: workingRefString,
                documentPath: doc.documentPath, beforeAdjustments: current.adjustments)
            return try journaled(entry, doc: doc, source: current, dispatch: { () -> DeleteVariantResult in
                try executor.executeAndDecode(handler: "deleteVariant", args: [
                    NSAppleEventDescriptor(string: doc.documentId), NSAppleEventDescriptor(string: record.cloneVariantId),
                    NSAppleEventDescriptor(string: record.parentImagePath!), NSAppleEventDescriptor(string: record.sourceVariantId)])
            }, readback: { _, result in
                guard result.deleted && !result.existsNow else { return .mismatch(.readbackMismatch("Deleted variant still exists.")) }
                try store.remove(workingRef: workingRefString)
                return .confirmed(DeleteResult(deleted: true, workingRef: workingRefString, cloneVariantId: record.cloneVariantId))
            }).value
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

    func adjustmentTarget(_ ref: String, document: DocumentInfo) throws -> (workingRef: String, variantId: String, baselineAdjustments: Adjustments, baselineGeometry: Geometry?) {
        if EditingRecord.isEditingReference(ref) {
            let record = try EditingStore(document: document).resolve(ref, document: document)
            return (record.workingRef, record.variantId, record.baselineAdjustments, record.baselineGeometry)
        }
        let record = try ProvenanceStore(sessionDirectory: URL(fileURLWithPath: document.documentPath))
            .resolveManagedWorkingReference(ref, currentDocumentPath: document.documentPath)
        return (record.workingRef, record.cloneVariantId, record.baselineAdjustments, record.baselineGeometry)
    }

    // MARK: - Set / Add / Reset Mutations
    public func mutate(
        workingRefString: String,
        ifState expectedHash: String,
        setAdjustments: Adjustments?,
        addAdjustments: Adjustments?,
        isDryRun: Bool = false
    ) throws -> MutationResult {
        guard (setAdjustments != nil) != (addAdjustments != nil), (setAdjustments ?? addAdjustments)?.hasAnyField == true else {
            throw C1Error.invalidRequest("Provide exactly one nonempty set or add adjustment patch.")
        }
        let change: TonalWrite.Change = setAdjustments.map { .set($0) } ?? .add(addAdjustments!)
        return try tonalWrite(change, workingRef: workingRefString, ifState: expectedHash, dryRun: isDryRun)
    }

    private func tonalWrite(_ change: TonalWrite.Change, workingRef: String, ifState: String, dryRun: Bool) throws -> MutationResult {
        let outcome = try write(TonalWrite(change: change), workingRef: workingRef, precondition: ifState, dryRun: dryRun)
        let before = outcome.before.state
        guard let after = outcome.after else {
            let target = outcome.intended.target
            return MutationResult(operationId: outcome.operationId, workingRef: outcome.workingRef, before: before, after: target,
                diff: target.changes(from: before), stateHash: StateHash.compute(for: target).hex, isDryRun: true)
        }
        return MutationResult(operationId: outcome.operationId, workingRef: outcome.workingRef, before: before, after: after.state,
            diff: after.state.changes(from: before), stateHash: after.observation.stateHash, isDryRun: false)
    }

    // MARK: - Crop, rotation, and keystone
    public func geometrySet(workingRef: String, ifGeometryState expected: String, crop: CropRect? = nil,
                            rotation: Double? = nil, aspectRatio: Double? = nil, keystone: KeystoneAdjustments? = nil, dryRun: Bool = false) throws -> GeometryMutationResult {
        try geometryWrite(GeometryWrite(crop: crop, rotation: rotation, aspectRatio: aspectRatio, keystone: keystone, restore: false),
                          workingRef: workingRef, expected: expected, dryRun: dryRun)
    }

    public func geometryRestore(workingRef: String, ifGeometryState expected: String, dryRun: Bool = false) throws -> GeometryMutationResult {
        try geometryWrite(GeometryWrite(crop: nil, rotation: nil, aspectRatio: nil, keystone: nil, restore: true),
                          workingRef: workingRef, expected: expected, dryRun: dryRun)
    }

    private func geometryWrite(_ kind: GeometryWrite, workingRef: String, expected: String, dryRun: Bool) throws -> GeometryMutationResult {
        let outcome = try write(kind, workingRef: workingRef, precondition: expected, dryRun: dryRun)
        let before = outcome.before.state
        guard let after = outcome.after else {
            guard let target = outcome.intended.target else { throw C1Error.invalidRequest("Dry runs cannot predict this geometry change.") }
            return GeometryMutationResult(operationId: outcome.operationId, workingRef: workingRef, before: before.geometry, after: target,
                diff: target.changes(from: before.geometry), geometryStateHash: before.hash, isDryRun: true)
        }
        return GeometryMutationResult(operationId: outcome.operationId, workingRef: workingRef, before: before.geometry, after: after.state.geometry,
            diff: after.state.geometry.changes(from: before.geometry), geometryStateHash: after.state.hash, isDryRun: false)
    }

    // MARK: - Reset Mutation
    public func reset(
        workingRefString: String,
        ifState expectedHash: String,
        fields: [String] = [],
        isDryRun: Bool = false
    ) throws -> MutationResult {
        try tonalWrite(.reset(fields), workingRef: workingRefString, ifState: expectedHash, dryRun: isDryRun)
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
        after.changes(from: before)
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
        return try guarded("preview") { doc in
            let current = try get(ref: ref)
            try assertWritableImage(doc: doc, source: current)
            let opId = UUID().uuidString.lowercased()
            let root = URL(fileURLWithPath: outputDirOverride ?? doc.outputFolder).resolvingSymlinksInPath()
            let subfolder = "c1-previews/\(opId)"
            let jobDir = root.appendingPathComponent(subfolder, isDirectory: true)
            try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
            let entry = OperationRecord(operationId: opId, operationType: "preview", workingRef: ref,
                documentPath: doc.documentPath, preconditionStateHash: current.stateHash,
                beforeAdjustments: current.adjustments, previewOutputPath: jobDir.path, beforeGeometry: current.geometry)
            // Exports change no adjustments, so every failed check leaves the outcome unknown.
            return try journaled(entry, doc: doc, source: current, dispatch: {
                let args = [NSAppleEventDescriptor(string: doc.documentId),
                            NSAppleEventDescriptor(string: PreviewManager.defaultRecipeName), NSAppleEventDescriptor(string: root.path)]
                let _: PreviewRecipeResult = try executor.executeAndDecode(handler: "ensurePreviewRecipe", args: args)
                let _: ProcessPreviewResult = try executor.executeAndDecode(handler: "processPreview", args: [
                    args[0], NSAppleEventDescriptor(string: current.id), args[1], args[2],
                    NSAppleEventDescriptor(string: subfolder), NSAppleEventDescriptor(string: "preview")])
                return try previewMgr.pollForOutputFile(inDirectory: jobDir, timeout: timeout)
            }, readback: { pending, file in
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
                pending.update { $0.previewOutputPath = file.path }
                return .confirmed(PreviewResult(operationId: opId, workingRef: current.workingRef, outputPath: file.path,
                    fileSizeBytes: size, width: image.width, height: image.height, pixelSha256: image.pixelSha256,
                    stateHash: current.stateHash, nativeVariantId: current.id, geometry: current.geometry, geometryStateHash: current.geometryStateHash))
            }).value
        }
    }

    // MARK: - Rating and color tag writes
    public func metadataSet(workingRef: String, ifMetadataState: String, rating: Int? = nil,
                            colorTag: Int? = nil, dryRun: Bool = false) throws -> MetadataMutationResult {
        var arguments: [String: Any] = ["workingRef": workingRef, "ifMetadataState": ifMetadataState, "dryRun": dryRun]
        if let rating { arguments["rating"] = rating }
        if let colorTag { arguments["colorTag"] = colorTag }
        try ContractSchema.validate(tool: "metadata_set", arguments: arguments)
        let outcome = try write(MetadataWrite(rating: rating, colorTag: colorTag), workingRef: workingRef,
                                precondition: ifMetadataState, dryRun: dryRun)
        let before = outcome.before.state, after = outcome.after?.state ?? outcome.intended
        return MetadataMutationResult(operationId: outcome.operationId, workingRef: workingRef, before: before,
            after: after, diff: after.changes(from: before),
            metadataStateHash: (outcome.isDryRun ? before : after).stateHash, isDryRun: outcome.isDryRun)
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
            if ["clone", "baseline"].contains(entry.operationType) {
                guard let before = entry.variantIdsBefore, let parent = entry.parentImagePath else {
                    throw C1Error.identityAmbiguous("Creation lacks recovery identity evidence.")
                }
                // Any still-present known sibling finds the parent image; a whole-document
                // inventory remains only for when every known sibling is gone.
                let anchors = [entry.nativeVariantId].compactMap { $0 } + before
                let siblings = try VariantLookup(executor: executor).siblings(anchoredBy: anchors, parent: parent, in: doc)
                    ?? listVariants().filter { $0.parentImagePath == parent }.map(\.id)
                try checkedDocument(doc, writes: false)
                entry.observedVariantIds = siblings.filter { !before.contains($0) }
                // Other photographer-created variants are indistinguishable; do not adopt or delete them.
                entry.status = "reconciled"
                entry.error = "Previous app instance ended. Review observedVariantIds manually; no variants were adopted, deleted, or recreated."
            } else if let id = entry.nativeVariantId {
                guard let parent = entry.parentImagePath else {
                    throw C1Error.identityAmbiguous("Operation lacks a recorded parent image for its native variant.")
                }
                // Resolve only the recorded ID; a lookup error propagates and leaves the operation unresolved.
                let outcome = try VariantLookup(executor: executor).resolve(id, expectedParent: parent, in: doc)
                try checkedDocument(doc, writes: false)
                switch outcome {
                case .parentChanged(let observed):
                    throw C1Error.identityAmbiguous("Recovery variant parent changed: recorded '\(parent)', observed '\(observed)'.")
                case .present:
                    let current = try get(ref: id)
                    guard current.parentImagePath == parent else { throw C1Error.identityAmbiguous("Recovery variant parent changed.") }
                    entry.afterAdjustments = current.adjustments
                    entry.afterGeometry = current.geometry
                    entry.afterMetadata = VariantMetadata.from(current.metadata)
                    if entry.beforeNative != nil {
                        let target = entry.nativeAction == "color.delete" ? NativeTarget(layer:entry.beforeNative!.target.layer) : entry.nativeAction == "layer.delete" ? NativeTarget() : entry.beforeNative!.target
                        entry.afterNative = try nativeGet(ref: id, target: target)
                    }
                    entry.status = "reconciled"
                    entry.error = "Previous app instance ended. Observed current adjustments, geometry, and metadata are recorded; they do not prove historical completion. Review before creating a fresh editing reference."
                case .absent:
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

    func readNative(ref: String, target: NativeTarget) throws -> GetResult {
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
        let outcome = try write(NativeWrite(target: target, patch: patch, action: action, arguments: arguments),
                                workingRef: workingRef, precondition: expected, dryRun: dryRun)
        let before = outcome.before.state
        return NativeMutationResult(operationId: outcome.operationId, before: before, after: outcome.after?.state ?? before, dryRun: outcome.isDryRun)
    }

    /// Independent direct-property reader: does not call nativeRead/nativeReadField.
    func recipeOracle(ref: String) throws -> [String:NativeValue] {
        try lock.withLock {
            let doc = try getDocumentInfo(), source = try get(ref:ref)
            try checkedDocument(doc, writes:false)
            let values: [NativeValue] = try executor.executeAndDecode(handler:"nativeRecipeOracle", args:[.init(string:doc.documentId),.init(string:source.id),.init(string:source.parentImagePath ?? "")])
            guard values.count == Recipes.oracleFields.count else { throw C1Error.readbackMismatch("Invalid independent recipe observation.") }
            try checkedDocument(doc,writes:false)
            let observation = Dictionary(uniqueKeysWithValues:zip(Recipes.oracleFields,values))
            try NativeEditing.validate(observation,target:NativeTarget())
            return observation
        }
    }

    /// Bulk property records intentionally bypass nativeRead/nativeReadField and
    /// never provide write tokens. Indexed color objects must remain unevaluated.
    func recipeScopesOracle(ref: String) throws -> RecipeScopes.Observation {
        try lock.withLock {
            let doc = try getDocumentInfo(), source = try get(ref:ref)
            try checkedDocument(doc,writes:false)
            let wire: RecipeScopes.Wire = try executor.executeAndDecode(handler:"nativeRecipeScopesOracle",args:[.init(string:doc.documentId),.init(string:source.id),.init(string:source.parentImagePath ?? "")])
            try checkedDocument(doc,writes:false)
            return try RecipeScopes.Observation(wire)
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
            "geometry": ["testedBuilds": ["16.8.5.30"], "fields": ["crop", "rotation", "keystone"], "coordinateSpace": "oriented-rotated-canvas-bottom-left-pixels", "precondition": "geometry-v1", "rotationRange": [-Geometry.maximumRotation, Geometry.maximumRotation], "bounds": "native maximum crop for lens and keystone corrections; conservative centered rectangle otherwise", "lensDistortionRange": [0, 100], "correctedLensRotationDryRun": false, "correctedGeometryRotationDryRun": false, "perspectiveRatioDryRun": false, "existingKeystoneSupported": true, "existingLensMovementsSupported": true, "keystoneWrites": true, "keystoneChangeDryRun": false, "keystoneControls": ContractSchema.keystoneSchema],
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
            "writableMetadataFields": ContractSchema.writableMetadataSchema["properties"]!,
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
