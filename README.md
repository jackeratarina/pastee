<p align="center">
  <img src="images/fullimage.png" alt="Pastee Banner" width="600"/>
</p>

<p align="center">
  <b>Instant Shortcut Notes</b> — A blazing-fast desktop clipboard manager built with Flutter.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Linux-blue" alt="Platform"/>
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
| **Linux** (x64, arm64) | `Pastee-<version>-linux-x64.deb` (or `-arm64.deb`) | Ubuntu 22.04+, Debian 12+ and derivatives: `sudo apt install ./Pastee-<version>-linux-x64.deb`. |
| | `Pastee-<version>-linux-x64.tar.gz` (or `-arm64.tar.gz`) | Any distribution with GTK 3 and glibc 2.34+: unpack anywhere and run `pastee/pastee`. |

The builds are not code-signed yet, so the first launch shows a warning:

- **macOS:** open Pastee, click **Done** on the warning, then go to **System Settings → Privacy & Security** and click **Open Anyway**. (Or run `xattr -dr com.apple.quarantine /Applications/Pastee.app`.)
- **Windows:** on "Windows protected your PC", click **More info → Run anyway**.

From 1.4.0 on, Pastee checks for a new release once a day and updates itself in a click: see [Updates](#updates).

### Linux

- **Summon shortcut on X11:** Pastee registers **Ctrl+Alt+V** itself, like on Windows, and tells you if another app already owns it.
- **On Wayland,** apps can't grab keys. Pastee asks your desktop through the XDG GlobalShortcuts portal, which GNOME 48+, KDE Plasma 5.27+ and Hyprland provide; the desktop may ask you to confirm the shortcut, and you can change it in its keyboard settings. Elsewhere (GNOME 47 and older, which includes Ubuntu 24.04, Sway and other wlroots desktops), Settings says the desktop doesn't let apps set a shortcut: add one in your desktop's keyboard settings that runs `pastee --toggle` (with the tarball, the path to `pastee/pastee --toggle`). For example, GNOME: **Settings → Keyboard → View and Customize Shortcuts → Custom Shortcuts**; KDE: **System Settings → Shortcuts → Add New → Command**; Sway: `bindsym Ctrl+Alt+v exec pastee --toggle`.
- `pastee --toggle` works on X11 too. Starting `pastee` while it runs brings the window forward.
- Hiding Pastee minimizes it, so it stays in the taskbar, dock and Alt+Tab. Closing the window quits it, like on Windows.
- To start Pastee when you log in, add it to your desktop's startup applications, or copy `/usr/share/applications/com.pastee.pastee.desktop` to `~/.config/autostart/`.
- App Lock uses the passcode only: there is no Touch ID or Windows Hello equivalent on Linux.
- Uninstall with `sudo apt remove pastee`; your items stay in `~/.local/share/com.pastee.pastee` until you delete it.

## Features

- **Summon from anywhere.** Press **⌃⌘V** (macOS), **Alt+Shift+V** (Windows) or **Ctrl+Alt+V** (Linux) in any app to show or hide Pastee. Copy a field and Pastee hides itself again, so your next paste lands where you were.
- **Clipboard capture.** Paste anything with `⌘V` / `Ctrl+V`. Duplicates are detected and skipped.
- **Smart field extraction.** Up to 9 copyable fields per item: passwords, usernames, emails, links, phone numbers, order and invoice numbers, IP addresses, API keys, card numbers, one-time codes, and any `Key: value` line. English and Vietnamese labels.
- **Your own fields and numbers.** Teach Pastee your own phrases ("Member ID", "Mã thành viên") or patterns, and choose which number copies what, e.g. `⌘1` always the password. See [Fields & numbers](#fields--numbers).
- **Quick codes.** Give a field a short code like `st2`, then type it in the search bar and press `Enter`: Pastee copies that field and hides, back in the app you were in. No searching. See [Quick codes](#quick-codes).
- **App Lock.** Ask for a passcode, Touch ID or Windows Hello (passcode only on Linux) before Pastee shows anything: when it starts, and again after a time away that you choose. `⌘L` locks it right away.
- **Password masking.** Detected secrets show as `••••••••` everywhere until you click the eye. Copying always gets the real value. Mark any item **always hidden** with the lock.
- **Instant copy.** `⌘C` copies the top item, `⌘1`–`⌘9` copies one of its fields, and `Enter` copies the top search result.
- **Cut, delete, undo.** `⌘X` cuts the top item, `Delete` removes it, and `⌘Z` brings it back.
- **Inline title editing.** `⌘E` or double-click to rename. Titles are generated from the first line, with any password masked.
- **Real-time search.** Start typing (or press `⌘F`) to filter by title or content.
- **Copy flash.** A yellow highlight shows exactly what was copied, the whole item or a single field.
- **Updates in a click.** Pastee checks GitHub for a new release once a day. When there is one, a button in its header shows what's new and installs it: Pastee downloads the file for your system, checks its SHA-256, puts it in place and restarts. See [Updates](#updates).
- **Private and local.** Items are stored encrypted on your computer and never leave it. The only thing Pastee sends over the internet is its daily update check, which you can turn off.
- **Light, dark or system theme.**

## Keyboard shortcuts

On Windows and Linux, use `Ctrl` wherever macOS uses `⌘`.

| Shortcut | Action |
|---|---|
| **⌃⌘V** / **Alt+Shift+V** / **Ctrl+Alt+V** | Show or hide Pastee from any app (macOS / Windows / Linux, changeable in Settings) |
| `⌘V` | Save what's on the clipboard as a new item |
| `⌘C` or `Enter` | Copy the top item. When the search is a [quick code](#quick-codes), `Enter` copies its field instead and hides Pastee |
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

| Linux | |
|---|---|
| **Ctrl+Alt+V** | Recommended: no desktop binds it by default; GPaste and JetBrains IDEs use it |
| Alt+Super+V | Free in GNOME, KDE and Xfce, rarely taken by apps |
| Shift+Super+V | Popular with clipboard apps; GNOME clipboard extensions like Pano use it |
| Ctrl+Alt+Space | Rarely taken |

You can also record your own. It needs two modifier keys, and Pastee tells you if another app already owns it (or, on Linux, what the desktop uses it for: Ctrl+Alt+T, Ctrl+Alt+L, Ctrl+Alt+F1–F12 and others are refused).
On macOS, closing the window (or `⌘W`) keeps Pastee running so the shortcut keeps working; quit with `⌘Q`.
To have Pastee ready after you log in, add it under **System Settings → General → Login Items** (macOS), tick **Start Pastee when I sign in** in the installer (Windows), or add it to your desktop's startup applications (Linux).

## Fields & numbers

**Settings → Fields & numbers…** controls which fields Pastee picks out of a note, and which number key copies each one.

- **Your phrases.** Add a name (shown on the chip) and the phrases that label the value, such as `member id, mã thành viên`. Pastee finds them whatever the capitals or accents ("ma thanh vien" matches "Mã thành viên") and takes the text after the phrase, past a `:`, `=`, `-` or space. If nothing follows on that line, it takes the next line. Add a **value pattern** (a regular expression such as `[A-Z0-9]{5}`) to say what the value looks like, or use a pattern with no phrase to pick out every match, like `KH-\d+`. Turn on **Secret** to mask the value like a password and handle it like one when copied.
- **Numbers.** Give any field a number from 1 to 9, or leave it on **Auto**. A field with a number keeps it; if two want the same one, the one that comes first in the note gets it. Auto fields take the numbers left over, in reading order. Leave everything on Auto and numbering works as before.
- **Built-in fields.** Turn off kinds you don't want as chips (say, phone numbers), or give one a number, like passwords on `⌘1`. A secret kind that's turned off loses its chip but stays masked.
- **Try it.** Paste a sample note at the bottom of the page to see the chips and their numbers as you edit.

Patterns are checked for speed before they're saved. They are case-sensitive and run one line at a time.

## Quick codes

Copy a password without looking for it: give its field a short code, then type the code in the search bar.

1. **Set a code.** Right-click a field chip (or press and hold it) and type a code, such as `st2` for the password of your "silvertiger" note. One character is enough; spaces aren't allowed and capitals don't matter. The code then shows in green on the chip.
2. **Type it.** Summon Pastee (unlocking it if App Lock is on) and type `st2`. The search bar turns green, and the note comes to the top with that field outlined, even though `st2` appears nowhere in it.
3. **Press `Enter`.** Pastee copies the field and hides, handing focus back to the app you were in, so `⌘V` / `Ctrl+V` pastes it right there. A password is copied as a secret: it stays out of clipboard history and clears itself like any copied secret.

Each code belongs to one field, and each field has at most one code: right-click the chip again to change or remove it. Codes are saved with their note, encrypted, and go when the note is deleted. A code is a shortcut, not a password; App Lock is what keeps your notes private. If a change in [Fields & numbers](#fields--numbers) stops Pastee from finding a code's field, the search bar turns red and `Enter` says so instead of copying something else.

## Updates

Pastee 1.4.0 and later update themselves from this repository's [Releases](https://github.com/jackeratarina/pastee/releases).

1. **Pastee checks.** Once a day, Pastee asks GitHub for the list of releases (a few seconds after it starts, if the last check is more than a day old). When a newer one is out, an update button appears in its header, next to Settings.
2. **You choose.** Click it to read what's new in every release since yours, then **Update and restart**. **Later** keeps the button; **Skip this version** hides it until the next release (Settings → Updates still offers the skipped one).
3. **Pastee updates.** It downloads the file for your system and checks its SHA-256 against both the checksum GitHub recorded when the file was uploaded and the release's `SHA256SUMS.txt`. If any of them differ, nothing is installed. Then it quits, the new version goes in, and Pastee starts again with your items and settings as they were. If the new version can't go in, the old one stays and says so when it starts.

How the new version goes in depends on how you installed Pastee:

| Installed from | What the update does |
|---|---|
| macOS DMG | Replaces Pastee.app where it is. Your account must be able to change that folder; in Applications, an administrator account can. Otherwise, and when Pastee runs from the disk image, the update dialog links to the download instead. |
| Windows setup | Runs the new setup, which asks nothing, shows its progress and starts Pastee again. An install for all users asks for administrator rights; if the setup doesn't finish (you say no, say), the old Pastee starts again. |
| Windows zip | Replaces Pastee's files in the folder you unpacked it to. Your other files there stay. |
| Linux .deb | Installs the new package with apt. Your desktop asks for your password. |
| Linux tarball | Replaces the `pastee` folder where you unpacked it. |

- **Settings → Updates** shows your version and the last check, has **Check now**, and turns the daily check off.
- The check is one request to `api.github.com`, without an account. GitHub sees your IP address and that it's Pastee (`User-Agent: Pastee/<version>`); nothing about you or your items is sent.
- The checksums prove the download is the file published on this repository's release page. The builds aren't code-signed yet, so they can't prove who built it: an update is exactly as trustworthy as this GitHub repository.
- Pastee 1.3.0 and earlier don't update themselves: install 1.4.0 once by hand. Builds made from source without a version (`PASTEE_VERSION`) don't check.

## Privacy

- Items are stored with AES-256 encryption (Hive) in the app's data folder:
  - macOS: `~/Library/Application Support/com.pastee.pastee/data`
  - Windows: `%APPDATA%\com.pastee\Pastee\data`
  - Linux: `~/.local/share/com.pastee.pastee/data`
- On Windows, the encryption key is protected with DPAPI, so only your Windows account on this PC can unlock it.
- On Linux, the key sits next to the data in a folder only your user account can open (mode 0700; the key file is 0600). As on macOS, a copy of the data file on its own can't be read, but software running as you could read both. (The Secret Service keyring isn't used yet.)
- On macOS, the key sits next to the data in your private Library folder. A copy of the data file on its own can't be read, but software running as you could read both. (Unsigned Mac apps can't use the keychain or the App Sandbox without macOS asking for permission after every update, so Pastee uses neither until it has a signed build.)
- Pastee 1.0 kept an unencrypted file in Documents (on macOS, inside its sandbox container). 1.1 moves those items into encrypted storage on first launch and deletes the old file. On macOS, the system may ask once whether Pastee can access data from other apps: that's the old container.
- **App Lock** (Settings → App Lock) puts a passcode of 6 or more characters in front of Pastee, optionally with Touch ID (or your Mac password) or Windows Hello (not available on Linux). It locks when Pastee starts, and again after the time away or idle you pick, from "as soon as it's hidden" to "only when Pastee starts". When the summon shortcut hides Pastee, it draws the lock screen or a blank cover first, so taskbar, Alt+Tab and Exposé previews don't show your items. Pastee keeps only a salted PBKDF2 hash of the passcode, repeated wrong guesses add a wait that a restart doesn't reset, and loosening the lock or adding Touch ID needs the passcode. If you forget the passcode, the lock screen can erase your items and turn the lock off once you type ERASE; Pastee can't recover it. App Lock keeps people at your computer out of Pastee. Your items are already encrypted on disk.
- Masking hides secrets on screen (screen sharing, someone looking over your shoulder).
- **The update check** is the only time Pastee goes online: once a day it asks GitHub for its list of releases, and it downloads a release only when you click **Update and restart**. Turn the check off in Settings → Updates. See [Updates](#updates).
- **Copying a secret** (a detected password, code or key, or anything from an item set to always hide) empties the clipboard again after 30 seconds, unless you copied something else since; pick the delay or Never in Settings → Privacy. On Windows those copies are kept out of clipboard history (Win+V) and cloud clipboard sync. On macOS they're marked as concealed, so clipboard managers that follow the convention skip them, and they aren't sent to your other devices through Universal Clipboard. On Linux they carry KDE's password-manager hint, which Klipper and clipboard managers that follow it skip. Anything else you copy is a normal clipboard entry.
- Deleting or editing an item rewrites the storage file at once, so no copy of the old version stays on disk (1.1.0 and earlier kept one until enough deletions had piled up).
- App Lock guards the window, not the files: it doesn't add encryption of its own. On macOS, something that can read your files as you can read Pastee's too. Turn on FileVault, and encrypt Time Machine backups, to protect them when the Mac is off or a backup is lost.
- If you used Pastee 1.0 with a Documents folder that syncs to OneDrive, its old unencrypted `paste_items.hive` may still be in OneDrive's recycle bin or version history. Empty it there to be sure.

## Build from source

Requires [Flutter](https://docs.flutter.dev/get-started/install) 3.47 or later, plus Xcode (macOS), Visual Studio 2022 with "Desktop development with C++" (Windows), or on Linux `clang cmake ninja-build pkg-config libgtk-3-dev` (Ubuntu/Debian package names). The first Windows build downloads two NuGet packages for Windows Hello support, so it needs internet access.

```bash
git clone https://github.com/jackeratarina/pastee.git
cd pastee
flutter pub get
flutter test

flutter run -d macos      # or: flutter run -d windows / -d linux
flutter build macos       # or: flutter build windows / linux
```

### Releasing

1. Bump `version:` in `pubspec.yaml` and add a section for it to `CHANGELOG.md`.
2. Commit, then tag and push: `git tag v1.2.0 && git push origin main v1.2.0`.
3. GitHub Actions ([build.yml](.github/workflows/build.yml)) tests the code, builds the apps, and publishes a release with the DMG, the Windows installer and zip, the Linux .deb packages and tarballs (x64 and arm64), and checksums.

## Project structure

```
lib/
├── main.dart                    # Entry point: opens storage, starts the app
├── version.dart                 # Version string, set by the release build
├── model/
│   ├── paste_item.dart          # Item model + Hive adapter
│   ├── quick_code.dart          # Quick codes: matching and validation
│   ├── app_settings.dart        # Preferences
│   └── hotkey.dart              # Summon shortcut: presets, key codes, conflict checks
├── providers/
│   ├── providers.dart           # Riverpod state: items, search, settings, shortcut
│   └── update_provider.dart     # Daily update check, download, install
├── services/
│   ├── field_extractor.dart     # Field detection (passwords, links, codes, …)
│   ├── masking.dart             # Turning secrets into dots
│   ├── paste_titles.dart        # Generated titles
│   ├── quick_codes.dart         # Finding the field a quick code copies
│   ├── storage_service.dart     # Encrypted Hive storage + migration from 1.0
│   ├── key_store.dart           # Encryption key file (DPAPI on Windows)
│   ├── desktop_bridge.dart      # Dart side of the native shortcut/window bridge
│   ├── clipboard_service.dart   # Clipboard read/write
│   ├── updates.dart             # GitHub releases, versions, checksums, download
│   ├── update_installer.dart    # Putting an update in place, per install kind
│   └── text_utils.dart          # Emoji-safe truncation
└── ui/
    ├── home_screen.dart         # Main screen, keyboard handling
    ├── paste_tile.dart          # Item tile, field chips, masking, flash animation
    ├── settings_dialog.dart     # Shortcut picker and recorder, privacy, theme, updates
    ├── update_dialog.dart       # What's new, Update and restart
    └── …
macos/Runner/MainFlutterWindow.swift   # Global shortcut (Carbon) and show/hide
windows/runner/flutter_window.cpp      # Global shortcut (RegisterHotKey) and show/hide
windows/installer/pastee.iss           # Windows installer (Inno Setup)
linux/runner/native_bridge.cc          # Show/hide, clipboard, `pastee --toggle`
linux/runner/global_hotkey.cc          # Global shortcut (X11 grab, Wayland portal)
linux/packaging/                       # .deb and tarball, CI smoke test
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
