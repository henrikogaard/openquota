# Privacy and credential handling

[README](../README.md) · [Accounts](accounts.md) · [Provider reference](providers.md)

OpenQuota has no central service receiving your credentials. Usage requests go
to the configured provider. Protection at rest cannot turn a broad session into
a read-only credential or guarantee secrecy on a compromised Mac.

| Data | Storage/owner |
|---|---|
| Pasted API keys and Cursor sessions | macOS Keychain, device-only and non-synchronizable |
| Claude login | Claude Code's own storage; the bridge does not copy credentials |
| Codex login | Codex-managed files in an independent home per connection |
| Other local sign-ins | Provider-owned files; some adapters write refreshed tokens back |
| Profile/connection metadata | Local labels, IDs, paths—not keys |
| Last-good usage | Bounded local snapshot cache |
| Claude bridge | Sanitized percentages, reset times, and timestamp |
| Local spend estimates | Opt-in bounded scan; parsed usage cache remains in memory |

App-written private files use 0600 permissions in 0700 directories. Existing
files acquire these protections when rewritten; this is not an audit of all
provider-owned files.

## Data access

- Networking uses ephemeral sessions without retained cookies or response caches.
- Cursor is explicitly opt-in, manually supplied, and unofficial. No automatic
  browser import or session renewal occurs.
- The Claude bridge saves only allowlisted quota fields. It invokes any existing
  status-line command with its original input; that command stays under your control.
- Optional spend scanning reads local logs transiently, retaining parsed usage
  rather than prompts/responses. No pricing request uploads your logs.
  See [scan limits and exclusions](estimated-spend.md).
- Sparkle checks and downloads updates from GitHub.

Credentials must never be logged, cached in snapshots, echoed in errors, or
placed in URL parameters or subprocess arguments. Custom provider specs are
trusted configuration: inspect their hosts and mappings, and never put secrets
directly into the JSON.

## Removal is not revocation

Removing a saved key deletes OpenQuota's Keychain entry, not the key at the
provider. Local credential files and Codex's managed home remain after removing
a connection. Claude disconnect restores the previous status line only if the
installed wrapper is unchanged.

Revoke access through provider controls or the correct CLI profile's logout.
Deleting the app bundle does not revoke credentials or remove all Application
Support and Keychain data.
