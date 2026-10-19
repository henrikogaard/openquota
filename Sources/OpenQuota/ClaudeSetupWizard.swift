#if os(macOS)
import SwiftUI
import AppKit
import OpenQuotaCore

/// Three steps to connect one Claude login: pick which login, sign it in to
/// a folder, then name it and choose how it updates. Run once per account.
struct ClaudeSetupWizard: View {
    enum Login: String, CaseIterable, Identifiable {
        case main, another, desktop
        var id: String { rawValue }

        var title: String {
            switch self {
            case .main: L("My usual Claude Code login", "Min vanlige Claude Code-pålogging")
            case .another: L("Another Claude account", "En annen Claude-konto")
            case .desktop: L("Claude Desktop's account", "Kontoen i Claude Desktop")
            }
        }

        var detail: String {
            switch self {
            case .main:
                L("The login you get when you type claude in Terminal.",
                  "Påloggingen du får når du skriver claude i Terminal.")
            case .another:
                L("A second subscription in its own folder. Your usual login is not changed.",
                  "Et annet abonnement i en egen mappe. Den vanlige påloggingen endres ikke.")
            case .desktop:
                L("Claude Desktop keeps its login to itself, so you sign the same account in to a folder OpenQuota can check.",
                  "Claude Desktop holder påloggingen for seg selv, så du logger inn samme konto i en mappe OpenQuota kan sjekke.")
            }
        }

        var defaultFolder: String {
            switch self {
            case .main: "~/.claude"
            case .another: "~/.claude-work"
            case .desktop: "~/.claude-desktop"
            }
        }

        var defaultLabel: String {
            switch self {
            case .main: "Claude"
            case .another: L("Work", "Jobb")
            case .desktop: "Desktop"
            }
        }
    }

    enum Step { case choose, signIn, finish }

    var model: AppModel
    var onConnected: () -> Void = {}
    var onCancel: () -> Void = {}

    @State private var step = Step.choose
    @State private var login = Login.main
    @State private var folder = Login.main.defaultFolder
    @State private var label = ""
    @State private var cliUsageCheck = false
    @State private var status = ClaudeProfileStatus.folderMissing
    @State private var copied = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stepHeader
                    switch step {
                    case .choose: chooseStep
                    case .signIn: signInStep
                    case .finish: finishStep
                    }
                    if let errorText {
                        Text(errorText).font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            FormActions(
                primary: step == .finish ? L("Connect", "Koble til") : L("Continue", "Fortsett"),
                disabled: step == .signIn && status == .folderMissing,
                action: next,
                cancel: onCancel,
                back: backAction)
        }
        .task(id: "\(step)|\(folder)") {
            // Notice the sign-in in Terminal without a button press.
            while !Task.isCancelled {
                status = ClaudeProfileStatus.check(configDirectory: folder)
                guard step == .signIn else { return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var stepHeader: some View {
        let number = switch step { case .choose: 1; case .signIn: 2; case .finish: 3 }
        return Text(L("Step \(number) of 3", "Steg \(number) av 3"))
            .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Step 1

    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Which Claude login do you want to track?", "Hvilken Claude-pålogging vil du følge?"))
                .font(.headline)
            ForEach(Login.allCases) { option in
                Button {
                    login = option
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: login == option ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(login == option ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                            Text(option.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(L("Each account is its own connection. Run this setup again for every account you want to see.",
                   "Hver konto er en egen tilkobling. Kjør oppsettet på nytt for hver konto du vil se."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Step 2

    private var signInStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(login == .main ? L("Check your Claude login", "Sjekk Claude-påloggingen")
                                : L("Sign in to a separate folder", "Logg inn i en egen mappe"))
                .font(.headline)
            HStack {
                Text(L("Folder", "Mappe")).frame(width: 64, alignment: .leading)
                TextField(L("Folder", "Mappe"), text: $folder)
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .disabled(login == .main)
                Button(L("Choose…", "Velg…"), action: chooseFolder)
            }
            numbered(1, L("Copy this command and run it in Terminal:", "Kopier denne kommandoen og kjør den i Terminal:"))
            HStack(spacing: 8) {
                Text(command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                Button(copied ? L("Copied", "Kopiert") : L("Copy", "Kopier")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                Button(L("Open Terminal", "Åpne Terminal")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                }
            }
            numbered(2, signInHint)
            numbered(3, L("When Claude says you're signed in, type /exit. OpenQuota notices by itself.",
                          "Når Claude sier at du er logget inn, skriv /exit. OpenQuota merker det selv."))
            statusRow
        }
        .onChange(of: folder) { _, _ in copied = false }
    }

    private var signInHint: String {
        switch login {
        case .main:
            L("If Claude asks you to sign in, type /login and choose your Claude subscription.",
              "Hvis Claude ber deg logge inn, skriv /login og velg Claude-abonnementet ditt.")
        case .another:
            L("Follow Claude's sign-in steps (or type /login). Choose the Claude subscription you want to add, not an API key.",
              "Følg innloggingen i Claude (eller skriv /login). Velg abonnementet du vil legge til, ikke en API-nøkkel.")
        case .desktop:
            L("Follow Claude's sign-in steps (or type /login) with the same account Claude Desktop uses. Desktop shows it in its settings.",
              "Følg innloggingen i Claude (eller skriv /login) med samme konto som Claude Desktop bruker. Desktop viser den i innstillingene.")
        }
    }

    @ViewBuilder private var statusRow: some View {
        HStack(spacing: 8) {
            switch status {
            case .signedIn(let email):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(email.map { L("Signed in as \($0)", "Logget inn som \($0)") }
                     ?? L("Signed in", "Logget inn"))
            case .signedOut:
                ProgressView().controlSize(.small)
                Text(L("Folder found. Waiting for sign-in…", "Mappen finnes. Venter på pålogging…"))
                    .foregroundStyle(.secondary)
            case .folderMissing:
                ProgressView().controlSize(.small)
                Text(L("Waiting for Claude to create the folder…", "Venter på at Claude lager mappen…"))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    // MARK: Step 3

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Name it and choose how it updates", "Gi den et navn og velg hvordan den oppdateres"))
                .font(.headline)
            HStack {
                Text(L("Label", "Navn")).frame(width: 64, alignment: .leading)
                TextField(L("Label", "Navn"), text: $label, prompt: Text(login.defaultLabel))
                    .labelsHidden().textFieldStyle(.roundedBorder)
            }
            Toggle(L("Check with Claude CLI every 30 minutes", "Sjekk med Claude CLI hvert 30. minutt"), isOn: $cliUsageCheck)
            Text(L("Keeps the card current even when you don't use this login in Terminal. Also runs when you press Refresh. Each check sends one tiny request that counts toward this subscription. OpenQuota never sees your token.",
                   "Holder kortet oppdatert selv om du ikke bruker påloggingen i Terminal. Kjører også når du trykker Oppdater. Hver sjekk sender én liten forespørsel som teller mot abonnementet. OpenQuota ser aldri nøkkelen din."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("OpenQuota also adds a small status-line helper to this folder, so readings arrive right away while you use it. Your existing status line keeps working.",
                   "OpenQuota legger også til et lite statuslinjeprogram i mappen, så målinger kommer med en gang mens du bruker den. Den eksisterende statuslinjen fortsetter å virke."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private var command: String { ClaudeProfileStatus.signInCommand(configDirectory: folder) }

    private func numbered(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func next() {
        errorText = nil
        switch step {
        case .choose:
            folder = login.defaultFolder
            cliUsageCheck = login != .main
            label = ""
            step = .signIn
        case .signIn:
            step = .finish
        case .finish:
            connect()
        }
    }

    private var backAction: (() -> Void)? {
        step == .choose ? nil : { back() }
    }

    private func back() {
        errorText = nil
        step = step == .finish ? .signIn : .choose
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            folder = url.path
            if ClaudeProfileStatus.isDefault(url.path) { login = .main }
        }
    }

    private func connect() {
        guard let helper = ClaudeBridgeHelper.executable() else {
            errorText = L("The openquota-bridge helper is missing. Reinstall the app or run it from a complete build.", "Hjelpeprogrammet openquota-bridge mangler. Installer appen på nytt.")
            return
        }
        do {
            try model.installClaudeStatusLine(
                label: SubscriptionConnectForm.resolvedLabel(label, fallback: login.defaultLabel),
                configurationDirectory: folder,
                helper: helper,
                cliUsageCheck: cliUsageCheck)
            onConnected()
        } catch {
            errorText = ClaudeBridgeHelper.message(for: error)
        }
    }
}

/// Finds the bridge helper and words install errors; shared by setup UI.
enum ClaudeBridgeHelper {
    static func executable() -> URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/openquota-bridge")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        var candidates = [Bundle.main.executableURL].compactMap { $0 }
        if let argument = CommandLine.arguments.first {
            if argument.contains("/") {
                candidates.append(URL(fileURLWithPath: argument))
            } else {
                for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "")
                    .split(separator: ":").map(String.init) {
                    candidates.append(URL(fileURLWithPath: directory).appendingPathComponent(argument))
                }
            }
        }
        for candidate in candidates {
            let sibling = candidate.resolvingSymlinksInPath()
                .deletingLastPathComponent().appendingPathComponent("openquota-bridge")
            if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        return nil
    }

    static func message(for error: Error) -> String {
        guard let error = error as? ClaudeStatusLineInstallError else {
            return L("The subscription connection could not be saved.", "Abonnementstilkoblingen kunne ikke lagres.")
        }
        switch error {
        case .duplicateConfigurationDirectory:
            return L("That Claude configuration is already connected.", "Denne Claude-konfigurasjonen er allerede koblet til.")
        case .configurationDirectoryNotFound:
            return L("Choose an existing Claude configuration directory.", "Velg en eksisterende Claude-konfigurasjonsmappe.")
        case .invalidHelper:
            return L("The OpenQuota bridge helper is unavailable.", "Hjelpeprogrammet til OpenQuota er utilgjengelig.")
        case .recursiveBridge:
            return L("This status line already invokes OpenQuota. Disconnect it before reconnecting.", "Denne statuslinjen bruker allerede OpenQuota. Koble den fra før du kobler til på nytt.")
        case .unsupportedStatusLine:
            return L("The existing status-line type is unsupported; settings were not changed.", "Den eksisterende statuslinjetypen støttes ikke; innstillingene ble ikke endret.")
        case .malformedSettings, .settingsTooLarge:
            return L("Claude settings could not be read safely; no changes were made.", "Claude-innstillingene kunne ikke leses trygt; ingenting ble endret.")
        default:
            return L("Claude could not be connected. Check the label and configuration directory.", "Claude kunne ikke kobles til. Sjekk navnet og konfigurasjonsmappen.")
        }
    }
}
#endif
