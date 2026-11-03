import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Cross-platform image helpers built on ImageIO.
enum ImageCoder {
    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Decodes and downsamples in one step (memory friendly).
    static func thumbnail(from data: Data, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(source: source, maxPixel: maxPixel)
    }

    static func thumbnail(url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(source: source, maxPixel: maxPixel)
    }

    private static func thumbnail(source: CGImageSource, maxPixel: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func encode(_ image: CGImage, type: UTType = .jpeg, quality: CGFloat = 0.8) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Prepares an image for sending to a model: max 1568px on the long edge, JPEG.
    static func preparedForModel(_ data: Data, maxPixel: CGFloat = 1568) -> (data: Data, mimeType: String)? {
        guard let image = thumbnail(from: data, maxPixel: maxPixel),
              let jpeg = encode(image, type: .jpeg, quality: 0.82) else { return nil }
        return (jpeg, "image/jpeg")
    }

    static func preparedForModel(_ image: CGImage, maxPixel: CGFloat = 1568) -> Attachment? {
        let scaled = downscale(image, maxPixel: maxPixel) ?? image
        guard let jpeg = encode(scaled, type: .jpeg, quality: 0.8) else { return nil }
        return Attachment(name: "screen.jpg", mimeType: "image/jpeg", data: jpeg)
    }

    static func downscale(_ image: CGImage, maxPixel: CGFloat) -> CGImage? {
        let longest = CGFloat(max(image.width, image.height))
        guard longest > maxPixel else { return image }
        let scale = maxPixel / longest
        let width = Int(CGFloat(image.width) * scale)
        let height = Int(CGFloat(image.height) * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// A tiny grayscale fingerprint used to detect whether the screen changed.
    static func fingerprint(_ image: CGImage, size: Int = 24) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: size * size)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        return pixels
    }

    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        var total = 0
        for index in a.indices { total += abs(Int(a[index]) - Int(b[index])) }
        return Double(total) / Double(a.count)
    }
}

extension Image {
    /// Creates a SwiftUI image from encoded image data on either platform.
    init?(imageData: Data) {
        #if os(iOS)
        guard let image = UIImage(data: imageData) else { return nil }
        self.init(uiImage: image)
        #else
        guard let image = NSImage(data: imageData) else { return nil }
        self.init(nsImage: image)
        #endif
    }
}
