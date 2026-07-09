// send_to_shortcut.h  —  Phase 3d (Roadmap)
//
// Creates a .lnk shortcut in the user's "Send to" folder
// (%APPDATA%\Microsoft\Windows\SendTo\Conduit.lnk) so Conduit appears
// in Explorer's right-click → "Send to" sub-menu.
//
// Uses IShellLinkW + IPersistFile (Shell32 / Ole32). No COM registration,
// no manifest UAC elevation, no registry keys beyond what Shell32 does
// internally.
//
// Safe to call repeatedly — overwrites any existing shortcut.

#pragma once
#ifndef CONDUIT_SEND_TO_SHORTCUT_H
#define CONDUIT_SEND_TO_SHORTCUT_H

// Returns true if the shortcut was created (or already existed and was
// refreshed), false on any error.
bool CreateSendToShortcut();

#endif  // CONDUIT_SEND_TO_SHORTCUT_H
