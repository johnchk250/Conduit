#include "flutter_window.h"

#include <optional>
#include <sstream>

#include "flutter/generated_plugin_registrant.h"
#include "send_to_shortcut.h"

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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Phase 3d: Setup method channels.
  auto messenger = flutter_controller_->engine()->messenger();
  shell_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "conduit/shell",
      &flutter::StandardMethodCodec::GetInstance());
  share_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "conduit/share_receive",
      &flutter::StandardMethodCodec::GetInstance());

  // Handle "conduit/shell" methods (e.g. creating the Send To shortcut).
  shell_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "createSendToShortcut") {
          bool ok = CreateSendToShortcut();
          result->Success(flutter::EncodableValue(ok));
        } else if (call.method_name() == "shareHandlerReady") {
          share_handler_ready_ = true;
          if (!pending_send_paths_.empty()) {
            SendPathsToDart(pending_send_paths_);
            pending_send_paths_.clear();
          }
          result->Success(flutter::EncodableValue(true));
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
    // Mark the engine as ready. Shared files are flushed only after Dart
    // registers its method-channel handler and calls shareHandlerReady.
    is_dart_ready_ = true;
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::SendPathsToDart(const std::vector<std::wstring>& paths) {
  if (!is_dart_ready_ || !share_handler_ready_ || !share_channel_) return;

  // Convert wstrings to UTF-8 strings.
  flutter::EncodableList list;
  for (const auto& wpath : paths) {
    int size_needed = WideCharToMultiByte(CP_UTF8, 0, wpath.c_str(), (int)wpath.size(), NULL, 0, NULL, NULL);
    std::string path(size_needed, 0);
    WideCharToMultiByte(CP_UTF8, 0, wpath.c_str(), (int)wpath.size(), &path[0], size_needed, NULL, NULL);
    list.push_back(flutter::EncodableValue(path));
  }

  flutter::EncodableMap args = {
    {flutter::EncodableValue("uris"), flutter::EncodableValue(list)}
  };

  share_channel_->InvokeMethod("incomingFiles", std::make_unique<flutter::EncodableValue>(args));
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

    // Phase 3d: Handle incoming file paths forwarded from a second instance via WM_COPYDATA.
    case WM_COPYDATA: {
      auto cds = reinterpret_cast<COPYDATASTRUCT*>(lparam);
      if (cds && cds->dwData == 1) { // magic ID for SendTo paths
        const wchar_t* data = reinterpret_cast<const wchar_t*>(cds->lpData);
        size_t len = cds->cbData / sizeof(wchar_t);
        // Copy to wstring safely (data might not be null-terminated depending on cbData).
        std::wstring encoded(data, len);
        // The paths are separated by U+001F (unit separator).
        std::vector<std::wstring> paths;
        std::wstringstream wss(encoded);
        std::wstring segment;
        while (std::getline(wss, segment, L'\x1F')) {
          if (!segment.empty() && segment.back() == L'\0') {
            segment.pop_back(); // Remove null terminator if it was copied
          }
          if (!segment.empty()) {
            paths.push_back(segment);
          }
        }

        if (!paths.empty()) {
          if (is_dart_ready_ && share_handler_ready_) {
            SendPathsToDart(paths);
          } else {
            pending_send_paths_.insert(pending_send_paths_.end(), paths.begin(), paths.end());
          }
        }
        return TRUE; // Message handled
      }
      break;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
