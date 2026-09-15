import Foundation
import ImageIO

/// Capture One's parent-image dimensions can follow the first variant's rotated
/// canvas. Bounds must instead use the original file's intrinsic pixel dimensions.
public enum ImageDimensions {
    public static func read(_ path: String) -> [Double]? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue.isFinite, height.doubleValue.isFinite,
              width.doubleValue > 0, height.doubleValue > 0 else { return nil }
        return [width.doubleValue, height.doubleValue]
    }
}
