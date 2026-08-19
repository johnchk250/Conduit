#include "send_popup.h"

#include <commctrl.h>
#include <dwmapi.h>
#include <flutter_windows.h>

namespace {

constexpr wchar_t kPopupClassName[] = L"CONDUIT_SEND_POPUP";

// Same fallback as win32_window.cpp in case the SDK is older than 22000.
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

// Registry key for the app theme preference (mirrors win32_window.cpp).
constexpr wchar_t kGetPreferredBrightnessRegKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// Logical -> physical pixel scaling for the popup's target DPI.
int Scale(int value, int dpi) {
  return value * dpi / 96;
}

bool IsDarkMode() {
  DWORD light_mode = 1;
  DWORD size = sizeof(light_mode);
  if (RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                  kGetPreferredBrightnessRegValue, RRF_RT_REG_DWORD, nullptr,
                  &light_mode, &size) != ERROR_SUCCESS) {
    return false;
  }
  return light_mode == 0;
}

}  // namespace

SendPopup::SendPopup() = default;

SendPopup::~SendPopup() {
  Hide();
}

void SendPopup::Show(const std::wstring& title, const std::wstring& subtitle) {
  if (hwnd_ == nullptr) {
    POINT pt;
    GetCursorPos(&pt);
    HMONITOR monitor = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
    dpi_ = FlutterDesktopGetDpiForMonitor(monitor);
    hwnd_ = CreateWindowAndControls(dpi_);
    if (hwnd_ == nullptr) {
      return;
    }
  }
  SetText(title_, title);
  SetText(subtitle_, subtitle);
  if (!IsWindowVisible(hwnd_)) {
    ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  }
  // Re-anchor (cheap) so a monitor/taskbar change mid-batch doesn't leave the
  // popup stranded somewhere unexpected.
  PlaceBottomRight();
}

void SendPopup::UpdateProgress(const std::wstring& subtitle, int percent) {
  if (hwnd_ == nullptr) {
    return;
  }
  SetText(subtitle_, subtitle);
  SendMessageW(progress_, PBM_SETPOS, static_cast<WPARAM>(percent), 0);
}

void SendPopup::Complete(bool success, const std::wstring& message) {
  if (hwnd_ == nullptr) {
    return;
  }
  if (success) {
    Hide();
    return;
  }
  SetText(title_, L"Send failed");
  SetText(subtitle_, message);
  if (!IsWindowVisible(hwnd_)) {
    ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  }
}

void SendPopup::Hide() {
  if (hwnd_ != nullptr) {
    DestroyWindow(hwnd_);
    // WM_DESTROY in MessageHandler nulls hwnd_ and the child handles.
  }
}

bool SendPopup::IsVisible() const {
  return hwnd_ != nullptr && IsWindowVisible(hwnd_);
}

// static
void SendPopup::SetText(HWND control, const std::wstring& text) {
  if (control != nullptr) {
    SetWindowTextW(control, text.c_str());
  }
}

HFONT SendPopup::CreateFontAtDpi(int dpi) {
  return CreateFontW(-MulDiv(9, dpi, 72), 0, 0, 0, FW_NORMAL, FALSE, FALSE,
                     FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                     CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH,
                     L"Segoe UI");
}

void SendPopup::ApplyFont() {
  if (font_ == nullptr) {
    return;
  }
  for (HWND control : {title_, subtitle_, close_button_}) {
    SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(font_), TRUE);
  }
}

HWND SendPopup::CreateWindowAndControls(int dpi) {
  INITCOMMONCONTROLSEX common_controls{};
  common_controls.dwSize = sizeof(common_controls);
  common_controls.dwICC = ICC_PROGRESS_CLASS;
  InitCommonControlsEx(&common_controls);

  static bool class_registered = false;
  if (!class_registered) {
    WNDCLASSEX wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = &SendPopup::WndProc;
    wc.hInstance = GetModuleHandle(nullptr);
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    // Background handled via WM_ERASEBKGND so it can follow the app theme.
    wc.hbrBackground = nullptr;
    wc.lpszClassName = kPopupClassName;
    if (!RegisterClassEx(&wc)) {
      return nullptr;
    }
    class_registered = true;
  }

  const bool dark = IsDarkMode();
  text_color_ = dark ? RGB(0xE8, 0xE8, 0xE8) : RGB(0x1F, 0x1F, 0x1F);
  background_brush_ =
      CreateSolidBrush(dark ? RGB(0x2B, 0x2B, 0x2E) : RGB(0xFF, 0xFF, 0xFF));

  const int width = Scale(kWidth, dpi);
  const int height = Scale(kHeight, dpi);

  HWND hwnd = CreateWindowExW(
      WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE, kPopupClassName,
      L"Conduit", WS_POPUP, 0, 0, width, height, nullptr, nullptr,
      GetModuleHandle(nullptr), this);
  if (hwnd == nullptr) {
    return nullptr;
  }

  // Match the app's dark/light window decorations (same attribute the main
  // Flutter window uses in win32_window.cpp).
  DWORD enable_dark = dark ? 1 : 0;
  DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &enable_dark,
                        sizeof(enable_dark));

  font_ = CreateFontAtDpi(dpi);

  title_ = CreateWindowExW(
      0, L"STATIC", L"", WS_CHILD | WS_VISIBLE | SS_LEFT | SS_CENTERIMAGE, 0, 0,
      0, 0, hwnd, nullptr, GetModuleHandle(nullptr), nullptr);
  progress_ = CreateWindowExW(0, PROGRESS_CLASS, L"",
                              WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, nullptr,
                              GetModuleHandle(nullptr), nullptr);
  subtitle_ = CreateWindowExW(
      0, L"STATIC", L"",
      WS_CHILD | WS_VISIBLE | SS_LEFT | SS_CENTERIMAGE | SS_ENDELLIPSIS, 0, 0,
      0, 0, hwnd, nullptr, GetModuleHandle(nullptr), nullptr);
  close_button_ = CreateWindowExW(
      0, L"BUTTON", L"\u2715", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0,
      0, hwnd, nullptr, GetModuleHandle(nullptr), nullptr);

  ApplyFont();
  SendMessageW(progress_, PBM_SETRANGE, 0, MAKELPARAM(0, 100));

  Layout(dpi);
  PlaceBottomRight();
  return hwnd;
}

void SendPopup::Layout(int dpi) {
  if (hwnd_ == nullptr) {
    return;
  }
  const int pad = Scale(10, dpi);
  const int gap = Scale(8, dpi);
  const int title_h = Scale(20, dpi);
  const int bar_h = Scale(16, dpi);
  const int subtitle_h = Scale(18, dpi);
  const int win_w = Scale(kWidth, dpi);
  const int win_h = Scale(kHeight, dpi);
  const int close_w = Scale(24, dpi);

  SetWindowPos(hwnd_, nullptr, 0, 0, win_w, win_h,
               SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
  MoveWindow(title_, pad, pad, win_w - 2 * pad - close_w - Scale(6, dpi),
             title_h, TRUE);
  MoveWindow(close_button_, win_w - pad - close_w, pad, close_w, title_h, TRUE);
  MoveWindow(progress_, pad, pad + title_h + gap, win_w - 2 * pad, bar_h,
             TRUE);
  MoveWindow(subtitle_, pad, pad + title_h + gap + bar_h + gap,
             win_w - 2 * pad, subtitle_h, TRUE);
}

void SendPopup::PlaceBottomRight() {
  if (hwnd_ == nullptr) {
    return;
  }
  POINT pt;
  GetCursorPos(&pt);
  HMONITOR monitor = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi{};
  mi.cbSize = sizeof(mi);
  if (!GetMonitorInfoW(monitor, &mi)) {
    return;
  }
  RECT win;
  GetWindowRect(hwnd_, &win);
  const int margin = Scale(12, dpi_);
  int x = mi.rcWork.right - (win.right - win.left) - margin;
  int y = mi.rcWork.bottom - (win.bottom - win.top) - margin;
  if (x < mi.rcWork.left) {
    x = mi.rcWork.left;
  }
  if (y < mi.rcWork.top) {
    y = mi.rcWork.top;
  }
  SetWindowPos(hwnd_, HWND_TOPMOST, x, y, 0, 0,
               SWP_NOSIZE | SWP_NOACTIVATE);
}

// static
LRESULT CALLBACK SendPopup::WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                    LPARAM lparam) noexcept {
  SendPopup* popup = nullptr;
  if (message == WM_NCCREATE) {
    auto* create_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    popup = static_cast<SendPopup*>(create_struct->lpCreateParams);
    SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(popup));
    popup->hwnd_ = hwnd;
  } else {
    popup = reinterpret_cast<SendPopup*>(
        GetWindowLongPtr(hwnd, GWLP_USERDATA));
  }
  if (popup != nullptr) {
    return popup->MessageHandler(hwnd, message, wparam, lparam);
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

LRESULT SendPopup::MessageHandler(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept {
  switch (message) {
    case WM_COMMAND:
      if (HIWORD(wparam) == BN_CLICKED &&
          reinterpret_cast<HWND>(lparam) == close_button_) {
        Hide();
        return 0;
      }
      break;
    case WM_DPICHANGED: {
      dpi_ = HIWORD(wparam);
      if (font_ != nullptr) {
        DeleteObject(font_);
      }
      font_ = CreateFontAtDpi(dpi_);
      ApplyFont();
      Layout(dpi_);
      PlaceBottomRight();
      return 0;
    }
    case WM_ERASEBKGND:
      if (background_brush_ != nullptr) {
        RECT rc;
        GetClientRect(hwnd, &rc);
        FillRect(reinterpret_cast<HDC>(wparam), &rc, background_brush_);
        return 1;
      }
      break;
    case WM_CTLCOLORSTATIC: {
      HDC hdc = reinterpret_cast<HDC>(wparam);
      SetBkMode(hdc, TRANSPARENT);
      SetTextColor(hdc, text_color_);
      return reinterpret_cast<LRESULT>(background_brush_);
    }
    case WM_DESTROY:
      if (font_ != nullptr) {
        DeleteObject(font_);
      }
      if (background_brush_ != nullptr) {
        DeleteObject(background_brush_);
      }
      font_ = nullptr;
      background_brush_ = nullptr;
      hwnd_ = nullptr;
      title_ = nullptr;
      subtitle_ = nullptr;
      progress_ = nullptr;
      close_button_ = nullptr;
      return 0;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}
