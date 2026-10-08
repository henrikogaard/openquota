# Accounts and subscriptions

[README](../README.md) · [Troubleshooting](troubleshooting.md) · [Privacy](privacy.md)

Use **Settings → Accounts → +**. Pick a provider, then its connection method.
A provider login, workspace subscription, and API key are not always the same
thing. Give independently monitored sources labels such as “Personal” and “Work”.
Blank names get a default.

## Claude: another subscription without replacing your CLI login

Claude Code supports separate logins through `CLAUDE_CONFIG_DIR`:

1. Start a separate profile in Terminal:
   ```bash
   CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude
   ```
2. Sign in to the other subscription. Choose subscription login, not API billing.
   Ensure shell API-key/provider overrides are not selecting another source.
3. Add **Claude Code** in OpenQuota, name it “Work”, select that configuration
   folder, and connect. Use **⌘⇧G** in the picker to enter the path, or **⌘⇧.**
   to show hidden folders.
4. Restart that Claude session and use it normally. After a response, Claude can
   send the documented rate-limit fields through the status-line bridge.

Repeat with a different directory per account. Use the same command when
returning to that profile; normal `claude` keeps its normal configuration unless
your shell already overrides it.

**Monitoring is passive.** Idle profiles do not continuously refresh. Readings
become outdated after ten minutes without a bridge event. Refresh in OpenQuota
only reads the latest file. A connection follows the login in that folder, not
an immutable provider identity. An API key does not provide subscription quotas.

The bridge preserves your existing status-line command and forwards its output.
Disconnect restores the previous configuration only if the installed wrapper
has not changed; later user edits are preserved.

See Claude's [authentication](https://code.claude.com/docs/en/authentication)
and [status-line](https://code.claude.com/docs/en/statusline) docs. Separate
Console logins without API keys have different isolation limitations; do not
assume they behave like claude.ai subscription profiles.

## Codex / ChatGPT

Choose **Codex / ChatGPT → Sign In with ChatGPT…**. Each connection uses a
dedicated Codex home; Codex manages its credentials. Your regular Codex home is
not imported or replaced. Repeat for each account.

If Codex is not found, choose the CLI executable, not a credential file.
OpenAI API keys have separate billing and do not provide ChatGPT subscription
allowance. Removing a connection retains its Codex-managed home.

## OpenCode Go workspace subscriptions

One login can own several workspace subscriptions. Choose **OpenCode Go →
Add workspace subscription** and use the intended workspace's key from
[OpenCode](https://opencode.ai/zen). Repeat for each subscription.

Distinct keys are monitored independently. Adding an identical saved key updates
its entry instead of duplicating it. Two keys for the same workspace may share
one quota; separate rows do not imply separate allowances. OpenQuota does not
switch the active OpenCode CLI key.

The main CLI login is detected separately. Current OpenCode versions use a
database; old `auth.json` files may be stale. **Use another sign-in file** is for
a separate legacy credential-file profile, not the recommended workspace flow.

## Devin and other local accounts

Devin normally uses `~/.local/share/devin/credentials.toml`, with its
`windsurf_api_key` field. Sign in through Devin's CLI if missing or rejected.
Extra profiles require a different credential file, not a directory or the
default file again. Copying a file does not create a new subscription.

See the [provider matrix](providers.md) for other supported sources.

## Cursor: experimental

Follow the form's local setup instructions and read the consent text. This uses
an unofficial endpoint and a sensitive account session, **not a read-only key**.
No browser credentials are imported automatically. Never share the token in chat,
screenshots, or bug reports.

A new token for the same Cursor identity replaces its saved token. A different
identity gets an independent entry. [Technical details](providers.md#cursor-experimental-explicit-opt-in).

## Replace or remove

- **Saved key/session:** select it and use **Replace Credential…**. The ID and
  label stay intact. Use the same account/workspace: generic keys cannot be
  matched to a provider identity offline.
- **Cursor:** replacement must resolve to the existing identity.
- **Claude:** use that CLI profile again; there is no separate token to reconnect.
- **Local CLI:** sign in again through the CLI, then refresh.
- **Legacy Claude/Codex file profile:** remove it and use the explicit connection.

Use **−** to remove a removable entry. This does not cancel a subscription or
revoke credentials at the provider. Provider-owned files stay in place;
OpenQuota-owned saved keys are removed from its Keychain storage.
