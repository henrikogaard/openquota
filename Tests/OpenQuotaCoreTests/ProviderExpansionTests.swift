import XCTest
@testable import OpenQuotaCore

/// Captures requests and returns canned responses keyed by URL substring.
final class RecordingHTTP: HTTPClient, @unchecked Sendable {
    var requests: [HTTPRequest] = []
    var responses: [(match: String, response: HTTPResponse)] = []
    var defaultBody = "{}"

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        for (match, response) in responses
        where request.url.absoluteString.contains(match) {
            return response
        }
        return HTTPResponse(status: 200, headers: [:], body: Data(defaultBody.utf8))
    }

    func stub(_ urlPart: String, status: Int = 200, body: String,
              headers: [String: String] = [:]) {
        responses.append((urlPart, HTTPResponse(
            status: status, headers: headers, body: Data(body.utf8))))
    }
}

final class JSONPathExtensionTests: XCTestCase {
    func test_wildcardFlattenAndKeyAccess() {
        let root: [String: Any] = [
            "data": [
                ["amount": ["value": 1.5]],
                ["amount": ["value": 2.0]],
            ]
        ]
        XCTAssertEqual(JSONPath.sum(root, at: "$.data[*].amount.value"), 3.5)
    }

    func test_keyValueFilter() {
        let root: [String: Any] = [
            "limits": [
                ["type": "TIME_LIMIT", "percentage": 80],
                ["type": "TOKENS_LIMIT", "percentage": 60],
            ]
        ]
        XCTAssertEqual(
            JSONPath.double(root, at: "$.limits[type=TOKENS_LIMIT].percentage"), 60)
    }

    func test_epochMillisDate() {
        let root: [String: Any] = ["t": 1_800_000_000_000.0]
        XCTAssertEqual(
            JSONPath.date(root, at: "$.t", format: "epochMillis"),
            Date(timeIntervalSince1970: 1_800_000_000))
    }

    func test_sumOnScalarAndStrings() {
        let root: [String: Any] = ["v": "2.5", "xs": [1, "2", 3.5]]
        XCTAssertEqual(JSONPath.sum(root, at: "$.v"), 2.5)
        XCTAssertEqual(JSONPath.sum(root, at: "$.xs"), 6.5)
    }
}

final class SpecLibraryTests: XCTestCase {
    private func makeProvider(
        _ spec: ProviderSpec, dir: URL
    ) throws -> (GenericProvider, RecordingHTTP) {
        let http = RecordingHTTP()
        let credentials = FileCredentialStore(directory: dir)
        let provider = GenericProvider(
            spec: spec, http: http, credentials: credentials,
            manifestURL: dir.appendingPathComponent("\(spec.id)-keys.json"))
        _ = try provider.addKey("sk-test", label: "test")
        return (provider, http)
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
    }

    func test_everyLibrarySpecHasADisplayNameAndWindows() {
        for spec in SpecLibrary.all {
            XCTAssertFalse(spec.displayName.isEmpty, spec.id)
            XCTAssertFalse(spec.url.isEmpty, spec.id)
            XCTAssertFalse(spec.windows.isEmpty, "\(spec.id) has no windows")
        }
    }

    func test_deepseekBalance() async throws {
        let dir = tempDir()
        let (provider, http) = try makeProvider(SpecLibrary.deepseek, dir: dir)
        http.defaultBody = """
            {"is_available":true,"balance_infos":[
              {"currency":"USD","total_balance":"7.25","granted_balance":"0","topped_up_balance":"7.25"}]}
            """
        let accounts = try await provider.accounts()
        let snapshot = try await provider.refresh(account: accounts[0])
        XCTAssertEqual(snapshot.creditsRemaining, 7.25)
        XCTAssertEqual(snapshot.windows[0].remaining, 7.25)
        XCTAssertEqual(http.requests[0].headers["Authorization"], "Bearer sk-test")
    }

    func test_elevenLabsUsesCustomHeaderAndParsesQuota() async throws {
        let dir = tempDir()
        let (provider, http) = try makeProvider(SpecLibrary.elevenLabs, dir: dir)
        http.defaultBody = """
            {"tier":"free","character_count":2500,"character_limit":10000,
             "next_character_count_reset_unix":1800000000}
            """
        let snapshot = try await provider.refresh(account: try provider.accounts()[0])
        XCTAssertEqual(snapshot.account.plan, "free")
        let window = snapshot.windows[0]
        XCTAssertEqual(window.used, 2500)
        XCTAssertEqual(window.limit, 10000)
        XCTAssertEqual(window.percentRemaining, 75)
        XCTAssertNotNil(window.resetsAt)
        XCTAssertEqual(http.requests[0].headers["xi-api-key"], "sk-test")
        XCTAssertNil(http.requests[0].headers["Authorization"])
    }

    func test_zaiFiltersLimitsByType() async throws {
        let dir = tempDir()
        let (provider, http) = try makeProvider(SpecLibrary.zai, dir: dir)
        http.defaultBody = """
            {"code":200,"data":{"limits":[
              {"type":"TIME_LIMIT","percentage":82,"nextResetTime":1800000000000},
              {"type":"TOKENS_LIMIT","percentage":45,"nextResetTime":1800000000000},
              {"type":"WEB_SEARCH","percentage":90}]}}
            """
        let snapshot = try await provider.refresh(account: try provider.accounts()[0])
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.windows[0].remaining, 82)
        XCTAssertEqual(snapshot.windows[1].remaining, 45)
        XCTAssertEqual(snapshot.windows[0].resetsAt,
                       Date(timeIntervalSince1970: 1_800_000_000))
    }

    func test_warpPostsGraphQLBody() async throws {
        let dir = tempDir()
        let (provider, http) = try makeProvider(SpecLibrary.warp, dir: dir)
        http.defaultBody = """
            {"data":{"requestLimitInfo":{"isUnlimited":false,"requestLimit":2500,
              "requestsUsedSincePeriodStart":400,
              "nextLimitResetTime":"2027-01-01T00:00:00Z"}}}
            """
        let snapshot = try await provider.refresh(account: try provider.accounts()[0])
        XCTAssertEqual(snapshot.windows[0].used, 400)
        XCTAssertEqual(snapshot.windows[0].limit, 2500)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertNotNil(request.body)
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
    }

    func test_openAIAdminSumsBucketsAndSubstitutesURL() async throws {
        let dir = tempDir()
        let (provider, http) = try makeProvider(SpecLibrary.openAIAdmin, dir: dir)
        http.defaultBody = """
            {"object":"page","data":[
              {"results":[{"amount":{"value":1.5,"currency":"usd"}},
                          {"amount":{"value":0.5,"currency":"usd"}}]},
              {"results":[{"amount":{"value":2.0,"currency":"usd"}}]}],
             "has_more":false}
            """
        let snapshot = try await provider.refresh(account: try provider.accounts()[0])
        XCTAssertEqual(snapshot.windows[0].used, 4.0)
        // {d30} template substituted with epoch seconds.
        let url = http.requests[0].url.absoluteString
        XCTAssertTrue(url.contains("start_time="), url)
        XCTAssertFalse(url.contains("{d30}"), url)
    }

    func test_perplexityCookieAuthHeader() async throws {
        let dir = tempDir()
        let (provider, http) = try makeProvider(SpecLibrary.perplexity, dir: dir)
        http.defaultBody = #"{"data":{"credits":42}}"#
        _ = try await provider.refresh(account: try provider.accounts()[0])
        XCTAssertEqual(http.requests[0].headers["Cookie"], "sk-test")
        XCTAssertNil(http.requests[0].headers["Authorization"])
    }

    func test_unverifiedFlagPropagates() {
        XCTAssertTrue(GenericProvider(
            spec: SpecLibrary.zai, http: RecordingHTTP(),
            credentials: FileCredentialStore(directory: tempDir())).unverified)
        XCTAssertTrue(GenericProvider(
            spec: BuiltinProviders.openRouter, http: RecordingHTTP(),
            credentials: FileCredentialStore(directory: tempDir())).unverified)
    }
}

final class AdapterTests: XCTestCase {
    private func tempHome() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent(".gemini"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent(".grok"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent(".local/share/opencode"),
            withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent(".local/share/devin"),
            withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent(".config/gh"), withIntermediateDirectories: true)
        return url
    }

    private func write(_ home: URL, _ path: String, _ contents: String) throws {
        try Data(contents.utf8).write(
            to: home.appendingPathComponent(path))
    }

    func test_noFilesMeansNoAccounts() async throws {
        let home = tempHome()
        let files = LocalCredentialFiles(home: home)
        let http = RecordingHTTP()
        let creds = FileCredentialStore(
            directory: home.appendingPathComponent("creds"))
        for adapter in Adapters.all(http: http, credentials: creds, files: files) {
            let found = try await adapter.accounts()
            XCTAssertTrue(found.isEmpty, adapter.id)
        }
    }

    func test_grokMultiEntry() async throws {
        let home = tempHome()
        try write(home, ".grok/auth.json", """
            {"work":{"key":"a1","expires_at":"2100-01-01T00:00:00Z"},
             "play":{"key":"a2","expires_at":"2100-01-01T00:00:00Z"}}
            """)
        let http = RecordingHTTP()
        http.defaultBody = #"{"config":{"creditUsagePercent":0.5,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2027-01-01T00:00:00Z"}}}"#
        let provider = GrokProvider(
            http: http, files: LocalCredentialFiles(home: home))
        let accounts = try await provider.accounts()
        XCTAssertEqual(accounts.count, 2)
        let snapshot = try await provider.refresh(account: accounts[0])
        XCTAssertEqual(snapshot.windows[0].used, 0.5)
        XCTAssertNil(snapshot.creditsRemaining)
        XCTAssertEqual(http.requests[0].headers["X-XAI-Token-Auth"], "xai-grok-cli")
    }

    func test_opencodeReadsApiKey() async throws {
        let home = tempHome()
        try write(home, ".local/share/opencode/auth.json", """
            {"opencode-go":{"type":"api","key":"zen-key-1"}}
            """)
        let http = RecordingHTTP()
        http.defaultBody = """
            {"usage":{"rolling":{"percent":0.5,"resetsAt":"2027-01-01T00:00:00Z"},
              "weekly":{"percent":8,"resetsAt":"2027-01-08T00:00:00Z"}}}
            """
        let provider = OpenCodeProvider(
            http: http, files: LocalCredentialFiles(home: home))
        let snapshot = try await provider.refresh(
            account: try provider.accounts()[0])
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].used, 0.5)
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
        XCTAssertEqual(
            http.requests[0].headers["Authorization"], "Bearer zen-key-1")
    }

    func test_devinParsesTomlAndPostsConnect() async throws {
        let home = tempHome()
        try write(home, ".local/share/devin/credentials.toml", """
            api_key = "dv-key-42"
            api_server_url = "https://server.codeium.com"
            """)
        let http = RecordingHTTP()
        http.defaultBody = """
            {"userStatus":{"planStatus":{"weeklyQuotaRemainingPercent":88,
              "weeklyQuotaResetAtUnix":"1800000000","overageBalanceMicros":"40000000",
              "planInfo":{"planName":"pro"}}}}
            """
        let provider = DevinProvider(
            http: http, files: LocalCredentialFiles(home: home))
        let snapshot = try await provider.refresh(
            account: try provider.accounts()[0])
        XCTAssertEqual(snapshot.windows[0].used, 12)
        XCTAssertEqual(snapshot.creditsRemaining, 40)
        let request = http.requests[0]
        XCTAssertTrue(request.url.absoluteString.contains(
            "SeatManagementService/GetUserStatus"))
        XCTAssertEqual(request.method, "POST")
        let payload = try JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any]
        XCTAssertEqual((payload?["metadata"] as? [String: Any])?["apiKey"] as? String, "dv-key-42")
        XCTAssertEqual(
            request.headers["Connect-Protocol-Version"], "1")
    }

    func test_cursorParsesSessionCookie() async throws {
        let home = tempHome()
        let creds = FileCredentialStore(
            directory: home.appendingPathComponent("creds"))
        let http = RecordingHTTP()
        let provider = CursorProvider(http: http, credentials: creds,
                                      manifestURL: home.appendingPathComponent("cursor-keys.json"))
        _ = try provider.addSessionToken("user-123::jwt-abc")
        let accounts = try await provider.accounts()
        XCTAssertEqual(accounts.count, 1)
        http.stub("GetCurrentPeriodUsage", body: """
            {"planUsage":{"totalSpend":12000,"limit":50000},
             "billingCycleEnd":"2027-02-01T00:00:00Z"}
            """)
        http.stub("GetPlanInfo", body: #"{"planName":"pro"}"#)
        http.stub("GetCreditGrantsBalance", body: #"{"totalCents":1000,"usedCents":250}"#)
        let snapshot = try await provider.refresh(account: accounts[0])
        XCTAssertEqual(snapshot.account.plan, "pro")
        XCTAssertEqual(snapshot.windows[0].used, 120)
        XCTAssertEqual(snapshot.windows[0].limit, 500)
        XCTAssertEqual(snapshot.creditsRemaining, 7.5)
        let usageReq = http.requests.first {
            $0.url.absoluteString.contains("GetCurrentPeriodUsage")
        }
        XCTAssertEqual(usageReq?.headers["Authorization"], "Bearer jwt-abc")
    }

    func test_copilotExchangesGhTokenThenReadsQuotas() async throws {
        let home = tempHome()
        try write(home, ".config/gh/hosts.yml", """
            github.com:
                oauth_token: gho_test123
                user: henrik
            """)
        let http = RecordingHTTP()
        http.stub("v2/token", body: #"{"token":"cop-tok","expires_at":1800000000}"#)
        http.stub("copilot_internal/user", body: """
            {"quota_snapshots":{
              "premium_interactions":{"percent_remaining":62,"entitlement":300},
              "chat":{"percent_remaining":95,"entitlement":1000}},
             "quota_reset_date":"2027-02-01"}
            """)
        let provider = CopilotProvider(
            http: http, files: LocalCredentialFiles(home: home))
        let snapshot = try await provider.refresh(
            account: try provider.accounts()[0])
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(http.requests[0].headers["Authorization"],
                       "Bearer gho_test123")
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].remaining, 62)
    }

    func test_geminiAbsentWithoutCreds() async throws {
        let provider = GeminiProvider(
            http: RecordingHTTP(),
            files: LocalCredentialFiles(home: tempHome()))
        let accounts = try await provider.accounts()
        XCTAssertTrue(accounts.isEmpty)
    }
}

final class CLIProviderTests: XCTestCase {
    func test_missingBinaryHasNoAccounts() async throws {
        let provider = CLIProvider(spec: .init(
            id: "nope", displayName: "Nope", binary: "definitely-missing-cli",
            args: ["--json"], windows: []), searchPath: ["/nonexistent"])
        let accounts = try await provider.accounts()
        XCTAssertTrue(accounts.isEmpty)
    }

    func test_scriptOutputMapsToWindows() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("fakecli")
        try Data("""
            #!/bin/sh
            echo '{"used": 30, "limit": 100}'
            """.utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        let provider = CLIProvider(spec: .init(
            id: "fake", displayName: "Fake", binary: "fakecli", args: [],
            windows: [.init(label: "Month", used: "$.used", limit: "$.limit")]),
            searchPath: [dir.path])
        let accounts = try await provider.accounts()
        XCTAssertEqual(accounts.count, 1)
        let snapshot = try await provider.refresh(account: accounts[0])
        XCTAssertEqual(snapshot.windows[0].percentRemaining, 70)
    }

    func test_largeValidOutputIsDrainedPastPipeCapacity() async throws {
        let filler = String(repeating: "x", count: 256)
        let script = try makeScript("""
            printf '{"used":30,"limit":100,"padding":"'
            i=0
            while [ "$i" -lt 400 ]; do
              printf '\(filler)'
              i=$((i + 1))
            done
            printf '"}\\n'
            """)

        let data = try await CLIProvider.run(binary: script, args: [])
        XCTAssertGreaterThan(data.count, 64 * 1024)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((json["used"] as? NSNumber)?.doubleValue, 30)
    }

    func test_outputOverOneMiBIsRejected() async throws {
        let filler = String(repeating: "x", count: 256)
        let script = try makeScript("""
            printf '{"padding":"'
            i=0
            while [ "$i" -lt 5000 ]; do
              printf '\(filler)'
              i=$((i + 1))
            done
            printf '"}\\n'
            """)

        do {
            _ = try await CLIProvider.run(binary: script, args: [])
            XCTFail("CLI output above the cap must fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .badResponse("CLI output too large"))
        }
    }

    func test_cancellationStopsLongRunningCLI() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("started")
        let script = directory.appendingPathComponent("fakecli")
        try Data("""
            #!/bin/sh
            printf started > "\(marker.path)"
            while :; do sleep 1; done
            """.utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        let task = Task {
            try await CLIProvider.run(binary: script, args: [])
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled CLI must not complete successfully")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        }
    }

    func test_cliRegistryFindsBundledSpecs() {
        let providers = CLIProviders.all(environment: ["PATH": "/usr/bin"])
        XCTAssertEqual(providers.map(\.id), ["amp", "kiro", "augment"])
    }

    private func makeScript(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fakecli")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}

final class RegressionTests: XCTestCase {
    /// Bug found by live testing: `%x` on UInt64 reads only the low 32 bits
    /// on Darwin, so every account id was `provider@00000000` and a second
    /// key silently overwrote the first in the manifest + keychain.
    func test_makeID_differsAcrossKeys() {
        let a = AccountIdentity.makeID(providerID: "deepseek", identityKey: "sk-one")
        let b = AccountIdentity.makeID(providerID: "deepseek", identityKey: "sk-two")
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.hasSuffix("@00000000"))
        XCTAssertFalse(b.hasSuffix("@00000000"))
    }

    /// Bug found by live testing: a first-failure snapshot got providerID ""
    /// so error cards rendered without a provider name.
    func test_failureSnapshotKeepsProviderID() async {
        let store = SnapshotStore()
        await store.finishRefresh(
            accountID: "deepseek@deadbeef",
            result: .failure(.unauthorized))
        let snapshot = await store.snapshot(for: "deepseek@deadbeef")
        XCTAssertEqual(snapshot?.providerID, "deepseek")
        XCTAssertEqual(snapshot?.account.providerID, "deepseek")
    }
}

final class ProviderRegistryTests: XCTestCase {
    func test_registryContainsSpecsAdaptersAndCLIs() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let registry = ProviderRegistry(
            http: RecordingHTTP(),
            credentials: FileCredentialStore(directory: home),
            environment: ["PATH": "/usr/bin"])
        let ids = Set(registry.providers.map(\.id))
        // spec library
        for specID in SpecLibrary.all.map(\.id) {
            XCTAssertTrue(ids.contains(specID), specID)
        }
        // adapters
        for adapterID in ["gemini", "grok", "opencode",
                          "devin", "cursor", "copilot"] {
            XCTAssertTrue(ids.contains(adapterID), adapterID)
        }
        XCTAssertFalse(ids.contains("claude"))
        XCTAssertFalse(ids.contains("codex"))
        // cli providers
        for cliID in ["amp", "kiro", "augment"] {
            XCTAssertTrue(ids.contains(cliID), cliID)
        }
    }
}
