import Foundation
import NIOConcurrencyHelpers
import NIOCore

public struct TCPProbeResult: Sendable, Equatable {
    /// Time from starting the connect to the socket going active.
    public var connectMillis: Double?
    /// The server's identification line, e.g. `SSH-2.0-OpenSSH_9.6p1`.
    public var banner: String?
    public var error: SSHClientError?

    public var connected: Bool { connectMillis != nil }
}

public enum SSHProbe {
    /// Opens a plain TCP connection, reads the SSH identification line, and hangs up before key
    /// exchange. Sends nothing.
    public static func banner(address: String, port: Int, timeout: TimeAmount = .seconds(5)) async -> TCPProbeResult {
        let line = NIOLockedValueBox<EventLoopPromise<String>?>(nil)
        let initializer: @Sendable (Channel) -> EventLoopFuture<Void> = { channel in
            let promise = channel.eventLoop.makePromise(of: String.self)
            line.withLockedValue { $0 = promise }
            return channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(BannerReader(line: promise))
            }
        }

        var result = TCPProbeResult()
        let start = ContinuousClock.now
        let channel: Channel
        do {
            channel = try await SSHConnection.bootstrap(initializer: initializer, timeout: timeout)
                .connect(host: address, port: port).get()
        } catch {
            result.error = SSHClientError.wrap(error)
            return result
        }
        result.connectMillis = Self.millis(since: start)
        defer { channel.close(promise: nil) }

        guard let promise = line.withLockedValue({ $0 }) else { return result }
        let timer = channel.eventLoop.scheduleTask(in: timeout) {
            promise.fail(SSHClientError.connectFailed("connected, but the server sent no SSH banner"))
        }
        do {
            result.banner = try await promise.futureResult.get()
        } catch {
            result.error = SSHClientError.wrap(error)
        }
        timer.cancel()
        return result
    }

    public static func millis(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}

/// Collects bytes until the first `SSH-` line (RFC 4253 allows other lines before it).
private final class BannerReader: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let line: EventLoopPromise<String>
    private var buffer: [UInt8] = []
    private var done = false

    init(line: EventLoopPromise<String>) {
        self.line = line
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !done else { return }
        buffer.append(contentsOf: unwrapInboundIn(data).readableBytesView)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let raw = String(decoding: buffer[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(...newline)
            if raw.hasPrefix("SSH-") {
                finish(.success(raw), context: context)
                return
            }
        }
        if buffer.count > 4096 {
            finish(.failure(SSHClientError.connectFailed("that port is not an SSH server")), context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(.failure(SSHClientError.connectFailed("the server closed the connection before sending a banner")), context: context)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(.failure(SSHClientError.wrap(error)), context: context)
    }

    // A failed TCP connect never goes active; the promise must still complete.
    func handlerRemoved(context: ChannelHandlerContext) {
        guard !done else { return }
        done = true
        line.fail(SSHClientError.connectFailed("connection closed"))
    }

    private func finish(_ result: Result<String, Error>, context: ChannelHandlerContext) {
        guard !done else { return }
        done = true
        line.completeWith(result)
        context.close(promise: nil)
    }
}
