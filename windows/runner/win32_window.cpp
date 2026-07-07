#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// M1: the smallest LOGICAL window size the app is designed to remain usable at.
// Below this the fixed-px chrome (nav rail + sheet rail + right inspector) plus
// a usable canvas overflow with no reflow, so the native window enforces a floor
// via WM_GETMINMAXINFO — the OS itself can't shrink the frame smaller (e.g. a
// Windows 11 Snap Layout that would otherwise clip the rails). Scaled to physical
// pixels by the window's current monitor DPI at handle time.
constexpr int kMinWindowLogicalWidth = 1024;
constexpr int kMinWindowLogicalHeight = 700;

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

// --- M3: window placement persistence -------------------------------------
//
// Remember the window's position, size, and maximized state across launches.
// The placement is written on close and restored on the next launch, into the
// same per-user app-data dir the Dart side uses for settings/recovery
// (%APPDATA%\iSystem). Every step is best-effort and defensive.

// A tiny, versioned on-disk record of the window geometry. Fixed-size + a magic
// so a truncated / foreign / older file is rejected by a simple size + magic
// check (never partially parsed, never crashing).
struct SavedPlacementFile {
  DWORD magic;
  DWORD version;
  LONG left;
  LONG top;
  LONG right;
  LONG bottom;
  DWORD show_cmd;  // SW_SHOWNORMAL or SW_SHOWMAXIMIZED
};

constexpr DWORD kPlacementMagic = 0x4D584957;  // 'WIXM'
constexpr DWORD kPlacementVersion = 1;

// %APPDATA%\iSystem\window_placement.dat, or an empty string when APPDATA is
// unavailable (then save/restore no-op). Reads the SAME env var the Dart
// appSupportDir() does, so the file lands beside settings.json / recovery\.
std::wstring PlacementFilePath() {
  wchar_t buffer[MAX_PATH];
  DWORD len = GetEnvironmentVariableW(L"APPDATA", buffer, MAX_PATH);
  if (len == 0 || len >= MAX_PATH) {
    return std::wstring();
  }
  return std::wstring(buffer, len) + L"\\iSystem\\window_placement.dat";
}

// Ensure %APPDATA%\iSystem exists (the Dart side creates it lazily on its first
// write, which may not have happened by the first close).
void EnsurePlacementDir() {
  wchar_t buffer[MAX_PATH];
  DWORD len = GetEnvironmentVariableW(L"APPDATA", buffer, MAX_PATH);
  if (len == 0 || len >= MAX_PATH) {
    return;
  }
  std::wstring dir = std::wstring(buffer, len) + L"\\iSystem";
  CreateDirectoryW(dir.c_str(), nullptr);  // ignores ERROR_ALREADY_EXISTS
}

void WritePlacementFile(const SavedPlacementFile& record) {
  const std::wstring path = PlacementFilePath();
  if (path.empty()) {
    return;
  }
  EnsurePlacementDir();
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  DWORD record_size = sizeof(record);
  DWORD written = 0;
  WriteFile(file, &record, record_size, &written, nullptr);
  CloseHandle(file);
}

bool ReadPlacementFile(SavedPlacementFile* out) {
  const std::wstring path = PlacementFilePath();
  if (path.empty()) {
    return false;
  }
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  SavedPlacementFile record{};
  DWORD record_size = sizeof(record);
  DWORD read = 0;
  BOOL ok = ReadFile(file, &record, record_size, &read, nullptr);
  CloseHandle(file);
  if (!ok || read != record_size || record.magic != kPlacementMagic ||
      record.version != kPlacementVersion) {
    return false;
  }
  *out = record;
  return true;
}

// Reject a saved rect that no longer intersects any connected monitor's work
// area (e.g. the second monitor it lived on was unplugged), so the window can
// never open where the user can't see or reach it.
bool RectIsVisible(const RECT& rect) {
  HMONITOR monitor = MonitorFromRect(&rect, MONITOR_DEFAULTTONULL);
  if (monitor == nullptr) {
    return false;
  }
  MONITORINFO info;
  info.cbSize = sizeof(info);
  if (!GetMonitorInfo(monitor, &info)) {
    return false;
  }
  RECT intersection;
  return IntersectRect(&intersection, &rect, &info.rcWork) != 0;
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  // M3: load any saved placement now (into members). It is applied in |Show|,
  // not here, so the window is never shown before its first frame is ready.
  RestoreWindowPlacement();

  return OnCreate();
}

bool Win32Window::Show() {
  // M3: restore the saved geometry + show state (normal / maximized) in one
  // call at first-frame time. The window was created hidden, so applying the
  // placement here shows it directly at the remembered position with no flash.
  if (has_saved_placement_) {
    return SetWindowPlacement(window_handle_, &saved_placement_) != 0;
  }
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_DESTROY:
      // M3: capture the window placement before the handle is torn down, so the
      // next launch reopens where the user left it. Fires on every destroy path
      // (the X, Alt+F4, programmatic close), not just WM_CLOSE.
      SaveWindowPlacement();
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_GETMINMAXINFO: {
      // M1: clamp the minimum track size to kMinWindowLogicalWidth/Height,
      // converted to physical pixels using this window's monitor DPI so the
      // floor is correct at 100/125/150 % Windows scaling. (During creation
      // this can arrive before the child view exists; the client-area sizing
      // in WM_SIZE still applies, so no special-casing is needed here.)
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
      const double scale_factor = dpi / 96.0;
      info->ptMinTrackSize.x = Scale(kMinWindowLogicalWidth, scale_factor);
      info->ptMinTrackSize.y = Scale(kMinWindowLogicalHeight, scale_factor);
      return 0;
    }

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}

void Win32Window::SaveWindowPlacement() {
  if (window_handle_ == nullptr) {
    return;
  }
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(WINDOWPLACEMENT);
  if (!GetWindowPlacement(window_handle_, &placement)) {
    return;
  }
  // Persist maximized when the window is (or restores to) maximized; NEVER
  // persist minimized — the window should re-open normal or maximized, not
  // hidden. GetWindowPlacement gives the restored (normal) rect regardless of
  // the current show state, which is exactly what we want to remember.
  const bool maximized = placement.showCmd == SW_SHOWMAXIMIZED ||
                         (placement.flags & WPF_RESTORETOMAXIMIZED) != 0;
  const RECT& rect = placement.rcNormalPosition;
  SavedPlacementFile record{};
  record.magic = kPlacementMagic;
  record.version = kPlacementVersion;
  record.left = rect.left;
  record.top = rect.top;
  record.right = rect.right;
  record.bottom = rect.bottom;
  record.show_cmd = maximized ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL;
  WritePlacementFile(record);
}

void Win32Window::RestoreWindowPlacement() {
  SavedPlacementFile record{};
  if (!ReadPlacementFile(&record)) {
    return;  // no / corrupt / older file — keep the default placement.
  }
  const RECT rect = {record.left, record.top, record.right, record.bottom};
  if (!RectIsVisible(rect)) {
    return;  // saved on a monitor that's no longer connected — ignore it.
  }
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(WINDOWPLACEMENT);
  placement.flags = 0;
  placement.showCmd =
      record.show_cmd == SW_SHOWMAXIMIZED ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL;
  placement.ptMinPosition = {-1, -1};
  placement.ptMaxPosition = {-1, -1};
  placement.rcNormalPosition = rect;
  saved_placement_ = placement;
  has_saved_placement_ = true;
}
