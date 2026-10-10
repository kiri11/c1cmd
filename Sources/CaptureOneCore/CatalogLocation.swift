import Foundation

/// Resolve the actual database, never the package directory's inode or its parent.
struct CatalogLocation {
    let package: URL
    let database: URL

    init(nativeID: String) throws {
        guard nativeID.hasPrefix("/") else {
            throw C1Error.identityAmbiguous("Catalog ID must be an absolute path.")
        }
        let native = URL(fileURLWithPath: nativeID).resolvingSymlinksInPath()
        let package = native.pathExtension == "cocatalogdb" ? native.deletingLastPathComponent() : native
        let database: URL
        if native.pathExtension == "cocatalogdb" {
            // An exact native ID identifies the active database even when siblings exist.
            database = native
        } else {
            let databases = try FileManager.default.contentsOfDirectory(at: package, includingPropertiesForKeys: [.isRegularFileKey])
                .filter { $0.pathExtension == "cocatalogdb" }
            guard databases.count == 1, let onlyDatabase = databases.first else {
                throw C1Error.identityAmbiguous("Catalog package must contain exactly one identifiable database file when no exact database path is supplied.")
            }
            database = onlyDatabase
        }
        guard try database.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              database.resolvingSymlinksInPath().deletingLastPathComponent().path == package.path else {
            throw C1Error.identityAmbiguous("Catalog database must be a regular file inside its Catalog package.")
        }
        self.package = package
        self.database = database.resolvingSymlinksInPath()
    }

    static func writeDenial(openNativeID: String, configuredPath: String?) throws -> CatalogWriteDenial? {
        guard let configuredPath, !configuredPath.isEmpty else { return .unset }
        guard configuredPath.hasPrefix("/") else { return .relativePath }
        let open = try CatalogLocation(nativeID: openNativeID)
        let configuredURL = URL(fileURLWithPath: configuredPath).resolvingSymlinksInPath()
        guard let configured = try? CatalogLocation(nativeID: configuredPath) else {
            return configuredURL.path == open.package.path ? .databasePathRequired : .differentCatalog(configuredPath: configuredURL.path)
        }
        guard configured.database.path == open.database.path else { return .differentCatalog(configuredPath: configuredURL.path) }
        // Ordinary directories require an exact database opt-in, never a broad folder opt-in.
        if open.package.pathExtension != "cocatalog", configuredURL.pathExtension != "cocatalogdb" { return .databasePathRequired }
        return nil
    }
}

enum CatalogWriteDenial: Equatable {
    case unset
    case differentCatalog(configuredPath: String)
    case relativePath
    case databasePathRequired

    var reason: WritesDisabledReason {
        switch self {
        case .unset: .unset
        case .differentCatalog: .differentCatalog
        case .relativePath: .relativePath
        case .databasePathRequired: .databasePathRequired
        }
    }
}
