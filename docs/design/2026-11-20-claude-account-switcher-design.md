# Claude Account Switcher — Design

Date: 2026-11-20 · Status: approved 2026-11-20

## Intent

The user has two Claude accounts: a **main** and a **backup**. When the main hits its usage limits, they want to flip Claude Code over to the backup with one click and **keep working in the same Code sessions** — across the Claude CLI, the VS Code extension, and the Claude Desktop app's Code tab. Regular Desktop *chats* are out of scope (they live server-side per account and cannot move).

## Goals

- One-click switch main ⇄ backup from the macOS menu bar.
- After switching, CLI / VS Code / Desktop Code tab all use the new account.
- Code sessions the user chooses remain visible and resumable under the new account.
- Show which account is active at a glance.

## Non-goals

- Syncing claude.ai / Desktop *chat* conversations.
- Running both accounts at the same time.
- Auto-detecting usage limits and switching automatically (possible later).
- More than a handful of accounts (design allows N, UI tuned for 2).

## Anti-goals (failure even if it "works")

- Losing or corrupting a login, so the user has to sign in again after every switch.
- Losing or corrupting session history.
- Storing tokens anywhere less safe than the macOS Keychain.

## What exists today (found on this Mac)

| Thing | Where | Account-bound? |
|---|---|---|
| CLI / VS Code login (OAuth tokens) | Keychain item, service `Claude Code-credentials` | yes |
| CLI / VS Code account identity | `~/.claude.json` → `oauthAccount` (accountUuid, organizationUuid, email, rate-limit tier…) | yes |
| Code session transcripts | `~/.claude/projects/<cwd-slug>/<cliSessionId>.jsonl` | **no** — shared by all accounts |
| Desktop app login | `~/Library/Application Support/Claude/` (Cookies, Local Storage, IndexedDB…) + Keychain `Claude Safe Storage` (Electron encryption key) | yes |
| Desktop Code-tab session list | `~/Library/Application Support/Claude/claude-code-sessions/<accountUuid>/<orgUuid>/local_<id>.json` — each record points at a `cliSessionId` + `cwd` | **yes, per account** |

Key consequence: CLI and VS Code already see every session under any account (`claude --resume`). The Desktop sidebar is the only place sessions are split per account — so "choose which sessions to share" is concretely **copying selected `local_*.json` records from one account's folder into the other's**. The transcripts themselves are never copied.

Note: on this Mac the Desktop app and the CLI are currently signed in to *different* accounts (two accountUuid folders exist). The switcher will bring them into line.

## Approaches considered

- **A. Swap the login in place (chosen).** One shared `~/.claude`; the app stores each account's login and swaps it in on switch. Simplest, covers all three clients with one session store. Trade-off: one account active at a time.
- **B. Separate config dir per account** (`CLAUDE_CONFIG_DIR`, symlinked `projects/`). Lets two CLIs run on different accounts at once, but VS Code and Desktop don't take a config dir cleanly — two mechanisms to maintain. Rejected.
- **C. Shell script + SwiftBar.** Same logic as A, quicker, but brittle around Keychain and app relaunch. Rejected.

User picked **A**.

## Design

### Form
Native macOS menu-bar app, Swift + SwiftUI (`MenuBarExtra`), no Dock icon. Target macOS 14+. Not sandboxed (it must read/write `~/.claude*`, the Desktop app's support folder, and other apps' Keychain items) — distributed as a locally built, ad-hoc/self-signed app.

### Account vault
- Each saved account = a **profile**: label (`Main`/`Backup`), role, accountUuid, orgUuid, email.
- Secrets stored in the Keychain under the app's own service (e.g. `ClaudeSwitcher.<accountUuid>`):
  - the raw `Claude Code-credentials` blob,
  - a snapshot of the Desktop login files (encrypted archive of the relevant folders; key in Keychain).
- Non-secret profile data + `oauthAccount` snapshot in `~/Library/Application Support/ClaudeSwitcher/profiles.json`.

**Capture flow ("Add account")**: user signs in normally (CLI `/login`, Desktop sign-in), then clicks *Save current login as…*. App reads the live Keychain item + `oauthAccount` + Desktop login files and stores them as that profile.

### Switch flow (main → backup)
1. **Pre-flight**: warn if Claude Desktop has a Code session mid-turn or `claude` processes are running; user confirms.
2. **Save back** the live login into the *current* profile (tokens refresh while in use, so a stale stored copy would eventually fail — this step is mandatory).
3. Quit Claude Desktop (graceful `NSRunningApplication.terminate`, then wait).
4. Write the target profile's credentials into Keychain `Claude Code-credentials` and its `oauthAccount` into `~/.claude.json` (edit only that key; write atomically; keep a backup copy).
5. Swap the Desktop login files to the target profile's snapshot.
6. **Share selected sessions** (below).
7. Relaunch Claude Desktop.
8. Notify: "Now on Backup. Restart running `claude` sessions and reload VS Code's Claude panel; use `claude --resume` to continue."

Every step is reversible: before step 3 the app snapshots everything it will touch; on any failure it restores the snapshot and reports what happened.

### Choosing which sessions carry over
- Menu shows recent Desktop Code sessions of the active account (title, folder, last activity) with a **"Share with other account"** toggle (★).
- On switch, starred records are copied (not moved) into the target account's `claude-code-sessions/<accountUuid>/<orgUuid>/` folder, if not already there. Unstarred ones stay private to their account.
- CLI/VS Code need nothing — they always see every transcript.
- Optional setting: *Share all sessions automatically*.

### Menu bar UI (sketch)
```
● Main  (you@main…)            ← active
  Switch to Backup  ⌘⇧B
──────────────────────
Sessions on Main
  ★ api refactor        ~/git/app        2h ago
  ☆ landing page        ~/git/site       yesterday
──────────────────────
Accounts…   Settings…   Quit
```

## Risks / unknowns (to verify in a spike first)

1. **Desktop login swap** — does the Desktop app accept a swapped-in set of cookies/storage cleanly, or does it force a re-login? Which exact files are the minimal set? Is the `Claude Safe Storage` key shared across both logins (likely yes — it's per-install, not per-account)?
2. **Desktop Code-tab auth** — does the Desktop Code tab use the CLI Keychain item or its own token? Determines whether step 4 alone covers it.
3. **Copied session records** — does Desktop show and resume a `local_*.json` copied from another account's folder, given fields like `cwd` pointing into an account-keyed scratch path?
4. **VS Code** — whether the extension picks up a new login on panel reload or needs a full window reload.
5. Token refresh racing the swap if a `claude` process is still running.

The spike answers 1–4 by hand on this Mac before the app is built; findings feed the plan.

## Left to the builder

Project layout, Xcode vs SwiftPM, exact Keychain API usage, archive format for Desktop snapshots, error-message wording, icons.
