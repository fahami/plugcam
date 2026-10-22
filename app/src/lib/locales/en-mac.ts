// Texts that differ on macOS, where the English one wins over the platform-neutral string of
// the chosen language: a sentence about Windows would be wrong in any language. Keys come from
// en.ts; i18n.ts picks these when the backend says it runs on macOS.

import type { Key } from "./en";

const mac: Partial<Record<Key, string>> = {
  "set.language.system": "Same as macOS",
  "set.launchAtLogin": "Open at login",
  "set.closeToTray": "Keep running in the menu bar when closed",
  "set.removeCamera": "Remove Plugcam Camera from this Mac",
  "set.removeCamera.hint": "Do this before you move Plugcam to the Trash",
  "set.detailedLog.hint": "Keeps a longer log in a file on this Mac. Turn it on if a problem keeps coming back.",
  "upd.adminNote": "Plugcam replaces itself and opens again; the camera is back a moment later.",
  "upd.installing": "Installing. Plugcam restarts by itself.",
  "portable.camera.title": "Add Plugcam Camera to your Mac",
  "portable.camera.hint": "macOS asks you once to allow it in System Settings, so video apps can see the camera.",
  "portable.camera.failed":
    "The camera was not added. Click again, then turn Plugcam on in System Settings → General → Login Items & Extensions → Camera Extensions.",
  "wifi.tip.firewall": "The first time, macOS may ask whether adb can accept incoming connections: allow it.",
};

export default mac;
