import Foundation
#if canImport(Network)
import Network

/// Accepts the JPEG posts the ReplayKit broadcast extension sends to localhost.
public final class FrameInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var onFrame: (@Sendable (Data) -> Void)?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "lojo.frame.inbox")

    public init() {}

    public func setHandler(_ handler: @escaping @Sendable (Data) -> Void) {
        lock.lock()
        onFrame = handler
        lock.unlock()
    }

    public func start(port: UInt16 = ScreenRelay.localPort) {
        lock.lock()
        let already = listener != nil
        lock.unlock()
        guard !already, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let listener = try NWListener(using: .tcp, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            lock.lock()
            self.listener = listener
            lock.unlock()
        } catch {
            // Sound keeps working. Live frames wait until this port is free.
        }
    }

    private func accept(_ connection: NWConnection) {
        let box = InboxBuffer()
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                if let data { box.append(data) }
                if box.bytes.count > FrameInboxParser.maxBytes + 4096 {
                    connection.cancel()
                    return
                }
                switch FrameInboxParser.parse(box.bytes) {
                case .frame(let jpeg):
                    self.emit(jpeg)
                    let response = Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                case .reject:
                    connection.cancel()
                case .needMore:
                    if error != nil || complete { connection.cancel() } else { receive() }
                }
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func emit(_ jpeg: Data) {
        lock.lock()
        let handler = onFrame
        lock.unlock()
        handler?(jpeg)
    }
}

private final class InboxBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var bytes: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
}
#endif
