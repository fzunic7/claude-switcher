# Accounts, Usage & Costs Panel — Design (part 1)

Date: 2026-11-21 · Status: approved 2026-11-21 · Builds on `docs/2026-11-20-claude-account-switcher-design.md`

## Intent

The switcher works but setup is painful (forms, labels, checkboxes, signing in by hand twice), and the user can't see how much of each account is left — the reason they switch at all. They want it to feel like switching accounts in the Codex app: add an account through the Claude website, switch with one click, and every local session is still there. Sessions stay on this Mac; nothing is pushed anywhere.

The look follows the user's reference screenshot: a menu-bar panel with **Usage / Costs / Accounts** tabs and one card per account.

## Goals

- **Add account = sign in on the Claude website.** No forms.
- **Sessions never get lost or split by account**, in CLI, VS Code and Desktop.
- **Usage at a glance** per account: Session (5-hour) and Weekly bars with reset times.
- **Costs** = spending beyond the plan (Extra usage) per account.
- Menu-bar title shows the active account and its session usage.

## Non-goals (this part)

- "Today's Activity" (turns, active time, lines, per-model counts) — **part 2**, from local session files, designed separately.
- API-price cost estimates (user has no API).
- Refreshing a non-active account's login in the background.
- Usage alerts / auto-switch at a threshold.

## Anti-goals

- Losing or hiding a session when switching.
- The app handling passwords or imitating Claude's sign-in — it only starts Claude Code's official login.
- Quitting Claude Desktop without the user asking (only a switch may).
- Saving a login under the wrong account.

## Approaches considered

- **A. Automatic detection + official browser sign-in (chosen).** "Add account" runs Claude Code's own `claude auth login`, which opens claude.ai in the browser; the app detects the new account and saves it. Accounts signed in any other way (`/login`) are picked up too.
- **B. Guided first-run window.** Same detection with a checklist. Extra UI used once.
- **C. App implements the sign-in itself.** Rejected: copies Claude Code's private login flow; fragile and impersonates the client.

User picked **A**; the browser sign-in is A's "Add account" button.

## Design

### Adding an account
1. Accounts tab → **Add account**. The app runs `claude auth login` (Claude Code 2.1.329 has it). It opens the Claude website; the user signs in there.
   - If the command needs a terminal (it prompts for input instead of finishing on its own), the app opens Terminal with that command instead. *(Builder confirms which on first run.)*
2. The app watches for the CLI account to change (`~/.claude.json` → `oauthAccount.accountUuid`, polled every 2 s while adding, every 30 s otherwise).
3. New account → saved automatically (vault Keychain item + `oauthAccount`). Label = the part of the email before `@`; first account = Main, later ones = Backup. Rename / Make Main in the Accounts tab.
4. Then the app **puts the CLI back on the account that was active before**, using the switch's write path (Claude Code login + `~/.claude.json` only; Desktop untouched). Adding a backup never moves you onto it.
5. Accounts signed in outside the app are detected the same way and saved; those are not switched back (the user chose that sign-in).
6. Removing the currently signed-in account: it's ignored while it stays the live CLI account, so it isn't re-added 30 s later.

### Sessions (Codex-style)
- CLI and VS Code already show every session under any account (session files aren't tied to an account). Unchanged.
- Claude Desktop keeps a session list per account. **On every switch, the two lists are merged both ways**: every `local_*.json` record missing from one account's folder is copied in. Existing records are never overwritten. Result: Desktop shows the same sessions whichever account is active.
- The ★ / "share" controls and the *Share all* setting are removed (old fields in `profiles.json` are ignored).

### Desktop login
- Desktop's signed-in account = `lastKnownAccountUuid` in `~/Library/Application Support/Claude/config.json`.
- During a switch (Desktop is quit anyway) its login is saved under the account Desktop is signed in to, if that account is saved in the app. Fixes review finding I3.
- After the switcher applies a saved Desktop login, `config.json` names the old account until Desktop runs again; the switcher records `desktopAccountId` on every apply and trusts its own record while `config.json` hasn't been modified since.
- First switch to an account Desktop has never been signed in to: Desktop stays as it was, and the card says "Sign in to Claude Desktop once as this account". After that the app remembers it.

### Usage & Costs data
- Source: the endpoint Claude Code uses for `/usage` (`GET https://api.anthropic.com/api/oauth/usage`, bearer access token). Undocumented; on any failure the app falls back silently. Its response shape is the one Claude Code caches in `~/.claude.json` → `cachedUsageUtilization.utilization`:
  - `five_hour` / `seven_day` → `utilization` (%), `resets_at`
  - `extra_usage` → `is_enabled`, `monthly_limit`, `used_credits`, `utilization`, `currency`, `decimal_places`
- **Active account:** live fetch with the live access token (never refreshed); fallback `cachedUsageUtilization` when its `accountUuid` matches.
- **Other accounts:** live fetch with the saved access token while it is still valid (`expiresAt` in the saved blob); after that, last known numbers with "as of <time>". Last known = Claude Code's cache captured when switching away, or the last successful fetch. Not refreshed on purpose (would act as Claude Code's login client and rotate that account's saved login).
- Refresh every 5 min and when the panel opens (at most once a minute); ↻ button forces it.
- Plan badge (Max / Pro / Team…) from `oauthAccount` (`billingType`, `organizationRateLimitTier`, `seatTier`). *Builder maps the values seen on this Mac; unknown → no badge.*

### Panel (MenuBarExtra in window style)
```
Menu bar:   [icon] main 42%          ← active label + session %, "–" if unknown

┌─────────────────────────────────────────┐
│ [icon] main  [Max]                       │
│        main@example.com                  │
│  ( Usage )   Costs    Accounts           │
│ ┌─────────────────────────────────────┐ │
│ │ backup@example.com           [Max]  │ │   ← one card per account,
│ │ Session        Resets in 4 hr 9 min │ │     active one first and
│ │ ▓░░░░░░░░░░░░░░░░░░░░░░░░░░    1%   │ │     marked [Active];
│ │ Weekly          Resets Wed 10:00    │ │     others get a
│ │ ▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░    27%   │ │     [Switch] button
│ │ Extra usage                    Off  │ │
│ │ [ Switch ]            as of 2h ago  │ │
│ └─────────────────────────────────────┘ │
│ ┌ main@example.com [Active]   [Max] ──┐ │
│ │ …                                    │ │
│ └──────────────────────────────────────┘ │
│                              ↻   ⚙   ⏻   │
└─────────────────────────────────────────┘
```
- **Usage tab:** account cards as above. Bars green < 75 %, amber ≥ 75 %, red ≥ 90 %.
- **Costs tab:** per account, Extra usage: Off, or "€12.40 of €50.00 this month" with a bar, plus whether the spend limit is reached.
- **Accounts tab:** each account with Switch, Rename, Make Main, Remove (confirm); **Add account** button; while adding, "Waiting for you to sign in in the browser…" with Cancel.
- **⚙ Settings:** Open at login (`SMAppService`). **⏻** Quit. **↻** refresh usage.
- Switch keeps today's behaviour: warning when `claude` is running, Desktop quit and reopened, rollback on failure.
- The look is our own (system materials, accent colour); the screenshot guides layout, not branding.

## My calls (check these)

- Label = email prefix; Main/Backup only decide order and which is "home".
- After **Add account**, the CLI goes back to the previously active account.
- Polling (2 s while adding, 30 s idle) instead of file watching.
- Bar thresholds 75 % / 90 %.
- Desktop session lists merged both ways on every switch; never overwrite, never delete.

## Left to the builder

Exact request headers for the usage endpoint, plan-badge mapping, SwiftUI layout details, how `claude auth login` is launched (background process vs Terminal).
