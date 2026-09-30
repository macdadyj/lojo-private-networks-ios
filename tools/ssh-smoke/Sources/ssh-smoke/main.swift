import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOSSH
import LojoSSH

// ssh-smoke --host A --port N --user U --ed25519 FILE --ecdsa FILE --fingerprint SHA256:… --known FILE
// Runs the LojoSSH client against a real OpenSSH server. Prints PASS/FAIL per check.

var args: [String: String] = [:]
var it = CommandLine.arguments.dropFirst().makeIterator()
while let k = it.next(), k.hasPrefix("--"), let v = it.next() { args[String(k.dropFirst(2))] = v }
guard let host = args["host"], let port = args["port"].flatMap(Int.init), let user = args["user"],
      let edPath = args["ed25519"], let ecPath = args["ecdsa"], let expectFP = args["fingerprint"],
      let knownPath = args["known"] else {
    FileHandle.standardError.write(Data("usage: ssh-smoke --host --port --user --ed25519 --ecdsa --fingerprint --known\n".utf8))
    exit(2)
}

var failures = 0
@MainActor func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : " — " + detail))
    if !ok { failures += 1 }
    fflush(nil)
}

let known = NIOLockedValueBox(KnownHosts(parsing: (try? String(contentsOfFile: knownPath, encoding: .utf8)) ?? ""))
func verifier(expect: String?, accepted: NIOLockedValueBox<KnownHosts.Verdict?>) -> @Sendable (HostKeyInfo) async -> Bool {
    { key in
        let verdict = known.withLockedValue { $0.verdict(address: host, port: port, key: key) }
        accepted.withLockedValue { $0 = verdict }
        switch verdict {
        case .trusted: return true
        case .changed: return false
        case .unknown:
            guard key.fingerprint == expect else { return false }
            known.withLockedValue { $0.trust(address: host, port: port, key: key) }
            try? known.withLockedValue { $0.serialized() }.write(toFile: knownPath, atomically: true, encoding: .utf8)
            return true
        }
    }
}

let policy = OverlayPolicy()
check("policy allows overlay + LOJO routes", policy.allows(address: "100.96.1.18") && policy.allows(address: "192.168.7.42") && policy.allows(address: "10.128.0.3"))
check("policy refuses public addresses", !policy.allows(address: "8.8.8.8") && !policy.allows(address: "34.121.0.1") && !policy.allows(address: "192.168.1.10"))
check("policy refuses public names", (try? policy.resolve("example.com")) == nil)

let edKey = try KeyImport.parse(String(contentsOfFile: edPath, encoding: .utf8))
let ecKey = try KeyImport.parse(String(contentsOfFile: ecPath, encoding: .utf8))
let edPub = try String(contentsOfFile: edPath + ".pub", encoding: .utf8)
let ecPub = try String(contentsOfFile: ecPath + ".pub", encoding: .utf8)
check("import openssh ed25519 matches .pub", edPub.hasPrefix(String(openSSHPublicKey: edKey.sshKey.publicKey)))
check("import openssh ecdsa-p256 matches .pub", ecPub.hasPrefix(String(openSSHPublicKey: ecKey.sshKey.publicKey)))

let target = SSHTarget(address: try policy.resolve(host), port: port, username: user)

// 1. first use: unknown key, trusted only because the fingerprint matches the server's
let v1 = NIOLockedValueBox<KnownHosts.Verdict?>(nil)
let conn = try await SSHConnection.connect(to: target, credentials: [.key(edKey.sshKey)], verifyHostKey: verifier(expect: expectFP, accepted: v1))
check("first connect: host key unknown then trusted", v1.withLockedValue { $0 } == .unknown && conn.hostKey.fingerprint == expectFP, conn.hostKey.fingerprint)

let (out, status) = try await conn.exec("printf ok; id -un")
check("exec returns stdout + exit 0", String(decoding: out, as: UTF8.self) == "ok" + user + "\n" && status.status == 0)

try await conn.ping()
try await conn.ping()
check("keep-alive ping answered", true)

let output = NIOLockedValueBox([UInt8]())
let exited = AsyncStream<ShellExit>.makeStream()
let shell = try await conn.openShell(cols: 80, rows: 24, onOutput: { b in output.withLockedValue { $0 += b } }, onExit: { exited.continuation.yield($0); exited.continuation.finish() })
shell.resize(cols: 100, rows: 30)
try await Task.sleep(for: .milliseconds(300))
shell.send(Array("stty size; echo PTY-$((6*7)); tty; exit 3\r".utf8))
var shellExit: ShellExit?
for await e in exited.stream { shellExit = e }
let text = String(decoding: output.withLockedValue { $0 }, as: UTF8.self)
check("pty shell runs commands", text.contains("PTY-42") && text.contains("/dev/pts/"))
check("window-change reaches the pty", text.contains("30 100"))
check("shell exit status reported", shellExit?.status == 3, String(describing: shellExit))
conn.close()

// 2. second connect: key is on file
let v2 = NIOLockedValueBox<KnownHosts.Verdict?>(nil)
let conn2 = try await SSHConnection.connect(to: target, credentials: [.key(ecKey.sshKey)], verifyHostKey: verifier(expect: nil, accepted: v2))
check("reconnect: host key trusted from known_hosts", v2.withLockedValue { $0 } == .trusted)
let (out2, _) = try await conn2.exec("printf p256")
check("ecdsa-p256 user key accepted (same algorithm as Secure Enclave keys)", String(decoding: out2, as: UTF8.self) == "p256")
conn2.close()

// 3. host key changed: refuse
let other = HostKeyInfo(NIOSSHPrivateKey(ed25519Key: .init()).publicKey)
known.withLockedValue { k in
    k.forget(address: host, port: port)
    k.trust(address: host, port: port, key: other)
}
let v3 = NIOLockedValueBox<KnownHosts.Verdict?>(nil)
do {
    _ = try await SSHConnection.connect(to: target, credentials: [.key(edKey.sshKey)], verifyHostKey: verifier(expect: expectFP, accepted: v3))
    check("changed host key is refused", false, "connected anyway")
} catch let e as SSHClientError {
    let changed: Bool
    if case .changed = v3.withLockedValue({ $0 }) { changed = true } else { changed = false }
    check("changed host key is refused", e == .hostKeyRejected && changed, e.description)
}
known.withLockedValue { $0 = KnownHosts(parsing: (try? String(contentsOfFile: knownPath, encoding: .utf8)) ?? "") }

// 4. key the server doesn't know: auth fails cleanly; password prompt not offered (server is key-only)
let prompted = NIOLockedValueBox(false)
do {
    _ = try await SSHConnection.connect(
        to: target, credentials: [.key(NIOSSHPrivateKey(ed25519Key: .init()))],
        passwordPrompt: { prompted.withLockedValue { $0 = true }; return nil },
        verifyHostKey: verifier(expect: nil, accepted: .init(nil))
    )
    check("unknown user key rejected", false, "connected anyway")
} catch let e as SSHClientError {
    check("unknown user key rejected", e == .authenticationFailed && !prompted.withLockedValue { $0 }, e.description)
}

// 5. nothing listening: fast, typed failure
do {
    _ = try await SSHConnection.connect(to: SSHTarget(address: target.address, port: 1, username: user), credentials: [], verifyHostKey: { _ in false }, connectTimeout: .seconds(3))
    check("closed port fails", false)
} catch let e as SSHClientError {
    if case .connectFailed = e { check("closed port fails", true, e.description) } else { check("closed port fails", false, e.description) }
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
