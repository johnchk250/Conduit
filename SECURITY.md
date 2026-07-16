# Security policy

## Supported version

Security fixes target the current `2.x` application line. Older plaintext
builds are intentionally incompatible with Secure Transport v1.

## Threat model

Conduit assumes:

- the local network may be observed or modified by an attacker;
- discovery packets are public to the reachable local network;
- paired device owners trust each other;
- operating-system Bluetooth pairing alone is not sufficient authorization.

Conduit protects application messages against network interception,
modification, replay, and unauthenticated peers.

The current protection boundary does not include:

- malware running as the user;
- a compromised or unlocked paired device;
- operating-system account or filesystem compromise;
- extraction of locally stored identity keys;
- denial of service by a network or radio attacker;
- vulnerabilities in Flutter, the operating system, or platform libraries.

## Secure Transport v1

All application messages over LAN and Bluetooth use the same secure session:

1. Peers exchange ephemeral X25519 public keys and random nonces.
2. They build a canonical, role-bound transcript.
3. Persistent Ed25519 identities sign the transcript hash.
4. Existing peers must match the stored public-key pin.
5. HKDF-SHA256 derives independent directional keys and nonce prefixes.
6. ChaCha20-Poly1305 protects application records.
7. Monotonic 64-bit sequence numbers reject replay, skipped, and out-of-order
   records.
8. Encrypted key confirmation completes before the session is published.

Any authentication, ordering, or record-integrity failure closes the
connection.

## Pairing

First-time QR pairing uses a random 256-bit secret that is:

- time-limited;
- single-use;
- bound into the authenticated handshake;
- consumed only after encrypted confirmation.

The secret itself is not sent as an application message. A saved peer
reconnects through its pinned device ID and public key.

Discovery exposes only public connection metadata:

- device name and ID;
- platform;
- public identity key;
- protocol version;
- listen port.

## Feature boundaries

Remote PC actions are disabled unless enabled by the user and are restricted
to a fixed application allowlist. Conduit does not expose a general shell or
caller-provided command line.

Phone alert is a fixed action with a phone-side setting. It does not allow a
peer to supply a sound, intent, command, or unlimited duration.

Transfer receipt frames travel only inside an authenticated encrypted session.
They contain an offer ID, bounded status, received-byte count, and optional
fixed failure code. They contain no paths, file names, hashes, or file
contents. Unknown, duplicate, stale-session, and wrong-peer confirmations do
not complete an outgoing transfer.

Clipboard synchronization is optional. Clipboard contents are not stored in
receipt history or diagnostics.

## Local secrets

Identity private keys, peer pins, and configuration are stored in the
application support directory and rely on operating-system user/filesystem
protection. Conduit does not currently integrate with Windows Credential
Manager, Android Keystore hardware backing, or an application passcode.

Do not share:

- `identity.json`;
- pairing QR payloads or secrets;
- private or session keys;
- diagnostic output containing information you have explicitly opted to
  include.

## Reporting a vulnerability

Report security issues privately through the repository's private
vulnerability-reporting or security-advisory channel when available. Otherwise
contact the maintainer privately before opening a public issue.

Include:

- affected Conduit version and platform;
- reproduction steps;
- expected and observed behavior;
- security impact;
- logs with secrets and personal file data removed.

Do not include pairing secrets, private/session keys, clipboard contents, or
user file contents.

Conduit has not received a formal independent security audit.
