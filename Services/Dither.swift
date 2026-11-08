import CoreGraphics
import Foundation
import UIKit

/// Turns album art into a tiny 1-bit bitmap for the dial mode's monochrome
/// screen, using Atkinson error diffusion (crisp, high-contrast results at
/// small sizes). Pure and off-main-safe.
nonisolated enum Dither {

    /// `side × side` booleans, row-major; true = lit pixel.
    static func bitmap(from image: UIImage, side: Int) -> [Bool]? {
        guard side > 0, let gray = grayscale(image, side: side) else { return nil }
        return atkinson(gray, width: side, height: side)
    }

    /// Area-averaged greyscale (0…255) at `side × side`, contrast-stretched.
    static func grayscale(_ image: UIImage, side: Int) -> [Double]? {
        guard let cg = image.cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: side * side)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return nil }
        var values = bytes.map(Double.init)
        // Stretch to the full range so dark covers still show detail.
        if let lo = values.min(), let hi = values.max(), hi - lo > 8 {
            values = values.map { ($0 - lo) / (hi - lo) * 255 }
        }
        return values
    }

    /// Atkinson dithering: spreads 6/8 of the error to six neighbours.
    static func atkinson(_ input: [Double], width: Int, height: Int) -> [Bool] {
        var v = input
        var out = [Bool](repeating: false, count: width * height)
        let neighbours = [(1, 0), (2, 0), (-1, 1), (0, 1), (1, 1), (0, 2)]
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let old = v[i]
                let lit = old >= 128
                out[i] = lit
                let err = (old - (lit ? 255 : 0)) / 8
                for (dx, dy) in neighbours {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, nx < width, ny < height { v[ny * width + nx] += err }
                }
            }
        }
        return out
    }

    /// Loads an image from a file or https URL and dithers it.
    static func load(url: URL, side: Int) async -> [Bool]? {
        let data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url, options: .mappedIfSafe)
        } else {
            data = try? await URLSession.shared.data(from: url).0
        }
        guard let data, let image = UIImage(data: data) else { return nil }
        return bitmap(from: image, side: side)
    }
}
