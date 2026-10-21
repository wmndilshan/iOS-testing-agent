import Foundation
import ImageIO
import AgentCore

/// Shrinks a full-resolution screenshot to what a vision model needs to read a phone screen. The full PNG stays on disk as
/// evidence; only the smaller JPEG is uploaded, which cuts upload time and the model's image processing.
public enum ScreenshotCompressor {
    /// A JPEG whose longest side is at most `maxPixels`, or nil when the image cannot be read or encoded.
    public static func jpeg(from image: Data, maxPixels: Int = 1100, quality: Double = 0.7) -> Data? {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
