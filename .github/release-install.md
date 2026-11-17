
## Install

**Already running Pastee 1.4.0 or later?** It updates itself: click the update button in its header, or look in Settings → Updates.

**macOS 12 or later** (Apple silicon and Intel): download `Pastee-*-macos.dmg`, open it and drag Pastee into Applications.
This build isn't signed with an Apple Developer ID, so the first time you open it macOS says it can't check it for malware:

1. Open Pastee once and click **Done** on the warning.
2. Go to **System Settings → Privacy & Security** (on macOS 12: **System Preferences → Security & Privacy → General**), scroll down and click **Open Anyway** next to the Pastee message.
3. Open Pastee again and confirm.

(Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/Pastee.app`.)

**Windows 10 or 11** (64-bit): download `Pastee-*-windows-x64-setup.exe` and run it. No admin rights needed.
If SmartScreen says "Windows protected your PC", click **More info → Run anyway**; the build isn't code-signed.
Prefer not to install? Unzip `Pastee-*-windows-x64.zip` anywhere and run `pastee.exe`.

**Linux** (64-bit Intel/AMD or ARM; Ubuntu 22.04+, Debian 12+, or any distribution with GTK 3 and glibc 2.34+):
on Ubuntu, Debian and their derivatives, download `Pastee-*-linux-x64.deb` (`-arm64.deb` on ARM) and run `sudo apt install ./Pastee-*-linux-x64.deb`.
Elsewhere, unpack `Pastee-*-linux-x64.tar.gz` (`-arm64.tar.gz` on ARM) anywhere and run `pastee/pastee`.

- On X11, Pastee sets the summon shortcut itself.
- On Wayland, it asks your desktop through the GlobalShortcuts portal (GNOME 48+, KDE Plasma 5.27+, Hyprland), which may ask you to confirm it.
  Where that isn't available (GNOME 47 and older, including Ubuntu 24.04; Sway), add a shortcut in your desktop's keyboard settings that runs `pastee --toggle`.
- Hiding Pastee minimizes it; closing the window quits it. App Lock uses the passcode only on Linux.

**Summon shortcut:** press **⌃⌘V** (macOS), **Alt+Shift+V** (Windows) or **Ctrl+Alt+V** (Linux) in any app to show or hide Pastee.
You can pick another one in Settings (**⌘,** / **Ctrl+,**).

`SHA256SUMS.txt` lists the checksum of every file.
