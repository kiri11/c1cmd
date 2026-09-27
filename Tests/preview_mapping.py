"""Compare a cropped preview with the matching region of a context preview."""
from pathlib import Path
import struct
import subprocess
import tempfile


def pixels(path):
    # macOS image decoding with no third-party Python packages. BMP rows are BGR.
    with tempfile.TemporaryDirectory(prefix='c1-preview-pixels-') as directory:
        out = Path(directory) / 'preview.bmp'
        subprocess.run(['sips', '-s', 'format', 'bmp', str(path), '--out', str(out)],
                       check=True, capture_output=True)
        data = out.read_bytes()
    offset = struct.unpack_from('<I', data, 10)[0]
    width, height = struct.unpack_from('<ii', data, 18)
    bits = struct.unpack_from('<H', data, 28)[0]
    compression = struct.unpack_from('<I', data, 30)[0]
    assert bits in (24, 32) and compression == 0, (bits, compression)
    stride = ((width * bits + 31) // 32) * 4
    def pixel(x, y):
        x, y = min(width-1, max(0, int(x))), min(abs(height)-1, max(0, int(y)))
        row = abs(height)-1-y if height > 0 else y
        pos = offset + row*stride + x*(bits//8)
        return data[pos:pos+3]
    return width, abs(height), pixel


def check_mapping(context, cropped):
    cw, ch, cp = pixels(context['outputPath'])
    pw, ph, pp = pixels(cropped['outputPath'])
    outer, inner = context['geometry']['crop'], cropped['geometry']['crop']
    left, top = outer['centerX']-outer['width']/2, outer['centerY']+outer['height']/2
    def error(dx=0, dy=0, scale=1):
        # Mean absolute channel error with the mapped crop displaced by context
        # pixels and scaled about its center. Sample away from JPEG edges.
        values = []
        for iy in range(4, 77):
            for ix in range(4, 77):
                u, v = ix/80, iy/80
                x = inner['centerX']+(u-.5)*inner['width']*scale
                y = inner['centerY']-(v-.5)*inner['height']*scale
                px = (x-left)/outer['width']*cw+dx
                py = (top-y)/outer['height']*ch+dy
                values.extend(abs(a-b) for a, b in zip(cp(px, py), pp(u*pw, v*ph)))
        return sum(values)/len(values)
    # The absolute residual follows image texture (resampling of fine detail),
    # so locate the best alignment instead of thresholding the mapped residual.
    shifted = {(dx, dy): error(dx, dy) for dx in range(-4, 5) for dy in range(-4, 5)}
    mapped = shifted[0, 0]
    bx, by = min(shifted, key=shifted.get)
    def vertex(a, b, c):
        return (a-c)/(2*(a-2*b+c)) if a-2*b+c > 0 else 0
    # Parabolic sub-pixel refinement; a search-edge optimum stays at the edge.
    offset = (bx + (vertex(*(shifted[bx+d, by] for d in (-1, 0, 1))) if abs(bx) < 4 else 0),
              by + (vertex(*(shifted[bx, by+d] for d in (-1, 0, 1))) if abs(by) < 4 else 0))
    metrics = {'meanAbsoluteChannelError': mapped, 'alignmentOffsetPixels': offset,
               'maximumOffsetPixels': 1,
               'displacedRatio': mapped/min(e for s, e in shifted.items() if max(map(abs, s)) == 4),
               'scaledRatio': mapped/min(error(scale=s) for s in (.98, .99, 1.01, 1.02)),
               'unrelatedRatio': mapped/error(60, 40), 'sampledPixels': 73*73}
    # Correct mappings on qualified fixtures stay within .8 context pixels
    # (about 3 native pixels) and have ratios below .73; injected 4-7 native
    # pixel shifts and 1% scale errors fail. The ratios reject pairs too
    # featureless to locate an optimum.
    assert (max(map(abs, offset)) <= metrics['maximumOffsetPixels']
            and metrics['scaledRatio'] < 1 and metrics['displacedRatio'] < .85
            and metrics['unrelatedRatio'] < .35), ('Preview/crop coordinate mismatch', metrics)
    return metrics
