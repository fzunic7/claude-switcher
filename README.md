# Claude Switcher

A macOS menu-bar app that switches Claude Code (CLI, VS Code extension) and the Claude Desktop app between a **main** and a **backup** account, so you can keep working when the main one hits its usage limits. Your Code sessions carry over.

## Build

Needs only the Xcode Command Line Tools (macOS 14+).

```bash
scripts/test.sh          # run the tests
scripts/bundle.sh        # builds dist/Claude Switcher.app
```

Copy `dist/Claude Switcher.app` to `/Applications` and open it. It lives in the menu bar (M = main, B = backup).

## First-time setup

1. Sign in to your **main** account: `claude` → `/login`, and in Claude Desktop.
2. Menu bar → **Accounts…** → label `Main`, role Main, tick *Also save Claude Desktop's sign-in* → **Save current login**.
3. Sign in to the **backup** account in both places (`/login` again; sign out/in in Desktop).
4. **Accounts…** → label `Backup`, role Backup, tick the Desktop box → **Save current login**.

Only tick the Desktop box when Desktop is signed in to the *same* account as the CLI.

## Switching

Menu bar → **Switch to Backup** (⌘⇧B). The app:

1. saves the current login back (logins renew themselves, so this keeps the saved copy fresh),
2. quits Claude Desktop, swaps in the other account's login for CLI/VS Code and Desktop,
3. copies the Desktop Code sessions you starred (★) into the other account's session list,
4. reopens Desktop.

If any step fails, everything is put back and you're told which step failed.

Afterwards: restart any running `claude` (it keeps the old account until restarted), reload VS Code's Claude panel, and continue with `claude --resume`.

## Sessions

- CLI and VS Code always see every session, whichever account is active — session files aren't tied to an account.
- Claude Desktop keeps a session list per account. Star a session in the menu to have it copied to the other account on the next switch, or turn on *Share all sessions automatically* in **Accounts…**.

## Where things live

- Saved logins: Keychain items `ClaudeSwitcher.<accountUuid>`
- Profiles: `~/Library/Application Support/ClaudeSwitcher/profiles.json`
- Desktop login copies: `~/Library/Application Support/ClaudeSwitcher/vault/<accountUuid>/desktop/` (owner-only)
- `~/.claude.json` is backed up to `~/.claude.json.switcher-bak` before each change.

## Known limits

- One account active at a time.
- Switching quits Claude Desktop, which interrupts Code sessions running in it.
- Regular Desktop chats (claude.ai conversations) can't move between accounts.
- The set of Desktop files that hold its sign-in is a best guess until checked by hand (see `docs/superpowers/plans/…` Task 0). If Desktop asks you to sign in again after a switch, that list needs adjusting in `DesktopLoginFiles.defaultPaths`.
