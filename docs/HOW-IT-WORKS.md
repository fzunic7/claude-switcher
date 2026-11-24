# How Claude Switcher works

## What "an account" means here

Each saved account has:

- a copy of **Claude Code's sign-in** — the Keychain item Claude Code itself uses (`Claude Code-credentials`, under your macOS user name), saved as `ClaudeSwitcher.<account id>`;
- optionally a copy of **Claude Desktop's sign-in** — a few files from `~/Library/Application Support/Claude/` (cookies and local storage), saved in `~/Library/Application Support/ClaudeSwitcher/vault/<account id>/desktop/`;
- the account details Claude Code keeps in `~/.claude.json` (`oauthAccount`).

## Knowing who is signed in

`~/.claude.json` is rewritten by every running Claude Code process (including the one inside Claude Desktop), so it can name a different account than the real sign-in. The app therefore asks Claude Code directly — `claude auth status --json` — and only trusts `~/.claude.json` when it agrees.

## Adding an account

1. The app runs Claude Code's own sign-in (`claude auth login`) with a private, temporary config folder (`CLAUDE_CONFIG_DIR`). Claude Code keeps logins per config folder, so this sign-in lands in its own Keychain entry and account file — **the login your terminals, VS Code and Claude Desktop use is never touched**.
2. The browser opens; you sign in.
3. The app reads the new account from that folder and its login from the new Keychain entry, saves them as an account, and deletes the temporary folder and entry.

Accounts you sign in to any other way (`/login`, `claude auth login`) are picked up within 30 seconds.

## Switching

1. Save the current sign-in back into its account (sign-ins renew themselves, so the saved copy is kept fresh).
2. Quit Claude Desktop and save its sign-in under the account it's signed in to (`lastKnownAccountUuid` in Desktop's `config.json`).
3. Put the target account's Claude Code sign-in into the Keychain and its details into `~/.claude.json`.
4. Put the target account's Desktop sign-in in place, if one was saved.
5. Sync Claude Desktop's per-account session lists both ways. Desktop deletes a session by removing its `local_<id>.json` record and writing a `deleted_<id>` marker; a deletion on one side is carried to the other (the record is moved to `~/Library/Application Support/ClaudeSwitcher/removed-sessions/`, not erased). Every remaining session is copied to the side that lacks it, and a newer copy replaces an older one.
6. Reopen Claude Desktop.

If any step fails, everything is put back as it was and you're told which step failed.

## Usage numbers

From `https://api.anthropic.com/api/oauth/usage` (what Claude Code's `/usage` uses), with each account's own sign-in. Access tokens last about 8 hours and Claude Code renews them only while the CLI runs, so the app renews expired ones itself, exactly as Claude Code does (`https://platform.claude.com/v1/oauth/token`, refresh grant), and writes the result back: into Claude Code's own Keychain item for the active account, into the saved copy for the others. If Claude Code renewed the same login at the same moment, its copy wins. After a "too many requests" answer the app leaves that account alone for 15 minutes; it checks every 15 minutes otherwise.

## Sessions

- **Terminal / VS Code:** session files in `~/.claude/projects/` aren't tied to an account, so every account sees all of them (`claude --resume`).
- **Claude Desktop:** keeps a list per account in `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/`. Each entry points to a session file above; the app copies entries between accounts so both lists match.
