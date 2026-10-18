# Volume HUD missing after unlocking: postmortem

October 18, 2026 · Fixed in v1.1.3 (build 6)

## What happened

After locking the Mac and returning to a second Mission Control desktop, volume keys still changed the Focusrite's volume, but the volume HUD did not appear there. Desktop 1 could still show it. “Desktop 2” means a virtual desktop, not a second physical monitor.

The media-key handler and audio writer continued working. The failure was in the independent feedback window, so an audible volume change did not mean the HUD had reached the screen.

## Evidence

On the affected Sonoma 14.5 Mac, a media-key event changed FC2's independently read volume from −16 dB to −20 dB on Desktop 2. The original 200 × 200-point HUD window had full opacity and the expected screen coordinates, but was absent from WindowServer's onscreen window list. The starting volume was restored after the check.

An isolated, newly created panel using the same HUD implementation, appearance, and Space flags appeared on that desktop without activating its application. This established that the display coordinates and HUD drawing could work there, while the existing window could not.

After installing the fix, real media events produced onscreen HUDs on Desktop 2, Desktop 1, and Desktop 2 again. A fresh native window was used after each desktop transition, and no HUD window remained after dismissal. The user then locked and unlocked the Mac and confirmed that the HUD appeared on Desktop 2 afterward.

## Cause and uncertainty

The app created a single native `NSPanel` lazily, hid it after two seconds using `orderOut`, and retained it for the rest of the process's lifetime. Subsequent adjustments kept ordering that same window to the front. There was no window-lifecycle recovery for desktop changes, lock-related transitions, sleep/wake, or display reconfiguration.

This allowed a window that no longer presented correctly on another desktop to be reused indefinitely. The app treated correct geometry, full opacity, and a request to order the window onscreen as sufficient. They were not sufficient in the reproduced state.

The exact internal WindowServer transition that made the old window invisible was not traced. The evidence supports a stale native-window presentation problem and the effectiveness of replacing that window; it does not establish a specific undocumented macOS defect. No private Space-management API was added to the app.

## Why the previous fix and checks missed it

v1.1.2 corrected a separate, reproduced problem: `NSPanel` hid on application deactivation by default. It explicitly set `hidesOnDeactivate = false` and `canHide = false`, and those settings remain necessary.

That release passed visibility checks while inactive and across two desktops. Those checks did not reproduce the later state of a long-lived panel after a lock/unlock cycle. The automated visibility test also started with a newly created window. Passing it established that a fresh HUD could be shown; it did not establish recovery of an old window after environmental transitions.

The verification gap was window lifetime across transitions. Checking that audio changed, or that a panel was logically visible or associated with the active Space, could not substitute for checking that the HUD was actually onscreen.

## What v1.1.3 changes

- Dismissal cancels the timer, orders the HUD out, closes its native window, and releases the manager's reference. The next adjustment creates a fresh window rather than reviving a hidden one from an earlier lock cycle.
- Desktop changes, screen reconfiguration, display/system sleep and wake, and user-session changes discard the current window and its timer. Notifications alone never open a HUD.
- Rapid presses while the HUD is already visible reuse that panel and restart its two-second timer. There is no window rebuild on every held-key repeat.
- Closing the panel after ordinary dismissal provides recovery even when locking does not generate a sleep or user-session notification.

The audio-writing path, optimistic volume updates, confirmed Dock value, tick mapping, pointer-display placement, window level, Space/fullscreen flags, and appearance are preserved. Showing the HUD still does not activate the app or take keyboard focus.

## Verification and limits

The regression suite covers replacement after dismissal, each registered environment notification, actual replacement-window visibility, reuse during rapid adjustments, expiration after the latest press, and cancellation of a retired window's timer. Existing volume and shortcut tests remain in place.

The installed Modern Release app was checked on both desktops while another application remained active. The HUD was verified through the onscreen window list; changes in window identifiers confirmed replacement between desktops. The live-check starting volume of −13 dB and Desktop 2 were restored. The user separately confirmed the physical lock/unlock scenario.

All 24 tests passed for each of the Modern, Ventura, and Monterey source variants on Sonoma 14.5. Each release ZIP was extracted and checked for its signature, Apple silicon/Intel architectures, minimum-OS declarations, version, and bundled license notices. Download checksums are provided with the release and verified after upload. Ventura and Monterey remain experimental: testing their builds on Sonoma does not verify their behavior on those older systems. This incident's physical lock/unlock confirmation covers the Modern build on Sonoma only.

## Prevention

For future HUD changes, verify both native window lifetime and actual onscreen presentation. Keep the lifecycle and timer regressions, and include a physical lock/unlock check across desktops in the manual release checks. A fresh-window test, logical visibility flag, or successful audio adjustment alone is insufficient evidence that the HUD recovers after locking.

Keep the overlay's recovery independent of audio control: replacing a feedback window must not replay an adjustment, write an extra volume value, or change the foreground app. Preserve old release archives and publish corrections as a new version.
