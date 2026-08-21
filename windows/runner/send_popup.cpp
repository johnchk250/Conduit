#include "send_popup.h"

#include <commctrl.h>
#include <dwmapi.h>
#include <flutter_windows.h>
#include <windowsx.h>

namespace {

constexpr wchar_t kPopupClassName[] = L"CONDUIT_SEND_POPUP";

// Same fallback as win32_window.cpp in case the SDK is older than 22000.
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

// Windows 11's rounded corners are a no-op on earlier versions. Keep local
// fallbacks so the runner still builds with older Windows SDKs.
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWCP_ROUND
#define DWMWCP_ROUND 2
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
  KillTimer(hwnd_, kCompletionTimerId);
  terminal_ = false;
  SetCollapsed(false);
  SetText(title_, title);
  SetText(status_, L"0%");
  SetText(subtitle_, subtitle);
  SendMessageW(progress_, PBM_SETPOS, 0, 0);
  if (!IsWindowVisible(hwnd_)) {
    ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  }
  // Re-anchor (cheap) so a monitor/taskbar change mid-batch doesn't leave the
  // popup stranded somewhere unexpected.
  PlaceBottomRight();
}

void SendPopup::UpdateProgress(const std::wstring& subtitle, int percent) {
  if (hwnd_ == nullptr || terminal_) {
    return;
  }
  if (percent < 0) {
    percent = 0;
  } else if (percent > 100) {
    percent = 100;
  }
  SetText(subtitle_, subtitle);
  SetText(status_, std::to_wstring(percent) + L"%");
  SendMessageW(progress_, PBM_SETPOS, static_cast<WPARAM>(percent), 0);
}

void SendPopup::Complete(bool success, const std::wstring& message) {
  if (hwnd_ == nullptr) {
    return;
  }
  terminal_ = true;
  SetCollapsed(false);
  if (success) {
    SetText(title_, L"Sent");
    SetText(status_, L"100%");
    SetText(subtitle_, message);
    SendMessageW(progress_, PBM_SETPOS, 100, 0);
    if (!IsWindowVisible(hwnd_)) {
      ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
    }
    SetTimer(hwnd_, kCompletionTimerId, 2200, nullptr);
    return;
  }
  SetText(title_, L"Send failed");
  SetText(status_, L"");
  SetText(subtitle_, message);
  if (!IsWindowVisible(hwnd_)) {
    ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  }
}

void SendPopup::Hide() {
  if (hwnd_ != nullptr) {
    KillTimer(hwnd_, kCompletionTimerId);
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
  for (HWND control : {title_, status_, subtitle_, collapse_button_,
                       close_button_}) {
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
    wc.style = CS_HREDRAW | CS_VREDRAW | CS_DROPSHADOW;
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

  const int width = Scale(kExpandedWidth, dpi);
  const int height = Scale(kExpandedHeight, dpi);

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
  const DWORD corner_preference = DWMWCP_ROUND;
  DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE,
                        &corner_preference, sizeof(corner_preference));

  font_ = CreateFontAtDpi(dpi);

  title_ = CreateWindowExW(
      0, L"STATIC", L"", WS_CHILD | WS_VISIBLE | SS_LEFT | SS_CENTERIMAGE, 0, 0,
      0, 0, hwnd, nullptr, GetModuleHandle(nullptr), nullptr);
  status_ = CreateWindowExW(
      0, L"STATIC", L"", WS_CHILD | WS_VISIBLE | SS_RIGHT | SS_CENTERIMAGE,
      0, 0, 0, 0, hwnd, nullptr, GetModuleHandle(nullptr), nullptr);
  progress_ = CreateWindowExW(0, PROGRESS_CLASS, L"",
                              WS_CHILD | WS_VISIBLE | PBS_SMOOTH, 0, 0, 0, 0,
                              hwnd, nullptr, GetModuleHandle(nullptr), nullptr);
  subtitle_ = CreateWindowExW(
      0, L"STATIC", L"",
      WS_CHILD | WS_VISIBLE | SS_LEFT | SS_CENTERIMAGE | SS_ENDELLIPSIS, 0, 0,
      0, 0, hwnd, nullptr, GetModuleHandle(nullptr), nullptr);
  collapse_button_ = CreateWindowExW(
      0, L"BUTTON", L"Minimize",
      WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON | BS_FLAT, 0, 0, 0, 0, hwnd,
      nullptr, GetModuleHandle(nullptr), nullptr);
  close_button_ = CreateWindowExW(0, L"BUTTON", L"\u00d7",
                                  WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON | BS_FLAT,
                                  0, 0, 0, 0, hwnd, nullptr,
                                  GetModuleHandle(nullptr), nullptr);

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
  const int pad = Scale(12, dpi);
  const int gap = Scale(8, dpi);
  const int title_h = Scale(20, dpi);
  const int bar_h = Scale(collapsed_ ? 5 : 8, dpi);
  const int subtitle_h = Scale(18, dpi);
  const int win_w = Scale(collapsed_ ? kCollapsedWidth : kExpandedWidth, dpi);
  const int win_h = Scale(collapsed_ ? kCollapsedHeight : kExpandedHeight, dpi);
  const int close_w = Scale(24, dpi);
  const int collapse_w = Scale(collapsed_ ? 44 : 70, dpi);
  const int status_w = Scale(40, dpi);

  SetWindowPos(hwnd_, nullptr, 0, 0, win_w, win_h,
               SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
  MoveWindow(title_, pad, pad,
             win_w - 2 * pad - status_w - collapse_w - close_w - 3 * gap,
             title_h, TRUE);
  MoveWindow(status_, win_w - pad - close_w - collapse_w - 2 * gap - status_w,
             pad, status_w, title_h, TRUE);
  MoveWindow(collapse_button_, win_w - pad - close_w - collapse_w - gap, pad,
             collapse_w, title_h, TRUE);
  MoveWindow(close_button_, win_w - pad - close_w, pad, close_w, title_h, TRUE);
  const int progress_y = pad + title_h + (collapsed_ ? Scale(5, dpi) : gap);
  MoveWindow(progress_, pad, progress_y, win_w - 2 * pad, bar_h, TRUE);
  MoveWindow(subtitle_, pad, progress_y + bar_h + gap, win_w - 2 * pad,
             subtitle_h, TRUE);
}

void SendPopup::SetCollapsed(bool collapsed) {
  if (hwnd_ == nullptr || collapsed_ == collapsed) {
    return;
  }
  collapsed_ = collapsed;
  ShowWindow(subtitle_, collapsed_ ? SW_HIDE : SW_SHOWNA);
  SetWindowTextW(collapse_button_, collapsed_ ? L"Show" : L"Minimize");
  Layout(dpi_);
  PlaceBottomRight();
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
      if (HIWORD(wparam) == BN_CLICKED) {
        const HWND control = reinterpret_cast<HWND>(lparam);
        if (control == collapse_button_) {
          SetCollapsed(!collapsed_);
          return 0;
        }
        if (control == close_button_) {
          Hide();
          return 0;
        }
      }
      break;
    case WM_TIMER:
      if (wparam == kCompletionTimerId) {
        Hide();
        return 0;
      }
      break;
    case WM_NCHITTEST: {
      const POINT screen_point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      const HWND hit = WindowFromPoint(screen_point);
      if (hit != collapse_button_ && hit != close_button_) {
        POINT client_point = screen_point;
        ScreenToClient(hwnd, &client_point);
        const int header_bottom = Scale(12 + 20, dpi_);
        if (client_point.y >= 0 && client_point.y <= header_bottom) {
          return HTCAPTION;
        }
      }
      break;
    }
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
      status_ = nullptr;
      subtitle_ = nullptr;
      progress_ = nullptr;
      collapse_button_ = nullptr;
      close_button_ = nullptr;
      collapsed_ = false;
      terminal_ = false;
      return 0;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}
