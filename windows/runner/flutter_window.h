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

  // Phase 3d: Method channels for shell operations and sending shared files.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> shell_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> share_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> bluetooth_channel_;
  std::unique_ptr<BluetoothProxyWin> bluetooth_proxy_;
  std::mutex platform_tasks_mutex_;
  std::deque<std::function<void()>> platform_tasks_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
