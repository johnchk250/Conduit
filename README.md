# Conduit

Conduit is a direct, local-first file synchronization app for Windows and
Android. It keeps selected folders in sync, sends individual files, and offers
small cross-device tools without accounts, cloud storage, or a relay service.

**Current version:** 2.0.0+2

**Supported platforms:** Windows and Android

## What it does

- Synchronizes folder pairs in two-way, send-only, or receive-only mode.
- Connects over LAN when possible and falls back to Bluetooth Classic when LAN
  is unavailable.
- Automatically upgrades an authenticated Bluetooth session back to LAN.
- Pairs devices with a QR code or one-time secret and pins their identities.
- Encrypts every application message with Secure Transport v1.
- Resumes large files in verified 1 MiB blocks after an interrupted connection.
- Preserves overwritten, conflicted, and peer-deleted versions for 14 days.
- Shows an informational sync preview based on the same decisions as real sync.
- Provides reusable Camera, Screenshots, Downloads, Documents, and Inbox
  folder presets.
- Sends individual files without creating a folder pair.
- Stores a local, clearable 30-day transfer-receipt history.
- Optionally synchronizes clipboard content.
- Exposes allowlisted remote-PC actions and phone status/alert tools.
- Includes onboarding and a Connection Doctor for setup and troubleshooting.

Conduit has no account system, analytics, advertising, or runtime dependency on
an internet service. Devices must be reachable over a local network or paired
through the operating system's Bluetooth settings.

## Quick start

### 1. Install and open Conduit

Run Conduit on both devices. The first-run guide explains permissions,
background operation, pairing, and optional folder presets.

On Windows, allow inbound private-network traffic when prompted. Conduit uses
TCP port `41828` by default. The Connection Doctor can identify a missing
firewall rule or an unreachable peer.

If a manual rule is required, run this from an Administrator Command Prompt:

```cmd
netsh advfirewall firewall add rule name="Conduit" dir=in action=allow protocol=TCP localport=41828
```

### 2. Pair the devices

Open **Devices** on both devices:

1. Generate a pairing QR code on one device.
2. Scan it from the other device.
3. Confirm that both devices show as paired and connected.

The QR contains a random, single-use pairing secret. Pairing is separate from
operating-system Bluetooth pairing.

### 3. Create a folder pair

Open **Folders**, choose a preset or **Custom**, select the peer and local
folder, then create the pair. The peer receives an invitation and chooses its
corresponding local folder.

Direction meanings:

- **Two-way:** edits and deletions can propagate in both directions.
- **Send only:** this device advertises its changes to the peer.
- **Receive only:** this device receives changes from the peer.

These modes synchronize state; they are not append-only archive policies.

## Connections

LAN is preferred because it provides the best throughput. UDP discovery finds
peers on reachable local networks, while saved identity pins allow reconnection
after addresses change.

Bluetooth fallback requires:

1. Bluetooth enabled on Windows and Android.
2. The devices paired once in their operating-system Bluetooth settings.
3. Android Nearby devices/Bluetooth permission granted to Conduit.

Large transfers over 10 MiB are deferred while the active transport is
Bluetooth and resume when LAN returns. Control messages and small operations
remain available.

## Recovery and receipts

Conduit keeps local recovery copies under `.syncversions` before it overwrites a
file or applies a winning peer deletion, when storage access permits. Version
History can restore a copy through the normal scanner and version-vector path.
Recovery copies expire after 14 days.

A file manually deleted on the same device cannot always be recovered because
its bytes may be gone before Conduit observes the deletion. A prior vaulted
version can still be restored.

Transfer receipts are stored only on the local device for up to 30 days and
1,000 rows. A supported peer can confirm an ad-hoc file only after it has
verified and committed the file. Older peers remain compatible and are shown
as unconfirmed rather than failed.

## Build from source

### Requirements

- Flutter with Dart 3.6 or newer
- Windows: Visual Studio 2022 with **Desktop development with C++**
- Android: Android Studio, Android SDK, and JDK 17 or newer

### Validate

```powershell
flutter pub get
flutter analyze
flutter test
```

### Build

```powershell
flutter build windows --release
flutter build apk --release
```

Outputs:

```text
build/windows/x64/runner/Release/
build/app/outputs/flutter-apk/app-release.apk
```

The repository also includes PowerShell and batch wrappers for the locally
configured toolchain.

## Project layout

```text
lib/
  main.dart                 Flutter entry point and provider composition
  l10n/                     localization resources
  src/
    controllers/            scoped application snapshots and commands
    core/                   identity and persistent configuration
    diagnostics/            Connection Doctor and sanitized diagnostics
    net/                    discovery, sessions, encryption, transport policy
    platform/               Android SAF adapter
    protocol/               wire messages and folder-pair models
    runtime/                dependency and application composition
    storage/                per-pair SQLite indexes
    sync/                   scanner, versioning, preview, transfer engine
    transfers/              durable transfer receipts
    ui/                     responsive Windows/Android interface
android/                    Android host, SAF, Bluetooth, background service
windows/                    Windows runner and Bluetooth bridge
test/                       unit, widget, and two-node integration tests
```

## Local data

Application support storage contains:

- `identity.json`: persistent device identity;
- `config.json`: paired peers, folder pairs, and preferences;
- `index/*.db`: durable per-folder sync indexes;
- `vault_log/*.json`: version-history catalogs;
- `transfer_history.db`: bounded transfer receipts.

Windows stores this under `%APPDATA%\Conduit`. Android uses the app's private
support directory. Vaulted file bytes live under `.syncversions` inside the
associated folder tree and are excluded from synchronization.

## Documentation

- [Architecture](ARCHITECTURE.md)
- [Version history](CHANGELOG.md)
- [Roadmap](Roadmap.md)
- [Security](SECURITY.md)
- [Privacy](PRIVACY.md)
- [Windows/Android smoke checklist](docs/windows-android-smoke-checklist.json)

## License

Personal project. Not licensed for redistribution.
