#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shlwapi.h>  // StrStrW

#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

// ── Phase 3d: single-instance + --send forwarding ─────────────────────────
//
// When Explorer's "Send to → Conduit" fires, it launches:
//   conduit.exe --send "path1" "path2" ...
//
// If another Conduit instance is already running we forward the paths to
// it via WM_COPYDATA and exit immediately (single window guarantee).
// If we ARE the first instance we start normally and let FlutterWindow.cpp
// pick up the --send args via the MethodChannel after Flutter initialises.
//
// WM_COPYDATA payload format: a UTF-16 string where paths are separated by
// the UNIT SEPARATOR character (U+001F, 0x1F). FlutterWindow.cpp and the
// Dart handler both expect this delimiter.

static constexpr wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
static constexpr wchar_t kWindowTitle[] = L"Conduit";

// Parse --send args from the raw command line into a list of file paths.
// Returns empty vector if --send is not present.
static std::vector<std::wstring> ParseSendArgs(int argc, wchar_t** argv) {
  std::vector<std::wstring> paths;
  bool inSend = false;
  for (int i = 1; i < argc; ++i) {
    if (std::wstring(argv[i]) == L"--send") {
      inSend = true;
    } else if (inSend) {
      paths.push_back(argv[i]);
    }
  }
  return paths;
}

// Encode a list of paths into a single WM_COPYDATA string (U+001F separator).
static std::wstring EncodePaths(const std::vector<std::wstring>& paths) {
  std::wstring out;
  for (size_t i = 0; i < paths.size(); ++i) {
    if (i) out += L'\x1F';
    out += paths[i];
  }
  return out;
}

// Find the first top-level Conduit window.
// Returns NULL if none is found.
static HWND FindExistingInstance() {
  return FindWindowW(kWindowClass, kWindowTitle);
}

// Forward paths to an already-running instance via WM_COPYDATA and bring
// its window to the foreground.
static void ForwardToExistingInstance(HWND existing,
                                      const std::vector<std::wstring>& paths) {
  std::wstring encoded = EncodePaths(paths);
  COPYDATASTRUCT cds{};
  cds.dwData = 1;  // magic: "these are --send paths"
  cds.cbData =
      static_cast<DWORD>((encoded.size() + 1) * sizeof(wchar_t));
  cds.lpData = const_cast<wchar_t*>(encoded.c_str());
  SendMessageW(existing, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&cds));
  // Bring the existing window to the front. Close-to-tray hides the top-level
  // window rather than minimizing it, so always show it before focusing.
  ShowWindow(existing, IsIconic(existing) ? SW_RESTORE : SW_SHOWNORMAL);
  SetForegroundWindow(existing);
}

// ── wWinMain ─────────────────────────────────────────────────────────────
int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t* command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Phase 3d: parse --send args before anything else.
  int argc = 0;
  wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  std::vector<std::wstring> sendPaths;
  if (argv) {
    sendPaths = ParseSendArgs(argc, argv);
    LocalFree(argv);
  }

  // Single-instance gate. A normal second launch focuses the existing app; a
  // Send To launch also forwards the selected paths before exiting.
  HWND existing = FindExistingInstance();
  if (existing != nullptr) {
    if (!sendPaths.empty()) {
      ForwardToExistingInstance(existing, sendPaths);
    } else {
      ShowWindow(existing, IsIconic(existing) ? SW_RESTORE : SW_SHOWNORMAL);
      SetForegroundWindow(existing);
    }
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // Phase 3d: pass any --send paths so FlutterWindow can forward them to Dart
  // once the MethodChannel is ready.
  window.SetPendingSendPaths(sendPaths);

  // Phase 4: when this cold start is itself a "Send to Conduit" delivery
  // (ParseSendArgs found --send paths, and — since we only reach this line
  // at all when the single-instance gate above found no existing window to
  // forward to — this process is about to become the one and only window),
  // create the native window at roughly the compact size SendWidgetScreen
  // (lib/src/ui/send_widget_screen.dart) resizes it to anyway, instead of
  // the normal 1280x720. Dart would shrink an oversized window down a frame
  // or two after launch regardless, but sizing it here avoids a visible
  // flash of the full-size window first. windowManager.center() on the Dart
  // side repositions it properly once the engine is up, so only the size —
  // not this initial origin — needs to roughly match; kept in sync manually
  // with SendWidgetScreen's _popupWidth/_popupHeight since native and Dart
  // code can't share a source file across the platform boundary.
  Win32Window::Point origin(10, 10);
  Win32Window::Size size = sendPaths.empty() ? Win32Window::Size(1280, 720)
                                              : Win32Window::Size(400, 560);
  if (!window.Create(L"Conduit", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
