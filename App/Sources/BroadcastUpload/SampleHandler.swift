import CoreMedia
import Foundation
import LojoRemote
import ReplayKit

/// View-only broadcast. Frames go to the app on this phone, which forwards them to the relay.
/// Nothing here injects touches or reads messages.
final class SampleHandler: RPBroadcastSampleHandler {
    private let poster = ScreenFramePoster()
    private var lastSent = Date.distantPast

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {}

    override func broadcastFinished() {}

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSent) >= 0.5 else { return }
        guard let jpeg = BroadcastJPEG.encode(sampleBuffer), !jpeg.isEmpty else { return }
        lastSent = now
        poster.post(jpeg)
    }
}
