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

/// Absolute keystone controls. Omitted fields retain their current values.
public struct KeystoneAdjustments: Codable, Equatable {
    public var amount: Double?
    public var vertical: Double?
    public var horizontal: Double?
    public var skew: Double?
    public var aspect: Double?
    public static let fields = ["amount", "vertical", "horizontal", "skew", "aspect"]
    public static let ranges: [ClosedRange<Double>] = [10...120, -75...75, -75...75, -45...45, -50...100]
    public init(amount: Double? = nil, vertical: Double? = nil, horizontal: Double? = nil, skew: Double? = nil, aspect: Double? = nil) {
        self.amount = amount; self.vertical = vertical; self.horizontal = horizontal; self.skew = skew; self.aspect = aspect
    }
    public var values: [Double?] { [amount, vertical, horizontal, skew, aspect] }
    public func validate() throws {
        guard values.contains(where: { $0 != nil }) else { throw C1Error.invalidRequest("Provide at least one keystone control.") }
        for (index, value) in values.enumerated() {
            if let value {
                guard value.isFinite, Self.ranges[index].contains(value), index != 0 || value.rounded() == value else {
                    throw C1Error.invalidRequest("Keystone \(Self.fields[index]) must be within \(Self.ranges[index]); amount must be an integer.")
                }
            }
        }
    }
    public func applying(to current: [Double]) throws -> [Double] {
        try validate()
        guard current.count == Self.fields.count else { throw C1Error.invalidRequest("Incomplete keystone state.") }
        return zip(values, current).map { $0 ?? $1 }
    }
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

    public var hasLensDistortion: Bool { lensGeometry.first.map { $0 != 0 } ?? false }
    public var hasPerspectiveOrMovements: Bool {
        keystone.dropFirst().contains { $0 != 0 } || lensGeometry.dropFirst(2).contains { $0 != 0 }
    }
    public var requiresNativeBounds: Bool { hasLensDistortion || hasPerspectiveOrMovements }

    public var unsupportedReason: String? {
        guard [0, 90, 180, 270].contains(orientation), flip == "none" else { return "Orientation or flip is not qualified for geometry writes." }
        guard keystone.count == 5, lensGeometry.count == 8, !cropOutsideImage else {
            return "Incomplete geometry or crop-outside-image settings require manual review."
        }
        guard (0...100).contains(lensGeometry[0]) else { return "Lens distortion amounts outside 0...100 are not qualified." }
        guard maximumCrop.values.allSatisfy({ $0.isFinite }), keystone.allSatisfy({ $0.isFinite }), lensGeometry.allSatisfy({ $0.isFinite }),
              imageWidth.isFinite, imageHeight.isFinite, imageWidth > 0, imageHeight > 0,
              maximumCrop.width > 0, maximumCrop.height > 0,
              rotation.isFinite, abs(rotation) <= 45, crop.values.allSatisfy({ $0.isFinite }), crop.width > 0, crop.height > 0 else {
            return "Image geometry is unavailable or outside the qualified range."
        }
        return nil
    }

    /// Native reported bounds for corrected geometry; perspective fits may be
    /// further reduced by Capture One. Otherwise a conservative centered rectangle
    /// inside the rotated image, excluding triangular corner areas.
    public func safeBounds(rotation angle: Double) throws -> CropRect {
        // Native bounds are valid only in the currently observed canvas. A new
        // corrected geometry rotation must obtain fresh bounds inside the journaled handler.
        if requiresNativeBounds {
            guard angle == rotation else { throw C1Error.invalidRequest("Native corrected geometry bounds belong to the current rotation only.") }
            return maximumCrop
        }
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
        // Independent from the legacy tonal hash; includes mutable geometry and preserved lens/orientation context.
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
        guard !requiresNativeBounds || angle == rotation else {
            throw C1Error.invalidRequest("Corrected geometry bounds at a new rotation require native execution; a dry run cannot predict them.")
        }
        if requiresNativeBounds && requested == nil && aspectRatio == nil { return self }
        let bounds = try safeBounds(rotation: angle)
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
        for (index, name) in KeystoneAdjustments.fields.enumerated() where keystone.count == 5 && before.keystone.count == 5 {
            if keystone[index] != before.keystone[index] { result["keystone." + name] = DoubleDiff(before: before.keystone[index], after: keystone[index]) }
        }
        return result
    }
    public func matchesTarget(_ target: Geometry) -> Bool {
        zip(crop.values, target.crop.values).allSatisfy { abs($0 - $1) <= 2 } &&
        abs(rotation-target.rotation) <= 0.001 && keystone.count == target.keystone.count &&
        zip(keystone, target.keystone).allSatisfy { abs($0 - $1) <= 0.001 }
    }
    public func sameContext(as other: Geometry, includingKeystone: Bool = true) -> Bool {
        orientation == other.orientation && imageWidth == other.imageWidth && imageHeight == other.imageHeight &&
        flip == other.flip && aspectRatioName == other.aspectRatioName && (!includingKeystone || keystone == other.keystone) &&
        lensGeometry == other.lensGeometry && lensProfile == other.lensProfile && hideDistortedAreas == other.hideDistortedAreas && cropOutsideImage == other.cropOutsideImage
    }
}

/// Retained before native dispatch when the final crop depends on bounds that
/// Capture One can only report after rotation or keystone setters. No fabricated target rectangle.
public struct GeometryRequest: Codable, Equatable {
    public let crop: CropRect?
    public let rotation: Double
    public let aspectRatio: Double?
    public let keystone: KeystoneAdjustments?

    public init(crop: CropRect?, rotation: Double, aspectRatio: Double?, keystone: KeystoneAdjustments? = nil) throws {
        try keystone?.validate()
        guard crop == nil || aspectRatio == nil else { throw C1Error.invalidRequest("Provide crop or aspectRatio, not both.") }
        guard rotation.isFinite, abs(rotation) <= 45 else { throw C1Error.invalidRequest("Rotation must be finite and between -45 and 45 degrees.") }
        if let crop {
            guard crop.values.allSatisfy({ $0.isFinite }), crop.width >= 1, crop.height >= 1 else { throw C1Error.invalidRequest("Crop dimensions must be positive finite pixels.") }
        }
        if let aspectRatio {
            guard aspectRatio.isFinite, aspectRatio > 0 else { throw C1Error.invalidRequest("aspectRatio must be finite and positive.") }
        }
        self.crop = crop; self.rotation = rotation; self.aspectRatio = aspectRatio; self.keystone = keystone
    }
}

struct CorrectedGeometryResult: Decodable {
    let targetCropValues: [Double]
    let boundsValues: [Double]
    let fittedCropValues: [Double]?
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
            NSAppleEventDescriptor(int32:Int32(orientation)),
            NSAppleEventDescriptor(string:flip), NSAppleEventDescriptor(string:aspectRatioName ?? ""),
            numbers(keystone), numbers(lensGeometry), NSAppleEventDescriptor(string:lensProfile),
            NSAppleEventDescriptor(boolean:hideDistortedAreas), NSAppleEventDescriptor(boolean:cropOutsideImage)])
    }
}
