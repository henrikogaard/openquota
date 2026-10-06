import Foundation
import XCTest
@testable import OpenQuotaCore

final class AccountProfilesTests: XCTestCase {
    func test_storePersistsProfileMetadataAndRemovesProfiles() throws {
        let directory = temporaryDirectory()
        let credentialFile = directory.appendingPathComponent("credentials.json")
        try Data("private-token-marker".utf8).write(to: credentialFile)
        let store = LocalAccountProfileStore(url: directory.appendingPathComponent("profiles.json"))

        let profile = try store.add(
            providerID: "claude",
            label: " Work ",
            credentialPath: credentialFile.path)

        XCTAssertEqual(profile.label, "Work")
        XCTAssertEqual(try store.profiles(), [profile])
        let persisted = try String(contentsOf: directory.appendingPathComponent("profiles.json"),
                                   encoding: .utf8)
        XCTAssertTrue(persisted.contains(credentialFile.path))
        XCTAssertTrue(persisted.contains("Work"))
        XCTAssertFalse(persisted.contains("private-token-marker"))

        try store.remove(id: profile.id)
        XCTAssertTrue(try store.profiles().isEmpty)
    }

    func test_storeValidatesProviderPathFileTypeAndSize() throws {
        let directory = temporaryDirectory()
        let credentialFile = directory.appendingPathComponent("credentials.json")
        try Data("{}".utf8).write(to: credentialFile)
        let store = LocalAccountProfileStore(url: directory.appendingPathComponent("profiles.json"))

        XCTAssertThrowsError(try store.add(
            providerID: "gemini", label: "Work", credentialPath: credentialFile.path)) {
            XCTAssertEqual($0 as? LocalAccountProfileError, .invalidProvider)
        }
        XCTAssertThrowsError(try store.add(
            providerID: "claude", label: "Work", credentialPath: "relative/path")) {
            XCTAssertEqual($0 as? LocalAccountProfileError, .invalidCredentialPath)
        }
        XCTAssertThrowsError(try store.add(
            providerID: "claude", label: "Work", credentialPath: directory.path)) {
            XCTAssertEqual($0 as? LocalAccountProfileError, .credentialNotRegularFile)
        }

        let oversizedFile = directory.appendingPathComponent("large.json")
        try Data(repeating: 0, count: Int(LocalAccountProfileStore.maxCredentialFileBytes) + 1)
            .write(to: oversizedFile)
        XCTAssertThrowsError(try store.add(
            providerID: "claude", label: "Work", credentialPath: oversizedFile.path)) {
            XCTAssertEqual($0 as? LocalAccountProfileError, .credentialFileTooLarge)
        }
    }

    func test_storeEnforcesProfileLimit() throws {
        let directory = temporaryDirectory()
        let credentialFile = directory.appendingPathComponent("credentials.json")
        try Data("{}".utf8).write(to: credentialFile)
        let store = LocalAccountProfileStore(url: directory.appendingPathComponent("profiles.json"))

        for index in 0..<LocalAccountProfileStore.maxProfiles {
            try store.add(
                providerID: "claude",
                label: "Profile \(index)",
                credentialPath: credentialFile.path)
        }
        XCTAssertThrowsError(try store.add(
            providerID: "claude", label: "Overflow", credentialPath: credentialFile.path)) {
            XCTAssertEqual($0 as? LocalAccountProfileError, .profileLimitReached)
        }
    }

    func test_profiledProviderNamespacesAccountsAndRewritesRefreshIdentity() async throws {
        let first = AccountDescriptor(
            account: AccountIdentity(providerID: "codex", id: "codex@1", label: "Personal"),
            source: .configFile,
            isDefaultHome: true)
        let second = AccountDescriptor(
            account: AccountIdentity(providerID: "codex", id: "codex@2", label: "Business"),
            source: .keychainItem,
            isDefaultHome: true)
        let base = StaticProfileTestProvider(accounts: [first, second])
        let profile = LocalAccountProfile(
            id: "profile-1", providerID: "codex", label: "Work", credentialPath: "/unused")
        let provider = ProfiledProvider(profile: profile, base: base)
        let accounts = try await provider.accounts()

        XCTAssertEqual(accounts.map(\.account.id), [
            AccountIdentity.makeID(providerID: "codex", identityKey: "profile-1/codex@1"),
            AccountIdentity.makeID(providerID: "codex", identityKey: "profile-1/codex@2"),
        ])
        XCTAssertEqual(accounts[0].account.label, "Work · Personal")
        XCTAssertEqual(accounts[1].account.label, "Work · Business")
        XCTAssertTrue(accounts.allSatisfy { !$0.isDefaultHome })
        XCTAssertEqual(accounts.map(\.source), [.configFile, .keychainItem])

        let snapshot = try await provider.refresh(account: accounts[1])
        XCTAssertEqual(snapshot.account.id, accounts[1].account.id)
        XCTAssertEqual(snapshot.account.label, "Work · Business")
        XCTAssertEqual(snapshot.account.plan, "Team")
        XCTAssertEqual(snapshot.providerID, "codex")
    }

    func test_singleAccountProfileUsesOnlyProfileLabel() async throws {
        let descriptor = AccountDescriptor(
            account: AccountIdentity(providerID: "grok", id: "grok@1", label: "Old label"),
            source: .configFile)
        let provider = ProfiledProvider(
            profile: LocalAccountProfile(
                id: "profile-2", providerID: "grok", label: "Personal", credentialPath: "/unused"),
            base: StaticProfileTestProvider(accounts: [descriptor]))

        let accounts = try await provider.accounts()
        let account = try XCTUnwrap(accounts.first)
        XCTAssertEqual(account.account.label, "Personal")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}

private struct StaticProfileTestProvider: UsageProvider {
    let descriptors: [AccountDescriptor]
    let id: String

    init(accounts: [AccountDescriptor]) {
        self.descriptors = accounts
        self.id = accounts.first?.account.providerID ?? "test"
    }

    var displayName: String { "Test" }
    var dashboardURL: URL? { nil }

    func accounts() async throws -> [AccountDescriptor] {
        descriptors
    }

    func refresh(account: AccountDescriptor) async throws -> UsageSnapshot {
        var identity = account.account
        identity.plan = "Team"
        return UsageSnapshot(account: identity, providerID: id)
    }
}
