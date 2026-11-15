#include "global_hotkey.h"

#include <string>
#include <utility>
#include <vector>

#ifdef GDK_WINDOWING_X11
#include <X11/XKBlib.h>
#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <gdk/gdkx.h>
#endif
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif

namespace {

// X modifier masks, as sent by HotKeySpec.nativeModifiers on Linux.
constexpr guint kShiftMask = 1;    // ShiftMask
constexpr guint kControlMask = 4;  // ControlMask
constexpr guint kAltMask = 8;      // Mod1Mask
constexpr guint kSuperMask = 64;   // Mod4Mask

// Presses of a held key closer together than this are autorepeat.
constexpr guint32 kRepeatWindowMs = 1000;

constexpr char kPortalBusName[] = "org.freedesktop.portal.Desktop";
constexpr char kPortalPath[] = "/org/freedesktop/portal/desktop";
constexpr char kShortcutsInterface[] = "org.freedesktop.portal.GlobalShortcuts";
constexpr char kRequestInterface[] = "org.freedesktop.portal.Request";
constexpr char kSessionInterface[] = "org.freedesktop.portal.Session";
constexpr char kRegistryInterface[] = "org.freedesktop.host.portal.Registry";
constexpr char kShortcutId[] = "summon";
constexpr char kShortcutDescription[] = "Show or hide Pastee";

// In a Wayland session, apps can't grab keys: X11 grabs only see keys typed
// into other X11 apps, which is why even an X11 Pastee there (GDK_BACKEND=x11)
// goes through the portal.
bool IsWaylandSession(GdkDisplay* display) {
#ifdef GDK_WINDOWING_WAYLAND
  if (GDK_IS_WAYLAND_DISPLAY(display)) {
    return true;
  }
#endif
  return g_strcmp0(g_getenv("XDG_SESSION_TYPE"), "wayland") == 0;
}

// The shortcut in the format of the XDG shortcuts specification, which the
// portal takes as the preferred trigger: "CTRL+ALT+v".
std::string PortalTrigger(guint keyval, guint modifiers) {
  const gchar* name = gdk_keyval_name(keyval);
  if (name == nullptr) {
    return std::string();
  }
  std::string trigger;
  if (modifiers & kControlMask) {
    trigger += "CTRL+";
  }
  if (modifiers & kAltMask) {
    trigger += "ALT+";
  }
  if (modifiers & kShiftMask) {
    trigger += "SHIFT+";
  }
  if (modifiers & kSuperMask) {
    trigger += "LOGO+";
  }
  return trigger + name;
}

}  // namespace

// ── X11: a passive grab on the root window ───────────────────────────────

#ifdef GDK_WINDOWING_X11

class X11KeyGrab {
 public:
  X11KeyGrab(GdkDisplay* display, GlobalHotKey::PressedCallback on_pressed);
  ~X11KeyGrab();

  int Grab(guint keyval, guint modifiers);
  void Ungrab();

 private:
  static GdkFilterReturn Filter(GdkXEvent* gdk_xevent, GdkEvent* event,
                                gpointer data);
  static void OnKeysChanged(GdkKeymap* keymap, gpointer data);

  GdkDisplay* display_;
  GdkWindow* root_;
  GlobalHotKey::PressedCallback on_pressed_;
  gulong keys_changed_handler_ = 0;

  guint keyval_ = 0;
  guint modifiers_ = 0;
  // The grabbed key, or 0.
  KeyCode keycode_ = 0;
  // The lock-key states grabbed along with |modifiers_|, and all lock masks.
  std::vector<unsigned int> lock_states_;
  unsigned int lock_masks_ = 0;

  bool held_ = false;
  guint32 last_press_ = 0;
};

X11KeyGrab::X11KeyGrab(GdkDisplay* display,
                       GlobalHotKey::PressedCallback on_pressed)
    : display_(display),
      root_(gdk_screen_get_root_window(gdk_display_get_default_screen(display))),
      on_pressed_(std::move(on_pressed)) {
  gdk_window_add_filter(root_, Filter, this);
  keys_changed_handler_ =
      g_signal_connect(gdk_keymap_get_for_display(display), "keys-changed",
                       G_CALLBACK(OnKeysChanged), this);
}

X11KeyGrab::~X11KeyGrab() {
  Ungrab();
  g_signal_handler_disconnect(gdk_keymap_get_for_display(display_),
                              keys_changed_handler_);
  gdk_window_remove_filter(root_, Filter, this);
}

int X11KeyGrab::Grab(guint keyval, guint modifiers) {
  Ungrab();
  Display* xdisplay = GDK_DISPLAY_XDISPLAY(display_);
  const KeyCode keycode = XKeysymToKeycode(xdisplay, keyval);
  if (keycode == 0) {
    return kHotKeyNoSuchKey;
  }

  // Caps Lock, Num Lock and Scroll Lock are modifiers to X, and a grab only
  // matches its exact modifier state, so each combination of them is grabbed.
  std::vector<unsigned int> lock_states = {0};
  unsigned int lock_masks = 0;
  const unsigned int masks[] = {
      LockMask,
      XkbKeysymToModifiers(xdisplay, XK_Num_Lock),
      XkbKeysymToModifiers(xdisplay, XK_Scroll_Lock),
  };
  for (unsigned int mask : masks) {
    if (mask == 0 || (mask & (modifiers | lock_masks)) != 0) {
      continue;
    }
    lock_masks |= mask;
    const size_t count = lock_states.size();
    for (size_t i = 0; i < count; i++) {
      lock_states.push_back(lock_states[i] | mask);
    }
  }

  const Window root = GDK_WINDOW_XID(root_);
  gdk_x11_display_error_trap_push(display_);
  for (unsigned int locks : lock_states) {
    XGrabKey(xdisplay, keycode, modifiers | locks, root, False, GrabModeAsync,
             GrabModeAsync);
  }
  // Waits for the server: BadAccess if another client holds a grab on it.
  const int error = gdk_x11_display_error_trap_pop(display_);
  if (error != Success) {
    gdk_x11_display_error_trap_push(display_);
    for (unsigned int locks : lock_states) {
      XUngrabKey(xdisplay, keycode, modifiers | locks, root);
    }
    XFlush(xdisplay);
    gdk_x11_display_error_trap_pop_ignored(display_);
    return error;
  }

  keyval_ = keyval;
  modifiers_ = modifiers;
  keycode_ = keycode;
  lock_states_ = std::move(lock_states);
  lock_masks_ = lock_masks;
  held_ = false;
  return kHotKeyOk;
}

void X11KeyGrab::Ungrab() {
  if (keycode_ == 0) {
    return;
  }
  Display* xdisplay = GDK_DISPLAY_XDISPLAY(display_);
  const Window root = GDK_WINDOW_XID(root_);
  gdk_x11_display_error_trap_push(display_);
  for (unsigned int locks : lock_states_) {
    XUngrabKey(xdisplay, keycode_, modifiers_ | locks, root);
  }
  // Released now, not at the next flush: the shortcut recorder needs the keys.
  XFlush(xdisplay);
  gdk_x11_display_error_trap_pop_ignored(display_);
  keycode_ = 0;
  lock_states_.clear();
  held_ = false;
}

GdkFilterReturn X11KeyGrab::Filter(GdkXEvent* gdk_xevent, GdkEvent* event,
                                   gpointer data) {
  auto* self = static_cast<X11KeyGrab*>(data);
  const auto* xevent = static_cast<const XEvent*>(gdk_xevent);
  if (self->keycode_ == 0 ||
      (xevent->type != KeyPress && xevent->type != KeyRelease) ||
      xevent->xkey.keycode != self->keycode_) {
    return GDK_FILTER_CONTINUE;
  }
  if (xevent->type == KeyRelease) {
    self->held_ = false;
    return GDK_FILTER_REMOVE;
  }
  // The low 8 bits are the modifiers (the rest is the XKB group and buttons).
  const unsigned int state = xevent->xkey.state & 0xff & ~self->lock_masks_;
  if (state != self->modifiers_) {
    return GDK_FILTER_CONTINUE;
  }
  // Holding the keys down repeats the press. Only the first one counts, so
  // the window doesn't flicker (MOD_NOREPEAT on Windows).
  const guint32 time = xevent->xkey.time;
  const bool repeat = self->held_ && time - self->last_press_ < kRepeatWindowMs;
  self->held_ = true;
  self->last_press_ = time;
  if (!repeat) {
    // The event time lets the window manager give Pastee the focus.
    self->on_pressed_(time, nullptr);
  }
  return GDK_FILTER_REMOVE;
}

void X11KeyGrab::OnKeysChanged(GdkKeymap* keymap, gpointer data) {
  auto* self = static_cast<X11KeyGrab*>(data);
  if (self->keycode_ == 0 ||
      XKeysymToKeycode(GDK_DISPLAY_XDISPLAY(self->display_), self->keyval_) ==
          self->keycode_) {
    return;
  }
  // The new keyboard layout has the key somewhere else.
  const int status = self->Grab(self->keyval_, self->modifiers_);
  if (status != kHotKeyOk) {
    g_warning("The summon shortcut is lost after a keyboard change (%d)",
              status);
  }
}

#else

class X11KeyGrab {};

#endif  // GDK_WINDOWING_X11

// ── Wayland: org.freedesktop.portal.GlobalShortcuts ───────────────────────

// One shortcut in a GlobalShortcuts portal session, on a D-Bus connection of
// its own (the portal identifies a host app by its connection, see Connect).
// The portal binds a session's shortcuts only once, so a different trigger
// means a new session. The desktop may show a dialog to confirm the shortcut
// and decides the final key; the user can change it in the system settings.
class PortalShortcut {
 public:
  explicit PortalShortcut(GlobalHotKey::PressedCallback on_pressed);
  ~PortalShortcut();

  void Bind(const std::string& trigger, GlobalHotKey::DoneCallback done);
  void Unbind();

 private:
  enum class Portal { kUnknown, kConnecting, kAvailable, kUnavailable };
  using ResponseHandler = void (PortalShortcut::*)(guint32 response,
                                                   GVariant* results);

  // Moves toward |wanted_|, one portal request at a time.
  void Advance();
  void Connect();
  void ConnectionReady(GDBusConnection* bus);
  void PortalChecked(bool available);
  void CreateSession();
  void SessionCreated(guint32 response, GVariant* results);
  void ShortcutsBound(guint32 response, GVariant* results);
  void BindDone(int status);
  void CloseSession();
  void Resolve(int status);

  // Calls a portal method that answers through a Request object.
  void Request(const gchar* method, GVariant* parameters,
               const std::string& token, ResponseHandler handler);
  void WatchRequest(const std::string& path);
  std::string NextToken();

  static void OnConnected(GObject* source, GAsyncResult* result, gpointer data);
  static void OnRegistered(GObject* source, GAsyncResult* result,
                           gpointer data);
  static void OnVersion(GObject* source, GAsyncResult* result, gpointer data);
  static void OnRequestSent(GObject* source, GAsyncResult* result,
                            gpointer data);
  static void OnResponse(GDBusConnection* bus, const gchar* sender,
                         const gchar* path, const gchar* interface,
                         const gchar* signal, GVariant* parameters,
                         gpointer data);
  static void OnActivated(GDBusConnection* bus, const gchar* sender,
                          const gchar* path, const gchar* interface,
                          const gchar* signal, GVariant* parameters,
                          gpointer data);

  GlobalHotKey::PressedCallback on_pressed_;
  GCancellable* cancellable_;
  GDBusConnection* bus_ = nullptr;
  Portal portal_ = Portal::kUnknown;

  // The trigger to bind, or empty for none.
  std::string wanted_;
  // A Bind call since the last attempt: a failed trigger may be tried again.
  bool retry_ = false;
  // Calls waiting for the outcome.
  std::vector<GlobalHotKey::DoneCallback> waiters_;

  // A portal request is in flight.
  bool busy_ = false;
  std::string binding_;
  std::string request_path_;
  ResponseHandler response_handler_ = nullptr;
  guint response_subscription_ = 0;

  // The open session and the trigger bound in it.
  std::string session_;
  std::string bound_;
  // The last trigger that couldn't be bound, and why.
  std::string failed_;
  int failed_status_ = kHotKeyOk;

  guint activated_subscription_ = 0;
  unsigned int tokens_ = 0;
};

PortalShortcut::PortalShortcut(GlobalHotKey::PressedCallback on_pressed)
    : on_pressed_(std::move(on_pressed)), cancellable_(g_cancellable_new()) {}

PortalShortcut::~PortalShortcut() {
  // Pending callbacks see the cancellation and leave this object alone.
  g_cancellable_cancel(cancellable_);
  g_object_unref(cancellable_);
  if (bus_ != nullptr) {
    if (response_subscription_ != 0) {
      g_dbus_connection_signal_unsubscribe(bus_, response_subscription_);
    }
    if (activated_subscription_ != 0) {
      g_dbus_connection_signal_unsubscribe(bus_, activated_subscription_);
    }
    // Closing the connection ends the session and releases the shortcut.
    g_object_unref(bus_);
  }
}

void PortalShortcut::Bind(const std::string& trigger,
                          GlobalHotKey::DoneCallback done) {
  waiters_.push_back(std::move(done));
  wanted_ = trigger;
  retry_ = true;
  Advance();
}

void PortalShortcut::Unbind() {
  wanted_.clear();
  Advance();
}

void PortalShortcut::Advance() {
  if (busy_) {
    return;  // Back here when the request in flight is done.
  }
  switch (portal_) {
    case Portal::kUnknown:
      Connect();
      return;
    case Portal::kConnecting:
      return;
    case Portal::kUnavailable:
      Resolve(kHotKeyUnavailable);
      return;
    case Portal::kAvailable:
      break;
  }
  if (wanted_.empty()) {
    CloseSession();
    // A Bind that was overtaken by Unbind: nothing went wrong.
    Resolve(kHotKeyOk);
    return;
  }
  if (!session_.empty() && bound_ == wanted_) {
    Resolve(kHotKeyOk);
    return;
  }
  if (wanted_ == failed_ && !retry_) {
    Resolve(failed_status_);
    return;
  }
  retry_ = false;
  CloseSession();
  binding_ = wanted_;
  busy_ = true;
  CreateSession();
}

void PortalShortcut::Connect() {
  portal_ = Portal::kConnecting;
  g_autoptr(GError) error = nullptr;
  g_autofree gchar* address =
      g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (address == nullptr) {
    g_warning("No session bus for the shortcuts portal: %s", error->message);
    PortalChecked(false);
    return;
  }
  g_dbus_connection_new_for_address(
      address,
      static_cast<GDBusConnectionFlags>(
          G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
          G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
      nullptr, cancellable_, OnConnected, this);
}

void PortalShortcut::OnConnected(GObject* source, GAsyncResult* result,
                                 gpointer data) {
  g_autoptr(GError) error = nullptr;
  GDBusConnection* bus = g_dbus_connection_new_for_address_finish(result, &error);
  if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
    return;
  }
  auto* self = static_cast<PortalShortcut*>(data);
  if (bus == nullptr) {
    g_warning("Could not connect to the session bus: %s", error->message);
    self->PortalChecked(false);
    return;
  }
  self->ConnectionReady(bus);
}

void PortalShortcut::ConnectionReady(GDBusConnection* bus) {
  bus_ = bus;
  // Portals tell apps apart by their sandbox, and see an unsandboxed app as
  // nameless unless it registers its ID first (xdg-desktop-portal 1.19 and
  // later; older ones don't know the call). It has to be the first portal
  // call on the connection, hence a connection of Pastee's own.
  GApplication* app = g_application_get_default();
  const gchar* app_id =
      app != nullptr ? g_application_get_application_id(app) : nullptr;
  if (app_id == nullptr) {
    app_id = APPLICATION_ID;
  }
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_dbus_connection_call(bus_, kPortalBusName, kPortalPath, kRegistryInterface,
                         "Register", g_variant_new("(sa{sv})", app_id, &options),
                         nullptr, G_DBUS_CALL_FLAGS_NONE, -1, cancellable_,
                         OnRegistered, this);
}

void PortalShortcut::OnRegistered(GObject* source, GAsyncResult* result,
                                  gpointer data) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) reply =
      g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
  if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
    return;
  }
  if (reply == nullptr) {
    g_debug("Host app registry: %s", error->message);
  }
  // Whether the portal offers GlobalShortcuts at all: only when a backend for
  // the desktop implements it (GNOME 48, KDE Plasma 5.27, Hyprland...).
  auto* self = static_cast<PortalShortcut*>(data);
  g_dbus_connection_call(
      self->bus_, kPortalBusName, kPortalPath,
      "org.freedesktop.DBus.Properties", "Get",
      g_variant_new("(ss)", kShortcutsInterface, "version"),
      G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, -1, self->cancellable_,
      OnVersion, self);
}

void PortalShortcut::OnVersion(GObject* source, GAsyncResult* result,
                               gpointer data) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) reply =
      g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
  if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
    return;
  }
  if (reply == nullptr) {
    g_message("No global shortcuts portal: %s", error->message);
  }
  static_cast<PortalShortcut*>(data)->PortalChecked(reply != nullptr);
}

void PortalShortcut::PortalChecked(bool available) {
  portal_ = available ? Portal::kAvailable : Portal::kUnavailable;
  if (available) {
    activated_subscription_ = g_dbus_connection_signal_subscribe(
        bus_, kPortalBusName, kShortcutsInterface, "Activated", kPortalPath,
        nullptr, G_DBUS_SIGNAL_FLAGS_NONE, OnActivated, this, nullptr);
  }
  Advance();
}

std::string PortalShortcut::NextToken() {
  return "pastee" + std::to_string(++tokens_);
}

void PortalShortcut::CreateSession() {
  const std::string token = NextToken();
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token",
                        g_variant_new_string(token.c_str()));
  g_variant_builder_add(&options, "{sv}", "session_handle_token",
                        g_variant_new_string(NextToken().c_str()));
  Request("CreateSession", g_variant_new("(a{sv})", &options), token,
          &PortalShortcut::SessionCreated);
}

void PortalShortcut::SessionCreated(guint32 response, GVariant* results) {
  const gchar* handle = nullptr;
  if (response != 0 ||
      !(g_variant_lookup(results, "session_handle", "&s", &handle) ||
        g_variant_lookup(results, "session_handle", "&o", &handle))) {
    BindDone(response == 1 ? kHotKeyDeclined : kHotKeyPortalFailed);
    return;
  }
  session_ = handle;

  GVariantBuilder shortcuts;
  g_variant_builder_init(&shortcuts, G_VARIANT_TYPE("a(sa{sv})"));
  GVariantBuilder properties;
  g_variant_builder_init(&properties, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&properties, "{sv}", "description",
                        g_variant_new_string(kShortcutDescription));
  g_variant_builder_add(&properties, "{sv}", "preferred_trigger",
                        g_variant_new_string(binding_.c_str()));
  g_variant_builder_add(&shortcuts, "(sa{sv})", kShortcutId, &properties);

  const std::string token = NextToken();
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token",
                        g_variant_new_string(token.c_str()));
  // No parent window: the desktop's confirmation dialog stands on its own.
  Request("BindShortcuts",
          g_variant_new("(oa(sa{sv})sa{sv})", session_.c_str(), &shortcuts, "",
                        &options),
          token, &PortalShortcut::ShortcutsBound);
}

void PortalShortcut::ShortcutsBound(guint32 response, GVariant* results) {
  if (response != 0) {
    // 1: the user dismissed the desktop's dialog.
    BindDone(response == 1 ? kHotKeyDeclined : kHotKeyPortalFailed);
    return;
  }
  // The desktop may leave a shortcut out, or bind it to no key.
  bool bound = false;
  g_autoptr(GVariant) shortcuts =
      g_variant_lookup_value(results, "shortcuts", G_VARIANT_TYPE("a(sa{sv})"));
  if (shortcuts != nullptr) {
    GVariantIter iter;
    g_variant_iter_init(&iter, shortcuts);
    const gchar* id = nullptr;
    GVariant* properties = nullptr;
    while (g_variant_iter_loop(&iter, "(&s@a{sv})", &id, &properties)) {
      if (g_strcmp0(id, kShortcutId) == 0) {
        const gchar* trigger = nullptr;
        bound = !g_variant_lookup(properties, "trigger_description", "&s",
                                  &trigger) ||
                trigger[0] != '\0';
      }
    }
  }
  BindDone(bound ? kHotKeyOk : kHotKeyDeclined);
}

void PortalShortcut::BindDone(int status) {
  busy_ = false;
  if (status == kHotKeyOk) {
    bound_ = binding_;
    failed_.clear();
  } else {
    CloseSession();
    failed_ = binding_;
    failed_status_ = status;
  }
  binding_.clear();
  Advance();
}

void PortalShortcut::CloseSession() {
  if (session_.empty()) {
    return;
  }
  g_dbus_connection_call(bus_, kPortalBusName, session_.c_str(),
                         kSessionInterface, "Close", nullptr, nullptr,
                         G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr, nullptr);
  session_.clear();
  bound_.clear();
}

void PortalShortcut::Resolve(int status) {
  std::vector<GlobalHotKey::DoneCallback> waiters;
  waiters.swap(waiters_);
  for (auto& done : waiters) {
    done(status);
  }
}

void PortalShortcut::Request(const gchar* method, GVariant* parameters,
                             const std::string& token,
                             ResponseHandler handler) {
  // Listen before asking, so a quick answer isn't missed. The portal puts the
  // request at a path made of the caller's bus name and the token.
  std::string sender = g_dbus_connection_get_unique_name(bus_) + 1;
  for (char& c : sender) {
    if (c == '.') {
      c = '_';
    }
  }
  response_handler_ = handler;
  WatchRequest(std::string(kPortalPath) + "/request/" + sender + "/" + token);
  g_dbus_connection_call(bus_, kPortalBusName, kPortalPath, kShortcutsInterface,
                         method, parameters, G_VARIANT_TYPE("(o)"),
                         G_DBUS_CALL_FLAGS_NONE, -1, cancellable_,
                         OnRequestSent, this);
}

void PortalShortcut::WatchRequest(const std::string& path) {
  if (response_subscription_ != 0) {
    g_dbus_connection_signal_unsubscribe(bus_, response_subscription_);
  }
  request_path_ = path;
  response_subscription_ = g_dbus_connection_signal_subscribe(
      bus_, kPortalBusName, kRequestInterface, "Response", path.c_str(),
      nullptr, G_DBUS_SIGNAL_FLAGS_NO_MATCH_RULE, OnResponse, this, nullptr);
}

void PortalShortcut::OnRequestSent(GObject* source, GAsyncResult* result,
                                   gpointer data) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) reply =
      g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
  if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
    return;
  }
  auto* self = static_cast<PortalShortcut*>(data);
  if (reply == nullptr) {
    g_warning("Global shortcuts portal: %s", error->message);
    g_dbus_connection_signal_unsubscribe(self->bus_,
                                         self->response_subscription_);
    self->response_subscription_ = 0;
    self->BindDone(kHotKeyPortalFailed);
    return;
  }
  const gchar* path = nullptr;
  g_variant_get(reply, "(&o)", &path);
  if (self->response_subscription_ != 0 && self->request_path_ != path) {
    // Portals before 0.9 used other paths.
    self->WatchRequest(path);
  }
}

void PortalShortcut::OnResponse(GDBusConnection* bus, const gchar* sender,
                                const gchar* path, const gchar* interface,
                                const gchar* signal, GVariant* parameters,
                                gpointer data) {
  auto* self = static_cast<PortalShortcut*>(data);
  if (self->response_subscription_ == 0 || self->request_path_ != path ||
      !g_variant_is_of_type(parameters, G_VARIANT_TYPE("(ua{sv})"))) {
    return;
  }
  g_dbus_connection_signal_unsubscribe(bus, self->response_subscription_);
  self->response_subscription_ = 0;
  guint32 response = 2;
  g_autoptr(GVariant) results = nullptr;
  g_variant_get(parameters, "(u@a{sv})", &response, &results);
  (self->*self->response_handler_)(response, results);
}

void PortalShortcut::OnActivated(GDBusConnection* bus, const gchar* sender,
                                 const gchar* path, const gchar* interface,
                                 const gchar* signal, GVariant* parameters,
                                 gpointer data) {
  auto* self = static_cast<PortalShortcut*>(data);
  if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(osta{sv})"))) {
    return;
  }
  const gchar* session = nullptr;
  const gchar* id = nullptr;
  guint64 timestamp = 0;
  g_autoptr(GVariant) options = nullptr;
  g_variant_get(parameters, "(&o&st@a{sv})", &session, &id, &timestamp,
                &options);
  if (self->session_.empty() || self->session_ != session ||
      self->bound_.empty() || g_strcmp0(id, kShortcutId) != 0) {
    return;
  }
  // Wayland keeps input times to itself; the token lets the compositor focus
  // Pastee in answer to the shortcut (portal version 2).
  const gchar* token = nullptr;
  g_variant_lookup(options, "activation_token", "&s", &token);
  self->on_pressed_(GDK_CURRENT_TIME, token);
}

// ── GlobalHotKey ──────────────────────────────────────────────────────────

GlobalHotKey::GlobalHotKey(GdkDisplay* display, PressedCallback on_pressed) {
  if (IsWaylandSession(display)) {
    portal_ = std::make_unique<PortalShortcut>(std::move(on_pressed));
    return;
  }
#ifdef GDK_WINDOWING_X11
  if (GDK_IS_X11_DISPLAY(display)) {
    x11_ = std::make_unique<X11KeyGrab>(display, std::move(on_pressed));
  }
#endif
}

GlobalHotKey::~GlobalHotKey() = default;

void GlobalHotKey::Register(guint keyval, guint modifiers, DoneCallback done) {
#ifdef GDK_WINDOWING_X11
  if (x11_) {
    done(x11_->Grab(keyval, modifiers));
    return;
  }
#endif
  if (portal_) {
    const std::string trigger = PortalTrigger(keyval, modifiers);
    if (trigger.empty()) {
      done(kHotKeyNoSuchKey);
      return;
    }
    portal_->Bind(trigger, std::move(done));
    return;
  }
  done(kHotKeyUnavailable);
}

void GlobalHotKey::Unregister() {
#ifdef GDK_WINDOWING_X11
  if (x11_) {
    x11_->Ungrab();
  }
#endif
  if (portal_) {
    portal_->Unbind();
  }
}
