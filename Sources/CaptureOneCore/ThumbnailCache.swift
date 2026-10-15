import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The crop Capture One stored in a `.cot` thumbnail's EXIF UserComment. The cached pixels are
/// uncropped, so only a crop whose format is verified is applied.
package enum CotCrop: Equatable {
    /// Top-left-origin rectangle in thumbnail pixels.
    case applied(x: Double, y: Double, width: Double, height: Double)
    case fullFrame
    case notApplied(reason: Skip, userComment: String?)

    package enum Skip: String, CaseIterable {
        case absent
        /// Older builds; its origin and edge inclusivity are unverified.
        case formatVersion2 = "format-version-2"
        case unsupportedFormat = "unsupported-format"
    }

    /// Version 3 is `3|i;i;i|left;top;right;bottom|0` in bottom-left-origin thumbnail pixels.
    package static func parse(userComment: String?, width: Int, height: Int) -> CotCrop {
        guard let comment = userComment, !comment.isEmpty else { return .notApplied(reason: .absent, userComment: nil) }
        let fields = comment.split(separator: "|", omittingEmptySubsequences: false)
        switch fields.first {
        case "3": break
        case "2": return .notApplied(reason: .formatVersion2, userComment: comment)
        default: return .notApplied(reason: .unsupportedFormat, userComment: comment)
        }
        let unsupported = CotCrop.notApplied(reason: .unsupportedFormat, userComment: comment)
        guard fields.count == 4, fields[3] == "0" else { return unsupported }
        let middle = fields[1].split(separator: ";", omittingEmptySubsequences: false)
        let edges = fields[2].split(separator: ";", omittingEmptySubsequences: false).compactMap { Double($0) }.filter(\.isFinite)
        guard middle.count == 3, middle.allSatisfy({ Int($0) != nil }), edges.count == 4 else { return unsupported }
        let (left, top, right, bottom) = (edges[0], edges[1], edges[2], edges[3])
        let w = Double(width), h = Double(height)
        guard 0 <= left, left < right, right <= w, 0 <= bottom, bottom < top, top <= h else { return unsupported }
        if left == 0, top == h, right == w, bottom == 0 { return .fullFrame }
        return .applied(x: left, y: h - top, width: right - left, height: top - bottom)
    }
}

package struct SessionThumbnailKey: Equatable {
    package let variantUUID: UUID
    package let imageFileName: String

    package init(variantUUID: UUID, imageFileName: String) {
        self.variantUUID = variantUUID
        self.imageFileName = imageFileName
    }
}

/// Where Capture One 16.8.5.30 keeps a variant's thumbnail. Paths are derived from identity, never by listing
/// the cache directory, whose files are not live membership.
package enum ThumbnailCache {
    package static func storedID(_ nativeID: String) throws -> Int {
        guard !nativeID.hasPrefix("0"), nativeID.utf8.allSatisfy({ (48...57).contains($0) }), let id = Int(nativeID), id > 0 else {
            throw C1Error.identityAmbiguous("Variant ID '\(nativeID)' is not a stored database ID, so no thumbnail can be mapped to it.")
        }
        return id
    }

    package static func catalogThumbnail(databasePath: String, variantID: Int) -> URL {
        let digits = String(variantID)
        return URL(fileURLWithPath: databasePath).deletingLastPathComponent()
            .appendingPathComponent("Cache/Thumbnails", isDirectory: true)
            .appendingPathComponent(String(repeating: "0", count: max(0, 8 - digits.count)) + digits + ".cot")
    }

    package static func sessionThumbnail(parentImagePath: String, key: SessionThumbnailKey) throws -> URL {
        let original = URL(fileURLWithPath: parentImagePath)
        guard parentImagePath.hasPrefix("/"), key.imageFileName == original.lastPathComponent else {
            throw C1Error.identityAmbiguous("The Session stores '\(key.imageFileName)' for a variant of \(parentImagePath); no sheet was made.")
        }
        return original.deletingLastPathComponent()
            .appendingPathComponent("CaptureOne/Cache/Thumbnails", isDirectory: true)
            .appendingPathComponent("\(key.imageFileName).[\(key.variantUUID.uuidString.lowercased())].cot")
    }
}

extension ThumbnailCache {
    static let maximumBytes = 4 * 1024 * 1024

    private enum Attempt { case read(TileContent), changed }

    /// Capture One replaces a thumbnail atomically, so a read that saw two different files is retried once.
    package static func read(_ url: URL, testHookAfterStat: () -> Void = {}) -> TileContent {
        for _ in 0..<2 {
            if case .read(let content) = attempt(url, testHookAfterStat: testHookAfterStat) { return content }
        }
        return .unreadable(.changedDuringRead)
    }

    private static func attempt(_ url: URL, testHookAfterStat: () -> Void) -> Attempt {
        var before = stat()
        guard lstat(url.path, &before) == 0 else {
            return .read([ENOENT, ENOTDIR].contains(errno) ? .missing(.notCached) : .unreadable(.inaccessible))
        }
        guard before.st_mode & S_IFMT == S_IFREG else { return .read(.unreadable(.notRegularFile)) }
        guard before.st_size <= maximumBytes else { return .read(.unreadable(.tooLarge)) }
        testHookAfterStat()
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return [ENOENT, ELOOP].contains(errno) ? .changed : .read(.unreadable(.inaccessible)) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: maximumBytes + 1) ?? Data() else { return .read(.unreadable(.inaccessible)) }
        var after = stat()
        guard lstat(url.path, &after) == 0, after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_size == before.st_size, data.count == Int(before.st_size),
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
            return .changed
        }
        let modifiedAt = Date(timeIntervalSince1970: Double(before.st_mtimespec.tv_sec) + Double(before.st_mtimespec.tv_nsec) / 1e9)
        return .read(decode(data, modifiedAt: modifiedAt))
    }

    private static func decode(_ data: Data, modifiedAt: Date) -> TileContent {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            return .unreadable(.undecodable)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        for tag in [properties[kCGImagePropertyOrientation], tiff?[kCGImagePropertyTIFFOrientation]] {
            if let tag, (tag as? NSNumber)?.intValue != 1 { return .unreadable(.orientationTag) }
        }
        let comment = (properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] as? String
        return .shown(CachedThumbnail(image: image, modifiedAt: modifiedAt,
                                      crop: CotCrop.parse(userComment: comment, width: image.width, height: image.height)))
    }
}
