# How Claude Switcher works

## What "an account" means here

Each saved account has:

- a copy of **Claude Code's sign-in** — the Keychain item Claude Code itself uses (`Claude Code-credentials`, under your macOS user name), saved as `ClaudeSwitcher.<account id>`;
- optionally a copy of **Claude Desktop's sign-in** — a few files from `~/Library/Application Support/Claude/` (cookies and local storage), saved in `~/Library/Application Support/ClaudeSwitcher/vault/<account id>/desktop/`;
- the account details Claude Code keeps in `~/.claude.json` (`oauthAccount`).

## Knowing who is signed in

`~/.claude.json` is rewritten by every running Claude Code process (including the one inside Claude Desktop), so it can name a different account than the real sign-in. The app therefore asks Claude Code directly — `claude auth status --json` — and only trusts `~/.claude.json` when it agrees.

## Adding an account

1. The app saves your current sign-in (it's about to be replaced).
2. It runs `claude auth login`, which opens the Claude website.
3. When the sign-in finishes and `claude auth status` reports a new account, it's saved.
4. Claude Code is put back on the account you were using.

Accounts you sign in to any other way (`/login`, `claude auth login`) are picked up within 30 seconds.

## Switching

1. Save the current sign-in back into its account (sign-ins renew themselves, so the saved copy is kept fresh).
2. Quit Claude Desktop and save its sign-in under the account it's signed in to (`lastKnownAccountUuid` in Desktop's `config.json`).
3. Put the target account's Claude Code sign-in into the Keychain and its details into `~/.claude.json`.
4. Put the target account's Desktop sign-in in place, if one was saved.
5. Merge Claude Desktop's per-account session lists both ways (never deleting; a newer copy replaces an older one; sessions you deleted stay deleted).
6. Reopen Claude Desktop.

If any step fails, everything is put back as it was and you're told which step failed.

## Usage numbers

From `https://api.anthropic.com/api/oauth/usage` (what Claude Code's `/usage` uses), with each account's own saved sign-in. Sign-ins aren't refreshed by the app — that's Claude Code's job — so an account you haven't used for a few hours shows its last known numbers. Claude Code's own cache in `~/.claude.json` is the fallback for the active account.

## Sessions

- **Terminal / VS Code:** session files in `~/.claude/projects/` aren't tied to an account, so every account sees all of them (`claude --resume`).
- **Claude Desktop:** keeps a list per account in `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/`. Each entry points to a session file above; the app copies entries between accounts so both lists match.
