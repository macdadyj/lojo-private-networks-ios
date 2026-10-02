import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
#if canImport(Network)
import Network
import NIOTransportServices
#endif

/// One authenticated SSH connection. Child channels (shells, execs) are opened on top of it.
public final class SSHConnection: Sendable {
    public let target: SSHTarget
    public let hostKey: HostKeyInfo
    /// What the server accepted: "key SHA256:…", "password" or "none".
    public let authenticatedWith: String
    private let channel: Channel
    private let firstError: NIOLockedValueBox<SSHClientError?>

    private init(
        target: SSHTarget, hostKey: HostKeyInfo, authenticatedWith: String,
        channel: Channel, firstError: NIOLockedValueBox<SSHClientError?>
    ) {
        self.target = target
        self.hostKey = hostKey
        self.authenticatedWith = authenticatedWith
        self.channel = channel
        self.firstError = firstError
    }

    /// Connects, verifies the host key through `verifyHostKey`, and authenticates with `credentials`
    /// in order. `passwordPrompt` is asked once, only if the server accepts passwords and every
    /// credential failed.
    public static func connect(
        to target: SSHTarget,
        credentials: [SSHCredential],
        passwordPrompt: (@Sendable () async -> String?)? = nil,
        verifyHostKey: @escaping @Sendable (HostKeyInfo) async -> Bool,
        connectTimeout: TimeAmount = .seconds(10)
    ) async throws -> SSHConnection {
        let firstError = NIOLockedValueBox<SSHClientError?>(nil)
        let seenKey = NIOLockedValueBox<HostKeyInfo?>(nil)
        let authenticated = NIOLockedValueBox<EventLoopPromise<Void>?>(nil)
        let trace = NIOLockedValueBox(AuthTrace(username: target.username))

        let initializer: @Sendable (Channel) -> EventLoopFuture<Void> = { channel in
            let done = channel.eventLoop.makePromise(of: Void.self)
            authenticated.withLockedValue { $0 = done }
            return channel.eventLoop.makeCompletedFuture {
                let userAuth = UserAuth(username: target.username, credentials: credentials, passwordPrompt: passwordPrompt, trace: trace)
                let serverAuth = HostKeyGate(seen: seenKey, verify: verifyHostKey)
                let ssh = NIOSSHHandler(
                    role: .client(.init(userAuthDelegate: userAuth, serverAuthDelegate: serverAuth)),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )
                try channel.pipeline.syncOperations.addHandlers([
                    ssh, ConnectionWatcher(firstError: firstError, authenticated: done),
                ])
            }
        }

        let channel: Channel
        do {
            channel = try await bootstrap(initializer: initializer, timeout: connectTimeout)
                .connect(host: target.address, port: target.port).get()
        } catch {
            throw SSHClientError.wrap(error)
        }

        do {
            guard let done = authenticated.withLockedValue({ $0 }) else { throw SSHClientError.disconnected("no pipeline") }
            try await done.futureResult.get()
        } catch {
            channel.close(promise: nil)
            let failure = firstError.withLockedValue { $0 } ?? SSHClientError.wrap(error)
            let current = trace.withLockedValue { $0 }
            if case .disconnected = failure, current.started {
                var auth = current.failure
                auth.serverClosed = true
                throw SSHClientError.authenticationFailed(auth)
            }
            throw failure
        }
        guard let key = seenKey.withLockedValue({ $0 }) else {
            channel.close(promise: nil)
            throw SSHClientError.hostKeyRejected
        }
        let method: String
        switch trace.withLockedValue({ $0.last }) {
        case .key(let fingerprint)?: method = "key \(fingerprint)"
        case .password?: method = "password"
        case .none?, nil: method = "none"
        }
        return SSHConnection(target: target, hostKey: key, authenticatedWith: method, channel: channel, firstError: firstError)
    }

    static func bootstrap(
        initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>,
        timeout: TimeAmount
    ) -> NIOClientTCPBootstrap {
        #if canImport(Network)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        // With waitForActivity on (the default), a refused or unroutable connect just sits in
        // NWConnection's .waiting state until the timeout and surfaces as "timed out".
        let ts = NIOTSConnectionBootstrap(group: NIOTSEventLoopGroup.singleton)
            .connectTimeout(timeout)
            .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
            .tcpOptions(tcp)
            .channelInitializer(initializer)
        // No requiredInterface. 100.64.0.0/10 is routed out the overlay utun; pinning the
        // socket to cellular (or to ipsec, which is also the 464XLAT CLAT) would miss that route.
        return NIOClientTCPBootstrap(ts, tls: NIOInsecureNoTLS())
        #else
        let posix = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(timeout)
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer(initializer)
        return NIOClientTCPBootstrap(posix, tls: NIOInsecureNoTLS())
        #endif
    }

    public var isActive: Bool { channel.isActive }

    /// Reason the connection went away, if it did so with an error.
    public var closeReason: SSHClientError? { firstError.withLockedValue { $0 } }

    public func onClose(_ body: @escaping @Sendable (SSHClientError?) -> Void) {
        let firstError = self.firstError
        channel.closeFuture.whenComplete { _ in body(firstError.withLockedValue { $0 }) }
    }

    public func close() {
        channel.close(promise: nil)
    }

    /// Round-trip that the server must answer: a `cancel-tcpip-forward` for a port we never
    /// forwarded, sent with want-reply. Accepted or refused both prove the peer is alive.
    public func ping(timeout: TimeAmount = .seconds(10)) async throws {
        let channel = self.channel
        let result = channel.eventLoop.makePromise(of: Void.self)
        channel.eventLoop.execute {
            guard let ssh = try? channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self) else {
                result.fail(SSHClientError.disconnected("connection closed"))
                return
            }
            let once = Once()
            let timer = channel.eventLoop.scheduleTask(in: timeout) {
                if once.claim() { result.fail(SSHClientError.pingTimeout) }
            }
            let reply = channel.eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
            reply.futureResult.whenComplete { _ in
                timer.cancel()
                if once.claim() { result.succeed(()) }
            }
            ssh.sendTCPForwardingRequest(.cancel(host: "keepalive.lojo.invalid", port: 1), promise: reply)
        }
        try await result.futureResult.get()
    }

    /// Opens an interactive shell with a PTY. Output (stdout and stderr) is delivered on NIO's
    /// event loop; hop to the main actor before touching UI.
    public func openShell(
        term: String = "xterm-256color",
        cols: Int,
        rows: Int,
        onOutput: @escaping @Sendable ([UInt8]) -> Void,
        onExit: @escaping @Sendable (ShellExit) -> Void
    ) async throws -> ShellChannel {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: term,
            terminalCharacterWidth: cols, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        let child = try await openSession(mode: .shell(pty), onOutput: onOutput, onExit: onExit)
        return ShellChannel(channel: child)
    }

    /// Runs one command without a PTY and returns its stdout (stderr is dropped).
    public func exec(_ command: String, maxBytes: Int = 1 << 20) async throws -> (output: Data, exit: ShellExit) {
        let collected = NIOLockedValueBox(Data())
        let finished = channel.eventLoop.makePromise(of: ShellExit.self)
        _ = try await openSession(
            mode: .exec(command),
            onOutput: { bytes in collected.withLockedValue { if $0.count < maxBytes { $0.append(contentsOf: bytes) } } },
            onExit: { finished.succeed($0) },
            stdoutOnly: true
        )
        let exit = try await finished.futureResult.get()
        return (collected.withLockedValue { $0 }, exit)
    }

    private func openSession(
        mode: SessionHandler.Mode,
        onOutput: @escaping @Sendable ([UInt8]) -> Void,
        onExit: @escaping @Sendable (ShellExit) -> Void,
        stdoutOnly: Bool = false
    ) async throws -> Channel {
        let channel = self.channel
        let created = channel.eventLoop.makePromise(of: Channel.self)
        let ready = channel.eventLoop.makePromise(of: Void.self)
        channel.eventLoop.execute {
            guard let ssh = try? channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self) else {
                created.fail(SSHClientError.disconnected("connection closed"))
                return
            }
            ssh.createChannel(created, channelType: .session) { child, _ in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(SessionHandler(
                        mode: mode, ready: ready, stdoutOnly: stdoutOnly, onOutput: onOutput, onExit: onExit
                    ))
                }
            }
        }
        created.futureResult.whenFailure { ready.fail($0) }
        do {
            let child = try await created.futureResult.get()
            try await ready.futureResult.get()
            return child
        } catch {
            throw firstError.withLockedValue { $0 } ?? SSHClientError.wrap(error)
        }
    }
}

/// A live shell channel. All methods are safe from any thread.
public final class ShellChannel: Sendable {
    private let channel: Channel

    init(channel: Channel) {
        self.channel = channel
    }

    public func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
    }

    public func resize(cols: Int, rows: Int) {
        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols, terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0
        )
        channel.triggerUserOutboundEvent(event, promise: nil)
    }

    public func close() {
        channel.close(promise: nil)
    }
}

/// Guards single completion of a promise between a timer and a reply; only touched on one event loop.
private final class Once: @unchecked Sendable {
    private var done = false
    func claim() -> Bool {
        if done { return false }
        done = true
        return true
    }
}

struct AuthTrace: Sendable {
    enum Offer: Sendable { case none, key(String), password }

    var started = false
    var last: Offer?
    var failure: AuthFailure

    init(username: String) {
        failure = AuthFailure(username: username)
    }
}

private final class UserAuth: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private var remaining: [SSHCredential]
    private let passwordPrompt: (@Sendable () async -> String?)?
    private var askedForPassword = false
    private let trace: NIOLockedValueBox<AuthTrace>

    init(
        username: String, credentials: [SSHCredential],
        passwordPrompt: (@Sendable () async -> String?)?, trace: NIOLockedValueBox<AuthTrace>
    ) {
        self.username = username
        self.remaining = credentials
        self.passwordPrompt = passwordPrompt
        self.trace = trace
        trace.withLockedValue { $0.failure.credentialCount = credentials.count }
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // NIOSSH passes `.all` before the server has answered anything; a "none" request makes the
        // server list the methods it really accepts, so keys are only offered where they can work.
        let first = trace.withLockedValue { t -> Bool in
            defer { t.started = true }
            return !t.started
        }
        if first {
            trace.withLockedValue { $0.last = AuthTrace.Offer.none }
            nextChallengePromise.succeed(offer(.none))
            return
        }
        trace.withLockedValue { t in
            t.failure.serverMethods = Self.names(availableMethods)
            switch t.last {
            case .key(let fingerprint)?: t.failure.rejectedKeys.append(fingerprint)
            case .password?: t.failure.passwordRejected = true
            default: break
            }
            t.last = nil
        }
        while !remaining.isEmpty {
            switch remaining.removeFirst() {
            case .key(let key):
                guard availableMethods.contains(.publicKey) else {
                    trace.withLockedValue { $0.failure.skippedKeys += 1 }
                    continue
                }
                let fingerprint = HostKeyInfo(key.publicKey).fingerprint
                trace.withLockedValue { $0.last = .key(fingerprint) }
                nextChallengePromise.succeed(offer(.privateKey(.init(privateKey: key))))
                return
            case .password(let password) where availableMethods.contains(.password):
                trace.withLockedValue { $0.last = .password }
                nextChallengePromise.succeed(offer(.password(.init(password: password))))
                return
            default:
                continue
            }
        }
        if availableMethods.contains(.password), !askedForPassword, let prompt = passwordPrompt {
            askedForPassword = true
            let username = self.username
            let trace = self.trace
            Task {
                if let password = await prompt() {
                    trace.withLockedValue { $0.last = .password }
                    nextChallengePromise.succeed(.init(username: username, serviceName: "ssh-connection", offer: .password(.init(password: password))))
                } else {
                    let failure = trace.withLockedValue { t -> AuthFailure in
                        t.failure.passwordCancelled = true
                        return t.failure
                    }
                    nextChallengePromise.fail(SSHClientError.authenticationFailed(failure))
                }
            }
            return
        }
        nextChallengePromise.fail(SSHClientError.authenticationFailed(trace.withLockedValue { $0.failure }))
    }

    private static func names(_ methods: NIOSSHAvailableUserAuthenticationMethods) -> [String] {
        var names: [String] = []
        if methods.contains(.publicKey) { names.append("publickey") }
        if methods.contains(.password) { names.append("password") }
        if methods.contains(.hostBased) { names.append("hostbased") }
        return names
    }

    private func offer(_ o: NIOSSHUserAuthenticationOffer.Offer) -> NIOSSHUserAuthenticationOffer {
        .init(username: username, serviceName: "ssh-connection", offer: o)
    }
}

private final class HostKeyGate: NIOSSHClientServerAuthenticationDelegate {
    private let seen: NIOLockedValueBox<HostKeyInfo?>
    private let verify: @Sendable (HostKeyInfo) async -> Bool

    init(seen: NIOLockedValueBox<HostKeyInfo?>, verify: @escaping @Sendable (HostKeyInfo) async -> Bool) {
        self.seen = seen
        self.verify = verify
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let info = HostKeyInfo(hostKey)
        let verify = self.verify
        let seen = self.seen
        Task {
            if await verify(info) {
                seen.withLockedValue { $0 = info }
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHClientError.hostKeyRejected)
            }
        }
    }
}

/// Completes `authenticated` on UserAuthSuccessEvent, remembers the first error, closes on error.
private final class ConnectionWatcher: ChannelInboundHandler {
    typealias InboundIn = Any

    private let firstError: NIOLockedValueBox<SSHClientError?>
    private let authenticated: EventLoopPromise<Void>

    init(firstError: NIOLockedValueBox<SSHClientError?>, authenticated: EventLoopPromise<Void>) {
        self.firstError = firstError
        self.authenticated = authenticated
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            authenticated.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let wrapped = SSHClientError.wrap(error)
        firstError.withLockedValue { if $0 == nil { $0 = wrapped } }
        authenticated.fail(wrapped)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        authenticated.fail(firstError.withLockedValue { $0 } ?? .disconnected("connection closed"))
        context.fireChannelInactive()
    }

    // A failed TCP connect never goes active; the promise must still complete.
    func handlerRemoved(context: ChannelHandlerContext) {
        authenticated.fail(firstError.withLockedValue { $0 } ?? .connectFailed("connection closed"))
    }
}

/// Child "session" channel: sends pty-req + shell (or exec), relays data, reports exit.
private final class SessionHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    enum Mode {
        case shell(SSHChannelRequestEvent.PseudoTerminalRequest)
        case exec(String)
    }

    private let mode: Mode
    private let ready: EventLoopPromise<Void>
    private let stdoutOnly: Bool
    private let onOutput: @Sendable ([UInt8]) -> Void
    private let onExit: @Sendable (ShellExit) -> Void
    private var pendingReplies = 0
    private var isReady = false
    private var exit = ShellExit()

    init(
        mode: Mode, ready: EventLoopPromise<Void>, stdoutOnly: Bool,
        onOutput: @escaping @Sendable ([UInt8]) -> Void, onExit: @escaping @Sendable (ShellExit) -> Void
    ) {
        self.mode = mode
        self.ready = ready
        self.stdoutOnly = stdoutOnly
        self.onOutput = onOutput
        self.onExit = onExit
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
        if context.channel.isActive { sendRequests(context: context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        sendRequests(context: context)
        context.fireChannelActive()
    }

    private var requestsSent = false

    private func sendRequests(context: ChannelHandlerContext) {
        guard !requestsSent else { return }
        requestsSent = true
        switch mode {
        case .shell(let pty):
            pendingReplies = 2
            context.triggerUserOutboundEvent(pty, promise: nil)
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
        case .exec(let command):
            pendingReplies = 1
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        if stdoutOnly, message.type != .channel { return }
        onOutput(Array(buffer.readableBytesView))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            pendingReplies -= 1
            if pendingReplies == 0, !isReady {
                isReady = true
                ready.succeed(())
            }
        case is ChannelFailureEvent:
            let what: String
            if case .exec = mode { what = "the command" } else { what = pendingReplies == 2 ? "a terminal (pty)" : "a shell" }
            ready.fail(SSHClientError.channelRejected(what))
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus:
            exit.status = status.exitStatus
        case let signal as SSHChannelRequestEvent.ExitSignal:
            exit.signal = signal.signalName
        case ChannelEvent.inputClosed:
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        exit.error = SSHClientError.wrap(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !isReady { ready.fail(exit.error ?? .disconnected("channel closed")) }
        if exit.status == nil, exit.signal == nil, exit.error == nil {
            exit.error = .disconnected("connection lost")
        }
        onExit(exit)
        context.fireChannelInactive()
    }
}
