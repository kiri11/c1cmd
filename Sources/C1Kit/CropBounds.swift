import Foundation

/// The area a crop may cover, as four corners in Capture One's crop coordinates (pixels of the
/// oriented, rotated canvas, y up), clockwise from the top left as viewed.
public struct CropBounds: Equatable {
    public enum Source: String {
        /// The rotated image itself: exact.
        case image
        /// Capture One's `maximum crop`, used when keystone, lens corrections or flip change the usable
        /// area in ways only Capture One computes. It keeps the image's proportions, so it is narrower
        /// than the true area for other ratios.
        case maximumCrop
    }

    public static let cornerNames = ["top left", "top right", "bottom right", "bottom left"]
    /// Capture One's crop and image sizes differ by up to two pixels.
    public static let tolerance = 2.0

    public let corners: [[Double]]
    public let source: Source

    public init(corners: [[Double]], source: Source) { self.corners = corners; self.source = source }

    public init?(state: VariantState) {
        let a = state.adjustments, lens = state.lensCorrection
        func value(_ fields: [String: JSONValue], _ name: String) -> Double { fields[name]?.number ?? 0 }
        let corrected = ["keystone vertical", "keystone horizontal", "keystone skew", "keystone aspect"].contains { value(a, $0) != 0 }
            || ["distortion", "tilt", "shift"].contains { value(lens, $0) != 0 }
            || (a["flip"].map { $0 != .string("none") } ?? false)
        if corrected {
            guard let crop = state.maximumCrop, crop.count == 4 else { return nil }
            self = Self.rectangle(crop, source: .maximumCrop)
            return
        }
        guard let size = state.imageSize, size.count == 2, size[0] > 0, size[1] > 0 else { return nil }
        let quarterTurn = Int(value(a, "orientation")) % 180 != 0
        let (w, h) = quarterTurn ? (size[1], size[0]) : (size[0], size[1])
        let r = value(a, "rotation") * .pi / 180
        let c = cos(r), s = sin(r)
        let center = ((w * abs(c) + h * abs(s)) / 2, (w * abs(s) + h * abs(c)) / 2)
        // The image turns clockwise as viewed by `rotation` degrees about the canvas centre.
        corners = [(-w / 2, h / 2), (w / 2, h / 2), (w / 2, -h / 2), (-w / 2, -h / 2)].map { x, y in
            [center.0 + x * c + y * s, center.1 - x * s + y * c]
        }
        source = .image
    }

    static func rectangle(_ rect: [Double], source: Source) -> CropBounds {
        let (x, y, w, h) = (rect[0], rect[1], rect[2] / 2, rect[3] / 2)
        return CropBounds(corners: [[x - w, y + h], [x + w, y + h], [x + w, y - h], [x - w, y - h]], source: source)
    }

    /// The crop's corners outside the bounds by more than the tolerance, with how far outside.
    public func crossings(_ crop: [Double]) -> [(corner: String, distance: Double)] {
        CropBounds.rectangle(crop, source: source).corners.enumerated().compactMap { index, point in
            let distance = outside(point)
            return distance > Self.tolerance ? (Self.cornerNames[index], distance) : nil
        }
    }

    /// The largest distance from the point to the outside of any edge; positive means outside.
    func outside(_ point: [Double]) -> Double {
        (0..<4).map { index in
            let a = corners[index], b = corners[(index + 1) % 4]
            let edge = (b[0] - a[0], b[1] - a[1])
            let length = hypot(edge.0, edge.1)
            guard length > 0 else { return -Double.infinity }
            // Clockwise corners with y up: the inside lies to the right of each edge.
            return (edge.0 * (point[1] - a[1]) - edge.1 * (point[0] - a[0])) / length
        }.max()!
    }

    public var json: JSONValue {
        var fields: [String: JSONValue] = ["source": .string(source.rawValue)]
        for (name, corner) in zip(Self.cornerNames, corners) {
            fields[name] = .array(corner.map { .double(($0 * 10).rounded() / 10) })
        }
        return .object(fields)
    }
}

extension VariantState {
    public var cropBounds: CropBounds? { CropBounds(state: self) }
}
