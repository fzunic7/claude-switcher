# Claude Account Switcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu-bar app that switches Claude CLI, VS Code and Claude Desktop (Code tab) between a main and a backup account in one click, keeping chosen Code sessions available on both.

**Architecture:** A SwiftPM package with a UI-free, fully tested core library (`SwitcherCore`) and a thin SwiftUI `MenuBarExtra` executable (`ClaudeSwitcher`). Every side effect (Keychain, filesystem roots, launching apps, running processes) sits behind a protocol so the switch flow is tested against fakes and temp directories. A shell script wraps the binary into a `.app`.

**Tech Stack:** Swift 6.4, SwiftPM, Swift Testing (`import Testing`), SwiftUI `MenuBarExtra`, AppKit (`NSWorkspace`), `/usr/bin/security` for Keychain. Only Command Line Tools are installed (no Xcode) — everything must build with `swift build` / `swift test`.

**Spec:** `docs/2026-11-20-claude-account-switcher-design.md`

## Global Constraints

- macOS 14+ deployment target; menu-bar only (`LSUIElement = true`), no Dock icon.
- Not sandboxed; ad-hoc signed (`codesign -s -`).
- No third-party dependencies.
- Claude Code credentials: Keychain generic password, service `Claude Code-credentials`. Read/write it **through `/usr/bin/security`** (the item's ACL already trusts that binary because Claude Code uses it — avoids access prompts). Preserve the item's existing `acct` attribute when rewriting.
- `~/.claude.json`: only the `oauthAccount` key may be changed; all other keys preserved byte-for-byte in value; write atomically; keep `~/.claude.json.switcher-bak` before writing.
- Desktop app support root: `~/Library/Application Support/Claude/`; Desktop bundle id `com.anthropic.claudefordesktop` (verify in Task 0).
- Desktop session index: `<supportRoot>/claude-code-sessions/<accountUuid>/<orgUuid>/local_<id>.json`. Files starting `deleted_` and the `backlog` entry are ignored.
- Switcher data: `~/Library/Application Support/ClaudeSwitcher/` (dirs `0700`, files `0600`). Profile secrets (credentials blob) go in Keychain service `ClaudeSwitcher.<accountUuid>`.
- **Plan decision (deviates from spec, flag to user):** Desktop login snapshots are stored as plain directory copies under `ClaudeSwitcher/vault/<accountUuid>/desktop/` with `0700` perms, not an extra encrypted archive. Their cookie values are already encrypted with the `Claude Safe Storage` key, exactly as in the original location.
- Transcripts in `~/.claude/projects/` are never copied, moved or modified.

## Review Focus

1. **Token refreshed since capture** — the live login always wins: switch saves the live credentials into the *current* profile before overwriting. Test in Task 6.
2. **`~/.claude.json` rewritten by a running `claude` between read and write** — re-read immediately before writing, change only `oauthAccount`. Test in Task 2.
3. **Failure mid-switch** (e.g. Desktop snapshot copy fails) — Keychain item, `~/.claude.json` and Desktop files are restored to pre-switch state. Test in Task 6.
4. **Target profile has no Desktop snapshot** (user only logged in via CLI) — CLI/VS Code switch proceeds, Desktop untouched, result carries a warning. Test in Task 6.
5. **Shared session already present in target index** — never overwrite the existing record. Test in Task 5.

---

### Task 0: Spike — verify the unknowns by hand (no code kept)

**Files:**
- Create: `docs/spike-notes.md`

Do this with both real accounts. Back up first: `cp -Rp ~/Library/Application\ Support/Claude ~/claude-desktop-backup` and `security find-generic-password -s "Claude Code-credentials" -w > ~/cc-cred-backup` (delete both files after the spike).

- [ ] **Step 1:** Confirm Desktop bundle id: `osascript -e 'id of app "Claude"'`.
- [ ] **Step 2 (risk 1):** Signed in to Desktop as A, quit it, copy candidate login set (`Cookies`, `Cookies-journal`, `Local Storage`, `Session Storage`, `IndexedDB`, `Partitions`, `WebStorage`) aside. Sign in as B, quit, copy B's set aside. Restore A's set, launch → still A without re-login? Then B's set. Narrow to the minimal list that works. Record it.
- [ ] **Step 3 (risk 2):** After swapping only the Desktop files (not the CLI Keychain item), does the Desktop Code tab run under the new account? Check `claude-code-sessions/<accountUuid>` folder that new sessions land in. Record whether the Code tab has its own token.
- [ ] **Step 4 (risk 3):** Copy one `local_*.json` from A's index folder into B's, launch as B → does it show and resume? Record.
- [ ] **Step 5 (risk 4):** Swap the CLI Keychain item + `oauthAccount`, then in VS Code: does "reload Claude panel" pick it up, or is "Developer: Reload Window" needed? Record.
- [ ] **Step 6:** Write findings to `docs/spike-notes.md`; update `DesktopLoginFiles.defaultPaths` (Task 4) and the post-switch notification text (Task 8) accordingly. If Step 2 shows Desktop cannot be swapped without re-login, stop and return to the user before Task 4.

### Task 1: Package scaffold, profile model and store

**Files:**
- Create: `Package.swift`, `Sources/SwitcherCore/Profile.swift`, `Sources/SwitcherCore/ProfileStore.swift`, `Sources/ClaudeSwitcher/App.swift` (placeholder `@main` with empty `MenuBarExtra`), `Tests/SwitcherCoreTests/ProfileStoreTests.swift`, `.gitignore` (`.build/`, `dist/`)

**Interfaces:**
- Produces:
  - `enum ProfileRole: String, Codable { case main, backup }`
  - `struct Profile: Codable, Equatable, Identifiable { var id: String /* accountUuid */; var label: String; var role: ProfileRole; var orgUuid: String; var email: String; var oauthAccount: [String: JSONValue]; var hasDesktopSnapshot: Bool }`
  - `enum JSONValue: Codable, Equatable` (string/number/bool/null/array/object) — lossless round-trip of arbitrary JSON.
  - `struct SwitcherState: Codable, Equatable { var profiles: [Profile]; var activeId: String?; var sharedSessionIds: Set<String>; var shareAll: Bool }`
  - `final class ProfileStore { init(root: URL); func load() throws -> SwitcherState; func save(_: SwitcherState) throws }` — file `root/profiles.json`, missing file → empty state.

- [ ] **Step 1:** `git init`; write `Package.swift` (platform `.macOS(.v14)`, library `SwitcherCore`, executable `ClaudeSwitcher` depending on it, test target). Run `swift build` → succeeds. Run a trivial `@Test func smoke() { #expect(true) }` with `swift test` → PASS (proves Swift Testing works under CLT).
- [ ] **Step 2: Failing tests** `ProfileStoreTests`: `loadMissingFileReturnsEmpty` (`profiles == []`, `activeId == nil`); `roundTripPreservesNestedOauthAccount` (oauthAccount with nested object, number, bool, null survives save→load equal); `savedFileHasMode0600`.
- [ ] **Step 3:** `swift test` → FAIL (types missing).
- [ ] **Step 4:** Implement `JSONValue`, models, `ProfileStore` (atomic write, set `0600`, create root `0700`).
- [ ] **Step 5:** `swift test` → PASS. Commit `feat: profile model and store`.

### Task 2: `~/.claude.json` account editor

**Files:**
- Create: `Sources/SwitcherCore/ClaudeJSON.swift`, `Tests/SwitcherCoreTests/ClaudeJSONTests.swift`

**Interfaces:**
- Consumes: `JSONValue`
- Produces: `struct ClaudeJSON { init(url: URL); func readAccount() throws -> [String: JSONValue]?; func writeAccount(_: [String: JSONValue]) throws; func rawContents() throws -> Data; func restore(_: Data) throws }`

- [ ] **Step 1: Failing tests:** `readAccountReturnsOauthAccount`; `writeAccountPreservesOtherKeys` (fixture with `projects`, `numStartups: 42`, `oauthAccount{accountUuid:"a"}` → write `{accountUuid:"b"}` → `numStartups == 42`, `projects` equal, `oauthAccount.accountUuid == "b"`); `writeAccountRereadsFileBeforeWriting` (construct editor, modify file externally adding key `x`, then `writeAccount` → `x` still present); `writeAccountCreatesBackup` (`.switcher-bak` equals original bytes); `restoreWritesExactBytes`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement with `JSONSerialization` into `[String: Any]`, replace only `oauthAccount`, `.atomic` write.
- [ ] **Step 4:** Run → PASS. Commit `feat: edit oauthAccount in claude.json`.

### Task 3: Keychain access via `security`

**Files:**
- Create: `Sources/SwitcherCore/CommandRunner.swift`, `Sources/SwitcherCore/Keychain.swift`, `Tests/SwitcherCoreTests/KeychainTests.swift`

**Interfaces:**
- Produces:
  - `protocol CommandRunner { func run(_ path: String, _ args: [String]) throws -> (status: Int32, stdout: Data) }` + `struct ProcessRunner: CommandRunner`
  - `protocol SecretStore { func read(service: String) throws -> (account: String, secret: Data)?; func write(service: String, account: String, secret: Data) throws; func delete(service: String) throws }`
  - `struct SecurityCLIStore: SecretStore { init(runner: CommandRunner) }`
  - `final class InMemorySecretStore: SecretStore` (in `SwitcherCore`, used by tests and later tasks' tests)
  - `enum ServiceNames { static let claudeCode = "Claude Code-credentials"; static func vault(_ accountUuid: String) -> String }` → `"ClaudeSwitcher.\(accountUuid)"`

- [ ] **Step 1: Failing tests** with a `RecordingRunner` fake: `readParsesAcctAndPassword` (read issues `find-generic-password -s <svc>` for acct and `find-generic-password -s <svc> -w` for secret; returns acct `"unknown"`, secret bytes); `readReturnsNilOnStatus44` (item not found); `writeUsesUpdateFlag` (args contain `add-generic-password`, `-U`, `-s`, svc, `-a`, acct, `-w`, secret).
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement. Strip trailing newline from `-w` output. Parse `"acct"<blob>="…"` from attribute output.
- [ ] **Step 4:** Run → PASS. Manual check: `swift run`-free REPL not needed — add a hidden `--print-active-email` flag later in Task 8 instead. Commit `feat: keychain access via security CLI`.

### Task 4: Desktop login snapshots

**Files:**
- Create: `Sources/SwitcherCore/DesktopLogin.swift`, `Tests/SwitcherCoreTests/DesktopLoginTests.swift`

**Interfaces:**
- Produces: `struct DesktopLoginFiles { static let defaultPaths: [String] /* from Task 0 */; init(supportRoot: URL, vaultRoot: URL, paths: [String] = defaultPaths); func capture(into accountUuid: String) throws; func hasSnapshot(_ accountUuid: String) -> Bool; func apply(from accountUuid: String) throws; func backupCurrent() throws -> URL; func restore(from backup: URL) throws }`

- [ ] **Step 1: Failing tests** (temp dirs): `captureCopiesListedPathsOnly` (unlisted `claude-code-sessions` not copied); `applyReplacesListedPaths` (stale file inside listed dir removed); `applyLeavesUnlistedPathsUntouched`; `backupAndRestoreRoundTrip`; `vaultDirIsMode0700`; `missingSourcePathIsSkipped`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement with `FileManager` copy into `vault/<uuid>/desktop/`; apply = remove listed path then copy.
- [ ] **Step 4:** Run → PASS. Commit `feat: desktop login snapshots`.

### Task 5: Desktop session index and sharing

**Files:**
- Create: `Sources/SwitcherCore/SessionIndex.swift`, `Tests/SwitcherCoreTests/SessionIndexTests.swift`

**Interfaces:**
- Produces: `struct DesktopSession: Identifiable, Equatable { let id: String /* filename stem, e.g. local_… */; let title: String; let cwd: String; let lastActivityAt: Date; let isArchived: Bool }`; `struct SessionIndex { init(sessionsRoot: URL); func list(account: String, org: String) throws -> [DesktopSession] /* sorted newest first, archived excluded */; func share(ids: Set<String>, from: (String, String), to: (String, String)) throws -> [String] /* ids actually copied */ }`
  - `lastActivityAt` is epoch milliseconds in the record.

- [ ] **Step 1: Failing tests:** `listIgnoresDeletedAndBacklog`; `listSortsByLastActivityDesc`; `listExcludesArchived`; `shareCopiesSelectedIntoTargetFolder` (target folder created if missing); `shareNeverOverwritesExisting` (pre-existing target file with different content unchanged, id not in returned list); `shareSkipsUnknownIds`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement; decode only the needed fields with `Codable` (ignore unknown keys); copy file bytes verbatim.
- [ ] **Step 4:** Run → PASS. Commit `feat: desktop session index and sharing`.

### Task 6: Switch orchestrator with rollback

**Files:**
- Create: `Sources/SwitcherCore/Switcher.swift`, `Sources/SwitcherCore/Environment.swift`, `Tests/SwitcherCoreTests/SwitcherTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–5.
- Produces:
  - `protocol DesktopAppControl { var isRunning: Bool { get }; func quit() async throws; func launch() throws }`
  - `struct SwitcherEnvironment { var store: ProfileStore; var secrets: SecretStore; var claudeJSON: ClaudeJSON; var desktopLogin: DesktopLoginFiles; var sessions: SessionIndex; var desktop: DesktopAppControl; static func live() -> SwitcherEnvironment }`
  - `struct SwitchResult: Equatable { var to: String; var sharedSessionIds: [String]; var warnings: [String] }`
  - `enum SwitchError: Error { case unknownProfile(String), alreadyActive, noLiveLogin, stepFailed(step: String, underlying: String) }`
  - `final class Switcher { init(env: SwitcherEnvironment); func captureCurrent(label: String, role: ProfileRole) async throws -> Profile; func switchTo(_ id: String) async throws -> SwitchResult }`

`switchTo` order (spec "Switch flow"): save live CC credentials → `vault(currentId)` and live `oauthAccount` → current profile; if Desktop running quit it then capture Desktop login into current; snapshot (CC secret, `claudeJSON.rawContents()`, `desktopLogin.backupCurrent()`); write target CC secret (preserving live `acct`) and `oauthAccount`; apply target Desktop snapshot if present else warn `"No Desktop login saved for <label>; Desktop left unchanged."`; share sessions (`shareAll` → all ids from `list`) from current (account, org) to target; set `activeId`; launch Desktop if it was running. Any throw after snapshot → restore all three, relaunch Desktop if it was running, rethrow `stepFailed`.

- [ ] **Step 1: Failing tests** (fakes + temp dirs): `captureStoresSecretAndAccount`; `switchSavesRefreshedLiveTokenToCurrentProfileFirst` (live secret changed after capture → after switch, `vault(main)` holds the new value); `switchWritesTargetSecretAndAccount`; `switchToActiveThrowsAlreadyActive`; `switchWithoutDesktopSnapshotWarnsAndLeavesDesktopFiles`; `switchSharesSelectedSessions`; `failureDuringDesktopApplyRestoresEverything` (desktopLogin fake throws on apply → CC secret, claude.json bytes, Desktop files equal pre-switch; error is `stepFailed`); `desktopRelaunchedOnlyIfItWasRunning`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement. Make `DesktopLoginFiles`/`ClaudeJSON`/`SessionIndex` injectable via small protocols if needed for the failure test; keep their concrete types as defaults.
- [ ] **Step 4:** Run → PASS. Commit `feat: switch flow with rollback`.

### Task 7: Live Desktop control and running-process check

**Files:**
- Create: `Sources/SwitcherCore/LiveDesktopApp.swift`, `Sources/SwitcherCore/RunningClaude.swift`, `Tests/SwitcherCoreTests/RunningClaudeTests.swift`

**Interfaces:**
- Produces: `struct LiveDesktopApp: DesktopAppControl` (bundle id from Global Constraints; `quit` = `terminate()` then poll up to 10 s, then throw `SwitchError.stepFailed(step: "quit Desktop", …)`; `launch` via `NSWorkspace.openApplication`); `struct RunningClaude { init(runner: CommandRunner); func cliProcessCount() throws -> Int }` using `pgrep -x claude`.

- [ ] **Step 1: Failing tests:** `countParsesPgrepOutput` (`"123\n456\n"` → 2); `countIsZeroWhenPgrepExits1`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Manual: temporary `swift run ClaudeSwitcher --quit-desktop` debug flag quits and relaunches Claude Desktop; remove flag. Commit `feat: live desktop control`.

### Task 8: Menu bar UI

**Files:**
- Create: `Sources/ClaudeSwitcher/MenuView.swift`, `Sources/ClaudeSwitcher/AccountsWindow.swift`, `Sources/ClaudeSwitcher/AppModel.swift`; Modify: `Sources/ClaudeSwitcher/App.swift`

**Interfaces:**
- Consumes: `Switcher`, `SwitcherEnvironment.live()`, `SessionIndex.list`, `RunningClaude`, `SwitcherState`.
- Produces: `@MainActor final class AppModel: ObservableObject { @Published var state: SwitcherState; @Published var sessions: [DesktopSession]; func switchToOther() async; func toggleShared(_ id: String); func captureCurrent(label: String, role: ProfileRole) async }`

Menu layout exactly as the spec sketch: active account line with email; `Switch to <other label>` (shortcut ⌘⇧B); "Sessions on <label>" list (top 10) with ★/☆ toggle; `Accounts…` (window: list profiles, "Save current login as…" with label + role, remove), `Settings…` (toggle "Share all sessions automatically"), `Quit`. Menu-bar icon shows `M` or `B` for the active role.

Before switching: if `cliProcessCount() > 0` or Desktop running, show an `NSAlert` ("Claude is running. Running CLI sessions keep the old account until restarted. Desktop will be quit and relaunched.") with Switch / Cancel. After success: `UNUserNotificationCenter` notification "Now on <label>. Restart running `claude` and reload VS Code's Claude panel; use `claude --resume` to continue." (wording adjusted per Task 0 Step 5), plus any warnings. On error: alert with the step that failed and "Nothing was changed."

- [ ] **Step 1:** Implement; `swift build` → succeeds.
- [ ] **Step 2:** Manual: `swift run ClaudeSwitcher` → icon appears, Accounts window opens, sessions list matches Desktop's sidebar for the active account. Commit `feat: menu bar UI`.

### Task 9: App bundle and end-to-end check

**Files:**
- Create: `scripts/bundle.sh`, `Resources/Info.plist`, `README.md`

- [ ] **Step 1:** `scripts/bundle.sh`: `swift build -c release`, assemble `dist/Claude Switcher.app/Contents/{MacOS,Info.plist}`, `codesign -s - --force --deep`. Info.plist: `CFBundleIdentifier = local.claudeswitcher`, `LSUIElement = true`, `LSMinimumSystemVersion = 14.0`.
- [ ] **Step 2:** Run `scripts/bundle.sh` → `dist/Claude Switcher.app` exists; `codesign -v` passes; opening it shows the menu-bar icon.
- [ ] **Step 3: End-to-end (real accounts):** capture Main (CLI + Desktop), sign in as Backup in both, capture Backup; star one Desktop session; switch to Main then Backup. Verify: `claude` → `/status` shows the expected email; VS Code Claude panel shows it after reload; Desktop opens signed in without re-login; the starred session appears in Desktop's sidebar under the other account and resumes; `claude --resume` lists all sessions. Switch back and forth 3× — no re-login prompts.
- [ ] **Step 4:** README: install, capture flow, switching, known limits (one account at a time; running CLIs need restart). Commit `chore: app bundle and readme`.
