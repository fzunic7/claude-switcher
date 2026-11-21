# Claude Switcher

A macOS menu-bar app for people with more than one Claude account. It shows how much of each account's usage is left, and switches Claude Code (CLI, VS Code) and the Claude Desktop app to another account in one click — without losing any local sessions.

## Install

```bash
scripts/dmg.sh        # builds dist/ClaudeSwitcher-<version>.dmg
```

Open the `.dmg`, drag **Claude Switcher** onto **Applications**, open it. It sits in the menu bar showing the active account and its session usage, e.g. `main 42%`.

The app is ad-hoc signed, not notarized: a copy you built yourself opens normally; one downloaded from the internet needs right-click → **Open** the first time.

Development: `scripts/test.sh` runs the tests, `scripts/bundle.sh` builds just the `.app`.

## Adding accounts

Click the menu-bar item → **Accounts** → **Add account**. Claude Code's own sign-in (`claude auth login`) opens the Claude website; sign in there. The account is saved automatically and you stay on the account you were using. If the browser sign-in doesn't finish, use **Use Terminal instead**.

Accounts you sign in to any other way (`claude auth login`, `/login`) are picked up automatically too. The first account becomes Main, the rest Backup — change that and the names in **Accounts**.

**Claude Desktop:** the browser sign-in covers the CLI and VS Code. The first time you switch Desktop to an account it hasn't seen, sign in to Desktop once as that account; from then on the app swaps Desktop's login too.

## Switching

Click **Switch** on an account card. The app saves your current login, quits Claude Desktop, swaps in the other account's login for the CLI, VS Code and Desktop, and reopens Desktop. If anything fails it puts everything back and tells you what happened.

Afterwards restart any running `claude` (it keeps the old account until restarted) and reload VS Code's Claude panel.

## Sessions

Sessions live on this Mac and are never uploaded or deleted.

- CLI and VS Code show every session under any account (`claude --resume`).
- Claude Desktop keeps a session list per account; the app merges those lists both ways on every switch, so Desktop shows the same sessions whichever account is active.

## Usage and Costs

- **Usage**: Session (5-hour) and Weekly limits with reset times, per account. Bars turn amber at 75 % and red at 90 %.
- **Costs**: Extra usage — spending beyond your plan this month, against your monthly limit.

Numbers come from the same service Claude Code uses for `/usage`. The active account is fetched live; other accounts are live while their saved sign-in is still valid (a few hours after you last used them), otherwise the last known numbers are shown with "as of …". Switching to an account gives fresh numbers. The service is undocumented, so if it changes the app falls back to Claude Code's cached numbers.

## Where things live

- Saved logins: Keychain items `ClaudeSwitcher.<accountUuid>` (and `.prev`, the copy before the last save)
- Accounts and last known usage: `~/Library/Application Support/ClaudeSwitcher/profiles.json`
- Saved Desktop logins: `~/Library/Application Support/ClaudeSwitcher/vault/<accountUuid>/` (owner-only, not encrypted beyond what Desktop itself does)
- `~/.claude.json` is backed up to `~/.claude.json.switcher-bak` before each change.

## Known limits

- One account active at a time; switching quits Claude Desktop, interrupting Code sessions running in it.
- Regular Desktop chats (claude.ai conversations) can't move between accounts.
- Which Desktop files hold its sign-in is a best guess (`DesktopLoginFiles.defaultPaths`); if Desktop asks you to sign in after a switch, that list needs adjusting.
