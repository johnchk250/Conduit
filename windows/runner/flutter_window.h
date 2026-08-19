#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

#include "win32_window.h"
#include "send_popup.h"

class BluetoothProxyWin;

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // Phase 3d: set pending paths from the command line (--send).
  void SetPendingSendPaths(const std::vector<std::wstring>& paths) {
    pending_send_paths_ = paths;
    // A cold start launched by Explorer's "Send to Conduit" must keep the
    // main Flutter window hidden — the native SendPopup reports transfer
    // progress instead. Normal launches and tray Show still surface it.
    show_on_first_frame_ = paths.empty();
  }

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Phase 3d: Helper to send paths to Flutter Dart side.
  void SendPathsToDart(const std::vector<std::wstring>& paths);
  void FlushPendingSendPaths();
  void PostPlatformTask(std::function<void()> task);
  void DrainPlatformTasks();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

// Phase 3d: Pending paths to send to Dart when the engine is initialized.
  std::vector<std::wstring> pending_send_paths_;
  bool is_dart_ready_ = false;
  bool share_handler_ready_ = false;
  // True unless this cold start is itself a "Send to Conduit" delivery, in
  // which case the first-frame callback must NOT call Show() on the main
  // Flutter window (it stays hidden in the tray while the SendPopup reports
  // the background transfer).
  bool show_on_first_frame_ = true;

  // Phase 3d: Method channels for shell operations and sending shared files.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> shell_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> share_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> bluetooth_channel_;
  std::unique_ptr<BluetoothProxyWin> bluetooth_proxy_;
  // Roadmap Phase 4: the native background-transfer progress popup. Owned on
  // the platform thread like the rest of the runner's window plumbing.
  std::unique_ptr<SendPopup> send_popup_;
  std::mutex platform_tasks_mutex_;
  std::deque<std::function<void()>> platform_tasks_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
