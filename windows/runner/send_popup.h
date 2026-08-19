#ifndef RUNNER_SEND_POPUP_H_
#define RUNNER_SEND_POPUP_H_

#include <windows.h>

#include <string>

// A small, non-activating, always-on-top Win32 tool window that reports
// background "Send to Conduit" transfer progress. It lives in the runner —
// there is deliberately no desktop_multi_window dependency — and is created
// and driven exclusively on the platform thread, i.e. the same thread that
// pumps the Flutter window's message loop. Every Win32 call therefore
// happens on the thread that owns the popup (message-thread ownership), and
// the popup is destroyed from the same thread before the runner exits.
//
// Window-style decisions (all requirements of the Explorer "Send to" fix):
//   * WS_EX_TOOLWINDOW  -> no taskbar button, no Alt-Tab entry.
//   * WS_EX_TOPMOST     -> stays above the user's foreground app.
//   * WS_EX_NOACTIVATE  -> never steals focus/activation from the user.
//   * bottom-right of the work area of the monitor under the cursor, so it
//     reads as a system transfer notification instead of a centered dialog.
//   * only a title line, a progress bar, a file/peer subtitle and a close
//     button — no peer chips, no file picker, no ready-to-send card, and
//     never the full app shell.
class SendPopup {
 public:
  SendPopup();
  ~SendPopup();

  // Shows the popup (creating it first if needed) bottom-right of the work
  // area of the monitor under the cursor. Calling again simply retitles a
  // popup that is already up (e.g. a second batch replacing the first).
  // |title| is the status line, |subtitle| the file/peer line.
  void Show(const std::wstring& title, const std::wstring& subtitle);

  // Updates the subtitle and the progress bar. |percent| is 0..100.
  void UpdateProgress(const std::wstring& subtitle, int percent);

  // Terminal state. A successful send hides/destroys the popup immediately.
  // A failure leaves it visible with the failure message so the user
  // understands what happened — without ever revealing the main overview
  // window (which remains hidden).
  void Complete(bool success, const std::wstring& message);

  // Hides and destroys the popup window (user clicked its close button).
  void Hide();

  bool IsVisible() const;

 private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;
  LRESULT MessageHandler(HWND hwnd, UINT message, WPARAM wparam,
                         LPARAM lparam) noexcept;
  HWND CreateWindowAndControls(int dpi);
  void Layout(int dpi);
  void PlaceBottomRight();
  HFONT CreateFontAtDpi(int dpi);
  void ApplyFont();
  static void SetText(HWND control, const std::wstring& text);

  // Logical (96-dpi) popup metrics; scaled by the target monitor DPI.
  static constexpr int kWidth = 360;
  static constexpr int kHeight = 96;

  HWND hwnd_ = nullptr;
  HWND title_ = nullptr;
  HWND subtitle_ = nullptr;
  HWND progress_ = nullptr;
  HWND close_button_ = nullptr;

  HFONT font_ = nullptr;
  HBRUSH background_brush_ = nullptr;
  COLORREF text_color_ = RGB(0x1F, 0x1F, 0x1F);
  int dpi_ = 96;
};

#endif  // RUNNER_SEND_POPUP_H_