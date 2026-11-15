#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <glib-unix.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <csignal>

#include "flutter/generated_plugin_registrant.h"
#include "native_bridge.h"

namespace {

// The single-instance name on the session bus. A debug build gets its own,
// so `flutter run` works while the installed Pastee is running (and, since
// path_provider names the data folder after it, keeps its own data).
#ifdef NDEBUG
constexpr char kInstanceId[] = APPLICATION_ID;
#else
constexpr char kInstanceId[] = APPLICATION_ID ".debug";
#endif

constexpr char kWindowTitle[] = "Pastee";

// Window size in logical pixels; the layout works down to the minimum size.
constexpr int kWidth = 560;
constexpr int kPreferredHeight = 760;
constexpr int kMinFittingHeight = 480;
constexpr int kMinWidth = 420;
constexpr int kMinHeight = 440;

// The preferred height, shortened to fit the monitor's work area on small
// screens.
int FittingHeight(GtkWindow* window) {
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
  GdkMonitor* monitor = gdk_display_get_primary_monitor(display);
  if (monitor == nullptr) {
    monitor = gdk_display_get_monitor(display, 0);
  }
  if (monitor == nullptr) {
    return kPreferredHeight;
  }
  GdkRectangle area;
  gdk_monitor_get_workarea(monitor, &area);
  // Leave room for the title bar and the window's shadow.
  const int usable = area.height - 48;
  return CLAMP(usable, kMinFittingHeight, kPreferredHeight);
}

// The icon theme has Pastee's icon once the .deb is installed. The tarball
// carries it in data/ for the window icon on X11 (Wayland desktops take it
// from the .desktop file).
void SetWindowIcon(GtkWindow* window) {
  if (gtk_icon_theme_has_icon(gtk_icon_theme_get_default(), APPLICATION_ID)) {
    gtk_window_set_icon_name(window, APPLICATION_ID);
    return;
  }
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
  if (executable == nullptr) {
    return;
  }
  g_autofree gchar* directory = g_path_get_dirname(executable);
  g_autofree gchar* icon =
      g_build_filename(directory, "data", "app_icon.png", nullptr);
  if (g_file_test(icon, G_FILE_TEST_EXISTS)) {
    gtk_window_set_icon_from_file(window, icon, nullptr);
  }
}

}  // namespace

struct _MyApplication {
  GtkApplication parent_instance;
  GtkWindow* window;
  NativeBridge* bridge;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

static void window_destroyed_cb(MyApplication* self) {
  self->window = nullptr;
}

static void create_window(MyApplication* self, gchar** dart_arguments) {
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(self)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  }
  gtk_window_set_title(window, kWindowTitle);
  gtk_window_set_default_size(window, kWidth, FittingHeight(window));
  SetWindowIcon(window);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, dart_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  // The smallest size the layout is designed for.
  gtk_widget_set_size_request(GTK_WIDGET(view), kMinWidth, kMinHeight);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  // A window closed without quitting leaves its bridge, with the shortcut.
  delete self->bridge;
  self->bridge = new NativeBridge(window, view);

  gtk_widget_grab_focus(GTK_WIDGET(view));

  self->window = window;
  g_signal_connect_swapped(window, "destroy", G_CALLBACK(window_destroyed_cb),
                           self);
}

// Implements GApplication::command_line. Pastee runs once per session: a
// `pastee` started while it runs hands its command line to this one over
// D-Bus and exits.
static gint my_application_command_line(GApplication* application,
                                        GApplicationCommandLine* command_line) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->window == nullptr) {
    // Starting up (`pastee --toggle` starts Pastee too). The arguments left
    // after the options go to Dart, like in Flutter's template.
    g_auto(GStrv) arguments =
        g_application_command_line_get_arguments(command_line, nullptr);
    create_window(self, arguments + 1);
    return 0;
  }
  GVariantDict* options = g_application_command_line_get_options_dict(command_line);
  if (g_variant_dict_contains(options, "toggle")) {
    // Like the summon shortcut. A system keyboard shortcut can run this where
    // Pastee can't register one itself.
    g_debug("--toggle from another pastee");
    self->bridge->Toggle(GDK_CURRENT_TIME, nullptr);
  } else {
    self->bridge->Show();
  }
  return 0;
}

// Implements GApplication::activate (D-Bus activation, `gapplication launch`).
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->window == nullptr) {
    create_window(self, nullptr);
  } else {
    self->bridge->Show();
  }
}

// Quits like closing the window does, so Shutdown runs (logout, kill).
static gboolean quit_signal_cb(gpointer application) {
  g_application_quit(G_APPLICATION(application));
  return G_SOURCE_CONTINUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);

  g_unix_signal_add(SIGTERM, quit_signal_cb, application);
  g_unix_signal_add(SIGINT, quit_signal_cb, application);
  g_unix_signal_add(SIGHUP, quit_signal_cb, application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  // Before GtkApplication's shutdown, which hands the clipboard to a
  // clipboard manager.
  if (self->bridge != nullptr) {
    self->bridge->Shutdown();
  }

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  delete self->bridge;
  self->bridge = nullptr;
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->command_line = my_application_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  static const GOptionEntry kOptions[] = {
      {"toggle", 't', G_OPTION_FLAG_NONE, G_OPTION_ARG_NONE, nullptr,
       "Show Pastee, or hide it if it is in front (for a keyboard shortcut)",
       nullptr},
      {nullptr},
  };
  g_application_add_main_option_entries(G_APPLICATION(self), kOptions);
  g_application_set_option_context_summary(
      G_APPLICATION(self),
      "Instant Shortcut Notes. Starting Pastee again brings the running one "
      "to the front.");
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", kInstanceId, "flags",
                                     G_APPLICATION_HANDLES_COMMAND_LINE,
                                     nullptr));
}
