# Changelog

## 1.1.0 — 2026-11-14

### New
- **Summon shortcut.** Press **⌃⌘V** (macOS) or **Alt+Shift+V** (Windows) in any app to show or hide Pastee. Settings (**⌘,** / **Ctrl+,**) suggests other combinations, says what else uses them, lets you record your own, and tells you if another app already owns it.
- **Hide after copying.** If you summoned Pastee with the shortcut, copying an item or field hides it again, so the next paste lands in the app you came from. **Esc** hides it too.
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
