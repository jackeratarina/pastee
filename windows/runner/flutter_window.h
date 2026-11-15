#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <optional>
#include <string>

#include "win32_window.h"

// A window that hosts a Flutter view plus Pastee's small native bridge
// (channel "pastee/native"): a system-wide summon shortcut, showing or
// minimizing the window, and copying secrets.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void HandleNativeCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  bool IsWindowActive();
  void ShowAndFocus();
  void HideWindow();
  void StartHideFallback();
  void CancelHideFallback();
  void UnregisterSummonHotKey();
  // Returns the clipboard sequence number after writing, or nullopt if the
  // clipboard couldn't be opened or written.
  std::optional<DWORD> WriteClipboard(const std::string& text, bool concealed);
  // Empties the clipboard if its sequence number is still |sequence|.
  bool ClearClipboardIfUnchanged(DWORD sequence);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      native_channel_;
  bool hotkey_registered_ = false;

  // Set while a shortcut hide is waiting for Dart (the fallback timer runs).
  bool hide_pending_ = false;

  // The sequence number of a copied secret to clear when Pastee quits, if the
  // clipboard still holds it then.
  std::optional<DWORD> clear_on_exit_sequence_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
