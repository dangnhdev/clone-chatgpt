# clone-chatgpt

A native Swift tool with a CLI and a macOS GUI. It creates `Chat.app` from the
installed `ChatGPT.app`, with its own icon and fixed profile locations.

## Use

```sh
clone-chatgpt gui
clone-chatgpt clone --dry-run
clone-chatgpt clone
clone-chatgpt --json doctor
```

You can also double-click `build/Clone ChatGPT.app`. The GUI lets you choose the
icon and both profile directories, plus the source and destination apps.

Default paths:

| Setting | Path |
| --- | --- |
| Source | `/Applications/ChatGPT.app` |
| Destination | `/Applications/Chat.app` |
| Icon | `~/Downloads/chat.icns` |
| Bundle ID | `com.custom.chatgpt` |
| CODEX_HOME | `~/.codex-profiles/chat/codex-home` |
| Desktop data | `~/Library/Application Support/Codex Profiles/chat/user-data` |

Override any of them from the CLI:

```sh
clone-chatgpt clone \
  --icon "$HOME/Downloads/chat.icns" \
  --codex-home "$HOME/.codex-profiles/chat/codex-home" \
  --user-data "$HOME/Library/Application Support/Codex Profiles/chat/user-data"
```

## What happens

1. Validate paths, icon and source; refuse to replace a running destination.
2. Copy **only the application bundle** into a private staging directory.
3. Merge `CODEX_HOME` and `CODEX_ELECTRON_USER_DATA_PATH` into `LSEnvironment`.
   Set a separate bundle ID (`--bundle-id`) and the destination's display name.
4. Set the icon with Swift `NSWorkspace.setIcon`. Embed the selected artwork as
   `CFBundleIconFile`, removing conflicting `CFBundleIconName` and Finder custom
   icon metadata, so the finished bundle can pass code-signature verification.
5. Re-sign the copy locally (ad-hoc), remove entitlements that require OpenAI's
   signing team (APNs, shared keychain/application groups and team identity),
   and verify its full nested signature. Keep JIT and ordinary app permissions.
   Allow the clone and its helpers to load locally signed frameworks without an
   Apple Team ID (`disable-library-validation`); this change applies only to the
   copied apps, not the original app or macOS security settings.
6. Move the existing destination to macOS Trash, then install the verified copy.
   If installation fails, attempt to restore the previous app from Trash.
7. Refresh the copy's Launch Services registration.

The source app is never edited. No source account, conversation history, cache,
or profile files are migrated. Existing files in the selected profile folders
are kept; choose new directories for an empty profile. The clone contains a tiny
native Swift entry point that reads the plist and passes `--user-data-dir` before
executing the original binary. This is necessary for Chromium's early singleton
check. No external launcher or shell wrapper script is required.

Open `Chat.app` from Finder, Dock, Spotlight, or `open /Applications/Chat.app`.
Launching the original `Contents/MacOS/ChatGPT` directly bypasses this setup;
use the app bundle or its native `Contents/MacOS/clone-chatgpt-start` entry point.

The local signature replaces OpenAI's signature/notarization on the copy. The
copy needs to be recreated when the original app is updated. A separate bundle
ID keeps the copy distinct from the source in Launch Services and the Dock.

## Build and install

Requires macOS with Apple command-line developer tools (`xcrun swiftc`), AppKit
and the bundled macOS signing tools. No downloaded libraries are required.

```sh
make install    # CLI in ~/.local/bin; GUI in build/Clone ChatGPT.app
make test       # temporary fixture apps; copy, Trash, icon, plist and signing
```

Ensure `~/.local/bin` is on PATH. `make all` only builds, without installing.

## JSON

`--json` emits one object to stdout and uses exit status 0 on success, 1 on error.
Progress messages are suppressed in JSON mode. GUI mode does not support JSON.

```json
{"ok":true,"command":"clone","data":{"targetApp":"/Applications/Chat.app","signed":true,"trashPath":"/Users/example/.Trash/Chat.app","notes":[]}}
```

```json
{"ok":false,"error":{"message":"Quit Chat.app before replacing it."}}
```

`doctor` and `clone --dry-run` return the normalized configuration and whether
an existing destination would be moved to Trash. They do not mutate anything.
This is a local filesystem tool; it requires no network service or API key.
