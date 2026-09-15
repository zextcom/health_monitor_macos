import XCTest
import Network
import Security
@testable import ProjeHealthMonitor

/// A loopback-only TLS server backed by a self-signed test identity, so certificate-expiry
/// fetching can be exercised deterministically without depending on a real external host.
private final class LocalTLSServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.zext.healthmonitor.tests.tls-server")
    private var acceptedConnections: [NWConnection] = []
    private(set) var port: UInt16?

    /// `acceptConnections: false` binds and listens normally but never calls `start(queue:)` on
    /// incoming connections, so the TLS handshake never completes — used to exercise the client
    /// timeout path without touching any real host.
    init(identity: SecIdentity, acceptConnections: Bool = true) throws {
        let tlsOptions = NWProtocolTLS.Options()
        let secIdentity = sec_identity_create(identity)!
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)
        let parameters = NWParameters(tls: tlsOptions)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.acceptedConnections.append(connection)
            if acceptConnections {
                connection.start(queue: self?.queue ?? .main)
            }
        }
    }

    func start() async {
        await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state, let rawPort = self?.listener.port?.rawValue {
                    self?.port = rawPort
                    continuation.resume()
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        acceptedConnections.forEach { $0.cancel() }
    }
}

private enum TestIdentityLoaderError: Error {
    case importFailed(OSStatus)
}

private enum TestIdentityLoader {
    static func loadIdentity() throws -> SecIdentity {
        let p12Data = Data(base64Encoded: CertificateFixtures.p12Base64.replacingOccurrences(of: "\n", with: ""))!
        var rawItems: CFArray?
        let options = [kSecImportExportPassphrase as String: CertificateFixtures.p12Passphrase]
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess,
              let items = rawItems as? [[String: Any]],
              let firstItem = items.first,
              let identity = firstItem[kSecImportItemIdentity as String]
        else {
            throw TestIdentityLoaderError.importFailed(status)
        }
        return identity as! SecIdentity
    }
}

final class HealthCheckServiceCertificateTests: XCTestCase {
    private var server: LocalTLSServer?

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    func testFetchCertificateExpiryReadsExpiryFromLocalTLSServer() async throws {
        let identity = try TestIdentityLoader.loadIdentity()
        let localServer = try LocalTLSServer(identity: identity)
        server = localServer
        await localServer.start()
        guard let port = localServer.port else {
            XCTFail("Local TLS server never became ready")
            return
        }

        // The real host's certificate is self-signed and unknown to the system trust store, so a
        // plain `.tls` client would (correctly) reject it. Trusting it is safe only because this
        // is a loopback server we just stood up ourselves for this one test.
        let clientTLSOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            clientTLSOptions.securityProtocolOptions,
            { _, _, complete in complete(true) },
            DispatchQueue(label: "test-client-verify")
        )
        let clientParameters = NWParameters(tls: clientTLSOptions)

        // The first loopback TLS connection in a process can be noticeably slower than later ones
        // (path/interface evaluation warm-up), especially under load from a larger test run, so
        // this generous timeout is deliberate — not a statement about real-world latency.
        let expiry = await HealthCheckService.fetchCertificateExpiry(
            host: "127.0.0.1", port: port, timeout: 30, parameters: clientParameters
        )

        let unwrappedExpiry = try XCTUnwrap(expiry)
        XCTAssertEqual(unwrappedExpiry.timeIntervalSince1970,
                        CertificateFixtures.leafCertificateExpiry.timeIntervalSince1970,
                        accuracy: 2)
    }

    func testFetchCertificateExpiryReturnsNilWhenConnectionIsRefused() async {
        // Port 1 is a well-known reserved port that nothing listens on locally, so the TCP
        // handshake fails immediately (connection refused) without touching any real host.
        let expiry = await HealthCheckService.fetchCertificateExpiry(host: "127.0.0.1", port: 1, timeout: 5)
        XCTAssertNil(expiry)
    }

    func testFetchCertificateExpiryReturnsNilOnTimeout() async throws {
        let identity = try TestIdentityLoader.loadIdentity()
        let localServer = try LocalTLSServer(identity: identity, acceptConnections: false)
        server = localServer
        await localServer.start()
        guard let port = localServer.port else {
            XCTFail("Local TLS server never became ready")
            return
        }

        let expiry = await HealthCheckService.fetchCertificateExpiry(host: "127.0.0.1", port: port, timeout: 1)
        XCTAssertNil(expiry)
    }
}
