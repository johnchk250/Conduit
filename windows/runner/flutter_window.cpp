#include "flutter_window.h"

#include <optional>
#include <sstream>

#include "flutter/generated_plugin_registrant.h"
#include "send_to_shortcut.h"
#include "bluetooth_proxy_win.h"
#include "utils.h"

namespace {
constexpr UINT kPlatformTaskMessage = WM_APP + 73;

// True when [pid] is another process running THIS executable image. Used to
// authenticate WM_COPYDATA senders: the message cannot identify its poster,
// so the sender includes its own PID and we verify the image path. A same-user
// process that is not Conduit (script, browser helper, sandboxed app) is
// rejected; UIPI already blocks lower-integrity posters.
bool IsOwnExecutablePid(DWORD pid) {
  if (pid == 0) return false;
  if (pid == GetCurrentProcessId()) return true;
  wchar_t module_path[MAX_PATH];
  DWORD module_len = GetModuleFileNameW(nullptr, module_path, MAX_PATH);
  if (module_len == 0 || module_len >= MAX_PATH) return false;
  HANDLE process =
      OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) return false;
  wchar_t sender_path[MAX_PATH];
  DWORD sender_len = MAX_PATH;
  BOOL ok = QueryFullProcessImageNameW(process, 0, sender_path, &sender_len);
  CloseHandle(process);
  if (!ok || sender_len == 0 || sender_len >= MAX_PATH) return false;
  return _wcsicmp(sender_path, module_path) == 0;
}

// Read a string/int/bool out of a method-call argument map, falling back to a
// default when the key is absent or the type differs.
std::string ArgString(const flutter::EncodableMap* args, const char* key,
                      const std::string& fallback) {
  if (args == nullptr) return fallback;
  auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) return fallback;
  if (const auto* value = std::get_if<std::string>(&it->second)) return *value;
  return fallback;
}

int ArgInt(const flutter::EncodableMap* args, const char* key, int fallback) {
  if (args == nullptr) return fallback;
  auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) return fallback;
  if (const auto* value = std::get_if<int>(&it->second)) return *value;
  if (const auto* value64 = std::get_if<int64_t>(&it->second))
    return static_cast<int>(*value64);
  return fallback;
}

bool ArgBool(const flutter::EncodableMap* args, const char* key,
             bool fallback) {
  if (args == nullptr) return fallback;
  auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) return fallback;
  if (const auto* value = std::get_if<bool>(&it->second)) return *value;
  return fallback;
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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Phase 3d: Setup method channels.
  auto messenger = flutter_controller_->engine()->messenger();
  shell_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "conduit/shell",
      &flutter::StandardMethodCodec::GetInstance());
  share_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "conduit/share_receive",
      &flutter::StandardMethodCodec::GetInstance());
  bluetooth_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "conduit/bluetooth",
          &flutter::StandardMethodCodec::GetInstance());
  bluetooth_proxy_ = std::make_unique<BluetoothProxyWin>(
      [this](std::function<void()> task) {
        PostPlatformTask(std::move(task));
      },
      [this](const std::string& method,
             const flutter::EncodableValue& arguments) {
        if (!bluetooth_channel_) return;
        bluetooth_channel_->InvokeMethod(
            method, std::make_unique<flutter::EncodableValue>(arguments));
      });

  bluetooth_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (call.method_name() == "start") {
          int port = 0;
          if (args) {
            auto it = args->find(flutter::EncodableValue("dartPort"));
            if (it != args->end()) {
              if (const auto* value = std::get_if<int>(&it->second)) port = *value;
              if (const auto* value64 = std::get_if<int64_t>(&it->second))
                port = static_cast<int>(*value64);
            }
          }
          result->Success(flutter::EncodableValue(bluetooth_proxy_->Start(port)));
        } else if (call.method_name() == "stop") {
          bluetooth_proxy_->Stop();
          result->Success();
        } else if (call.method_name() == "requestPermissions") {
          result->Success();
        } else if (call.method_name() == "connect") {
          std::string endpoint;
          if (args) {
            auto it = args->find(flutter::EncodableValue("endpointId"));
            if (it != args->end()) {
              if (const auto* value = std::get_if<std::string>(&it->second))
                endpoint = *value;
            }
          }
          if (endpoint.empty()) {
            result->Error("BLUETOOTH_ENDPOINT", "Missing Bluetooth service id");
          } else {
            bluetooth_proxy_->Connect(
                endpoint,
                std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
                    std::move(result)));
          }
        } else {
          result->NotImplemented();
        }
      });

  // Handle "conduit/shell" methods (e.g. creating the Send To shortcut and
  // driving the native background-transfer progress popup).
  shell_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "createSendToShortcut") {
          bool ok = CreateSendToShortcut();
          result->Success(flutter::EncodableValue(ok));
        } else if (call.method_name() == "shareHandlerReady") {
          share_handler_ready_ = true;
          FlushPendingSendPaths();
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "sendPopupShow") {
          // Roadmap Phase 4: a background "Send to Conduit" batch is starting.
          // Pop up the small native tool window — never the main Flutter
          // window. Args: peerName, fileName, batchTotal.
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          const std::wstring peer = Utf16FromUtf8(ArgString(args, "peerName", ""));
          const std::wstring file = Utf16FromUtf8(ArgString(args, "fileName", ""));
          const int batch_total = ArgInt(args, "batchTotal", 1);
          if (send_popup_) {
            std::wstring title =
                batch_total > 1
                    ? L"Sending " + std::to_wstring(batch_total) +
                          L" files to " + peer
                    : L"Sending to " + peer;
            send_popup_->Show(title, file);
          }
          result->Success();
        } else if (call.method_name() == "sendPopupProgress") {
          // Per-file/batch progress update. Args: fileName, percent (0..100),
          // fileIndex, batchTotal.
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          const std::wstring file = Utf16FromUtf8(ArgString(args, "fileName", ""));
          const int percent = ArgInt(args, "percent", 0);
          const int index = ArgInt(args, "fileIndex", 1);
          const int batch_total = ArgInt(args, "batchTotal", 1);
          if (send_popup_) {
            std::wstring subtitle = file;
            if (batch_total > 1) {
              subtitle += L" (file " + std::to_wstring(index) + L" of " +
                          std::to_wstring(batch_total) + L")";
            }
            subtitle += L" \u2014 " + std::to_wstring(percent) + L"%";
            send_popup_->UpdateProgress(subtitle, percent);
          }
          result->Success();
        } else if (call.method_name() == "sendPopupComplete") {
          // Terminal event. Success hides/destroys the popup; failure leaves
          // it up showing |message| so the outcome stays understandable
          // without revealing the (hidden) overview window. Args: success,
          // message.
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          const bool success = ArgBool(args, "success", false);
          const std::wstring message =
              Utf16FromUtf8(ArgString(args, "message", ""));
          if (send_popup_) {
            send_popup_->Complete(success, message);
          }
          result->Success();
        } else if (call.method_name() == "sendPopupHide") {
          if (send_popup_) {
            send_popup_->Hide();
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // A cold-start "Send to Conduit" delivery must NOT surface the main
    // Flutter window — show_on_first_frame_ is false exactly then, and the
    // native SendPopup reports the transfer instead. Normal launches and the
    // tray's Show action keep the existing behavior.
    if (show_on_first_frame_) {
      this->Show();
    }
    // Mark the engine as ready. Shared files are flushed only after Dart
    // registers its method-channel handler and calls shareHandlerReady.
    is_dart_ready_ = true;
    FlushPendingSendPaths();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  // Roadmap Phase 4: the native background-transfer progress popup. Created
  // on the platform thread; driven from the shell channel handlers above.
  send_popup_ = std::make_unique<SendPopup>();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (bluetooth_proxy_) bluetooth_proxy_->Stop();
  bluetooth_proxy_.reset();
  // Destroy the native popup (if still up) before tearing down the window.
  send_popup_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::PostPlatformTask(std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(platform_tasks_mutex_);
    platform_tasks_.push_back(std::move(task));
  }
  PostMessage(GetHandle(), kPlatformTaskMessage, 0, 0);
}

void FlutterWindow::DrainPlatformTasks() {
  std::deque<std::function<void()>> tasks;
  {
    std::lock_guard<std::mutex> lock(platform_tasks_mutex_);
    tasks.swap(platform_tasks_);
  }
  for (auto& task : tasks) task();
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

void FlutterWindow::FlushPendingSendPaths() {
  if (!is_dart_ready_ || !share_handler_ready_ || !share_channel_ ||
      pending_send_paths_.empty()) {
    return;
  }
  SendPathsToDart(pending_send_paths_);
  pending_send_paths_.clear();
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
    case kPlatformTaskMessage:
      DrainPlatformTasks();
      return 0;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;

    // Phase 3d: Handle incoming file paths forwarded from a second instance via WM_COPYDATA.
    case WM_COPYDATA: {
      auto cds = reinterpret_cast<COPYDATASTRUCT*>(lparam);
      if (cds && cds->dwData == 1) { // magic ID for SendTo paths
        // Reject payloads that are not a whole number of UTF-16 code units.
        if (cds->cbData % sizeof(wchar_t) != 0 || cds->cbData == 0) {
          return TRUE;
        }
        const wchar_t* data = reinterpret_cast<const wchar_t*>(cds->lpData);
        size_t len = cds->cbData / sizeof(wchar_t);
        // Copy to wstring safely (data might not be null-terminated depending on cbData).
        std::wstring encoded(data, len);
        // Segments are separated by U+001F (unit separator). The FIRST
        // segment must be the sender's PID and must resolve to another
        // process running this same executable — see ForwardToExistingInstance
        // in main.cpp. Anything else is dropped silently.
        std::vector<std::wstring> segments;
        std::wstringstream wss(encoded);
        std::wstring segment;
        while (std::getline(wss, segment, L'\x1F')) {
          if (!segment.empty() && segment.back() == L'\0') {
            segment.pop_back(); // Remove null terminator if it was copied
          }
          if (!segment.empty()) {
            segments.push_back(segment);
          }
        }
        if (segments.empty()) {
          return TRUE;
        }
        DWORD sender_pid = wcstoul(segments.front().c_str(), nullptr, 10);
        if (!IsOwnExecutablePid(sender_pid)) {
          return TRUE;
        }
        std::vector<std::wstring> paths(segments.begin() + 1, segments.end());

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
