#include "clipboard_writer.h"

#include <cstring>

namespace {

// KDE's convention, also followed by CopyQ and other clipboard managers: text
// offered with this target set to "secret" is left out of their history.
constexpr char kPasswordHintTarget[] = "x-kde-passwordManagerHint";
constexpr char kPasswordHintValue[] = "secret";

// Target infos: which kind of data a paste asks for.
constexpr guint kTextTarget = 1;
constexpr guint kPasswordHint = 2;

}  // namespace

struct ClipboardWriter::Entry {
  // Null once the writer is gone (GTK may still serve the text until another
  // app takes the clipboard).
  ClipboardWriter* owner;
  gchar* text;
  bool concealed;
  bool clear_on_exit;
};

ClipboardWriter::ClipboardWriter(GtkClipboard* clipboard)
    : clipboard_(GTK_CLIPBOARD(g_object_ref(clipboard))) {}

ClipboardWriter::~ClipboardWriter() {
  if (current_ != nullptr) {
    current_->owner = nullptr;
  }
  g_object_unref(clipboard_);
}

int64_t ClipboardWriter::Write(const gchar* text, bool concealed,
                               bool clear_on_exit) {
  auto* entry = new Entry{this, g_strdup(text), concealed, clear_on_exit};

  GtkTargetList* list = gtk_target_list_new(nullptr, 0);
  gtk_target_list_add_text_targets(list, kTextTarget);
  if (concealed) {
    gtk_target_list_add(list, gdk_atom_intern_static_string(kPasswordHintTarget),
                        0, kPasswordHint);
  }
  gint n_targets = 0;
  GtkTargetEntry* targets = gtk_target_table_new_from_list(list, &n_targets);
  gtk_target_list_unref(list);

  // Taking the clipboard clears an earlier write of Pastee's first
  // (ContentsCleared), which counts as a change of its own.
  const gboolean taken = gtk_clipboard_set_with_data(
      clipboard_, targets, n_targets, GetContents, ContentsCleared, entry);
  gtk_target_table_free(targets, n_targets);

  change_count_++;
  g_debug("clipboard: wrote%s, change %" G_GINT64_FORMAT,
          concealed ? " (concealed)" : "", change_count_);
  if (taken) {
    current_ = entry;
    // Like other GTK apps, let a clipboard manager keep the text once Pastee
    // quits (X11) - except a secret that should go when Pastee does.
    if (!(concealed && clear_on_exit)) {
      gtk_clipboard_set_can_store(clipboard_, nullptr, 0);
    }
  } else {
    // GTK didn't take the data, so it won't call ContentsCleared for it.
    entry->owner = nullptr;
    ContentsCleared(clipboard_, entry);
  }
  return change_count_;
}

bool ClipboardWriter::Clear(int64_t change_count) {
  if (current_ == nullptr || change_count != change_count_) {
    return false;
  }
  // Gives the clipboard up; ContentsCleared runs before this returns.
  gtk_clipboard_clear(clipboard_);
  g_debug("clipboard: cleared");
  return true;
}

void ClipboardWriter::ClearOnExit() {
  if (current_ != nullptr && current_->concealed && current_->clear_on_exit) {
    gtk_clipboard_clear(clipboard_);
    g_debug("clipboard: cleared at exit");
  }
}

void ClipboardWriter::GetContents(GtkClipboard* clipboard,
                                  GtkSelectionData* data, guint info,
                                  gpointer user_data) {
  auto* entry = static_cast<Entry*>(user_data);
  if (info == kPasswordHint) {
    gtk_selection_data_set(data, gtk_selection_data_get_target(data), 8,
                           reinterpret_cast<const guchar*>(kPasswordHintValue),
                           sizeof(kPasswordHintValue) - 1);
  } else {
    gtk_selection_data_set_text(data, entry->text, -1);
  }
}

void ClipboardWriter::ContentsCleared(GtkClipboard* clipboard,
                                      gpointer user_data) {
  auto* entry = static_cast<Entry*>(user_data);
  ClipboardWriter* self = entry->owner;
  if (self != nullptr && self->current_ == entry) {
    self->current_ = nullptr;
    self->change_count_++;
    g_debug("clipboard: replaced or cleared, change %" G_GINT64_FORMAT,
            self->change_count_);
  }
  // The text may be a password: don't leave it in freed memory.
  explicit_bzero(entry->text, strlen(entry->text));
  g_free(entry->text);
  delete entry;
}
