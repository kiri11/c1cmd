import Foundation

enum CacheFolder: String {
    case thumbs, requests, contactSheets = "contact-sheets"

    var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/c1", isDirectory: true)
            .appendingPathComponent(rawValue, isDirectory: true)
    }
}
