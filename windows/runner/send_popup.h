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
//   * a draggable, compact transfer panel with a visible Minimize control.
//     Minimize collapses it into a short progress pill; Show restores it.
//     This preserves a discoverable status surface without forcing a taskbar
//     entry or exposing the full app shell.
//   * only transfer status, progress, a file/peer subtitle and dismiss/
//     collapse controls — no peer chips, file picker, ready-to-send card, or
//     full app shell.
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

  // Terminal state. Success remains visible briefly as confirmation before
  // disappearing; failure remains visible until dismissed. Neither outcome
  // reveals the hidden main window.
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
  void SetCollapsed(bool collapsed);
  HFONT CreateFontAtDpi(int dpi);
  void ApplyFont();
  static void SetText(HWND control, const std::wstring& text);

  // Logical (96-dpi) popup metrics; scaled by the target monitor DPI.
  static constexpr int kExpandedWidth = 400;
  static constexpr int kCollapsedWidth = 320;
  static constexpr int kExpandedHeight = 104;
  static constexpr int kCollapsedHeight = 52;
  static constexpr UINT_PTR kCompletionTimerId = 1;

  HWND hwnd_ = nullptr;
  HWND title_ = nullptr;
  HWND status_ = nullptr;
  HWND subtitle_ = nullptr;
  HWND progress_ = nullptr;
  HWND collapse_button_ = nullptr;
  HWND close_button_ = nullptr;

  HFONT font_ = nullptr;
  HBRUSH background_brush_ = nullptr;
  COLORREF text_color_ = RGB(0x1F, 0x1F, 0x1F);
  int dpi_ = 96;
  bool collapsed_ = false;
  bool terminal_ = false;
};

#endif  // RUNNER_SEND_POPUP_H_
