#ifndef RUNNER_GLOBAL_HOTKEY_H_
#define RUNNER_GLOBAL_HOTKEY_H_

#include <gtk/gtk.h>

#include <functional>
#include <memory>

// Results of GlobalHotKey::Register, returned as is by registerHotKey on the
// "pastee/native" channel (lib/services/desktop_bridge.dart describes them).
// A positive result is the X11 error the key grab failed with.
constexpr int kHotKeyOk = 0;
// X11 BadAccess: another app already grabbed the combination.
constexpr int kHotKeyTaken = 10;
// This session offers apps no global shortcuts: Wayland without the
// GlobalShortcuts portal, or no display connection Pastee can grab keys on.
constexpr int kHotKeyUnavailable = -2;
// The key isn't on the current keyboard layout.
constexpr int kHotKeyNoSuchKey = -3;
// The desktop's shortcut dialog was dismissed, or the desktop bound no key.
constexpr int kHotKeyDeclined = -4;
// The GlobalShortcuts portal reported an error.
constexpr int kHotKeyPortalFailed = -5;

class X11KeyGrab;
class PortalShortcut;

// The system-wide summon shortcut. On X11 it is a passive key grab on the
// root window; in Wayland sessions, where apps can't grab keys, it is asked
// for through the XDG desktop portal (org.freedesktop.portal.GlobalShortcuts).
class GlobalHotKey {
 public:
  // |time| is the X server time of the key press (GDK_CURRENT_TIME from the
  // portal); |activation_token| is an xdg-activation token, or null.
  using PressedCallback =
      std::function<void(guint32 time, const gchar* activation_token)>;
  using DoneCallback = std::function<void(int status)>;

  GlobalHotKey(GdkDisplay* display, PressedCallback on_pressed);
  ~GlobalHotKey();

  GlobalHotKey(const GlobalHotKey&) = delete;
  GlobalHotKey& operator=(const GlobalHotKey&) = delete;

  // Sets the shortcut, replacing the current one. |keyval| is an X keysym
  // (the same number as a GDK keyval), lowercase for letters; |modifiers| are
  // X modifier masks: Shift 1, Control 4, Mod1 (Alt) 8, Mod4 (Super) 64.
  // |done| gets one of the kHotKey* results, right away on X11 and once the
  // desktop has answered with the portal.
  void Register(guint keyval, guint modifiers, DoneCallback done);

  void Unregister();

 private:
  std::unique_ptr<X11KeyGrab> x11_;
  std::unique_ptr<PortalShortcut> portal_;
};

#endif  // RUNNER_GLOBAL_HOTKEY_H_
