<p align="center">
  <img src="images/fullimage.png" alt="Pastee Banner" width="600"/>
</p>

<p align="center">
  <b>Instant Shortcut Notes</b> — A blazing-fast desktop clipboard manager built with Flutter.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Windows-blue" alt="Platform"/>
  <img src="https://img.shields.io/badge/flutter-%3E%3D3.3-02569B?logo=flutter" alt="Flutter"/>
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License"/>
</p>

---

## Features

- **Clipboard Capture** — Paste anything with `⌘V` / `Ctrl+V`. Duplicates are automatically detected and skipped.
- **Smart Field Extraction** — Automatically detects and labels up to 9 copyable fields per item (emails, URLs, passwords, phone numbers, codes, etc.).
- **Instant Copy** — `⌘C` copies the first item. `⌘1`–`⌘9` copies a specific extracted field.
- **Cut & Delete** — `⌘X` cuts the first item. `Delete` removes it.
- **Inline Title Editing** — `⌘E` or double-click to rename. Titles auto-generate from content.
- **Real-time Search** — `⌘F` to find items by title or content with debounced filtering.
- **Copy Flash Animation** — Visual yellow highlight on the exact content copied (whole item or individual field chip).
- **Local Persistence** — All data stored locally with Hive. Nothing leaves your machine.
- **Light & Dark Mode** — Toggle with one click.

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `⌘V` / `Ctrl+V` | Paste clipboard text as new item |
| `⌘C` / `Ctrl+C` | Copy first item's full content |
| `⌘1`–`⌘9` / `Ctrl+1`–`9` | Copy extracted field N from first item |
| `⌘X` / `Ctrl+X` | Cut first item (copy + delete) |
| `⌘E` / `Ctrl+E` | Edit first item's title |
| `⌘F` / `Ctrl+F` | Focus search bar |
| `Delete` / `Backspace` | Delete first item |
| `Escape` | Clear search / exit editing |

## Getting Started

### Prerequisites

- [Flutter SDK](https://flutter.dev/docs/get-started/install) >= 3.3
- macOS or Windows

### Build & Run

```bash
# Clone the repo
git clone https://github.com/datdm/pastee.git
cd pastee

# Get dependencies
flutter pub get

# Run on desktop
flutter run -d macos    # or -d windows

# Build release
flutter build macos     # or: flutter build windows
```

## Project Structure

```
lib/
├── main.dart                 # App entry point, Hive init
├── model/
│   ├── paste_item.dart       # Data model with Hive annotations
│   └── paste_item.g.dart     # Generated Hive adapter
├── providers/
│   └── providers.dart        # Riverpod state management
├── services/
│   ├── clipboard_service.dart    # Clipboard read/write wrapper
│   ├── field_extractor.dart      # Smart field detection (email, URL, etc.)
│   └── storage_service.dart      # Hive CRUD operations
└── ui/
    ├── home_screen.dart      # Main screen, keyboard handling
    ├── paste_tile.dart       # Item tile with field chips & flash animation
    └── theme.dart            # Light/dark Material 3 themes
```

## Tech Stack

- **Flutter** — Cross-platform desktop UI
- **Riverpod** — State management
- **Hive** — Lightweight local storage
- **Material 3** — Modern theming with `ColorScheme.fromSeed`

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

Or send directly to **duongmandat003@gmail.com** via PayPal.

## License

MIT License. See [LICENSE](LICENSE) for details.
