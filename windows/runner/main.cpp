#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Must match the title passed to window.Create below.
constexpr const wchar_t kWindowTitle[] = L"Pastee";
// The class name Win32Window registers (see win32_window.cpp).
constexpr const wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// A debug build gets its own name, so `flutter run` still works while the
// installed Pastee is running.
#ifdef _DEBUG
constexpr const wchar_t kInstanceMutex[] = L"Local\\PasteeSingleInstance-debug";
#else
constexpr const wchar_t kInstanceMutex[] = L"Local\\PasteeSingleInstance";
#endif

// Window origin and preferred size, in logical pixels.
constexpr int kOriginX = 80;
constexpr int kOriginY = 60;
constexpr int kWidth = 560;
constexpr int kPreferredHeight = 760;
constexpr int kMinHeight = 480;

// The preferred height, shortened to fit the monitor's work area (taskbar
// excluded) on small or highly scaled screens.
unsigned int FittingHeight() {
  HMONITOR monitor = ::MonitorFromPoint(POINT{kOriginX, kOriginY},
                                        MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO info{};
  info.cbSize = static_cast<DWORD>(sizeof(info));
  if (!::GetMonitorInfoW(monitor, &info)) {
    return kPreferredHeight;
  }
  const int dpi = static_cast<int>(FlutterDesktopGetDpiForMonitor(monitor));
  const int usable = ::MulDiv(info.rcWork.bottom, 96, dpi) - kOriginY - 16;
  if (usable >= kPreferredHeight) {
    return kPreferredHeight;
  }
  return static_cast<unsigned int>(usable < kMinHeight ? kMinHeight : usable);
}

void BringExistingInstanceForward() {
  HWND existing = ::FindWindowW(kWindowClass, kWindowTitle);
  if (existing != nullptr) {
    // Async, so a hung first instance can't hang this launch too.
    ::ShowWindowAsync(existing, ::IsIconic(existing) ? SW_RESTORE : SW_SHOW);
    ::SetForegroundWindow(existing);
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Only one Pastee may own the summon shortcut and the data files. Launching
  // it again brings the running window forward instead.
  HANDLE instance_mutex = ::CreateMutexW(nullptr, TRUE, kInstanceMutex);
  const DWORD mutex_error = ::GetLastError();
  // ERROR_ACCESS_DENIED: the running copy was started as administrator.
  if ((instance_mutex != nullptr && mutex_error == ERROR_ALREADY_EXISTS) ||
      (instance_mutex == nullptr && mutex_error == ERROR_ACCESS_DENIED)) {
    BringExistingInstanceForward();
    if (instance_mutex != nullptr) {
      ::CloseHandle(instance_mutex);
    }
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(kOriginX, kOriginY);
  Win32Window::Size size(kWidth, FittingHeight());
  if (!window.Create(kWindowTitle, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex != nullptr) {
    ::ReleaseMutex(instance_mutex);
    ::CloseHandle(instance_mutex);
  }
  return EXIT_SUCCESS;
}
