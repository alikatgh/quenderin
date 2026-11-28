#if os(macOS)
import Foundation
import Network
import os
import XCTest
@testable import QuenderinKit

final class LocalAPIServerAdmissionTests: XCTestCase {
    private struct FixtureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let clientQueue = DispatchQueue(label: "org.quenderin.tests.local-api-clients")

    @MainActor
    func testOverflowAllowsPromotedRequestToFinishAndListenerToRestart() async throws {
        let suite = "LocalAPIServerAdmission-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, localAPIKeyStore: InMemoryLocalAPIKeyStore())
        settings.localAPIEnabled = true
        settings.localAPIKey = "admission-fixture"
        let server = LocalAPIServer(settings: settings, headerReadTimeoutSeconds: 60)
        defer { server.stop() }
        let port = try await startListener(server)
        let host = "Host: 127.0.0.1:\(port.rawValue)\r\n"
        let bearer = "Authorization: Bearer admission-fixture\r\n"

        let authorized = openClient(port)
        defer { authorized.cancel() }
        // A fixture route returns 404 after authorization without consulting model storage.
        send("POST /admission-fixture HTTP/1.1\r\n" + host + bearer
             + "Content-Type: application/json\r\nContent-Length: 2\r\n\r\n", to: authorized)
        try await waitUntil("promotion while the request body is pending") {
            server.admission.totalCount == 1 && server.admission.preAuthCount == 0
        }

        let stalled = (0..<8).map { _ in openClient(port) }
        defer { for client in stalled { client.cancel() } }
        for client in stalled {
            send("GET /admission-fixture HTTP/1.1\r\n" + host, to: client)
        }
        try await waitUntil("a full pre-auth budget") {
            server.admission.preAuthCount == 8
        }

        let overflow = openClient(port)
        defer { overflow.cancel() }
        let rejection = try await response(from: overflow)
        XCTAssertTrue(rejection.hasPrefix("HTTP/1.1 503 Service Unavailable\r\n"))
        XCTAssertTrue(rejection.contains("\r\nRetry-After: 5\r\n"))
        XCTAssertTrue(rejection.contains("\"connection_limit\""))
        try await waitUntil("release of the overflow connection") {
            server.admission.totalCount == 9
        }

        send("{}", to: authorized)
        let accepted = try await response(from: authorized)
        XCTAssertTrue(accepted.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        try await waitUntil("release of the authorized connection") {
            server.admission.totalCount == 8 && server.admission.preAuthCount == 8
        }

        server.stop()
        XCTAssertEqual(server.admission.totalCount, 0)
        let restartedPort = try await startListener(server)
        let fresh = openClient(restartedPort)
        defer { fresh.cancel() }
        send("GET /admission-fixture HTTP/1.1\r\nHost: 127.0.0.1:\(restartedPort.rawValue)\r\n\r\n", to: fresh)
        let restarted = try await response(from: fresh)
        XCTAssertTrue(restarted.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
    }

    @MainActor
    private func startListener(_ server: LocalAPIServer) async throws -> NWEndpoint.Port {
        server.start(port: 0)
        try await waitUntil("listener readiness") {
            if case .starting = server.status { return false }
            return true
        }
        guard case .listening(let port) = server.status, port != 0 else {
            throw FixtureError(message: "Expected a bound loopback listener. Got \(server.status).")
        }
        return try XCTUnwrap(NWEndpoint.Port(rawValue: port))
    }

    private func openClient(_ port: NWEndpoint.Port) -> NWConnection {
        let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        client.start(queue: clientQueue)
        return client
    }

    private func send(_ request: String, to client: NWConnection) {
        client.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
    }

    @MainActor
    private func response(from client: NWConnection) async throws -> String {
        let response = OSAllocatedUnfairLock<Result<Data, NWError>?>(initialState: nil)
        // The fixture replies are smaller than 4 KiB and the server closes the write side.
        client.receive(minimumIncompleteLength: 4096, maximumLength: 4096) { @Sendable data, _, _, error in
            response.withLock {
                if let error, data == nil {
                    $0 = .failure(error)
                } else {
                    $0 = .success(data ?? Data())
                }
            }
        }
        try await waitUntil("HTTP response") { response.withLock { $0 != nil } }
        let received = try XCTUnwrap(response.withLock { $0 })
        return String(decoding: try received.get(), as: UTF8.self)
    }

    @MainActor
    private func waitUntil(_ description: String, _ condition: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(15)
        while !condition() {
            guard clock.now < deadline else {
                throw FixtureError(message: "Timed out waiting for \(description).")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
#endif
