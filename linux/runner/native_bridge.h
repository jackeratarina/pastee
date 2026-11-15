#ifndef RUNNER_NATIVE_BRIDGE_H_
#define RUNNER_NATIVE_BRIDGE_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include "clipboard_writer.h"
#include "global_hotkey.h"

// Pastee's native side on Linux: the "pastee/native" channel, with the same
// contract as macos/Runner/MainFlutterWindow.swift and
// windows/runner/flutter_window.cpp. It owns the summon shortcut, shows and
// hides the window, and writes the clipboard.
//
// Hiding minimizes the window, like on Windows: it stays in the taskbar,
// dock, overview and Alt+Tab, so it can always be brought back even where no
// shortcut works, and the window manager hands the focus back to the window
// you were in. (Withdrawing it with gtk_widget_hide would leave nothing to
// click on any desktop without a tray.) Closing the window quits Pastee, as
// on Windows; there is no Dock icon to bring a closed window back from.
class NativeBridge {
 public:
  NativeBridge(GtkWindow* window, FlView* view);
  ~NativeBridge();

  NativeBridge(const NativeBridge&) = delete;
  NativeBridge& operator=(const NativeBridge&) = delete;

  // Another `pastee` was started: brings the window forward.
  void Show();

  // The summon shortcut or `pastee --toggle`: shows and focuses Pastee, or
  // hides it if it's in front. |time| is the input event's time if known,
  // otherwise GDK_CURRENT_TIME.
  void Toggle(guint32 time, const gchar* activation_token);

  // Pastee is quitting.
  void Shutdown();

 private:
  static void OnMethodCall(FlMethodChannel* channel, FlMethodCall* call,
                           gpointer data);
  static gboolean OnWindowState(GtkWidget* widget, GdkEventWindowState* event,
                                gpointer data);
  static void OnWindowDestroyed(GtkWidget* widget, gpointer data);
  static gboolean OnHideFallback(gpointer data);

  void HandleMethodCall(FlMethodCall* call);
  bool IsWindowActive();
  void ShowAndFocus(guint32 time, const gchar* activation_token);
  void HideWindow();
  void StartHideFallback();
  void CancelHideFallback();

  // Null once the window is destroyed.
  GtkWindow* window_;
  FlMethodChannel* channel_;
  GlobalHotKey hot_key_;
  ClipboardWriter clipboard_;

  bool iconified_ = false;
  gulong window_state_handler_ = 0;
  gulong destroy_handler_ = 0;

  // Set while a shortcut hide waits for Dart to call hideWindow.
  guint hide_fallback_ = 0;
};

#endif  // RUNNER_NATIVE_BRIDGE_H_
