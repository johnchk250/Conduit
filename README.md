# Conduit

Peer-to-peer folder sync between your **PC and phone**, over your local network.
No cloud. No account. No third-party relay. When both devices are on the same
Wi-Fi, changes propagate automatically in the background.

```
┌─── PC ───┐         ┌── Phone ──┐
│ D:\Sync  │ ◀─────▶ │ /Sync     │   two-way mirror, LAN only
└──────────┘  UDP+TLS └──────────┘
```

## Features

- **Automatic two-way sync** of any folder pair you define.
- **Per-pair direction**: two-way, receive-only, or send-only.
- **Seamless across networks**: paired devices auto-reconnect on any Wi-Fi
  (home ↔ office) with no re-pairing — UDP auto-discovery finds them.
- **Manual fallback**: scan a QR code if a network blocks auto-discovery
  (guest/corporate Wi-Fi with client isolation).
- **Secure**: self-signed TLS transport, ed25519 public-key pinning, single-
  use first-pair code (embedded in the QR for the scan flow, or typed for the
  manual fallback). The code is consumed on successful pair.
- **Safe conflicts**: when both sides edit the same file, the newer version
  wins and the loser is backed up to `.syncversions/` (kept 14 days).
- **Resumable transfers**: 1 MiB chunks, each SHA-256 verified; survives
  dropped connections mid-transfer.
- **Clipboard sync**: optional cross-device clipboard — PC→phone automatically,
  phone→PC via a one-tap floating chip (honors Android 10+ background rules).
- **Ad-hoc file send**: send any file directly to a paired peer without
  defining a sync folder (right-click → "Send to Conduit" on Windows).
- **One codebase → two apps**: built from a single Flutter/Dart project.

## Build it yourself

### Prerequisites

- **Flutter 3.27+** (`flutter doctor` must pass)
- **Windows build**: Visual Studio 2022 Build Tools with the
  `Desktop development with C++` workload (CMake + MSVC).
- **Android build**: Android Studio + Android SDK (API 24+), JDK 17–21.

### Commands

```bash
cd conduit

# Verify toolchain
flutter doctor

# Static analysis (should report 0 errors)
flutter analyze

# Windows standalone app (.exe + DLLs)
flutter build windows --release
# → build\windows\x64\runner\Release\conduit.exe

# Android APK
flutter build apk --release
# → build\app\outputs\flutter-apk\app-release.apk
```

## First-run setup

### One-time PC firewall rule (Windows)

Windows Firewall blocks inbound connections to `conduit.exe` by default,
which prevents the phone from reaching the PC. Open **an Administrator
Command Prompt** and run this once:

```cmd
netsh advfirewall firewall add rule name="Conduit" dir=in action=allow protocol=TCP localport=41828
```

Conduit listens on **TCP 41828** by default. If you skip this step, the
phone will report `Connection timed out` when pairing. (You can alternatively
launch the app once and click "Allow access" on the Windows prompt, but the
`netsh` rule is stable across reinstalls.)

Both devices must be on the **same Wi-Fi**. If the network blocks device-to-
device traffic (guest Wi-Fi, client isolation), use the QR fallback below.

### Pair the devices

The easiest flow is the **QR connect** (no typing):

1. On one device, open **Devices → Manual connect** — a QR is shown that
   embeds a one-time pairing code.
2. On the other device, open **Devices → Manual connect → Scan code** and
   point the camera at the QR. Pairing completes automatically — no code to
   type.

Alternatively, **auto-discovery**:

1. On the phone, open **Devices → On this network**.
2. Tap your PC when it appears; enter the 6-digit code shown on the PC's
   **Devices → Manual connect → Generate pairing code**.

### Sync a folder

1. Go to **Folders → Add folder**.
2. Pick a folder (Windows: any path; Android: a folder via the system picker).
3. Choose direction (two-way by default).
4. Do the same on the other device pointing at the corresponding folder.

That's it. Files now mirror automatically whenever both devices are on the
same network.

## If pairing fails

- **`Connection timed out` / `Connection refused`** → firewall on the PC, or
  the devices are not on the same Wi-Fi. Apply the `netsh` rule above.
- **`pairing rejected: wrong or expired code`** → the code was consumed or is
  from a previous attempt. Generate a fresh QR / code on the other device.
- **Guest / corporate Wi-Fi with client isolation** → device-to-device
  traffic is blocked at the network level. Switch to a network that allows
  it (home Wi-Fi, hotspot), or use a different LAN.

## Architecture

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full design reference.
The codebase is organised as:

```
lib/src/
  core/           identity (ed25519), config store (folder pairs, pinned peers)
  protocol/       wire message types, folder-pair model
  net/            UDP discovery, peer sessions, TLS framing, connection supervisor
  storage/        per-folder SQLite Index DB (durable source of truth)
  sync/           V2 engine: version vectors, scanner, index diff, block transfer
  clipboard/      clipboard sync controller
  platform/       Android SAF adapter
  ui/             dashboard, folders, devices, activity, clipboard screens
  app_state.dart  central ChangeNotifier wiring everything together
android/app/src/main/kotlin/.../
  MainActivity.kt   SAF tree-picker + wake-lock channel
  SafOps.kt         SAF read/write/list/delete/moveToVault
  SyncService.kt    foreground sync service with partial wake lock
```

## Storage locations

- **Windows:** `%APPDATA%\Conduit\` — identity.json, config.json
- **Android:** app support directory — identity.json, config.json
- **Per synced folder:** `.syncstate/` (manifests), `.syncversions/` (conflict
  backups, 14-day retention)

## Privacy

All data stays on your devices. Nothing is sent to any server. Discovery
beacons carry only your device's public identity (name, ID, public key,
listen port) — never your files. The first-pair code prevents strangers on
your Wi-Fi from connecting.

## License

Personal project. Not for redistribution.
