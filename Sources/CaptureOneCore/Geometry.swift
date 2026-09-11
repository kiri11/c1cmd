import Foundation
import CryptoKit

/// Pixels in Capture One's oriented, rotated canvas; origin at bottom left.
public struct CropRect: Codable, Equatable {
    public var centerX: Double
    public var centerY: Double
    public var width: Double
    public var height: Double
    public init(centerX: Double, centerY: Double, width: Double, height: Double) {
        self.centerX = centerX; self.centerY = centerY; self.width = width; self.height = height
    }
    public var values: [Double] { [centerX, centerY, width, height] }
    public var aspectRatio: Double { width / height }
}

public struct Geometry: Codable, Equatable {
    public var crop: CropRect
    public var rotation: Double
    public var orientation: Int
    public var imageWidth: Double
    public var imageHeight: Double
    public var maximumCrop: CropRect
    public var flip: String
    public var aspectRatioName: String?
    public var keystone: [Double]
    public var lensGeometry: [Double]
    public var lensProfile: String
    public var hideDistortedAreas: Bool
    public var cropOutsideImage: Bool

    public var unsupportedReason: String? {
        guard [0, 90, 180, 270].contains(orientation), flip == "none" else { return "Orientation or flip is not qualified for geometry writes." }
        guard keystone.count == 5, keystone.dropFirst().allSatisfy({ $0 == 0 }), lensGeometry.count == 8,
              lensGeometry[0] == 0, lensGeometry.dropFirst(2).allSatisfy({ $0 == 0 }), !cropOutsideImage else {
            return "Existing perspective, lens distortion/shift, or crop-outside-image settings require manual review."
        }
        guard maximumCrop.values.allSatisfy({ $0.isFinite }), keystone.allSatisfy({ $0.isFinite }), lensGeometry.allSatisfy({ $0.isFinite }),
              imageWidth.isFinite, imageHeight.isFinite, imageWidth > 0, imageHeight > 0,
              rotation.isFinite, abs(rotation) <= 45, crop.values.allSatisfy({ $0.isFinite }), crop.width > 0, crop.height > 0 else {
            return "Image geometry is unavailable or outside the qualified range."
        }
        return nil
    }

    /// A conservative centered rectangle inside the rotated image, preserving its
    /// native aspect ratio. It intentionally excludes the triangular corner areas.
    public func safeBounds(rotation angle: Double) -> CropRect {
        let portrait = orientation == 90 || orientation == 270
        let w = portrait ? imageHeight : imageWidth
        let h = portrait ? imageWidth : imageHeight
        let r = abs(angle) * .pi / 180
        let c = cos(r), s = sin(r)
        let scale = min(w / (w*c + h*s), h / (w*s + h*c))
        return CropRect(centerX: (w*c+h*s)/2, centerY: (w*s+h*c)/2,
                        width: floor(w*scale), height: floor(h*scale))
    }

    public func stateHash(tonalHash: String) -> String {
        // Independent from the legacy tonal hash; includes read-only geometry context.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "geometry-v1:unavailable" }
        let digest = SHA256.hash(data: Data(("geometry-v1|" + tonalHash + "|").utf8) + data)
        return "geometry-v1:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    public func target(crop requested: CropRect?, rotation angle: Double?, aspectRatio: Double?) throws -> Geometry {
        guard let reason = unsupportedReason else { return try validatedTarget(crop: requested, rotation: angle, aspectRatio: aspectRatio) }
        throw C1Error.invalidRequest(reason)
    }
    private func validatedTarget(crop requested: CropRect?, rotation angle: Double?, aspectRatio: Double?) throws -> Geometry {
        guard requested != nil || angle != nil || aspectRatio != nil else { throw C1Error.invalidRequest("Provide crop, rotation, or aspectRatio.") }
        guard requested == nil || aspectRatio == nil else { throw C1Error.invalidRequest("Provide crop or aspectRatio, not both.") }
        let angle = angle ?? rotation
        guard angle.isFinite, abs(angle) <= 45 else { throw C1Error.invalidRequest("Rotation must be finite and between -45 and 45 degrees.") }
        let bounds = safeBounds(rotation: angle)
        var rect = requested ?? crop
        if let ratio = aspectRatio {
            guard ratio.isFinite, ratio > 0 else { throw C1Error.invalidRequest("aspectRatio must be finite and positive.") }
            let w = min(bounds.width, bounds.height * ratio)
            rect = CropRect(centerX: bounds.centerX.rounded(), centerY: bounds.centerY.rounded(), width: floor(w), height: floor(w / ratio))
        }
        guard rect.values.allSatisfy({ $0.isFinite }), rect.width >= 1, rect.height >= 1 else { throw C1Error.invalidRequest("Crop dimensions must be positive finite pixels.") }
        // Native crop and parent dimensions differ by up to two pixels in retained probes.
        guard abs(rect.centerX - bounds.centerX) + rect.width/2 <= bounds.width/2 + 2,
              abs(rect.centerY - bounds.centerY) + rect.height/2 <= bounds.height/2 + 2 else {
            throw C1Error.invalidRequest("Crop lies outside conservative usable bounds at the requested rotation. Supply a smaller crop or aspectRatio.")
        }
        var result = self; result.crop = rect; result.rotation = angle
        return result
    }
    public func changes(from before: Geometry) -> [String: DoubleDiff] {
        var result: [String: DoubleDiff] = [:]
        for (key, a, b) in [("centerX",before.crop.centerX,crop.centerX),("centerY",before.crop.centerY,crop.centerY),
                            ("width",before.crop.width,crop.width),("height",before.crop.height,crop.height),("rotation",before.rotation,rotation)] where a != b {
            result[key] = DoubleDiff(before: a, after: b)
        }
        return result
    }
    public func matchesTarget(_ target: Geometry) -> Bool {
        zip(crop.values, target.crop.values).allSatisfy { abs($0 - $1) <= 2 } && abs(rotation-target.rotation) <= 0.001
    }
    public func sameContext(as other: Geometry) -> Bool {
        orientation == other.orientation && imageWidth == other.imageWidth && imageHeight == other.imageHeight &&
        flip == other.flip && aspectRatioName == other.aspectRatioName && keystone == other.keystone &&
        lensGeometry == other.lensGeometry && lensProfile == other.lensProfile && hideDistortedAreas == other.hideDistortedAreas && cropOutsideImage == other.cropOutsideImage
    }
}

public struct GeometryMutationResult: Codable {
    public let operationId: String
    public let workingRef: String
    public let before: Geometry
    public let after: Geometry
    public let diff: [String: DoubleDiff]
    public let geometryStateHash: String
    public let isDryRun: Bool
}

/// Bridge keys deliberately avoid Capture One's reserved AppleScript property names.
struct GeometryRecord: Codable, Equatable {
    let cropValues: [Double]
    let rotationDegrees: Double
    let orientationDegrees: Int
    let sourceDimensions: [Double]
    let maximumValues: [Double]
    let flipName: String
    let ratioName: String
    let keystoneValues: [Double]
    let lensValues: [Double]
    let profileName: String
    let hiddenAreas: Bool
    let outsideAllowed: Bool
    var geometry: Geometry? {
        guard cropValues.count == 4, maximumValues.count == 4, sourceDimensions.count == 2,
              keystoneValues.count == 5, lensValues.count == 8 else { return nil }
        func rect(_ a: [Double]) -> CropRect { CropRect(centerX:a[0], centerY:a[1], width:a[2], height:a[3]) }
        return Geometry(crop:rect(cropValues), rotation:rotationDegrees, orientation:orientationDegrees,
                        imageWidth:sourceDimensions[0], imageHeight:sourceDimensions[1], maximumCrop:rect(maximumValues),
                        flip:flipName, aspectRatioName:ratioName.isEmpty ? nil : ratioName,
                        keystone:keystoneValues, lensGeometry:lensValues, lensProfile:profileName,
                        hideDistortedAreas:hiddenAreas, cropOutsideImage:outsideAllowed)
    }
}

extension Geometry {
    var eventSnapshot: NSAppleEventDescriptor {
        func numbers(_ a: [Double]) -> NSAppleEventDescriptor { NSAppleEventDescriptor(list:a.map { NSAppleEventDescriptor(double:$0) }) }
        return NSAppleEventDescriptor(list: [numbers(crop.values), NSAppleEventDescriptor(double:rotation),
            NSAppleEventDescriptor(int32:Int32(orientation)), numbers([imageWidth,imageHeight]),
            NSAppleEventDescriptor(string:flip), NSAppleEventDescriptor(string:aspectRatioName ?? ""),
            numbers(keystone), numbers(lensGeometry), NSAppleEventDescriptor(string:lensProfile),
            NSAppleEventDescriptor(boolean:hideDistortedAreas), NSAppleEventDescriptor(boolean:cropOutsideImage)])
    }
}
