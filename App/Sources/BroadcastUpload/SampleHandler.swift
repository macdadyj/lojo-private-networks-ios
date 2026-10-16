import CoreImage
import CoreMedia
import Foundation
import LojoRemote
import ReplayKit

/// View-only broadcast. Frames go to the app on this phone, which forwards them to the relay.
/// Nothing here injects touches or reads messages.
final class SampleHandler: RPBroadcastSampleHandler {
    private let poster = ScreenFramePoster()
    private let context = CIContext()
    private var lastSent = Date.distantPast

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {}

    override func broadcastFinished() {}

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSent) >= 0.5 else { return }
        guard let jpeg = jpegData(from: sampleBuffer), !jpeg.isEmpty else { return }
        lastSent = now
        poster.post(jpeg)
    }

    private func jpegData(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        guard extent.width.isFinite, extent.width > 1, extent.height.isFinite else { return nil }
        let scale = min(1, 480 / extent.width)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.jpegRepresentation(
            of: scaled,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [:]
        )
    }
}
