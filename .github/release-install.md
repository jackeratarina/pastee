
## Install

**macOS 12 or later** (Apple silicon and Intel): download `Pastee-*-macos.dmg`, open it and drag Pastee into Applications.
This build isn't signed with an Apple Developer ID, so the first time you open it macOS says it can't check it for malware:

1. Open Pastee once and click **Done** on the warning.
2. Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to the Pastee message.
3. Open Pastee again and confirm.

(Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/Pastee.app`.)

**Windows 10 or 11** (64-bit): download `Pastee-*-windows-x64-setup.exe` and run it. No admin rights needed.
If SmartScreen says "Windows protected your PC", click **More info → Run anyway**; the build isn't code-signed.
Prefer not to install? Unzip `Pastee-*-windows-x64.zip` anywhere and run `pastee.exe`.

**Summon shortcut:** press **⌃⌘V** (macOS) or **Alt+Shift+V** (Windows) in any app to show or hide Pastee.
You can pick another one in Settings (**⌘,** / **Ctrl+,**).

`SHA256SUMS.txt` lists the checksum of every file.
