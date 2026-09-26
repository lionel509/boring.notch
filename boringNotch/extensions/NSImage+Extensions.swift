//
//  Image2Color.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import SwiftUI
import AppKit
import Cocoa
import Foundation
import CoreImage
import CoreGraphics
import CoreImage.CIFilterBuiltins

extension NSImage {

    
    /// The cover's dominant *vivid* colour, not its arithmetic mean.
    ///
    /// A mean of a dusky cover is a muddy grey-green whatever the art looks like: teal sky
    /// plus dark foreground plus pink cloud averages to #233840. Instead, pixels vote into
    /// 24 hue buckets weighted by saturation x brightness, and the heaviest bucket's own
    /// mean colour wins. Covers with no real colour fall back to a neutral grey.
    func averageColor(completion: @escaping (NSColor?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let color = self.dominantColor()
            DispatchQueue.main.async { completion(color) }
        }
    }

    private func dominantColor() -> NSColor? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // 48x48 is plenty to find a dominant hue, and the draw does the downsampling.
        let side = 48
        guard let context = CGContext(data: nil, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        let buckets = 24
        var weight = [CGFloat](repeating: 0, count: buckets)
        var rgb = [(CGFloat, CGFloat, CGFloat)](repeating: (0, 0, 0), count: buckets)
        for i in 0..<(side * side) {
            let r = CGFloat(bytes[i * 4]) / 255, g = CGFloat(bytes[i * 4 + 1]) / 255, b = CGFloat(bytes[i * 4 + 2]) / 255
            let maxC = max(r, g, b), minC = min(r, g, b)
            let sat = maxC == 0 ? 0 : (maxC - minC) / maxC
            guard sat > 0.15, maxC > 0.15 else { continue }
            let hue = NSColor(red: r, green: g, blue: b, alpha: 1).hueComponent
            let k = min(Int(hue * CGFloat(buckets)), buckets - 1)
            let w = sat * maxC
            weight[k] += w
            rgb[k].0 += r * w; rgb[k].1 += g * w; rgb[k].2 += b * w
        }

        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }),
              weight[best] > CGFloat(side * side) * 0.01
        else { return NSColor(white: 0.5, alpha: 1) }
        let w = weight[best]
        return NSColor(red: rgb[best].0 / w, green: rgb[best].1 / w, blue: rgb[best].2 / w, alpha: 1)
    }
    
    func getBrightness() -> CGFloat {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return 0
        }
        
        let inputImage = CIImage(cgImage: cgImage)
        
        let filter = CIFilter.areaAverage()
        filter.inputImage = inputImage
        filter.extent = inputImage.extent
        
        guard let outputImage = filter.outputImage else {
            return 0
        }
        
        let context = CIContext(options: nil)
        
        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(outputImage,
                       toBitmap: &bitmap,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        
        let brightness = (0.2126 * CGFloat(bitmap[0]) + 0.7152 * CGFloat(bitmap[1]) + 0.0722 * CGFloat(bitmap[2])) / 255.0
        
        return brightness
    }
}

extension Color {
    func ensureMinimumBrightness(factor: CGFloat) -> Color {
        guard factor >= 0 && factor <= 1 else {
            return self // Return original color if factor is out of bounds
        }
        
        let nsColor = NSColor(self)
        
        // Convert to RGB color space
        guard let rgbColor = nsColor.usingColorSpace(.sRGB) else {
            return self // Return original color if conversion fails
        }
        
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        
        rgbColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        
        // Brighten without moving the hue. Scaling each channel toward a luminance target
        // clips the strongest one first, and because green carries most of the luminance a
        // dark teal came out mint. So scale until the brightest channel reaches 1 (exact
        // ratios, exact hue), then mix toward white for whatever luminance is still owed.
        func luminance() -> CGFloat { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
        guard luminance() < factor else { return self }
        let peak = max(red, green, blue)
        guard peak > 0 else { return Color(white: Double(factor), opacity: Double(alpha)) }
        red /= peak; green /= peak; blue /= peak
        let current = luminance()
        if current < factor {
            let mix = (factor - current) / (1 - current)
            red += mix * (1 - red); green += mix * (1 - green); blue += mix * (1 - blue)
        }
        
        return Color(red: Double(red), green: Double(green), blue: Double(blue), opacity: Double(alpha))
    }
}
