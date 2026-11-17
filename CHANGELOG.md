# Changelog

## 1.4.0 — 2026-11-17

### New
- **Pastee updates itself** from its GitHub releases. Once a day it checks for a new release; when there is one, a button in the header shows what's new since your version. **Update and restart** downloads the file for your computer, checks its SHA-256 against GitHub's record and the release's `SHA256SUMS.txt`, and installs nothing if they don't match. Then Pastee quits, the new version goes in, and Pastee starts again and says it was updated. The macOS app replaces itself where it is; the Windows setup runs again without questions; the Windows zip and the Linux tarball replace their files in place; the Linux .deb is installed with apt, which asks for your password. If the new version can't go in, the old one stays.
- **Settings → Updates** shows your version and the last check, has **Check now**, and turns the daily check off. **Skip this version** hides a release until the next one.
- The check is the only time Pastee goes online: one request to GitHub, without an account, that sends nothing about you or your items.

### Fixed
- The Linux .deb now pulls in the EGL and OpenGL ES libraries Pastee draws with (`libegl1`, `libgles2`). On a minimal system without them, Pastee quit as soon as it started.

## 1.3.0 — 2026-11-17

### New
- **Quick codes.** Right-click a field chip (or press and hold it) to give the field a short code, like `st2` for the password of your "silvertiger" note. One character is enough. Type the code in the search bar: the bar turns green and the note comes to the top with that field outlined, even though the code appears nowhere in it. Press **Enter** to copy the field. Pastee then hides and hands focus back to the app you were in, ready to paste. A copied password gets the usual secret treatment: it stays out of clipboard history and clears itself. Codes are unique, ignore capitals, show in green on their chip, and are saved encrypted with their note.

### Fixed
- Typing while the list has focus no longer drops the first character: typing `st2` searched for `t2`.
- On Linux, Enter and Esc work every time you summon Pastee. After Pastee hid itself on one of those keys, the next press of that key was ignored and could take the focus out of the search box.

## 1.2.0 — 2026-11-15

### New
- **Linux app** (x64 and arm64): a .deb for Ubuntu 22.04+, Debian 12+ and derivatives, and a tarball for other distributions. The summon shortcut defaults to **Ctrl+Alt+V**. On X11 Pastee registers it itself; on Wayland it asks the desktop through the GlobalShortcuts portal (GNOME 48+, KDE Plasma 5.27+, Hyprland). Where neither works, bind `pastee --toggle` in your desktop's keyboard settings. Items live encrypted in `~/.local/share/com.pastee.pastee`, in a folder only your account can open. Copied secrets clear themselves as on the other platforms and carry KDE's password-manager hint, which Klipper and clipboard managers that follow it skip. App Lock uses the passcode alone on Linux.
- **Fields & numbers** (Settings → Fields & numbers…). Teach Pastee your own phrases, like `Member ID` or `Mã thành viên`, and it picks out the value after them as a field. Capitals, accents and extra spaces don't matter. Add a value pattern (a regular expression) to say what the value looks like, or use a pattern alone to pick out every match. Mark a phrase **secret** to mask it and copy it like a password.
- **Choose the number that copies a field.** Give any field, yours or a built-in kind like passwords, a fixed number, so **⌘1** / **Ctrl+1** always copies the password, for example. Auto fields take the numbers left over, and the settings warn when two fields want the same number. Turn off built-in kinds you don't want as chips; a secret kind that's turned off stays masked.
- A **Try it** box on the same page shows the chips and numbers for a sample note while you edit.

### Fixed
- Long field chips end in "…" instead of running past the edge of the item.

## 1.1.1 — 2026-11-15

### Privacy
- **Copied secrets clear themselves.** When you copy a password, code or key, or anything from an item you set to always hide, Pastee empties the clipboard after 30 seconds unless you've copied something else since. The "Copied" message says when. Choose 10 seconds to 5 minutes, or Never, in Settings → Privacy. Quitting Pastee clears a secret that's still on the clipboard.
- **Copied secrets stay out of clipboard history.** On Windows they're left out of clipboard history (**Win+V**) and cloud clipboard sync. On macOS they're marked the way password managers mark passwords, so clipboard managers that follow that convention skip them, and Universal Clipboard doesn't send them to your other Apple devices.
- **Deleted items leave the disk right away.** The storage file kept an encrypted copy of deleted and edited items until 60 more deletions had piled up. Pastee now rewrites the file whenever you delete or edit an item, and tidies up what 1.1.0 left behind the first time it starts.

## 1.1.0 — 2026-11-14

### New
- **Summon shortcut.** Press **⌃⌘V** (macOS) or **Alt+Shift+V** (Windows) in any app to show or hide Pastee. Settings (**⌘,** / **Ctrl+,**) suggests other combinations, says what else uses them, lets you record your own, and tells you if another app already owns it.
- **Hide after copying.** If you summoned Pastee with the shortcut, copying an item or field hides it again, so the next paste lands in the app you came from. **Esc** hides it too.
- **App Lock.** A passcode (6 or more characters), plus optional Touch ID or Windows Hello, in front of Pastee. It locks at launch, after a time away or idle that you choose (from "as soon as it's hidden" to "only when Pastee starts"), or right away with **⌘L** / **Ctrl+L**. Pastee draws the lock screen or a privacy cover before it hides, so taskbar and Exposé previews don't show your items. Only a salted PBKDF2 hash of the passcode is kept, wrong guesses add a wait that survives restarts, and loosening the lock needs the passcode.
- **Passwords are masked.** Detected passwords, API keys and tokens, card numbers (shown as `•••• 4242`), PINs and one-time codes show as `••••••••` in previews, titles and field chips. Click the eye (or **⌘R** / **Ctrl+R**) to reveal for 20 seconds. Copying always copies the real value. The header eye turns masking off.
- **Always hide** an item (lock button) to mask the whole note, even if nothing in it looks like a password.
- **Undo.** Delete and cut show an Undo button, and **⌘Z** / **Ctrl+Z** brings back the last 20 deleted items.
- **Type to search.** Start typing in the list and it goes into the search box. **Enter** copies the top result.
- Light, dark or system theme, remembered between launches.
- Windows installer (per-user, no admin rights, optional start at sign-in) and a portable zip; macOS DMG.

### Better field detection
- Labeled values anywhere on a line: `user: alice pass: s3cret`, `Password: …`, `PIN 4821`, `Order #12345`, `Invoice: INV-2024-0042`, and Vietnamese labels (`tk`, `mk`, `mật khẩu`, `SĐT`, `mã đơn`, …).
- `Key: value` lines keep their key as the label (Host, Port, Database…). A label on its own line followed by the value also works.
- Recognizes GitHub, GitLab, AWS, Slack, Stripe, Google, OpenAI and Anthropic keys, JWTs, bearer tokens, and PEM and PGP private keys.
- Passwords in JSON (`"password": "…"`), connection strings (`Password=…;`), `.env` and YAML files, longer keys (`Password for my email: …`), `pass - …`, and whole passphrases.
- Card numbers (Luhn-checked), one-time codes (`482913 is your Instagram code`), IPv4 addresses with ports, UUIDs, `www.` links, and the password inside connection URLs like `postgres://app:secret@db/prod`.
- Fewer false positives: URLs and emails no longer keep trailing punctuation, IP addresses, timestamps and order numbers are no longer "phone numbers", and words like "bypass" or "compass" no longer look like passwords.
- Fields are numbered in reading order, with plain lines after them.

### Fixed
- In the search box, **⌘X / ⌘V / ⌘C** edited the list instead of the search text, so cutting your search deleted the top item.
- Holding Delete, Backspace or ⌘X deleted items at key-repeat speed. One press now does one thing.
- Text with emoji could fail to draw (a title or chip cut an emoji in half).
- On Windows, AltGr (Ctrl+Alt) combinations that type characters such as `@` or `{` were treated as Ctrl shortcuts.
- Very large pastes made the list slow; previews and detection now only look at the start.
- The window could be made too small for its layout.

### Privacy and storage
- Items are now stored **encrypted** (AES-256) in the app's own data folder instead of the user's Documents folder, which OneDrive and other sync tools often upload. On Windows the key is protected with DPAPI, tied to your Windows account.
- Existing items are moved over automatically on first launch, and the old unencrypted file is deleted.
- Auto-generated titles never contain a detected password.
- On Windows, starting Pastee a second time brings the running window forward instead of opening another copy.
- On macOS, Pastee no longer runs in the App Sandbox: an unsigned sandboxed app gets a permission prompt after every update. Data now lives in `~/Library/Application Support/com.pastee.pastee`.
- Pasting a password you copied from Pastee saves it as an always-hidden item.

## 1.0.0 — 2026-02-27

First release.
