// send_to_shortcut.cpp  —  Phase 3d (Roadmap)
//
// Writes %APPDATA%\Microsoft\Windows\SendTo\Conduit.lnk pointing at the
// current conduit.exe so the entry appears in Explorer's "Send to" menu.
//
// Approach: IShellLinkW + IPersistFile — the standard Shell-provided COM
// objects that every Windows version ships with. No COM server registration
// required (we only create a client-side link object, not register a new COM
// class). The objects are created via CoCreateInstance, which always works
// for built-in Shell types.
//
// Link target: the running exe path (GetModuleFileNameW).
// Arguments:   --send (no files yet; Explorer fills EXTRA_STREAM on the cmd).
//              Actually, Explorer's "Send to" passes the selected file paths
//              directly as arguments — so we set the target exe + description;
//              Explorer will append " \"path1\" \"path2\"" at launch time.
// Icon:        same exe, icon index 0.

#include "send_to_shortcut.h"

#include <windows.h>
#include <shlobj.h>      // SHGetKnownFolderPath, IShellLinkW
#include <objbase.h>     // CoInitializeEx, CoCreateInstance, CoUninitialize
#include <objidl.h>      // IPersistFile
#include <shobjidl.h>    // IShellLinkW
#include <wrl/client.h>  // Microsoft::WRL::ComPtr

#include <string>

using Microsoft::WRL::ComPtr;

bool CreateSendToShortcut() {
    // COM is already initialised by Flutter's engine on the main thread
    // (it calls CoInitializeEx with COINIT_APARTMENTTHREADED). We call
    // CoInitializeEx as well; if it's already initialised the call is a
    // no-op and returns S_FALSE — that's fine, we MUST NOT call
    // CoUninitialize in that case. Track whether WE initialised so we
    // only uninitialise when we need to.
    bool weInitCom = false;
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (SUCCEEDED(hr) && hr != S_FALSE) {
        weInitCom = true;  // we initialised it; we must shut it down
    } else if (hr == RPC_E_CHANGED_MODE) {
        // Already initialised with a different apartment model — MTA.
        // CoCreateInstance will still work; just don't uninitialise.
        hr = S_OK;
    }
    if (FAILED(hr)) return false;

    bool ok = false;
    do {
        // ── 1. Resolve %APPDATA%\Microsoft\Windows\SendTo ─────────────────
        PWSTR sendToPath = nullptr;
        hr = SHGetKnownFolderPath(FOLDERID_SendTo, 0, nullptr, &sendToPath);
        if (FAILED(hr)) break;
        std::wstring linkPath(sendToPath);
        CoTaskMemFree(sendToPath);
        linkPath += L"\\Conduit.lnk";

        // ── 2. Resolve the current exe path ───────────────────────────────
        wchar_t exePath[MAX_PATH] = {};
        if (!GetModuleFileNameW(nullptr, exePath, MAX_PATH)) break;

        // ── 3. Create the IShellLinkW COM object ──────────────────────────
        ComPtr<IShellLinkW> link;
        hr = CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                              IID_IShellLinkW, &link);
        if (FAILED(hr)) break;

        // Target exe.
        link->SetPath(exePath);
        // Working directory = same as the exe directory.
        std::wstring exeDir(exePath);
        auto lastSlash = exeDir.rfind(L'\\');
        if (lastSlash != std::wstring::npos) exeDir.erase(lastSlash);
        link->SetWorkingDirectory(exeDir.c_str());
        // Description shown in tooltip.
        link->SetDescription(L"Send file(s) to Conduit");
        // Icon: use the exe itself, icon index 0.
        link->SetIconLocation(exePath, 0);
        // Arguments: --send will be prepended automatically by main.cpp
        // when it detects it was launched from "Send to". No static arg
        // needed here — Explorer appends the selected paths as arguments
        // at launch time.
        link->SetArguments(L"--send");

        // ── 4. Persist to disk ─────────────────────────────────────────────
        ComPtr<IPersistFile> pf;
        hr = link.As(&pf);
        if (FAILED(hr)) break;

        hr = pf->Save(linkPath.c_str(), TRUE);
        ok = SUCCEEDED(hr);
    } while (false);

    if (weInitCom) CoUninitialize();
    return ok;
}
