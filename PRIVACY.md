# Privacy policy

Conduit is a local-first application. It has no accounts, analytics,
advertising, cloud storage, hosted relay, or runtime font download.

## Network communication

Conduit communicates through:

- local UDP discovery;
- direct encrypted peer sockets over LAN;
- a local Bluetooth Classic bridge when Bluetooth is active.

Discovery beacons are visible on the reachable local network and include:

- device name and ID;
- platform;
- public identity key;
- protocol version;
- listen port.

File data, clipboard data, remote actions, device status, and transfer receipts
travel only inside an authenticated encrypted peer session.

## Data stored on this device

Conduit stores:

- a persistent device identity and private key;
- paired-device names, IDs, public-key pins, and connection settings;
- folder-pair settings and Android folder grants;
- per-folder SQLite sync indexes;
- application preferences;
- local version-history catalogs and recovery files;
- local transfer receipt metadata;
- bounded diagnostic and activity metadata.

Transfer receipts may contain:

- file display name;
- peer name and ID;
- file size;
- direction and transfer kind;
- result and confirmation level;
- start and completion time;
- folder-pair ID when relevant.

Receipts do not store source or destination paths, file contents, clipboard
contents, cryptographic keys, or file hashes.

## Optional feature data

Clipboard synchronization is opt-in. Clipboard text is transmitted to a
paired peer but is not saved as clipboard history.

Device status can share bounded battery, charging, storage, and application
health fields with a paired peer. Conduit does not use this feature to collect
analytics.

Remote controls and phone alert are explicit user-facing actions. The app does
not store arbitrary command payload history.

## Retention

- Recovery versions and their catalog rows are retained for 14 days.
- Transfer receipts are retained for 30 days and capped at 1,000 rows.
- The latest device-status snapshot may remain until replaced or the peer is
  removed.
- Configuration and identity remain until the app data is cleared.

Retention cleanup is best-effort. A storage or permission failure can delay
deletion until a later cleanup pass.

## User controls

Users can:

- disable clipboard synchronization;
- disable remote PC actions;
- disable phone alerts on the phone;
- clear one or all transfer receipts;
- clear one or all version-history entries;
- remove folder pairs;
- remove paired devices;
- clear the application's data through the operating system.

Removing a folder pair stops synchronization and removes application
bookkeeping. It does not delete the live user folder. Removing a peer removes
its pairing record and retained status/receipt association; it does not delete
user files.

## Diagnostics

Diagnostics are designed to contain event and protocol metadata, not:

- file or clipboard contents;
- pairing secrets;
- private or session keys;
- nonces or encrypted payloads;
- full local paths;
- transfer receipt file names by default.

Before sharing diagnostic output, review it for device names, peer identifiers,
or any information you consider sensitive.

## Platform services

Android uses the Storage Access Framework and foreground-service APIs. Windows
uses local filesystem, tray, firewall, and Bluetooth facilities. Their handling
of permissions, backups, application data, and logs is also governed by the
operating system.
