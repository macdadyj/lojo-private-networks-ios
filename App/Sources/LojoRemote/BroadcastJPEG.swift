import Foundation
#if canImport(CoreImage) && canImport(CoreMedia)
import CoreImage
import CoreMedia

/// Downscales a ReplayKit video frame to a JPEG the controller can show.
public enum BroadcastJPEG {
    public static func encode(_ sampleBuffer: CMSampleBuffer, maxWidth: CGFloat = 480) -> Data? {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        guard extent.width.isFinite, extent.width > 1, extent.height.isFinite, extent.height > 1 else { return nil }
        let scale = min(1, maxWidth / extent.width)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        return context.jpegRepresentation(
            of: scaled,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.5]
        )
    }
}
#endif
