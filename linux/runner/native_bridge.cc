#include "native_bridge.h"

#include <cstring>

#ifdef GDK_WINDOWING_X11
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <gdk/gdkx.h>
#endif
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif

namespace {

// How long a shortcut hide waits for Dart to call hideWindow before
// minimizing anyway.
constexpr guint kHideFallbackMs = 500;

FlValue* Argument(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  return fl_value_lookup_string(args, key);
}

bool GetIntArgument(FlValue* args, const char* key, int64_t* out) {
  FlValue* value = Argument(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_INT) {
    return false;
  }
  *out = fl_value_get_int(value);
  return true;
}

// False when missing.
bool GetBoolArgument(FlValue* args, const char* key) {
  FlValue* value = Argument(args, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL &&
         fl_value_get_bool(value);
}

void Respond(FlMethodCall* call, FlValue* result) {
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond_success(call, result, &error)) {
    g_warning("Failed to answer %s: %s", fl_method_call_get_name(call),
              error->message);
  }
}

void RespondBadArgs(FlMethodCall* call, const char* message) {
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond_error(call, "bad_args", message, nullptr,
                                    &error)) {
    g_warning("Failed to answer %s: %s", fl_method_call_get_name(call),
              error->message);
  }
}

#ifdef GDK_WINDOWING_X11
// The window the window manager considers active (_NET_ACTIVE_WINDOW). False
// without an EWMH window manager.
bool GetX11ActiveWindow(GdkWindow* window, Window* active) {
  GdkScreen* screen = gdk_window_get_screen(window);
  if (!gdk_x11_screen_supports_net_wm_hint(
          screen, gdk_atom_intern_static_string("_NET_ACTIVE_WINDOW"))) {
    return false;
  }
  GdkDisplay* display = gdk_window_get_display(window);
  Atom type = None;
  int format = 0;
  unsigned long count = 0;
  unsigned long remaining = 0;
  unsigned char* data = nullptr;
  gdk_x11_display_error_trap_push(display);
  const int status = XGetWindowProperty(
      GDK_DISPLAY_XDISPLAY(display),
      GDK_WINDOW_XID(gdk_screen_get_root_window(screen)),
      gdk_x11_get_xatom_by_name_for_display(display, "_NET_ACTIVE_WINDOW"), 0,
      1, False, XA_WINDOW, &type, &format, &count, &remaining, &data);
  const int error = gdk_x11_display_error_trap_pop(display);
  const bool found = status == Success && error == Success &&
                     type == XA_WINDOW && format == 32 && count == 1 &&
                     data != nullptr;
  if (found) {
    *active = *reinterpret_cast<Window*>(data);
  }
  if (data != nullptr) {
    XFree(data);
  }
  return found;
}
#endif

}  // namespace

NativeBridge::NativeBridge(GtkWindow* window, FlView* view)
    : window_(window),
      hot_key_(gtk_widget_get_display(GTK_WIDGET(window)),
               [this](guint32 time, const gchar* activation_token) {
                 Toggle(time, activation_token);
               }),
      clipboard_(gtk_clipboard_get_for_display(
          gtk_widget_get_display(GTK_WIDGET(window)), GDK_SELECTION_CLIPBOARD)) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  channel_ = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), "pastee/native",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel_, OnMethodCall, this,
                                            nullptr);
  window_state_handler_ = g_signal_connect(
      window, "window-state-event", G_CALLBACK(OnWindowState), this);
  destroy_handler_ =
      g_signal_connect(window, "destroy", G_CALLBACK(OnWindowDestroyed), this);
}

NativeBridge::~NativeBridge() {
  CancelHideFallback();
  if (window_ != nullptr) {
    g_signal_handler_disconnect(window_, window_state_handler_);
    g_signal_handler_disconnect(window_, destroy_handler_);
  }
  // The messenger keeps the channel alive; it must not call into a freed
  // bridge.
  fl_method_channel_set_method_call_handler(channel_, nullptr, nullptr,
                                            nullptr);
  g_object_unref(channel_);
}

void NativeBridge::Show() {
  g_debug("show (another pastee was started)");
  ShowAndFocus(GDK_CURRENT_TIME, nullptr);
}

void NativeBridge::Toggle(guint32 time, const gchar* activation_token) {
  if (window_ == nullptr) {
    return;
  }
  if (hide_fallback_ != 0) {
    // Pressed again while waiting for Dart: hide right away.
    HideWindow();
    return;
  }
  const bool show = !IsWindowActive();
  g_debug("summon: %s", show ? "show" : "hide");
  if (show) {
    ShowAndFocus(time, activation_token);
  } else {
    // Dart draws its lock screen or privacy cover first, so the window's
    // last frame (taskbar and Alt+Tab previews) never shows the items, then
    // calls hideWindow.
    StartHideFallback();
  }
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "shown", fl_value_new_bool(show));
  fl_method_channel_invoke_method(channel_, "onHotKey", args, nullptr, nullptr,
                                  nullptr);
}

void NativeBridge::Shutdown() {
  CancelHideFallback();
  clipboard_.ClearOnExit();
}

void NativeBridge::OnMethodCall(FlMethodChannel* channel, FlMethodCall* call,
                                gpointer data) {
  static_cast<NativeBridge*>(data)->HandleMethodCall(call);
}

void NativeBridge::HandleMethodCall(FlMethodCall* call) {
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);

  if (strcmp(method, "registerHotKey") == 0) {
    int64_t key_code = 0;
    int64_t modifiers = 0;
    if (!GetIntArgument(args, "keyCode", &key_code) ||
        !GetIntArgument(args, "modifiers", &modifiers) || key_code <= 0 ||
        key_code > G_MAXUINT32 || modifiers < 0 || modifiers > 0xff) {
      RespondBadArgs(call, "keyCode and modifiers are required");
      return;
    }
    // With the portal, the answer can take until the user has confirmed the
    // shortcut in the desktop's dialog.
    g_object_ref(call);
    hot_key_.Register(static_cast<guint>(key_code),
                      static_cast<guint>(modifiers), [call](int status) {
                        g_debug("registerHotKey: %d", status);
                        g_autoptr(FlValue) result = fl_value_new_int(status);
                        Respond(call, result);
                        g_object_unref(call);
                      });
  } else if (strcmp(method, "unregisterHotKey") == 0) {
    hot_key_.Unregister();
    Respond(call, nullptr);
  } else if (strcmp(method, "showWindow") == 0) {
    ShowAndFocus(GDK_CURRENT_TIME, nullptr);
    Respond(call, nullptr);
  } else if (strcmp(method, "hideWindow") == 0) {
    HideWindow();
    Respond(call, nullptr);
  } else if (strcmp(method, "isWindowActive") == 0) {
    g_autoptr(FlValue) result = fl_value_new_bool(IsWindowActive());
    Respond(call, result);
  } else if (strcmp(method, "writeClipboard") == 0) {
    FlValue* text = Argument(args, "text");
    if (text == nullptr || fl_value_get_type(text) != FL_VALUE_TYPE_STRING) {
      RespondBadArgs(call, "text is required");
      return;
    }
    const int64_t change_count = clipboard_.Write(
        fl_value_get_string(text), GetBoolArgument(args, "concealed"),
        GetBoolArgument(args, "clearOnExit"));
    if (change_count == 0) {
      // Like Windows: Dart falls back to Flutter's clipboard.
      g_autoptr(GError) error = nullptr;
      if (!fl_method_call_respond_error(call, "clipboard_busy",
                                        "Couldn't take the clipboard.",
                                        nullptr, &error)) {
        g_warning("Failed to answer writeClipboard: %s", error->message);
      }
      return;
    }
    g_autoptr(FlValue) result = fl_value_new_int(change_count);
    Respond(call, result);
  } else if (strcmp(method, "clearClipboard") == 0) {
    int64_t change_count = 0;
    if (!GetIntArgument(args, "changeCount", &change_count)) {
      RespondBadArgs(call, "changeCount is required");
      return;
    }
    g_autoptr(FlValue) result = fl_value_new_bool(clipboard_.Clear(change_count));
    Respond(call, result);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

bool NativeBridge::IsWindowActive() {
  if (window_ == nullptr || iconified_ ||
      !gtk_widget_get_visible(GTK_WIDGET(window_))) {
    return false;
  }
#ifdef GDK_WINDOWING_X11
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window_));
  Window active = None;
  // While the summon shortcut is held down, Pastee's own key grab has the X
  // input focus and GTK calls the window inactive. The window manager still
  // knows which window is in front.
  if (gdk_window != nullptr && GDK_IS_X11_WINDOW(gdk_window) &&
      GetX11ActiveWindow(gdk_window, &active)) {
    return active == GDK_WINDOW_XID(gdk_window);
  }
#endif
  return gtk_window_is_active(window_);
}

void NativeBridge::ShowAndFocus(guint32 time, const gchar* activation_token) {
  CancelHideFallback();
  if (window_ == nullptr) {
    return;
  }
#ifdef GDK_WINDOWING_WAYLAND
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window_));
  if (activation_token != nullptr && GDK_IS_WAYLAND_DISPLAY(display)) {
    // The portal's token lets the compositor raise and focus Pastee.
    gdk_wayland_display_set_startup_notification_id(display, activation_token);
    time = GDK_CURRENT_TIME;
  }
#endif
#ifdef GDK_WINDOWING_X11
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window_));
  if (time == GDK_CURRENT_TIME && gdk_window != nullptr &&
      GDK_IS_X11_WINDOW(gdk_window)) {
    // Window managers refuse to focus a window that asks with an old input
    // time (focus-stealing prevention). `pastee --toggle` runs from a key
    // the user just pressed, so the current server time is honest.
    time = gdk_x11_get_server_time(gdk_window);
  }
#endif
  // Also restores the window if it is minimized.
  gtk_window_present_with_time(window_, time);
}

void NativeBridge::HideWindow() {
  CancelHideFallback();
  if (window_ != nullptr) {
    gtk_window_iconify(window_);
  }
}

void NativeBridge::StartHideFallback() {
  CancelHideFallback();
  hide_fallback_ = g_timeout_add(kHideFallbackMs, OnHideFallback, this);
}

void NativeBridge::CancelHideFallback() {
  if (hide_fallback_ != 0) {
    g_source_remove(hide_fallback_);
    hide_fallback_ = 0;
  }
}

gboolean NativeBridge::OnHideFallback(gpointer data) {
  auto* self = static_cast<NativeBridge*>(data);
  // Dart didn't call hideWindow in time.
  self->hide_fallback_ = 0;
  g_debug("hide fallback");
  self->HideWindow();
  return G_SOURCE_REMOVE;
}

gboolean NativeBridge::OnWindowState(GtkWidget* widget,
                                     GdkEventWindowState* event,
                                     gpointer data) {
  static_cast<NativeBridge*>(data)->iconified_ =
      (event->new_window_state & GDK_WINDOW_STATE_ICONIFIED) != 0;
  return FALSE;
}

void NativeBridge::OnWindowDestroyed(GtkWidget* widget, gpointer data) {
  auto* self = static_cast<NativeBridge*>(data);
  self->CancelHideFallback();
  self->window_ = nullptr;
}
