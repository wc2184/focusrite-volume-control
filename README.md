<p align="center">
  <img src="docs/logo.png" width="128" alt="Focusrite Volume Control logo">
</p>

<h1 align="center">Focusrite Volume Control</h1>

<p align="center">🔊 Your Mac’s volume keys. Your Focusrite.</p>

<p align="center">
  <a href="https://github.com/wc2184/focusrite-volume-control/releases/latest">Download</a> ·
  <a href="https://github.com/wc2184/focusrite-volume-control/issues">Issues</a>
</p>

A tiny macOS app that lets your Mac’s volume keys control your Focusrite’s volume. Native-style volume HUD, custom shortcuts, and a big, readable Dock volume display. Works with Focusrite Control 2 minimized.

**Heavily based on [Nick Morozov’s Focusrite Volume Control](https://github.com/enum-dot-dev/focusrite-volume-control).** I made this version because the original required macOS Sequoia or later, and I wanted to stay on Sonoma. I also ran into bugs and reliability issues in everyday use, so I focused on making volume control more consistent and resilient, especially during rapid key presses and changes made in Focusrite Control 2.

<p align="center">
  <img src="docs/hud-demo.gif" width="220" alt="Volume HUD increasing from mute to full volume, then decreasing back to mute">
</p>

<p align="center"><sub>Volume up. Volume down. Right where you expect it.</sub></p>

## Install

1. Choose the ZIP for your macOS version from [Releases](https://github.com/wc2184/focusrite-volume-control/releases/latest), unzip it, and move **Focusrite Volume Control.app** to **Applications**.
2. This release is not notarized. Before opening it, run this in Terminal to remove quarantine attributes from the downloaded app:

   ```sh
   xattr -cr "/Applications/Focusrite Volume Control.app"
   ```

3. Open the app and grant **Accessibility** access in **System Settings → Privacy & Security → Accessibility**. Allow Automation if prompted.
4. Enable **Direct Monitor** in **Focusrite Control 2**, or press the **Direct** button on your physical Focusrite interface.
5. Keep **Focusrite Control 2** running and select your Focusrite as the Mac’s sound output. Press your volume keys.

| Build | macOS | Status |
| --- | --- | --- |
| [Modern-Sonoma-and-Later](https://github.com/wc2184/focusrite-volume-control/releases/download/v1.1.4/Focusrite-Volume-Control-v1.1.4-Modern-Sonoma-and-Later.zip) | Sonoma 14.5+ | Recommended |
| [Ventura-Experimental](https://github.com/wc2184/focusrite-volume-control/releases/download/v1.1.4/Focusrite-Volume-Control-v1.1.4-Ventura-Experimental.zip) | Ventura 13 | Experimental |
| [Monterey-Experimental](https://github.com/wc2184/focusrite-volume-control/releases/download/v1.1.4/Focusrite-Volume-Control-v1.1.4-Monterey-Experimental.zip) | Monterey 12 | Experimental |

The previous [v1.0.1 downloads](https://github.com/wc2184/focusrite-volume-control/releases/tag/v1.0.1) remain available unchanged.

All builds support Apple silicon and Intel Macs and require a compatible Focusrite interface and **Focusrite Control 2**. The experimental builds have passed build and unit checks on Sonoma; they have **not been tested on Ventura or Monterey**, and older FC2 versions may have different controls. Use an FC2 version compatible with your OS and interface.

On Monterey, set up launch at login manually in **System Preferences → Users & Groups → Login Items**; the app’s automatic toggle is unavailable.

## Everyday use

- Volume and mute keys control your interface. Custom shortcuts are available in Preferences; navigation keys require Command, Control, or Option.
- **Perceptual Volume Curve (Recommended)** is on by default: more control at low volumes and smoother changes in loudness, with halfway at **−16 dB**. Keys, slider, and HUD use discrete steps. You can switch it off; your choice is remembered and switching preserves the current volume.
- The Dock shows the confirmed dB value, a mute icon at −127, or **—** when unavailable or when Focusrite Control 2 has lost contact with your interface.
- If Focusrite Control 2 stops reaching your interface (its slider moves but the volume doesn't change), the app relaunches it minimized and restores your volume. Turn this off with **Auto-Restart Focusrite Control 2** in Preferences.
- Click the Dock icon to toggle Preferences; click the menu bar icon for the volume popover.

If volume keys stop working after an update, toggle the app off and on in Accessibility settings, then relaunch it.

**v1.1.1 fixes accidental shortcut recording and repairs unsafe saved navigation bindings.** Read the [bug recap and postmortem](docs/shortcut-bug-postmortem.md).

**v1.1.2 fixes a HUD visibility issue when another app or desktop is active.** [What changed](docs/hud-visibility-fix.md).

**v1.1.3 fixes the HUD disappearing on another desktop after locking and unlocking.** Read the [postmortem](docs/hud-lock-recovery-postmortem.md).

**v1.1.4 recovers automatically when Focusrite Control 2 loses contact with your interface.** [What happens and how it's detected](docs/fc2-connection-recovery.md).

## How it works

**Volume changes use cached, native Accessibility controls first.** The app writes directly to Focusrite Control 2 through macOS’s Accessibility API, avoiding the overhead of launching an AppleScript process for each volume change. If that direct path is unavailable, it falls back to AppleScript and re-establishes access to FC2’s controls.

Rapid key presses accumulate through a single volume writer, while older refresh results are prevented from overwriting pending changes. The HUD responds immediately; the Dock independently reads FC2’s confirmed volume to show what the interface has actually accepted.

When your Focusrite is selected as the sound output, a `CGEventTap` intercepts your volume keys and sends them through this control path. Nick’s project provided the foundation; this version adds the cached native write path and stronger state coordination to make everyday volume control more responsive and consistent.

---

An independent project, unaffiliated with Focusrite.
