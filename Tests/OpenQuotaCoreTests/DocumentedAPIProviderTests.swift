import XCTest
@testable import OpenQuotaCore

final class DocumentedAPIProviderTests: XCTestCase {
    private func refresh(_ spec: ProviderSpec, body: String,
                         stubs: [(String, String)] = []) async throws -> (UsageSnapshot, RecordingHTTP) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let http = RecordingHTTP()
        http.defaultBody = body
        for (match, stub) in stubs { http.stub(match, body: stub) }
        let provider = GenericProvider(
            spec: spec, http: http, credentials: FileCredentialStore(directory: dir),
            manifestURL: dir.appendingPathComponent("keys.json"))
        _ = try provider.addKey("sk-test", label: "test")
        let snapshot = try await provider.refresh(account: try provider.accounts()[0])
        return (snapshot, http)
    }

    func test_clinePassMapsTypedPercentWindows() async throws {
        let (snapshot, _) = try await refresh(SpecLibrary.clinePass, body: """
            {"data":{"limits":[
              {"type":"five_hour","percentUsed":40,"resetsAt":"2030-01-01T00:00:00Z"},
              {"type":"weekly","percentUsed":10,"resetsAt":null}]}}
            """)
        let byLabel = Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.label, $0) })
        XCTAssertEqual(byLabel["5 hours"]?.percentRemaining, 60)
        XCTAssertNotNil(byLabel["5 hours"]?.resetsAt)
        XCTAssertEqual(byLabel["Week"]?.percentRemaining, 90)
        XCTAssertNil(byLabel["Month"], "absent windows stay absent")
    }

    func test_zenMuxUsesFlowCountsAndPlanTier() async throws {
        let (snapshot, _) = try await refresh(SpecLibrary.zenMux, body: """
            {"success":true,"data":{"plan":{"tier":"pro"},"account_status":"healthy",
              "quota_5_hour":{"used_flows":25,"max_flows":100,"resets_at":"2030-01-01T00:00:00Z"},
              "quota_7_day":{"used_flows":300,"max_flows":1000}}}
            """)
        XCTAssertEqual(snapshot.account.plan, "pro")
        XCTAssertEqual(snapshot.windows.first?.percentRemaining, 75)
        XCTAssertEqual(snapshot.windows.last?.percentRemaining, 70)
    }

    func test_vercelBalanceFromDecimalStrings() async throws {
        let (snapshot, http) = try await refresh(SpecLibrary.vercelGateway,
                                                 body: #"{"balance":"12.50","total_used":"7.5"}"#)
        XCTAssertEqual(snapshot.creditsRemaining, 12.5)
        XCTAssertEqual(snapshot.windows.first { $0.label == "Lifetime spend" }?.used, 7.5)
        XCTAssertEqual(http.requests[0].headers["Authorization"], "Bearer sk-test")
    }

    func test_codebuffPostsJSONBody() async throws {
        let (snapshot, http) = try await refresh(SpecLibrary.codebuff,
                                                 body: #"{"usage":200,"quota":1000,"remainingBalance":800}"#)
        XCTAssertEqual(http.requests[0].method, "POST")
        XCTAssertEqual(http.requests[0].headers["Content-Type"], "application/json")
        XCTAssertEqual(snapshot.windows[0].percentRemaining, 80)
        XCTAssertEqual(snapshot.creditsRemaining, 800)
    }

    func test_v0TokenBillingAndSeparateRateLimitEndpoint() async throws {
        let (snapshot, http) = try await refresh(SpecLibrary.v0, body: """
            {"billingType":"token","data":{"balance":{"total":20,"remaining":5},"billingCycle":{"end":1900000000}}}
            """, stubs: [("rate-limits", #"{"limit":100,"remaining":90,"reset":1900000000}"#)])
        let labels = snapshot.windows.map(\.label)
        XCTAssertEqual(labels, ["Billing", "Requests"])
        XCTAssertEqual(snapshot.windows[0].percentRemaining, 25)
        XCTAssertEqual(http.requests.count, 2)
    }

    func test_poeAtlasAndDevPassBalances() async throws {
        let (poe, _) = try await refresh(SpecLibrary.poe, body: #"{"current_point_balance":4200}"#)
        XCTAssertEqual(poe.windows[0].remaining, 4200)
        let (atlas, _) = try await refresh(SpecLibrary.atlasCloud,
            body: #"{"object":"balance","scope":"account","available":{"value":"3.10","currency":"usd"}}"#)
        XCTAssertEqual(atlas.creditsRemaining, 3.1)
        let (devpass, _) = try await refresh(SpecLibrary.devPass, body: """
            {"data":{"devPlan":"pro","usage":"1.00","limit":null,"devPlanCreditsUsed":"5",
             "devPlanCreditsLimit":"20","devPlanPremiumCreditsUsed":"1","devPlanPremiumWeeklyLimit":"4",
             "devPlanPremiumWeekResetsAt":null}}
            """)
        XCTAssertEqual(devpass.account.plan, "pro")
        XCTAssertEqual(devpass.windows[0].percentRemaining, 75)
    }

    func test_opencodeGoPastedKeyMapsWindowsAndBalance() async throws {
        let (snapshot, http) = try await refresh(SpecLibrary.opencodeGo, body: """
            {"usage":{"rolling":{"percent":25,"resetsAt":"2030-01-01T00:00:00Z"},
              "weekly":{"percent":60},"monthly":{"percent":5},"balance":3.5}}
            """)
        let byLabel = Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.label, $0) })
        XCTAssertEqual(byLabel["5h"]?.percentRemaining, 75)
        XCTAssertNotNil(byLabel["5h"]?.resetsAt)
        XCTAssertEqual(byLabel["Week"]?.percentRemaining, 40)
        XCTAssertEqual(byLabel["Month"]?.percentRemaining, 95)
        XCTAssertEqual(snapshot.creditsRemaining, 3.5)
        XCTAssertEqual(http.requests[0].headers["Authorization"], "Bearer sk-test")
    }

    func test_opencodeGoKeysStaySeparate() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let provider = GenericProvider(
            spec: SpecLibrary.opencodeGo, http: RecordingHTTP(),
            credentials: FileCredentialStore(directory: dir),
            manifestURL: dir.appendingPathComponent("keys.json"))
        _ = try provider.addKey("go-key-personal", label: "Personal")
        _ = try provider.addKey("go-key-work", label: "Work")
        let accounts = try await provider.accounts()
        XCTAssertEqual(Set(accounts.map(\.account.id)).count, 2)
        XCTAssertEqual(Set(accounts.map(\.account.label)), ["Personal", "Work"])
    }
}
