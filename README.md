<p align="center">
  <img src="docs/logo.png" width="128" alt="Focusrite Volume Control logo">
</p>

<h1 align="center">Focusrite Volume Control</h1>

<p align="center">🔊 Your Mac’s volume keys. Your Focusrite.</p>

<p align="center">
  <a href="https://github.com/wc2184/focusrite-volume-control/releases/latest">Download</a> ·
  <a href="https://github.com/wc2184/focusrite-volume-control/issues">Issues</a> ·
  <a href="LICENSE">MIT License</a>
</p>

A tiny macOS app for controlling **Playback 1–2** in Focusrite Control 2. Native-style volume HUD, custom shortcuts, and a big, readable Dock volume display. Works with Focusrite Control 2 minimized.

## Install

1. Download the ZIP from [Releases](https://github.com/wc2184/focusrite-volume-control/releases/latest), unzip it, and move **Focusrite Volume Control.app** to **Applications**.
2. This release is not notarized. Before opening it, run this in Terminal to remove quarantine attributes from the downloaded app:

   ```sh
   xattr -cr "/Applications/Focusrite Volume Control.app"
   ```

3. Open the app and grant **Accessibility** access in **System Settings → Privacy & Security → Accessibility**. Allow Automation if prompted.
4. Keep **Focusrite Control 2** running and select your Focusrite as the Mac’s sound output. Press your volume keys.

Requires **macOS 14.5+** and a Focusrite interface supported by **Focusrite Control 2**. The release supports Apple silicon and Intel Macs.

## Everyday use

- Volume and mute keys control your interface. Custom shortcuts are available in Preferences.
- The Dock shows the confirmed dB value, a mute icon at −127, or **—** when unavailable.
- Click the Dock icon to toggle Preferences; click the menu bar icon for the volume popover.

If volume keys stop working after an update, toggle the app off and on in Accessibility settings, then relaunch it.

---

An independent project, unaffiliated with Focusrite. Based on [Enum’s Focusrite Volume Control](https://github.com/enum-dot-dev/focusrite-volume-control). [MIT licensed](LICENSE); see [attribution](NOTICE).
