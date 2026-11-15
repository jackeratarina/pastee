#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <cstring>
#include <optional>
#include <string>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Any id in 0x0000-0xBFFF identifies an application hotkey.
constexpr int kSummonHotKeyId = 0x5053;

// How long a shortcut hide waits for Dart to call hideWindow before minimizing
// anyway. Timer ids only need to be unique per window.
constexpr UINT kHideFallbackMs = 500;
constexpr UINT_PTR kHideFallbackTimerId = 1;

// Smallest window the layout is designed for, in logical pixels.
constexpr int kMinWidth = 420;
constexpr int kMinHeight = 440;

const flutter::EncodableValue* GetArgument(
    const flutter::EncodableValue* arguments, const char* key) {
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) {
    return nullptr;
  }
  auto it = map->find(flutter::EncodableValue(key));
  return it == map->end() ? nullptr : &it->second;
}

std::optional<int64_t> GetIntArgument(const flutter::EncodableValue* arguments,
                                      const char* key) {
  const auto* value = GetArgument(arguments, key);
  if (value == nullptr) {
    return std::nullopt;
  }
  if (const auto* number = std::get_if<int32_t>(value)) {
    return *number;
  }
  if (const auto* number = std::get_if<int64_t>(value)) {
    return *number;
  }
  return std::nullopt;
}

const std::string* GetStringArgument(const flutter::EncodableValue* arguments,
                                     const char* key) {
  const auto* value = GetArgument(arguments, key);
  return value == nullptr ? nullptr : std::get_if<std::string>(value);
}

bool GetBoolArgument(const flutter::EncodableValue* arguments,
                     const char* key) {
  const auto* value = GetArgument(arguments, key);
  const bool* flag = value == nullptr ? nullptr : std::get_if<bool>(value);
  return flag != nullptr && *flag;
}

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int size = static_cast<int>(utf8.size());
  const int length =
      ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), size, nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring utf16(static_cast<size_t>(length), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), size, utf16.data(), length);
  return utf16;
}

// Another app (often a clipboard viewer reacting to the last change) can hold
// the clipboard open for a moment, so retry briefly before giving up.
bool OpenClipboardWithRetry(HWND window) {
  for (int attempt = 0; attempt < 10; ++attempt) {
    if (::OpenClipboard(window)) {
      return true;
    }
    ::Sleep(10);
  }
  return false;
}

// Puts a copy of |size| bytes on the (open) clipboard in |format|.
bool SetClipboardBytes(UINT format, const void* data, size_t size) {
  if (format == 0) {
    return false;
  }
  HGLOBAL memory = ::GlobalAlloc(GMEM_MOVEABLE, size);
  if (memory == nullptr) {
    return false;
  }
  void* target = ::GlobalLock(memory);
  if (target == nullptr) {
    ::GlobalFree(memory);
    return false;
  }
  std::memcpy(target, data, size);
  ::GlobalUnlock(memory);
  if (::SetClipboardData(format, memory) == nullptr) {
    ::GlobalFree(memory);
    return false;
  }
  return true;  // The clipboard owns |memory| now.
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  native_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "pastee/native",
          &flutter::StandardMethodCodec::GetInstance());
  native_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleNativeCall(call, std::move(result)); });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  UnregisterSummonHotKey();
  native_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::HandleNativeCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "registerHotKey") {
    const auto key_code = GetIntArgument(call.arguments(), "keyCode");
    const auto modifiers = GetIntArgument(call.arguments(), "modifiers");
    if (!key_code || !modifiers) {
      result->Error("bad_args", "keyCode and modifiers are required");
      return;
    }
    UnregisterSummonHotKey();
    // MOD_NOREPEAT: holding the keys down doesn't toggle the window on and off.
    const UINT flags = static_cast<UINT>(*modifiers) | MOD_NOREPEAT;
    if (::RegisterHotKey(GetHandle(), kSummonHotKeyId, flags,
                         static_cast<UINT>(*key_code))) {
      hotkey_registered_ = true;
      result->Success(flutter::EncodableValue(0));
    } else {
      // ERROR_HOTKEY_ALREADY_REGISTERED (1409) when another app owns it.
      result->Success(
          flutter::EncodableValue(static_cast<int32_t>(::GetLastError())));
    }
  } else if (method == "unregisterHotKey") {
    UnregisterSummonHotKey();
    result->Success();
  } else if (method == "showWindow") {
    ShowAndFocus();
    result->Success();
  } else if (method == "hideWindow") {
    HideWindow();
    result->Success();
  } else if (method == "isWindowActive") {
    result->Success(flutter::EncodableValue(IsWindowActive()));
  } else if (method == "writeClipboard") {
    const std::string* text = GetStringArgument(call.arguments(), "text");
    if (text == nullptr) {
      result->Error("bad_args", "text is required");
      return;
    }
    const bool concealed = GetBoolArgument(call.arguments(), "concealed");
    const bool clear_on_exit =
        GetBoolArgument(call.arguments(), "clearOnExit");
    const std::optional<DWORD> sequence = WriteClipboard(*text, concealed);
    if (!sequence) {
      result->Error("clipboard_busy", "The clipboard is in use by another app.");
      return;
    }
    clear_on_exit_sequence_ =
        concealed && clear_on_exit ? sequence : std::nullopt;
    result->Success(flutter::EncodableValue(static_cast<int64_t>(*sequence)));
  } else if (method == "clearClipboard") {
    const auto sequence = GetIntArgument(call.arguments(), "changeCount");
    if (!sequence) {
      result->Error("bad_args", "changeCount is required");
      return;
    }
    result->Success(flutter::EncodableValue(
        ClearClipboardIfUnchanged(static_cast<DWORD>(*sequence))));
  } else {
    result->NotImplemented();
  }
}

std::optional<DWORD> FlutterWindow::WriteClipboard(const std::string& text,
                                                   bool concealed) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || !OpenClipboardWithRetry(hwnd)) {
    return std::nullopt;
  }
  const std::wstring utf16 = Utf16FromUtf8(text);
  const bool written =
      ::EmptyClipboard() &&
      SetClipboardBytes(CF_UNICODETEXT, utf16.c_str(),
                        (utf16.size() + 1) * sizeof(wchar_t));
  if (written && concealed) {
    // Keeps the text out of clipboard history (Win+V) and cloud clipboard
    // sync. The broader "ignore this" formats some password managers add are
    // left out on purpose: remote desktop and VM tools may then refuse to
    // paste it.
    const DWORD no = 0;
    SetClipboardBytes(::RegisterClipboardFormatW(L"CanIncludeInClipboardHistory"),
                      &no, sizeof(no));
    SetClipboardBytes(::RegisterClipboardFormatW(L"CanUploadToCloudClipboard"),
                      &no, sizeof(no));
  }
  ::CloseClipboard();
  if (!written) {
    return std::nullopt;
  }
  return ::GetClipboardSequenceNumber();
}

bool FlutterWindow::ClearClipboardIfUnchanged(DWORD sequence) {
  if (clear_on_exit_sequence_ == sequence) {
    clear_on_exit_sequence_.reset();
  }
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || ::GetClipboardSequenceNumber() != sequence ||
      !OpenClipboardWithRetry(hwnd)) {
    return false;
  }
  // Checked again while the clipboard is open, so nothing can slip in.
  const bool cleared =
      ::GetClipboardSequenceNumber() == sequence && ::EmptyClipboard();
  ::CloseClipboard();
  return cleared;
}

void FlutterWindow::UnregisterSummonHotKey() {
  if (hotkey_registered_) {
    ::UnregisterHotKey(GetHandle(), kSummonHotKeyId);
    hotkey_registered_ = false;
  }
}

bool FlutterWindow::IsWindowActive() {
  HWND hwnd = GetHandle();
  return hwnd != nullptr && ::GetForegroundWindow() == hwnd &&
         ::IsWindowVisible(hwnd) && !::IsIconic(hwnd);
}

void FlutterWindow::ShowAndFocus() {
  CancelHideFallback();
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  ::ShowWindow(hwnd, ::IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  // Pressing a registered hotkey gives this process permission to take the
  // foreground, so no input-queue tricks are needed (and AttachThreadInput can
  // hang or reset the modifier keys the user is still holding).
  ::SetForegroundWindow(hwnd);
}

// Minimizing (rather than hiding) keeps Pastee on the taskbar and hands focus
// back to the window you were in, so the next Ctrl+V lands there.
void FlutterWindow::HideWindow() {
  CancelHideFallback();
  HWND hwnd = GetHandle();
  if (hwnd != nullptr) {
    ::ShowWindow(hwnd, SW_MINIMIZE);
  }
}

// The taskbar and Alt+Tab keep showing a minimized window's last frame, so a
// shortcut hide leaves the window up for Dart to draw its lock or privacy
// cover; Dart then calls hideWindow. If it hasn't within kHideFallbackMs, the
// timer minimizes the window anyway so the shortcut never feels broken.
void FlutterWindow::StartHideFallback() {
  if (::SetTimer(GetHandle(), kHideFallbackTimerId, kHideFallbackMs,
                 nullptr) != 0) {
    hide_pending_ = true;
  } else {
    // Without the timer there is no fallback: minimize right away.
    HideWindow();
  }
}

void FlutterWindow::CancelHideFallback() {
  if (hide_pending_) {
    ::KillTimer(GetHandle(), kHideFallbackTimerId);
    hide_pending_ = false;
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_DESTROY:
      // Win32Window clears the window handle before OnDestroy runs, so the
      // hotkey and the hide timer have to be released here while GetHandle()
      // is still valid.
      UnregisterSummonHotKey();
      CancelHideFallback();
      // A copied secret doesn't outlive Pastee if nothing replaced it.
      if (clear_on_exit_sequence_) {
        ClearClipboardIfUnchanged(*clear_on_exit_sequence_);
      }
      break;
    case WM_HOTKEY:
      if (static_cast<int>(wparam) == kSummonHotKeyId) {
        if (hide_pending_) {
          // Pressed again while waiting for Dart: minimize right away.
          HideWindow();
          return 0;
        }
        const bool show = !IsWindowActive();
        if (show) {
          ShowAndFocus();
        } else {
          StartHideFallback();
        }
        if (native_channel_) {
          native_channel_->InvokeMethod(
              "onHotKey", std::make_unique<flutter::EncodableValue>(
                              flutter::EncodableMap{
                                  {flutter::EncodableValue("shown"),
                                   flutter::EncodableValue(show)}}));
        }
        return 0;
      }
      break;
    case WM_TIMER:
      if (static_cast<UINT_PTR>(wparam) == kHideFallbackTimerId) {
        // Dart didn't call hideWindow in time. A WM_TIMER still queued after
        // the fallback was cancelled finds nothing pending and is ignored.
        if (hide_pending_) {
          HideWindow();
        }
        return 0;
      }
      break;
    case WM_GETMINMAXINFO: {
      // kMinWidth x kMinHeight is the content size; add the frame around it.
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
      RECT frame = {0, 0, ::MulDiv(kMinWidth, static_cast<int>(dpi), 96),
                    ::MulDiv(kMinHeight, static_cast<int>(dpi), 96)};
      ::AdjustWindowRectExForDpi(&frame, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi);
      info->ptMinTrackSize.x = frame.right - frame.left;
      info->ptMinTrackSize.y = frame.bottom - frame.top;
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
