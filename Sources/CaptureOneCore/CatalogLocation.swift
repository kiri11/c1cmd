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

    func isAuthorized(by configuredPath: String?) -> Bool {
        guard let configuredPath, configuredPath.hasPrefix("/"),
              let configured = try? CatalogLocation(nativeID: configuredPath) else { return false }
        // Ordinary directories require an exact database opt-in, never a broad folder opt-in.
        if package.pathExtension != "cocatalog" {
            let configuredURL = URL(fileURLWithPath: configuredPath).resolvingSymlinksInPath()
            guard configuredURL.pathExtension == "cocatalogdb" else { return false }
        }
        return configured.package.path == package.path && configured.database.path == database.path
    }
}
