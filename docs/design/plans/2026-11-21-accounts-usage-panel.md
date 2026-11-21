# Accounts, Usage & Costs Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the form-based setup and text menu with browser sign-in, Codex-style shared sessions, and a Usage / Costs / Accounts panel showing each account's limits.

**Architecture:** New core pieces in `SwitcherCore` (usage models + client + service, account watcher, Desktop account reader, CLI-only switch, two-way session merge), all tested against fakes and temp dirs like the existing code. The SwiftUI layer becomes a `MenuBarExtra(.window)` panel driven by `AppModel` timers.

**Tech Stack:** unchanged — Swift 6.4, SwiftPM, Swift Testing via `scripts/test.sh`, SwiftUI, AppKit, `URLSession`, `SMAppService`. No dependencies. No `@State` (CLT lacks the SwiftUI macro plugin) — use `ObservableObject`.

**Spec:** `docs/2026-11-20-auto-setup-and-usage-design.md` (approved 2026-11-21). Previous spec/plan: `docs/2026-11-20-claude-account-switcher-design.md`, `docs/superpowers/plans/2026-11-20-claude-account-switcher.md`.

## Global Constraints

- Usage endpoint: `GET https://api.anthropic.com/api/oauth/usage`, headers `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`. Never call any token-refresh endpoint.
- Saved login blob (Keychain) JSON: `claudeAiOauth.accessToken` (String), `claudeAiOauth.expiresAt` (Int, epoch ms).
- Claude Code's usage cache: `~/.claude.json` → `cachedUsageUtilization` = `{fetchedAtMs, accountUuid, utilization}`; `utilization` has the same shape as the endpoint response.
- Response fields used: `five_hour` and `seven_day` → `utilization` (number, %), `resets_at` (ISO-8601 string, may be null; whole object may be null); `extra_usage` → `is_enabled`, `monthly_limit`, `used_credits`, `utilization`, `currency`, `decimal_places`, `spend_limit_reached` (any may be missing). Unknown keys ignored.
- Plan badge from `oauthAccount.organizationType`: `claude_max`→"Max", `claude_pro`→"Pro", `claude_team`→"Team", `claude_enterprise`→"Enterprise", else none.
- Desktop account: `~/Library/Application Support/Claude/config.json` → `lastKnownAccountUuid`.
- Login command: `claude auth login` (Claude Code ≥ 2.1.329). Locate `claude` at `~/.local/bin/claude`, else first hit of `/bin/zsh -lc 'command -v claude'`.
- Polling: account check every 30 s, every 2 s while an add is in progress (stop after 5 min); usage every 5 min, on panel open at most once per 60 s, ↻ forces.
- Bar colours: < 75 % green, ≥ 75 % amber, ≥ 90 % red.
- Account label default = email prefix before `@`; first account role `.main`, later `.backup`.
- Session records are never overwritten or deleted by merging.
- All existing tests keep passing; `profiles.json` written by the previous version must still load.

## Review Focus

1. **`profiles.json` from the previous version** (no new keys) must load without error and keep profiles. Test in Task 1.
2. **Usage endpoint fails** (401, 429, network error, unexpected JSON) — card shows fallback numbers or "unavailable", never crashes or blanks other accounts. Tests in Tasks 2–3.
3. **Saved token expired for the inactive account** — no network call; last known numbers with their timestamp. Test in Task 3.
4. **User signs in, during Add account, to an account that is already saved** (or cancels) — no duplicate profile, no switch-back of an account they didn't add. Test in Task 5.
5. **Desktop `config.json` stale after a switch applied a snapshot** — Desktop login is captured under the switcher's own record, not the stale value. Test in Task 4.

---

### Task 1: State v2, plan badge, backward-compatible loading

**Files:**
- Modify: `Sources/SwitcherCore/Profile.swift`
- Test: `Tests/SwitcherCoreTests/ProfileStoreTests.swift`

**Interfaces:**
- Produces:
  - `SwitcherState` gains `var ignoredAccountId: String?`, `var desktopAccountId: String?`, `var desktopAppliedAt: Date?`, `var lastUsage: [String: AccountUsage]` (all default empty/nil) and a custom `init(from:)` using `decodeIfPresent` for every field except `profiles`.
  - `extension Profile { var plan: String? }` per Global Constraints.
  - Create `Sources/SwitcherCore/Usage.swift` here with the three model structs from Task 2's Interfaces (`UsageWindow`, `ExtraUsage` without `formatted`, `AccountUsage`) — types only — so `lastUsage` compiles. Task 2 adds parsing to that file.

- [ ] **Step 1: Failing tests:** `loadsStateWrittenByPreviousVersion` (write the JSON `{"profiles":[{"id":"a","label":"Main","role":"main","orgUuid":"o","email":"a@x","oauthAccount":{},"hasDesktopSnapshot":false}],"activeId":"a","sharedSessionIds":[],"shareAll":false}` → loads, 1 profile, `lastUsage == [:]`, `ignoredAccountId == nil`); `roundTripPreservesNewFields` (set all four new fields incl. one `AccountUsage` → save/load equal); `planBadgeFromOrganizationType` (`claude_max`→"Max", `claude_pro`→"Pro", `something_else`→nil, missing→nil).
- [ ] **Step 2:** `scripts/test.sh` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `scripts/test.sh` → PASS. Commit `feat: state v2 with usage cache and plan badge`.

### Task 2: Usage models, parsing, client, credentials

**Files:**
- Modify: `Sources/SwitcherCore/Usage.swift`
- Create: `Sources/SwitcherCore/UsageClient.swift`, `Sources/SwitcherCore/Credentials.swift`
- Test: `Tests/SwitcherCoreTests/UsageTests.swift`

**Interfaces:**
- Produces:
  - `struct UsageWindow: Codable, Equatable, Sendable { var utilization: Double; var resetsAt: Date? }`
  - `struct ExtraUsage: Codable, Equatable, Sendable { var isEnabled: Bool; var monthlyLimit: Double?; var usedCredits: Double?; var utilization: Double?; var currency: String?; var decimalPlaces: Int; var spendLimitReached: Bool }` with `func formatted(_ amount: Double) -> String` (amount / 10^decimalPlaces, currency code via `NumberFormatter`, e.g. `1240`, 2, `"EUR"` → "€12.40").
  - `struct AccountUsage: Codable, Equatable, Sendable { var session: UsageWindow?; var weekly: UsageWindow?; var extra: ExtraUsage?; var fetchedAt: Date; var isLive: Bool }`
  - `enum UsageParser { static func parse(_ data: Data, fetchedAt: Date) throws -> AccountUsage }` (input = the `utilization` object / endpoint body; `isLive` true).
  - `enum UsageParser { static func parseCache(_ claudeJSONData: Data, accountUuid: String) -> AccountUsage? }` (reads `cachedUsageUtilization`; nil unless `accountUuid` matches; `fetchedAt` from `fetchedAtMs`; `isLive` false).
  - `protocol HTTPClient: Sendable { func get(_ url: URL, headers: [String: String]) async throws -> (status: Int, body: Data) }` + `struct URLSessionHTTPClient: HTTPClient` (15 s timeout).
  - `enum UsageError: Error, Equatable { case http(Int), badResponse }`
  - `struct UsageClient { init(http: HTTPClient); func fetch(accessToken: String) async throws -> AccountUsage }`
  - `struct OAuthCredentials: Equatable { let accessToken: String; let expiresAt: Date; static func parse(_ secret: Data) -> OAuthCredentials?; func isValid(at: Date, margin: TimeInterval = 60) -> Bool }`

- [ ] **Step 1: Failing tests:**
  - `parsesFiveHourWeeklyAndExtra` — fixture `{"five_hour":{"utilization":42,"resets_at":"2026-11-21T15:10:00Z"},"seven_day":{"utilization":23,"resets_at":"2026-11-24T10:00:00+00:00"},"extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1240,"utilization":24.8,"currency":"EUR","decimal_places":2,"spend_limit_reached":false},"unknown_thing":{"x":1}}` → session 42 with that date, weekly 23, extra used 1240 of 5000.
  - `parsesNullWindowsAndMissingExtra` — `{"five_hour":null,"seven_day":{"utilization":27,"resets_at":null}}` → session nil, weekly 27 with nil reset, extra nil.
  - `parseCacheRequiresMatchingAccount` — cache for "A" → `parseCache(..., "A")` non-nil with `isLive == false` and `fetchedAt` from `fetchedAtMs`; `"B"` → nil.
  - `extraFormatsCurrency` — `formatted(1240)` with `decimalPlaces 2`, `EUR` contains "12.40" or "12,40" and "€".
  - `clientSendsBearerAndBetaHeaders` — fake HTTP records URL `https://api.anthropic.com/api/oauth/usage`, headers `Authorization: Bearer tok`, `anthropic-beta: oauth-2025-04-20`.
  - `clientThrowsHttpErrorOn401` → `UsageError.http(401)`; `clientThrowsBadResponseOnGarbage` (status 200, body `"<html>"`) → `.badResponse`.
  - `credentialsParseAccessTokenAndExpiry` — `{"claudeAiOauth":{"accessToken":"t","refreshToken":"r","expiresAt":1763740800000}}` → token "t", expiry 2025-11-21T16:00:00Z; garbage → nil; `isValid` false within 60 s of expiry.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement (ISO-8601 with and without fractional seconds). **Step 4:** Run → PASS.
- [ ] **Step 5: Live check (read-only):** a throwaway script in the scratchpad reads the live access token from the Keychain and calls the endpoint with the Global Constraints headers; print only the parsed percentages and reset times, never the token. Expected: numbers matching `/usage` in Claude Code. If the response shape differs, ledger a ruling and adjust the parser + fixture.
- [ ] **Step 6:** Commit `feat: usage parsing and client`.

### Task 3: Usage service (live vs fallback)

**Files:**
- Create: `Sources/SwitcherCore/UsageService.swift`
- Test: `Tests/SwitcherCoreTests/UsageServiceTests.swift`

**Interfaces:**
- Consumes: Task 2 types; `SecretStore`, `ClaudeJSON`, `ProfileStore`, `ServiceNames`.
- Produces: `final class UsageService { init(secrets: SecretStore, claudeJSON: ClaudeJSON, store: ProfileStore, client: UsageClient, now: @escaping @Sendable () -> Date = Date.init); func refresh() async -> [String: AccountUsage] }`
  - For each profile: active (= live `oauthAccount.accountUuid`) → token from `ServiceNames.claudeCode`; others → token from `ServiceNames.vault(id)` only if `isValid(at: now)`.
  - Success → store in `state.lastUsage[id]` (re-load state right before saving; save only `lastUsage`).
  - Failure / no valid token → active: `UsageParser.parseCache` if newer than `lastUsage[id]`, else `lastUsage[id]` with `isLive = false`; others: `lastUsage[id]` with `isLive = false`; nothing known → omitted from result.

- [ ] **Step 1: Failing tests** (InMemorySecretStore, temp claude.json, fake HTTP keyed by token): `activeUsesLiveToken`; `inactiveWithValidSavedTokenFetchesLive`; `inactiveWithExpiredTokenMakesNoRequestAndReturnsLastKnown` (fake records zero calls; result `isLive == false`, same numbers); `activeFailureFallsBackToClaudeCodeCache`; `failureForOneAccountDoesNotAffectOther` (A → 429, B → 200 → B live, A last known); `successIsPersistedToLastUsage`; `unknownAccountWithNoDataIsOmitted`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. Commit `feat: usage service with fallbacks`.

### Task 4: Desktop account detection, two-way session merge, usage snapshot on switch

**Files:**
- Create: `Sources/SwitcherCore/DesktopAccount.swift`
- Modify: `Sources/SwitcherCore/SessionIndex.swift`, `Sources/SwitcherCore/Switcher.swift`, `Sources/SwitcherCore/Environment.swift`
- Test: `Tests/SwitcherCoreTests/DesktopAccountTests.swift`, `SessionIndexTests.swift`, `SwitcherTests.swift`

**Interfaces:**
- Produces:
  - `protocol DesktopAccountReading: Sendable { func signedInAccount() -> (id: String, modifiedAt: Date)? }` + `struct DesktopConfigReader: DesktopAccountReading { init(configURL: URL) }`.
  - `SessionSharing.merge(_ a: (String, String), _ b: (String, String)) throws -> (toA: [String], toB: [String])` — copies every valid record missing on the other side, both directions, never overwriting.
  - `SwitcherEnvironment` gains `desktopAccount: DesktopAccountReading` (live: `<desktopSupportRoot>/config.json`).
  - Switcher behaviour changes (spec "Desktop login", "Sessions"):
    - Desktop save-back: after quitting Desktop, owner = `state.desktopAccountId` if `desktopAppliedAt` exists and config `modifiedAt <= desktopAppliedAt`, else config's `id`. Capture into owner only if owner is a saved profile.
    - After applying the target's Desktop snapshot: `desktopAccountId = targetId`, `desktopAppliedAt = now`.
    - Sharing = `merge((current.id, current.orgUuid), (target.id, target.orgUuid))`; `SwitchResult.sharedSessionIds` = `toB`. `sharedSessionIds` / `shareAll` no longer read.
    - Before writing the target login: if `UsageParser.parseCache(claudeJSON, current.id)` exists, store it in `lastUsage[current.id]` unless an equal-or-newer entry exists.
    - Warning text when target has no Desktop snapshot becomes: `"Sign in to Claude Desktop once as <label>; the app remembers it after that."`

- [ ] **Step 1: Failing tests:**
  - `DesktopAccountTests.readsLastKnownAccountUuid`; `missingFileReturnsNil`.
  - `SessionIndexTests.mergeCopiesBothWaysWithoutOverwriting` (A has 1,2; B has 2′,3 → A gets 3, B gets 1, B's 2′ unchanged).
  - `SwitcherTests.desktopLoginSavedUnderDesktopsAccountNotCLIs` (CLI on B, Desktop config says A → after switch to A, `vault/A/desktop` has the live cookies, `vault/B/desktop` unchanged).
  - `staleDesktopConfigUsesSwitcherRecord` (switch B→A applies A's snapshot; config still says B with older mtime; switch A→B captures Desktop into A).
  - `desktopLoginNotSavedWhenDesktopAccountUnknown` (config names an account with no profile → no capture).
  - `switchMergesSessionsBothWays`.
  - `switchStoresClaudeCodeUsageCacheForAccountLeft`.
  - Update existing Switcher tests that relied on `includeDesktop` capture-back / `sharedSessionIds` to the new rules (World gets a temp `config.json`).
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. Commit `feat: desktop account detection and two-way session merge`.

### Task 5: Account watcher, CLI-only switch, add-account flow

**Files:**
- Create: `Sources/SwitcherCore/AccountWatcher.swift`, `Sources/SwitcherCore/LoginLauncher.swift`
- Modify: `Sources/SwitcherCore/Switcher.swift`
- Test: `Tests/SwitcherCoreTests/AccountWatcherTests.swift`

**Interfaces:**
- Consumes: `Switcher.captureCurrent(label:role:includeDesktop:)` (always `includeDesktop: false` from here on).
- Produces:
  - `Switcher.switchCLI(to id: String) throws` — writes the profile's vault secret to `ServiceNames.claudeCode` (keeping the live `acct`) and its `oauthAccount` to `~/.claude.json`; on failure restores both; sets `activeId`. No Desktop, no sessions.
  - `enum WatchEvent: Equatable { case none, added(Profile), addedAndRestored(added: Profile, restored: String) }`
  - `final class AccountWatcher { init(env: SwitcherEnvironment); func beginAdd(); func cancelAdd(); var isAdding: Bool; func check() async throws -> WatchEvent }`
    - `beginAdd` records the live account id as `returnTo`.
    - `check`: live id nil → `.none`. Clear `ignoredAccountId` if live ≠ it. Live id is a saved profile or the ignored one → `.none` (and if adding and live id ≠ `returnTo`, end the add without switching back). Else capture with label = email prefix, role per Global Constraints → if adding and `returnTo` is a saved profile ≠ new id → `switchCLI(to: returnTo)` → `.addedAndRestored`; else `.added`. Adding ends after a capture.
  - `AppModel` will call `Switcher.removeProfile(_ id: String)` — add it here: deletes vault + `.prev` items and vault folder, removes profile, sets `ignoredAccountId = id` if it's the live account.
  - `struct LoginLauncher { static func claudePath() -> String?; static func startLogin() throws -> Process }` — runs `claude auth login` with stdout/stderr to a log file in `~/Library/Application Support/ClaudeSwitcher/login.log`; caller terminates it on cancel.

- [ ] **Step 1: Failing tests:** `newSignInOutsideAppIsSavedNotRestored` (`.added`, label "b" for `b@x`, role backup when one profile exists); `firstAccountIsMain`; `addFlowSavesAndRestoresPrevious` (beginAdd on A, live becomes C → `.addedAndRestored(C, "A")`, live token and claude.json back to A); `addFlowSigningIntoExistingAccountDoesNothing` (live becomes B, already saved → `.none`, no new profile, not switched back, `isAdding == false`); `removedLiveAccountIsNotReAdded` then `ignoreClearedAfterSwitchingAway`; `switchCLIRestoresOnFailure` (claude.json path unwritable → live token unchanged).
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS.
- [ ] **Step 5: Live check of the launcher** — run `claude auth login --help` via `LoginLauncher.claudePath()` from a scratch script → prints help. Do **not** run a real login (that changes the user's live account); the end-to-end add is the user's check in Task 7.
- [ ] **Step 6:** Commit `feat: account watcher and browser sign-in flow`.

### Task 6: The panel

**Files:**
- Create: `Sources/ClaudeSwitcher/PanelView.swift`, `UsageTab.swift`, `CostsTab.swift`, `AccountsTab.swift`, `AccountCard.swift`, `SettingsView.swift`
- Modify: `Sources/ClaudeSwitcher/App.swift`, `AppModel.swift`
- Delete: `Sources/ClaudeSwitcher/MenuView.swift`, `AccountsWindow.swift`

**Interfaces:**
- Consumes: `UsageService`, `AccountWatcher`, `Switcher`, `LoginLauncher`, `Profile.plan`, `AccountUsage`, `ExtraUsage.formatted`.
- Produces: `AppModel` (`@MainActor ObservableObject`) with `@Published state, usage: [String: AccountUsage], tab: Tab (.usage/.costs/.accounts), isBusy, isAdding`; `func refreshUsage(force: Bool) async`, `func switchTo(_:) async`, `func addAccount()`, `func cancelAdd()`, `func rename(_:to:)`, `func makeMain(_:)`, `func remove(_:)`, `func setOpenAtLogin(_:)`; timers per Global Constraints.

Layout per spec "Panel" sketch: header (active label, plan badge, email); segmented tabs; scrollable cards; footer ↻ ⚙ ⏻. Card: email, Active badge or Switch button, plan badge, Session + Weekly rows ("Resets in 4 hr 9 min" when < 24 h, else "Resets Wed 10:00"), bar coloured per thresholds, Extra usage "Off"/"On", "as of <relative>" when `isLive == false`, Desktop hint when the profile has no Desktop snapshot. Costs tab: per account extra usage amount of limit with bar, "Limit reached" when `spendLimitReached`. Accounts tab: rows with Rename (inline text field via `ObservableObject` form), Make Main, Remove (confirm alert); **Add account** button → `addAccount()`; while adding: progress text "Waiting for you to sign in in the browser…" + Cancel. Fewer than 2 accounts → Usage tab shows the one-line hint plus an **Add account** button. Menu-bar label: `"\(label) \(Int(session))%"` or `"\(label) –"`. Panel width 360. Switch confirmation/error alerts carried over from current `AppModel`.

- [ ] **Step 1:** Implement; `swift build` → succeeds with no new warnings.
- [ ] **Step 2:** Launch `.build/debug/ClaudeSwitcher` for 5 s → stays up; check `~/Library/Application Support/ClaudeSwitcher/profiles.json` untouched if it doesn't exist. Commit `feat: usage, costs and accounts panel`.

### Task 7: Docs, package, hand-off

**Files:**
- Modify: `README.md`, `Resources/Info.plist` (version `0.2.0`)

- [ ] **Step 1:** README: replace setup/switching/sessions sections with the new flow (Add account → browser; sessions shared Codex-style; Desktop one-time sign-in per account; Usage/Costs tabs; data sources and their limits).
- [ ] **Step 2:** `scripts/test.sh` → all pass; `scripts/dmg.sh` → `dist/ClaudeSwitcher-0.2.0.dmg`; `hdiutil verify` → VALID.
- [ ] **Step 3:** Commit `chore: v0.2.0 docs and package`.
- [ ] **Step 4 (user):** end-to-end on the real accounts — Add account via browser, switch both ways, Desktop one-time sign-in, sessions visible under both, usage numbers match `/usage`.
