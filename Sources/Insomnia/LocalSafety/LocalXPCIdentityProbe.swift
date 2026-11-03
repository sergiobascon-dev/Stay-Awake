import Foundation
import Darwin

@objc private protocol LocalIdentityProbe {
    func ping(reply: @escaping (String) -> Void)
}

private final class ProbeEndpoint: NSObject, LocalIdentityProbe {
    func ping(reply: @escaping (String) -> Void) { reply("identity-probe") }
}

private final class ProbeListener: NSObject, NSXPCListenerDelegate {
    let requirement: String
    init(requirement: String) { self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: LocalIdentityProbe.self)
        connection.exportedObject = ProbeEndpoint()
        connection.resume()
        return true
    }
}

private final class ProbeResultGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?
    init(_ continuation: CheckedContinuation<String, Never>) { self.continuation = continuation }
    func finish(_ result: String) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

/// Exercises Foundation's real per-message signing gate on an anonymous local
/// endpoint. It has no connection to the power service, filesystem or pmset.
/// A timeout is a FAILURE, never evidence that a bad identity was rejected.
enum LocalXPCIdentityProbe {
    static func run() async throws {
        guard geteuid() != 0 else { throw LeaseFailure(message: "Identity probes must run without root") }
        let correct = try PowerBrokerPolicy.buildRequirement()
        let wrong = "cdhash H\"\(String(repeating: "00", count: 20))\""
        let accepted = await exchange(server: correct, client: correct)
        let wrongClient = await exchange(server: wrong, client: correct)
        let wrongServer = await exchange(server: correct, client: wrong)
        guard accepted == "accepted", wrongClient == "rejected", wrongServer == "rejected" else {
            throw LeaseFailure(message: "XPC identity probe failed: matching=\(accepted), wrongClient=\(wrongClient), wrongServer=\(wrongServer)")
        }
        print("XPC exact-build identity accepted; mismatched client and server rejected. No power service contacted.")
    }

    private static func exchange(server: String, client: String) async -> String {
        let delegate = ProbeListener(requirement: server)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        defer { connection.invalidate(); listener.invalidate() }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let gate = ProbeResultGate(continuation)
            connection.setCodeSigningRequirement(client)
            connection.remoteObjectInterface = NSXPCInterface(with: LocalIdentityProbe.self)
            connection.invalidationHandler = { gate.finish("rejected") }
            connection.interruptionHandler = { gate.finish("rejected") }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in gate.finish("rejected") } as? LocalIdentityProbe
            guard let proxy else { gate.finish("invalid-proxy"); return }
            proxy.ping { reply in gate.finish(reply == "identity-probe" ? "accepted" : "invalid-reply") }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { gate.finish("timeout") }
        }
        withExtendedLifetime(delegate) {}
        return result
    }
}
