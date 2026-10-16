import CoreMedia
import CoreVideo
import XCTest
@testable import LojoRemote

/// The broadcast extension and the spare-phone app meet on localhost. This is that hop.
final class BroadcastPathTests: XCTestCase {
    func testReplayKitFrameBecomesAJPEG() throws {
        let sample = try makeSampleBuffer(width: 32, height: 24)
        let jpeg = try XCTUnwrap(BroadcastJPEG.encode(sample, maxWidth: 16))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xff, 0xd8])
        XCTAssertLessThan(jpeg.count, 32 * 24 * 4)
    }

    func testExtensionPostReachesTheInbox() async throws {
        let port: UInt16 = 47_231
        let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
        let inbox = FrameInbox()
        let received = ExpectationBox()
        inbox.setHandler { data in
            received.store(data)
        }
        inbox.start(port: port)
        try await Task.sleep(nanoseconds: 300_000_000)

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/frame"))
        ScreenFramePoster(url: url).post(jpeg)
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline && received.value() == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(received.value(), jpeg)
    }

    private func makeSampleBuffer(width: Int, height: Int) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        let created = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixel
        )
        XCTAssertEqual(created, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0x40, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        let described = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &format
        )
        XCTAssertEqual(described, noErr)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let made = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: try XCTUnwrap(format),
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        XCTAssertEqual(made, noErr)
        return try XCTUnwrap(sample)
    }
}

private final class ExpectationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    func store(_ data: Data) {
        lock.lock()
        stored = data
        lock.unlock()
    }
    func value() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
