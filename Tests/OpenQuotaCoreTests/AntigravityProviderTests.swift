import XCTest
@testable import OpenQuotaCore

final class AntigravityProviderTests: XCTestCase {
    private let token = "0f4c2a9e-6b1d-4e7a-9c3f-2d8b5a1e7c60"

    private func home(hubs: [(name: String, json: String)]) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let daemon = home.appendingPathComponent(AntigravityProvider.daemonPath)
        try FileManager.default.createDirectory(at: daemon, withIntermediateDirectories: true)
        for (offset, hub) in hubs.enumerated() {
            let url = daemon.appendingPathComponent(hub.name)
            try Data(hub.json.utf8).write(to: url)
            // Later entries are older.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: Double(-60 * offset))], ofItemAtPath: url.path)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    private func hubJSON(pid: Int, port: Int) -> String {
        #"{"pid":\#(pid),"httpsPort":\#(port - 1),"httpPort":\#(port),"lsVersion":"2.33.0","csrfToken":"\#(token)"}"#
    }

    private let status = """
        {"userStatus":{"email":"someone@example.com",
          "planStatus":{"planInfo":{"planName":"Pro"}},
          "userTier":{"description":"Google AI Ultra"},
          "cascadeModelConfigData":{
            "clientModelConfigs":[
              {"label":"Gemini 4 Neon (High)","modelId":"gemini-4-neon-high","quotaInfo":{"resetTime":"2026-11-20T01:01:28Z"}},
              {"label":"Gemini 4 Neon (Low)","modelId":"gemini-4-neon-low","quotaInfo":{"remainingFraction":0.4,"resetTime":"2026-11-20T01:01:28Z"}},
              {"label":"Claude Opus 5.5 (Low)","modelId":"claude-opus-5-5-low","quotaInfo":{"remainingFraction":0.75,"resetTime":"2026-11-20T03:05:09Z"}},
              {"label":"Claude Opus 5.5 (High)","modelId":"claude-opus-5-5-high","quotaInfo":{"remainingFraction":1,"resetTime":"2026-11-20T03:05:09Z"}},
              {"label":"GPT-OSS 120B (Medium)","modelId":"gpt-oss-120b-medium","quotaInfo":{"remainingFraction":1,"resetTime":"2026-11-20T03:05:09Z"}},
              {"label":"No Quota Model","modelId":"no-quota"},
              {"label":"Null Reset (High)","modelId":"null-reset-high","quotaInfo":{"resetTime":null}}
            ],
            "groupedModels":{
              "gemini-4-neon":{"displayName":"Gemini 4 Neon"},
              "claude-opus-5-5":{"displayName":"Claude Opus 5.5"}
            }}}}
        """

    func test_readsPerFamilyQuotaFromTheRunningLanguageServer() async throws {
        let home = try home(hubs: [("hub_58108.json", hubJSON(pid: 38008, port: 58108))])
        let http = RecordingHTTP()
        http.stub("GetUserStatus", body: status)
        let provider = AntigravityProvider(http: http, files: LocalCredentialFiles(home: home), isRunning: { _ in true })

        let accounts = try await provider.accounts()
        XCTAssertEqual(accounts.count, 1)
        let snapshot = try await provider.refresh(account: accounts[0])

        XCTAssertEqual(snapshot.windows.map(\.label), ["Gemini 4 Neon", "Claude Opus 5.5", "GPT-OSS 120B"])
        // A reset time with no fraction is proto3's omitted zero: used up.
        XCTAssertEqual(snapshot.windows[0].used, 100)
        XCTAssertEqual(snapshot.windows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-11-20T01:01:28Z"))
        // The most-used variant decides the family's row.
        XCTAssertEqual(try XCTUnwrap(snapshot.windows[1].used), 25, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[2].used, 0)
        XCTAssertEqual(snapshot.account.plan, "Google AI Ultra")
        XCTAssertEqual(snapshot.account.email, "someone@example.com")

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url.absoluteString,
                       "http://127.0.0.1:58108/exa.language_server_pb.LanguageServerService/GetUserStatus")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["X-Codeium-Csrf-Token"], token)
        XCTAssertEqual(request.headers["Connect-Protocol-Version"], "1")
        XCTAssertFalse(request.allowsRedirects)
    }

    func test_skipsHubsWhoseProcessIsGoneAndTriesTheNextOnFailure() async throws {
        let home = try home(hubs: [
            ("hub_1001.json", hubJSON(pid: 11, port: 1001)), // newest, process gone
            ("hub_2002.json", hubJSON(pid: 22, port: 2002)), // running, port refuses
            ("hub_2500.json", hubJSON(pid: 25, port: 2500)), // running, port reused by something else
            ("hub_3003.json", hubJSON(pid: 33, port: 3003)), // running, answers
        ])
        let http = RecordingHTTP()
        http.stub(":2002/", status: 403, body: "{}")
        http.stub(":2500/", body: "not json")
        http.stub(":3003/", body: status)
        let provider = AntigravityProvider(
            http: http, files: LocalCredentialFiles(home: home), isRunning: { $0 != 11 })

        let snapshot = try await provider.refresh(account: try await provider.accounts()[0])
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(http.requests.map { $0.url.port }, [2002, 2500, 3003])
    }

    func test_noRunningAppAsksToOpenIt() async throws {
        let home = try home(hubs: [("hub_1001.json", hubJSON(pid: 11, port: 1001))])
        let http = RecordingHTTP()
        let provider = AntigravityProvider(
            http: http, files: LocalCredentialFiles(home: home), isRunning: { _ in false })
        do {
            _ = try await provider.refresh(account: try await provider.accounts()[0])
            XCTFail("expected an error")
        } catch let error as ProviderError {
            XCTAssertTrue(error.userMessage.contains("Antigravity"), error.userMessage)
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func test_noDaemonFolderMeansNoAccount() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let provider = AntigravityProvider(http: RecordingHTTP(), files: LocalCredentialFiles(home: home))
        let accounts = try await provider.accounts()
        XCTAssertTrue(accounts.isEmpty)
    }

    func test_rejectsMalformedHubFiles() {
        XCTAssertNil(AntigravityProvider.hub(from: ["pid": 1, "httpPort": 70_000, "csrfToken": token]))
        XCTAssertNil(AntigravityProvider.hub(from: ["pid": 1, "httpPort": 80, "csrfToken": "short"]))
        XCTAssertNil(AntigravityProvider.hub(from: ["pid": 1, "httpPort": 80, "csrfToken": "bad token\r\nX-Evil: 1"]))
        XCTAssertNil(AntigravityProvider.hub(from: ["pid": 0, "httpPort": 80, "csrfToken": token]))
        XCTAssertEqual(AntigravityProvider.hub(from: ["pid": 5, "httpPort": 80, "csrfToken": token])?.port, 80)
    }
}
