import Foundation
import LojoRemote
import Network

/// Accepts JPEG frames from the ReplayKit broadcast extension on localhost.
final class FrameInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var onFrame: (@Sendable (Data) -> Void)?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "lojo.frame.inbox")

    func setHandler(_ handler: @escaping @Sendable (Data) -> Void) {
        lock.lock()
        onFrame = handler
        lock.unlock()
    }

    func start() {
        lock.lock()
        let already = listener != nil
        lock.unlock()
        guard !already else { return }
        guard let port = NWEndpoint.Port(rawValue: ScreenRelay.localPort) else { return }
        do {
            let listener = try NWListener(using: .tcp, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            lock.lock()
            self.listener = listener
            lock.unlock()
        } catch {
            // The spare phone can still play sound. Live frames wait until this port is free.
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
