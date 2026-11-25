import XCTest
@testable import OpenQuotaCore

final class MistralVibeCLITests: XCTestCase {
    func testCLIKeyPrecedenceAndCustomHome() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let http = RecordingHTTP()
        http.stub("/budget", body: #"{"vibe_budget":{"usage_percentage":10,"initial_budget":20}}"#)
        http.stub("/subscription", body: #"{"vibe_payg_enabled":true}"#)
        for assignment in ["export MISTRAL_API_KEY='work' # team", "MISTRAL_API_KEY=work # team"] {
            try Data(assignment.utf8).write(to: home.appendingPathComponent(".env"))
            let provider = MistralVibeCLIProvider(http: http, files: .init(home: home),
                                                  environment: ["VIBE_HOME": home.path], keychain: { "personal" })
            let accounts = try await provider.accounts()
            let account = try XCTUnwrap(accounts.first)
            XCTAssertEqual(account.source, .configFile)
            let snapshot = try await provider.refresh(account: account)
            XCTAssertTrue(snapshot.windows[0].label.contains(Localized.text("PAYG on", "betaling per bruk på")))
            XCTAssertTrue(http.requests.allSatisfy { $0.headers["Authorization"] == "Bearer work" && !$0.allowsRedirects })
        }
    }
    func testVibeAllowanceIsIndependentOfConsoleAndSharedBudget() async throws {
        let http = RecordingHTTP()
        http.stub("/billing/budget", body: """
        {"usage_percentage":88,"api_budget":{"usage_percentage":91},
         "vibe_budget":{"usage_percentage":0.5,"initial_budget":25,"reset_at":"2026-12-01T00:00:00Z","payg_enabled":true}}
        """)
        let provider = MistralVibeCLIProvider(http: http, credential: { ("fixture", .keychainItem) })
        let accounts = try await provider.accounts()
        let account = try XCTUnwrap(accounts.first)
        XCTAssertTrue(account.id.hasPrefix("mistral-vibe-cli@"))
        XCTAssertTrue(http.requests.isEmpty)
        let snapshot = try await provider.refresh(account: account)
        XCTAssertEqual(snapshot.windows.map(\.used), [0.5])
        XCTAssertEqual(snapshot.windows.first?.resetsAt, ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://api.mistral.ai/v1/billing/budget")
        XCTAssertFalse(request.allowsRedirects)
        XCTAssertEqual(request.headers["Authorization"], "Bearer fixture")
    }

    func testMissingAndForbiddenBudgetsDoNotReportUnusedAllowance() async throws {
        for (status, body) in [(200, #"{"usage_percentage":0}"#),
                              (200, #"{"vibe_budget":{"usage_percentage":0,"initial_budget":0}}"#),
                              (403, "{}")] {
            let http = RecordingHTTP()
            http.stub("/billing/budget", status: status, body: body)
            let provider = MistralVibeCLIProvider(http: http, credential: { ("fixture", .configFile) })
            let accounts = try await provider.accounts()
            let account = try XCTUnwrap(accounts.first)
            do {
                _ = try await provider.refresh(account: account)
                XCTFail("Expected unavailable allowance")
            } catch ProviderError.badResponse { }
        }
    }
}
