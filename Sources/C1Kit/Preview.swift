import CoreGraphics
import CryptoKit
import Foundation

/// A rectangle in Capture One's crop convention, as `set` takes it: pixels of the oriented, rotated
/// canvas, centre and size, y up.
public struct CanvasRect: Codable, Equatable {
    public let centerX, centerY, width, height: Double

    public init(centerX: Double, centerY: Double, width: Double, height: Double) {
        self.centerX = centerX; self.centerY = centerY; self.width = width; self.height = height
    }

    init?(_ values: [Double]?) {
        guard let values, values.count == 4 else { return nil }
        self.init(centerX: values[0], centerY: values[1], width: values[2], height: values[3])
    }

    var array: [Double] { [centerX, centerY, width, height] }
    var left: Double { centerX - width / 2 }
    var top: Double { centerY + height / 2 }

    var json: JSONValue {
        .object(["centerX": .double(Self.tenth(centerX)), "centerY": .double(Self.tenth(centerY)),
                 "width": .double(Self.tenth(width)), "height": .double(Self.tenth(height))])
    }

    static func tenth(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}

/// How canvas pixels land in a render of the canvas area `area`: x' = (x − left) × scale, y' = (top − y) × scale,
/// with the render's origin at its top left.
public struct CanvasMapping: Equatable {
    public let scale, left, top: Double

    public init(area: CanvasRect, renderWidth: Int) {
        scale = Double(renderWidth) / area.width; left = area.left; top = area.top
    }

    public func point(_ x: Double, _ y: Double) -> (x: Double, y: Double) { ((x - left) * scale, (top - y) * scale) }

    public func rect(_ rect: CanvasRect) -> CGRect {
        let origin = point(rect.left, rect.top)
        return CGRect(x: origin.x, y: origin.y, width: rect.width * scale, height: rect.height * scale)
    }

    var json: JSONValue { .object(["scale": .double(scale), "left": .double(left), "top": .double(top)]) }
}

/// A detail region of the cropped preview, as fractions of its width and height from its top left.
public struct Region: Codable, Equatable {
    public let x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }

    func validate() throws {
        guard [x, y, width, height].allSatisfy(\.isFinite), x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1 + 1e-9, y + height <= 1 + 1e-9 else {
            throw C1Failure(.invalidArguments, "region needs x, y ≥ 0, width, height > 0 and x + width, y + height ≤ 1, as fractions of the cropped preview; got \(x), \(y), \(width), \(height).")
        }
    }

    /// The same area of the canvas, inside `crop`.
    func canvas(in crop: CanvasRect) -> CanvasRect {
        let w = width * crop.width, h = height * crop.height
        return CanvasRect(centerX: crop.left + x * crop.width + w / 2, centerY: crop.top - y * crop.height - h / 2, width: w, height: h)
    }
}

public struct PreviewArguments: Decodable {
    public var id: VariantID
    public var size: Int?
    public var fullFrame: Bool?
    public var region: Region?
    public var scale: Double?
    public var timeout: Double?

    public init(id: VariantID, size: Int? = nil, fullFrame: Bool? = nil, region: Region? = nil, scale: Double? = nil, timeout: Double? = nil) {
        self.id = id; self.size = size; self.fullFrame = fullFrame; self.region = region; self.scale = scale; self.timeout = timeout
    }
}

public struct CropPreviewArguments: Decodable {
    public var id: VariantID
    public var candidates: [CanvasRect]
    public var size: Int?
    public var refresh: Bool?
    public var timeout: Double?

    public init(id: VariantID, candidates: [CanvasRect], size: Int? = nil, refresh: Bool? = nil, timeout: Double? = nil) {
        self.id = id; self.candidates = candidates; self.size = size; self.refresh = refresh; self.timeout = timeout
    }
}

enum Preview {
    static let sizes = 200...3000
    static let defaultSize = 1500
    static let scales = 0.05...1.0
    static let regionCap = 2048
    /// Far beyond any sensor, so every pixel count derived from a candidate fits an Int.
    static let candidateLimit = 1e6
    static let timeouts = 1.0...600.0
    static let defaultTimeout = 120.0
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    static let candidates = 1...6
    /// Full-frame renders cut for `crop_preview` are at least this large, so each candidate keeps detail.
    static let minimumFrame = 1500

    static func size(_ size: Int?) throws -> Int {
        let size = size ?? defaultSize
        guard sizes.contains(size) else { throw C1Failure(.invalidArguments, "size must be \(sizes.lowerBound)–\(sizes.upperBound) px, got \(size).") }
        return size
    }

    static func timeout(_ timeout: Double?) throws -> Double {
        let timeout = timeout ?? defaultTimeout
        guard timeouts.contains(timeout) else {
            throw C1Failure(.invalidArguments, "timeout must be \(Int(timeouts.lowerBound))–\(Int(timeouts.upperBound)) seconds, got \(timeout).")
        }
        return timeout
    }

    /// The canvas area a full-frame export renders. `export crop method: ignore` renders the default crop, which is
    /// Capture One's `maximum crop`: the largest centred rectangle of the image's proportions inside the rotated image,
    /// not the whole canvas. c1 reads `maximum crop` only for corrections it cannot compute, so otherwise it computes it.
    static func fullFrameArea(_ state: VariantState) -> CanvasRect? {
        if let crop = CanvasRect(state.maximumCrop) { return crop }
        guard let canvas = state.canvasSize, canvas.count == 2, canvas[0] > 0, canvas[1] > 0 else { return nil }
        let r = (state.adjustments["rotation"]?.number ?? 0) * .pi / 180
        let c = abs(cos(r)), s = abs(sin(r))
        let determinant = c * c - s * s
        guard determinant > 0.05 else { return nil }
        let (W, H) = (canvas[0], canvas[1])
        let w = (W * c - H * s) / determinant, h = (H * c - W * s) / determinant
        let aspect = w / h
        let width = min(w / (c + s / aspect), h / (s + c / aspect))
        return CanvasRect(centerX: W / 2, centerY: H / 2, width: width, height: width / aspect)
    }

    /// Fields that do not change a full-frame render; a cropped render differs only in rating and color tag.
    static func rendersAlike(_ name: String, cropped: Bool) -> Bool {
        name == "rating" || name == "color tag" || (!cropped && (name == "crop" || name.hasPrefix("crop ")))
    }

    /// Names a render of `state` at `longEdge`: equal for states that render alike.
    static func cacheKey(_ state: VariantState, longEdge: Int, cropped: Bool = false) -> String {
        guard case .object(var fields) = state.json else { return "" }
        fields["variant"] = .object(state.variant.filter { !rendersAlike($0.key, cropped: cropped) })
        fields["longEdge"] = .int(Int64(longEdge))
        let digest = SHA256.hash(data: Data(JSONValue.object(fields).encoded().utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The names c1 gives its files. A Catalog's output folder may point into the previews folder, so the
    /// photographer's own exports can land beside them; prune deletes only these.
    static let ownName = try! Regex(#"(\d+-(full|crop|render|region|candidates)-\d+-[0-9a-f]{8}|(frame|tile)-\d+-[0-9a-f]{16}|thumb-\d+-\d+|sheet-\d+-\d+-[0-9a-f]{8})\.jpg"#)

    /// Deletes c1's preview files older than the retention, and folders left empty.
    static func prune(_ root: URL, now: Date) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        for folder in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
            var kept = 0
            for file in files {
                guard (try? ownName.wholeMatch(in: file.lastPathComponent)) != nil,
                      let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      now.timeIntervalSince(values.contentModificationDate ?? now) > retention else { kept += 1; continue }
                try? manager.removeItem(at: file)
            }
            if kept == 0 { try? manager.removeItem(at: folder) }
        }
    }

    /// Waits for Capture One to finish writing `file`: present, the same size twice in a row, and decodable.
    static func waitForJPEG(_ file: URL, timeout: Double) throws -> CGImage {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSize: Int?
        repeat {
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? nil
            if let size, size > 0, size == lastSize, let image = Images.decodeJPEG(file) { return image }
            lastSize = size
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw C1Failure(.timeout, "Capture One did not finish the export within \(Int(timeout)) seconds; it may still land at \(file.path).",
                        hint: "The variant was not written. Check that path later, or call again with a longer timeout.", outcomeUnknown: true)
    }

    static func checkLongEdge(_ image: CGImage, _ longEdge: Int, file: URL) throws {
        guard abs(max(image.width, image.height) - longEdge) <= 1 else {
            throw C1Failure(.scriptError, "The export at \(file.path) is \(image.width)×\(image.height) px; c1 asked for a long edge of \(longEdge) px.")
        }
    }

    /// Lays candidates out in rows of up to three at one height, so the whole image's long edge is `size`.
    static func layout(_ aspects: [Double], size: Int, gutter: Double = 8) -> (width: Int, height: Int, cells: [CGRect]) {
        let rowCount = (aspects.count + 2) / 3
        let perRow = (aspects.count + rowCount - 1) / rowCount
        let rows = stride(from: 0, to: aspects.count, by: perRow).map { Array($0..<min($0 + perRow, aspects.count)) }
        let side = Double(size)
        let fromWidth = rows.map { row in (side - Double(row.count + 1) * gutter) / row.reduce(0) { $0 + aspects[$1] } }.min()!
        let fromHeight = (side - Double(rows.count + 1) * gutter) / Double(rows.count)
        let height = min(fromWidth, fromHeight).rounded(.down)
        var cells: [CGRect] = []
        var widest = 0.0
        for (number, row) in rows.enumerated() {
            var x = gutter
            let y = gutter + Double(number) * (height + gutter)
            for index in row {
                let width = (aspects[index] * height).rounded()
                cells.append(CGRect(x: x, y: y, width: width, height: height))
                x += width + gutter
            }
            widest = max(widest, x)
        }
        return (Int(widest), Int(gutter + Double(rows.count) * (height + gutter)), cells)
    }
}

extension Service {
    var previewsRoot: URL { caches.appendingPathComponent("previews") }

    struct Rendered {
        let state: VariantState
        let image: CGImage
        let file: URL
        let cached: Bool
        var warnings: [String] = []
    }

    /// Reads the variant and starts its export inside the queue, then waits for the file outside it, so other
    /// calls run while Capture One renders. `plan` names the long edge and file; an existing file there is reused.
    func render(_ id: VariantID, fullFrame: Bool, timeout: Double,
                plan: (VariantState) throws -> (longEdge: Int, name: String, reuse: Bool)) throws -> Rendered {
        Preview.prune(previewsRoot, now: now())
        let (state, request, cached, outputSet) = try queue.run { () throws -> (VariantState, ExportRequest, CGImage?, Bool) in
            let read = try liveRead([id])
            let state: VariantState
            switch read.results[id] ?? .failed("Capture One returned no result for this id.") {
            case .state(let found): state = found
            case .notFound: throw C1Failure(.notFound, "Capture One has no variant \(id) in this document.")
            case .failed(let reason): throw C1Failure(.scriptError, "Reading variant \(id) failed: \(reason)")
            }
            let (longEdge, name, reuse) = try plan(state)
            let file = previewsRoot.appendingPathComponent(read.database.documentUUID).appendingPathComponent(name + ".jpg")
            let request = ExportRequest(target: ReadTarget(id, read.routes[id]!), longEdge: longEdge, fullFrame: fullFrame, file: file)
            if reuse, let image = Images.decodeJPEG(file) {
                try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: file.path)
                return (state, request, image, false)
            }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let outputSet = try captureOne.export(request, in: read.document)
            return (state, request, nil, outputSet)
        }
        if let cached { return Rendered(state: state, image: cached, file: request.file, cached: true) }
        let image = try Preview.waitForJPEG(request.file, timeout: timeout)
        try Preview.checkLongEdge(image, request.longEdge, file: request.file)
        let warnings = outputSet ? ["The Catalog's output folder was unset or missing, and Capture One refuses every export then, so c1 set it to \(request.file.deletingLastPathComponent().path). Choose another in Capture One's Output tool if you like."] : []
        return Rendered(state: state, image: image, file: request.file, cached: false, warnings: warnings)
    }

    static func uniqueName(_ id: VariantID, _ kind: String, _ longEdge: Int) -> String {
        "\(id)-\(kind)-\(longEdge)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// Deletes `id`'s cached full-frame renders and sheet tiles. Their cache keys hash the readable settings, which
    /// leave out mask pixels, so a mask edit would otherwise reuse a stale render.
    func dropCachedRenders(_ id: VariantID, documentUUID: String) {
        let folder = previewsRoot.appendingPathComponent(documentUUID)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix("frame-\(id)-") || name.hasPrefix("tile-\(id)-") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: preview

    public func preview(_ arguments: PreviewArguments) throws -> JSONValue {
        let timeout = try Preview.timeout(arguments.timeout)
        let fullFrame = arguments.fullFrame ?? false
        if let region = arguments.region {
            guard arguments.size == nil, !fullFrame else {
                throw C1Failure(.invalidArguments, "region takes scale, not size or fullFrame: it is a part of the cropped preview at scale × full resolution.")
            }
            try region.validate()
            let scale = arguments.scale ?? 1
            guard Preview.scales.contains(scale) else {
                throw C1Failure(.invalidArguments, "scale must be \(Preview.scales.lowerBound)–\(Preview.scales.upperBound), got \(scale).")
            }
            return try regionPreview(arguments.id, region: region, scale: scale, timeout: timeout)
        }
        guard arguments.scale == nil else { throw C1Failure(.invalidArguments, "scale goes with region.") }
        let size = try Preview.size(arguments.size)
        let rendered = try render(arguments.id, fullFrame: fullFrame, timeout: timeout) { _ in
            (size, Self.uniqueName(arguments.id, fullFrame ? "full" : "crop", size), false)
        }
        var output: [String: JSONValue] = ["id": .string(arguments.id.description), "path": .string(rendered.file.path),
                                           "width": .int(Int64(rendered.image.width)), "height": .int(Int64(rendered.image.height))]
        if fullFrame {
            output["fullFrame"] = Self.fullFrameJSON(rendered)
        }
        if !rendered.warnings.isEmpty { output["warnings"] = .array(rendered.warnings.map(JSONValue.string)) }
        return .object(output)
    }

    /// Where the canvas, the current crop and cropBounds land in a full-frame render.
    static func fullFrameJSON(_ rendered: Rendered) -> JSONValue {
        guard let area = Preview.fullFrameArea(rendered.state),
              abs(area.width / area.height - Double(rendered.image.width) / Double(rendered.image.height)) < 0.01 else {
            return .object(["warning": .string("The render's proportions differ from the canvas Capture One reported, so c1 gives no mapping.")])
        }
        let mapping = CanvasMapping(area: area, renderWidth: rendered.image.width)
        var fields: [String: JSONValue] = ["mapping": mapping.json]
        if let crop = CanvasRect(rendered.state.variant["crop"]?.array?.compactMap(\.number)) {
            fields["currentCrop"] = pixelJSON(mapping.rect(crop))
        }
        if let bounds = rendered.state.cropBounds {
            fields["cropBounds"] = .array(bounds.corners.map { corner in
                let point = mapping.point(corner[0], corner[1])
                return .array([.double(CanvasRect.tenth(point.x)), .double(CanvasRect.tenth(point.y))])
            })
        }
        return .object(fields)
    }

    static func pixelJSON(_ rect: CGRect) -> JSONValue {
        .object(["x": .double(CanvasRect.tenth(rect.minX)), "y": .double(CanvasRect.tenth(rect.minY)),
                 "width": .double(CanvasRect.tenth(rect.width)), "height": .double(CanvasRect.tenth(rect.height))])
    }

    func regionPreview(_ id: VariantID, region: Region, scale: Double, timeout: Double) throws -> JSONValue {
        var crop: CanvasRect?
        let rendered = try render(id, fullFrame: false, timeout: timeout) { state in
            guard let found = CanvasRect(state.variant["crop"]?.array?.compactMap(\.number)), found.width > 0, found.height > 0 else {
                throw C1Failure(.scriptError, "Capture One reported no crop for variant \(id).")
            }
            guard region.width * scale * found.width >= 1, region.height * scale * found.height >= 1 else {
                throw C1Failure(.invalidArguments, "region covers \(region.width * scale * found.width) × \(region.height * scale * found.height) px at scale \(scale); it needs at least 1 px each way.",
                                hint: "Widen the region or raise scale.")
            }
            crop = found
            let longEdge = max(1, Int((scale * max(found.width, found.height)).rounded()))
            return (longEdge, Self.uniqueName(id, "render", longEdge), false)
        }
        defer { try? FileManager.default.removeItem(at: rendered.file) }
        let image = rendered.image
        let cut = CGRect(x: region.x * Double(image.width), y: region.y * Double(image.height),
                         width: region.width * Double(image.width), height: region.height * Double(image.height))
        let shrink = min(1, Double(Preview.regionCap) / max(cut.width, cut.height))
        let width = max(1, Int((cut.width * shrink).rounded())), height = max(1, Int((cut.height * shrink).rounded()))
        let canvas = Images.Canvas(width: width, height: height, background: Images.background)
        canvas.draw(image, from: cut, in: CGRect(x: 0, y: 0, width: width, height: height))
        let file = rendered.file.deletingLastPathComponent().appendingPathComponent(Self.uniqueName(id, "region", max(width, height)) + ".jpg")
        try Images.writeJPEG(canvas.image(), to: file)
        let area = region.canvas(in: crop!)
        var output: [String: JSONValue] = ["id": .string(id.description), "path": .string(file.path),
                                           "width": .int(Int64(width)), "height": .int(Int64(height)),
                                           "region": .object(["crop": area.json, "scale": .double(Double(width) / area.width)])]
        if !rendered.warnings.isEmpty { output["warnings"] = .array(rendered.warnings.map(JSONValue.string)) }
        return .object(output)
    }

    // MARK: crop_preview

    public func cropPreview(_ arguments: CropPreviewArguments) throws -> JSONValue {
        let candidates = arguments.candidates
        guard Preview.candidates.contains(candidates.count) else {
            throw C1Failure(.invalidArguments, "crop_preview takes \(Preview.candidates.lowerBound)–\(Preview.candidates.upperBound) candidates, got \(candidates.count).")
        }
        for (index, candidate) in candidates.enumerated()
        where !(candidate.array.allSatisfy { abs($0) <= Preview.candidateLimit } && candidate.width >= 1 && candidate.height >= 1) {
            throw C1Failure(.invalidArguments, "Candidate \(index + 1) needs a width and height of at least 1 px and coordinates within ±\(Int(Preview.candidateLimit)) px.")
        }
        let size = try Preview.size(arguments.size)
        let timeout = try Preview.timeout(arguments.timeout)
        let frameEdge = max(size, Preview.minimumFrame)
        let rendered = try render(arguments.id, fullFrame: true, timeout: timeout) { state in
            guard let bounds = state.cropBounds, let area = Preview.fullFrameArea(state) else {
                throw C1Failure(.scriptError, "Capture One reported no image size for variant \(arguments.id), so c1 cannot check the candidates.")
            }
            let rendered = CropBounds.rectangle(area.array, source: .maximumCrop)
            for (index, candidate) in candidates.enumerated() {
                func detail(_ crossings: [(corner: String, distance: Double)]) -> String {
                    crossings.map { "the \($0.corner) corner by \(Int($0.distance.rounded(.up))) px" }.joined(separator: ", ")
                }
                let outside = bounds.crossings(candidate.array)
                guard outside.isEmpty else {
                    throw C1Failure(.invalidArguments, "Candidate \(index + 1) lies outside cropBounds (\(bounds.source.rawValue)): \(detail(outside)).",
                                    hint: "Read cropBounds with get and choose candidates inside it.")
                }
                // The full frame is the default crop, so a rotated image's slivers beyond it are not rendered.
                let unrendered = rendered.crossings(candidate.array)
                guard unrendered.isEmpty else {
                    throw C1Failure(.invalidArguments, "Candidate \(index + 1) reaches past the full-frame render, the largest centred rectangle of the image's proportions \(area.json.encoded()): \(detail(unrendered)).",
                                    hint: "Preview this crop with set and preview instead, or move it inside that rectangle.")
                }
            }
            return (frameEdge, "frame-\(arguments.id)-\(Preview.cacheKey(state, longEdge: frameEdge))", !(arguments.refresh ?? false))
        }
        guard let area = Preview.fullFrameArea(rendered.state),
              abs(area.width / area.height - Double(rendered.image.width) / Double(rendered.image.height)) < 0.01 else {
            throw C1Failure(.scriptError, "The full-frame render at \(rendered.file.path) does not have the canvas's proportions, so c1 cannot place the candidates.")
        }
        let mapping = CanvasMapping(area: area, renderWidth: rendered.image.width)
        let bounds = CGRect(x: 0, y: 0, width: rendered.image.width, height: rendered.image.height)
        let cuts = candidates.map { mapping.rect($0).intersection(bounds) }
        let layout = Preview.layout(candidates.map { $0.width / $0.height }, size: size)
        let canvas = Images.Canvas(width: layout.width, height: layout.height, background: Images.background)
        for (index, (cut, cell)) in zip(cuts, layout.cells).enumerated() {
            canvas.draw(rendered.image, from: cut, in: cell)
            let badge = CGRect(x: cell.minX, y: cell.minY, width: max(18, cell.height * 0.09), height: max(18, cell.height * 0.09))
            canvas.fill(badge, Images.amber)
            canvas.text("\(index + 1)", in: badge, size: badge.height * 0.7, color: Images.darkText, centered: true)
        }
        let file = rendered.file.deletingLastPathComponent().appendingPathComponent(Self.uniqueName(arguments.id, "candidates", size) + ".jpg")
        try Images.writeJPEG(canvas.image(), to: file)
        var output: [String: JSONValue] = [
            "id": .string(arguments.id.description), "path": .string(file.path),
            "width": .int(Int64(layout.width)), "height": .int(Int64(layout.height)), "cached": .bool(rendered.cached),
            "candidates": .array(zip(candidates, layout.cells).enumerated().map { index, pair in
                .object(["number": .int(Int64(index + 1)), "crop": pair.0.json, "rect": Self.pixelJSON(pair.1)])
            }),
        ]
        if !rendered.warnings.isEmpty { output["warnings"] = .array(rendered.warnings.map(JSONValue.string)) }
        return .object(output)
    }
}
