#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <optional>
#include <string>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Any id in 0x0000-0xBFFF identifies an application hotkey.
constexpr int kSummonHotKeyId = 0x5053;

// Smallest window the layout is designed for, in logical pixels.
constexpr int kMinWidth = 420;
constexpr int kMinHeight = 440;

std::optional<int64_t> GetIntArgument(const flutter::EncodableValue* arguments,
                                      const char* key) {
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) {
    return std::nullopt;
  }
  auto it = map->find(flutter::EncodableValue(key));
  if (it == map->end()) {
    return std::nullopt;
  }
  if (const auto* value = std::get_if<int32_t>(&it->second)) {
    return *value;
  }
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    return *value;
  }
  return std::nullopt;
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
  } else {
    result->NotImplemented();
  }
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
  HWND hwnd = GetHandle();
  if (hwnd != nullptr) {
    ::ShowWindow(hwnd, SW_MINIMIZE);
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
      // hotkey has to be released here while GetHandle() is still valid.
      UnregisterSummonHotKey();
      break;
    case WM_HOTKEY:
      if (static_cast<int>(wparam) == kSummonHotKeyId) {
        const bool show = !IsWindowActive();
        if (show) {
          ShowAndFocus();
        } else {
          HideWindow();
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
