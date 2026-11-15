#ifndef RUNNER_CLIPBOARD_WRITER_H_
#define RUNNER_CLIPBOARD_WRITER_H_

#include <gtk/gtk.h>

#include <cstdint>

// Puts text on the CLIPBOARD selection for the writeClipboard and
// clearClipboard calls of the "pastee/native" channel.
//
// GTK only reports changes to a selection Pastee owns, so the change count is
// Pastee's own: it goes up with every write, and when another app (or a text
// field in Pastee itself) takes the clipboard over. As long as it still equals
// the count a write returned, the clipboard holds that write.
class ClipboardWriter {
 public:
  explicit ClipboardWriter(GtkClipboard* clipboard);
  ~ClipboardWriter();

  ClipboardWriter(const ClipboardWriter&) = delete;
  ClipboardWriter& operator=(const ClipboardWriter&) = delete;

  // Replaces the clipboard with |text| and returns the new change count, or 0
  // if GTK couldn't take the clipboard. A |concealed| write also offers
  // x-kde-passwordManagerHint = "secret", which Klipper, and clipboard
  // managers that follow KDE's convention, take as "keep this out of the
  // history". With |concealed| and |clear_on_exit|, ClearOnExit() empties the
  // clipboard when Pastee quits, and the text is never handed to a clipboard
  // manager to keep.
  int64_t Write(const gchar* text, bool concealed, bool clear_on_exit);

  // Empties the clipboard if it still holds the write that returned
  // |change_count|. Returns whether it did.
  bool Clear(int64_t change_count);

  // Called as Pastee quits.
  void ClearOnExit();

 private:
  struct Entry;

  bool StillOwned() const;

  static void GetContents(GtkClipboard* clipboard, GtkSelectionData* data,
                          guint info, gpointer user_data);
  static void ContentsCleared(GtkClipboard* clipboard, gpointer user_data);

  GtkClipboard* clipboard_;

  // Pastee's write while it is on the clipboard, otherwise null.
  Entry* current_ = nullptr;
  int64_t change_count_ = 0;
};

#endif  // RUNNER_CLIPBOARD_WRITER_H_
