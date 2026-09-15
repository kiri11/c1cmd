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
        guard package.pathExtension == "cocatalog" else {
            throw C1Error.identityAmbiguous("Cannot identify the Catalog package: \(nativeID)")
        }
        let databases = try FileManager.default.contentsOfDirectory(at: package, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { $0.pathExtension == "cocatalogdb" }
        guard databases.count == 1, let database = databases.first,
              try database.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              database.resolvingSymlinksInPath().deletingLastPathComponent().path == package.path,
              native.path == package.path || native.path == database.resolvingSymlinksInPath().path else {
            throw C1Error.identityAmbiguous("Catalog must contain exactly one identifiable database file.")
        }
        self.package = package
        self.database = database.resolvingSymlinksInPath()
    }

    func isAuthorized(by configuredPath: String?) -> Bool {
        guard let configuredPath, configuredPath.hasPrefix("/"),
              let configured = try? CatalogLocation(nativeID: configuredPath) else { return false }
        return configured.package.path == package.path && configured.database.path == database.path
    }
}
