<p align="center">
  <img src="images/fullimage.png" alt="Pastee Banner" width="600"/>
</p>

<p align="center">
  <b>Instant Shortcut Notes</b> — A blazing-fast desktop clipboard manager built with Flutter.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Windows-blue" alt="Platform"/>
  <img src="https://img.shields.io/badge/flutter-3.47-02569B?logo=flutter" alt="Flutter"/>
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License"/>
  <a href="https://github.com/jackeratarina/pastee/actions/workflows/build.yml"><img src="https://github.com/jackeratarina/pastee/actions/workflows/build.yml/badge.svg" alt="Build"/></a>
</p>

---

## Download

Get the latest version from **[Releases](https://github.com/jackeratarina/pastee/releases/latest)**:

| | File | Notes |
|---|---|---|
| **macOS 12+** | `Pastee-<version>-macos.dmg` | Universal (Apple silicon and Intel). Drag Pastee into Applications. |
| **Windows 10/11** | `Pastee-<version>-windows-x64-setup.exe` | Installs for your user, no admin rights needed. Can start Pastee at sign-in. |
| | `Pastee-<version>-windows-x64.zip` | Portable: unzip anywhere and run `pastee.exe`. |

The builds are not code-signed yet, so the first launch shows a warning:

- **macOS:** open Pastee, click **Done** on the warning, then go to **System Settings → Privacy & Security** and click **Open Anyway**. (Or run `xattr -dr com.apple.quarantine /Applications/Pastee.app`.)
- **Windows:** on "Windows protected your PC", click **More info → Run anyway**.

## Features

- **Summon from anywhere.** Press **⌃⌘V** (macOS) or **Alt+Shift+V** (Windows) in any app to show or hide Pastee. Copy a field and Pastee hides itself again, so your next paste lands where you were.
- **Clipboard capture.** Paste anything with `⌘V` / `Ctrl+V`. Duplicates are detected and skipped.
- **Smart field extraction.** Up to 9 copyable fields per item: passwords, usernames, emails, links, phone numbers, order and invoice numbers, IP addresses, API keys, card numbers, one-time codes, and any `Key: value` line. English and Vietnamese labels.
- **Your own fields and numbers.** Teach Pastee your own phrases ("Member ID", "Mã thành viên") or patterns, and choose which number copies what, e.g. `⌘1` always the password. See [Fields & numbers](#fields--numbers).
- **App Lock.** Ask for a passcode, Touch ID or Windows Hello before Pastee shows anything: when it starts, and again after a time away that you choose. `⌘L` locks it right away.
- **Password masking.** Detected secrets show as `••••••••` everywhere until you click the eye. Copying always gets the real value. Mark any item **always hidden** with the lock.
- **Instant copy.** `⌘C` copies the top item, `⌘1`–`⌘9` copies one of its fields, and `Enter` copies the top search result.
- **Cut, delete, undo.** `⌘X` cuts the top item, `Delete` removes it, and `⌘Z` brings it back.
- **Inline title editing.** `⌘E` or double-click to rename. Titles are generated from the first line, with any password masked.
- **Real-time search.** Start typing (or press `⌘F`) to filter by title or content.
- **Copy flash.** A yellow highlight shows exactly what was copied, the whole item or a single field.
- **Private and local.** Items are stored encrypted on your computer. Nothing leaves your machine.
- **Light, dark or system theme.**

## Keyboard shortcuts

On Windows, use `Ctrl` wherever macOS uses `⌘`.

| Shortcut | Action |
|---|---|
| **⌃⌘V** / **Alt+Shift+V** | Show or hide Pastee from any app (changeable in Settings) |
| `⌘V` | Save what's on the clipboard as a new item |
| `⌘C` or `Enter` | Copy the top item |
| `⌘1`–`⌘9` | Copy the top item's field with that number |
| `⌘X` | Cut the top item (copy, then delete) |
| `Delete` / `Backspace` | Delete the top item |
| `⌘Z` | Undo the last delete or cut |
| `⌘E` | Rename the top item |
| `⌘R` | Show or hide the top item's masked text |
| `⌘F`, or just type | Search |
| `⌘L` | Lock Pastee (when App Lock is on) |
| `⌘,` | Settings |
| `Esc` | Clear the search, cancel renaming, or hide a summoned Pastee |

In the search box, `⌘X`, `⌘V`, `⌘A` and `⌘Z` edit the search text as usual.

### Choosing a summon shortcut

Settings suggests shortcuts that don't clash with the system or common apps:

| macOS | | Windows | |
|---|---|---|---|
| **⌃⌘V** | Recommended: free in macOS and most apps | **Alt+Shift+V** | Recommended: free in Windows and most apps |
| ⇧⌘V | Popular with clipboard apps; VS Code uses it | Ctrl+Shift+V | Browsers, Office and Terminal paste plain text with it |
| ⌥⌘V | Finder uses it to move files | Win+Alt+V | Rarely taken |
| ⌃⌥Space | Rarely taken | Ctrl+Alt+V | Office Paste Special; types a character on some layouts |

You can also record your own. It needs two modifier keys, and Pastee tells you if another app already owns it.
On macOS, closing the window (or `⌘W`) keeps Pastee running so the shortcut keeps working; quit with `⌘Q`.
To have Pastee ready after you log in, add it under **System Settings → General → Login Items** (macOS) or tick **Start Pastee when I sign in** in the installer (Windows).

## Fields & numbers

**Settings → Fields & numbers…** controls which fields Pastee picks out of a note, and which number key copies each one.

- **Your phrases.** Add a name (shown on the chip) and the phrases that label the value, such as `member id, mã thành viên`. Pastee finds them whatever the capitals or accents ("ma thanh vien" matches "Mã thành viên") and takes the text after the phrase, past a `:`, `=`, `-` or space. If nothing follows on that line, it takes the next line. Add a **value pattern** (a regular expression such as `[A-Z0-9]{5}`) to say what the value looks like, or use a pattern with no phrase to pick out every match, like `KH-\d+`. Turn on **Secret** to mask the value like a password and handle it like one when copied.
- **Numbers.** Give any field a number from 1 to 9, or leave it on **Auto**. A field with a number keeps it; if two want the same one, the one that comes first in the note gets it. Auto fields take the numbers left over, in reading order. Leave everything on Auto and numbering works as before.
- **Built-in fields.** Turn off kinds you don't want as chips (say, phone numbers), or give one a number, like passwords on `⌘1`. A secret kind that's turned off loses its chip but stays masked.
- **Try it.** Paste a sample note at the bottom of the page to see the chips and their numbers as you edit.

Patterns are checked for speed before they're saved. They are case-sensitive and run one line at a time.

## Privacy

- Items are stored with AES-256 encryption (Hive) in the app's data folder:
  - macOS: `~/Library/Application Support/com.pastee.pastee/data`
  - Windows: `%APPDATA%\com.pastee\Pastee\data`
- On Windows, the encryption key is protected with DPAPI, so only your Windows account on this PC can unlock it.
- On macOS, the key sits next to the data in your private Library folder. A copy of the data file on its own can't be read, but software running as you could read both. (Unsigned Mac apps can't use the keychain or the App Sandbox without macOS asking for permission after every update, so Pastee uses neither until it has a signed build.)
- Pastee 1.0 kept an unencrypted file in Documents (on macOS, inside its sandbox container). 1.1 moves those items into encrypted storage on first launch and deletes the old file. On macOS, the system may ask once whether Pastee can access data from other apps: that's the old container.
- **App Lock** (Settings → App Lock) puts a passcode of 6 or more characters in front of Pastee, optionally with Touch ID (or your Mac password) or Windows Hello. It locks when Pastee starts, and again after the time away or idle you pick, from "as soon as it's hidden" to "only when Pastee starts". When the summon shortcut hides Pastee, it draws the lock screen or a blank cover first, so taskbar, Alt+Tab and Exposé previews don't show your items. Pastee keeps only a salted PBKDF2 hash of the passcode, repeated wrong guesses add a wait that a restart doesn't reset, and loosening the lock or adding Touch ID needs the passcode. If you forget the passcode, the lock screen can erase your items and turn the lock off once you type ERASE; Pastee can't recover it. App Lock keeps people at your computer out of Pastee. Your items are already encrypted on disk.
- Masking hides secrets on screen (screen sharing, someone looking over your shoulder).
- **Copying a secret** (a detected password, code or key, or anything from an item set to always hide) empties the clipboard again after 30 seconds, unless you copied something else since; pick the delay or Never in Settings → Privacy. On Windows those copies are kept out of clipboard history (Win+V) and cloud clipboard sync. On macOS they're marked as concealed, so clipboard managers that follow the convention skip them, and they aren't sent to your other devices through Universal Clipboard. Anything else you copy is a normal clipboard entry.
- Deleting or editing an item rewrites the storage file at once, so no copy of the old version stays on disk (1.1.0 and earlier kept one until enough deletions had piled up).
- App Lock guards the window, not the files: it doesn't add encryption of its own. On macOS, something that can read your files as you can read Pastee's too. Turn on FileVault, and encrypt Time Machine backups, to protect them when the Mac is off or a backup is lost.
- If you used Pastee 1.0 with a Documents folder that syncs to OneDrive, its old unencrypted `paste_items.hive` may still be in OneDrive's recycle bin or version history. Empty it there to be sure.

## Build from source

Requires [Flutter](https://docs.flutter.dev/get-started/install) 3.47 or later, plus Xcode (macOS) or Visual Studio 2022 with "Desktop development with C++" (Windows). The first Windows build downloads two NuGet packages for Windows Hello support, so it needs internet access.

```bash
git clone https://github.com/jackeratarina/pastee.git
cd pastee
flutter pub get
flutter test

flutter run -d macos      # or: flutter run -d windows
flutter build macos       # or: flutter build windows
```

### Releasing

1. Bump `version:` in `pubspec.yaml` and add a section for it to `CHANGELOG.md`.
2. Commit, then tag and push: `git tag v1.2.0 && git push origin main v1.2.0`.
3. GitHub Actions ([build.yml](.github/workflows/build.yml)) tests the code, builds both apps, and publishes a release with the DMG, the Windows installer and zip, and checksums.

## Project structure

```
lib/
├── main.dart                    # Entry point: opens storage, starts the app
├── version.dart                 # Version string, set by the release build
├── model/
│   ├── paste_item.dart          # Item model + Hive adapter
│   ├── app_settings.dart        # Preferences
│   └── hotkey.dart              # Summon shortcut: presets, key codes, conflict checks
├── providers/
│   └── providers.dart           # Riverpod state: items, search, settings, shortcut
├── services/
│   ├── field_extractor.dart     # Field detection (passwords, links, codes, …)
│   ├── masking.dart             # Turning secrets into dots
│   ├── paste_titles.dart        # Generated titles
│   ├── storage_service.dart     # Encrypted Hive storage + migration from 1.0
│   ├── key_store.dart           # Encryption key file (DPAPI on Windows)
│   ├── desktop_bridge.dart      # Dart side of the native shortcut/window bridge
│   ├── clipboard_service.dart   # Clipboard read/write
│   └── text_utils.dart          # Emoji-safe truncation
└── ui/
    ├── home_screen.dart         # Main screen, keyboard handling
    ├── paste_tile.dart          # Item tile, field chips, masking, flash animation
    ├── settings_dialog.dart     # Shortcut picker and recorder, privacy, theme
    └── …
macos/Runner/MainFlutterWindow.swift   # Global shortcut (Carbon) and show/hide
windows/runner/flutter_window.cpp      # Global shortcut (RegisterHotKey) and show/hide
windows/installer/pastee.iss           # Windows installer (Inno Setup)
```

## Tech stack

- **Flutter**: cross-platform desktop UI
- **Riverpod**: state management
- **Hive**: lightweight encrypted local storage
- **Material 3**: theming with `ColorScheme.fromSeed`

---

## About

<p align="center">
  <img src="images/icon.png" alt="Pastee Icon" width="120"/>
</p>

Built by **[jackerata](https://github.com/datdm)**.

Pastee was created out of frustration with clunky clipboard managers. The goal is simple: paste once, copy anything instantly — emails, passwords, URLs, codes — all with keyboard shortcuts. No cloud, no accounts, no bloat.

## Support

If you find Pastee useful, consider buying me a coffee:

[![PayPal](https://img.shields.io/badge/PayPal-Donate-blue?logo=paypal)](https://paypal.me/duongmandat003)

## License

MIT License. See [LICENSE](LICENSE) for details.
