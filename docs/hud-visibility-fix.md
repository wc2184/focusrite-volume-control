# HUD missing on another desktop

Fixed in v1.1.2 · October 15, 2026

Volume changes could still reach Focusrite Control 2 while the HUD was missing on another Mission Control desktop. The window already had the correct physical-display coordinates and `canJoinAllSpaces`; the missing behavior was independent of the audio write path.

The HUD uses `NSPanel`, which defaults to hiding when its application deactivates. The app did not override that default. In the reproduced case, the panel was ordered, had full opacity, and belonged to the active Space, but was occluded and absent from the onscreen window list while its app was inactive. Making it a floating panel alone did not fix visibility. Disabling hiding on deactivation did.

The fix explicitly sets `hidesOnDeactivate = false` and `canHide = false` for the HUD. Existing all-Spaces and fullscreen behavior, pointer-display placement, click-through behavior, window level, and dismissal timing are preserved. Showing the HUD does not activate the app or make the panel a key window.

An isolated native comparison reproduced the original failure and verified the corrected HUD on both Desktop 1 and Desktop 2 with its app inactive, without changing interface volume. A regression test also checks actual onscreen visibility while the app is inactive, all-Spaces membership, and that showing the HUD does not activate the app or take keyboard focus.

All 21 tests passed for each source variant on Sonoma 14.5. The installed Modern app was also checked on both desktops while hidden and inactive: real media keys changed FC2's volume and the HUD appeared onscreen. The exact starting volume, app visibility, and Desktop 2 were restored afterward. Ventura and Monterey remain experimental and were not tested on their target operating systems.

Apple references: [panel hiding behavior](https://developer.apple.com/documentation/appkit/nswindow/hidesondeactivate), [all-Spaces behavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces), and [active-Space membership](https://developer.apple.com/documentation/appkit/nswindow/isonactivespace).

## Lock, wake, and desktop recovery

Follow-up fix in v1.1.3 · October 18, 2026

See the [lock/unlock recovery postmortem](hud-lock-recovery-postmortem.md) for the evidence, remaining uncertainty, verification gap, and prevention measures.

The earlier fix did not cover a long-lived HUD window becoming invisible after locking and returning to another desktop. On the affected Mac, a media-key press changed the confirmed FC2 volume on Desktop 2, but the original panel was absent from WindowServer's onscreen window list despite correct coordinates and full opacity. A newly created panel with the same appearance and Space flags was visible on that desktop without activating its app.

The HUD now closes and releases its native window after the two-second dismissal instead of retaining a hidden window indefinitely. The next adjustment creates a fresh window. Repeated adjustments while the HUD is visible continue to reuse that window and reset its dismissal timer, preserving immediate feedback without rebuilding on every repeat.

Desktop changes, display reconfiguration, display/system sleep and wake, and user-session transitions also discard the old window and cancel its timer. These notifications never show a HUD by themselves. Closing the window after ordinary dismissal covers lock cycles that do not deliver a sleep or user-session notification. The existing deactivation fix, click-through behavior, pointer-display placement, all-Spaces/fullscreen flags, geometry, and audio control path remain intact.

All 24 tests passed for each source variant on Sonoma 14.5. The added tests check actual visibility of replacement windows, each registered environment notification, reuse during rapid adjustments, and cancellation of an old window's dismissal timer. All three universal Release packages pass signature verification after extraction. Installed Modern v1.1.3 was verified with real media events on Desktop 2, Desktop 1, and back on Desktop 2: each HUD was onscreen while another app remained active. Window identifiers changed between desktops, and no HUD window remained after dismissal. The starting live-check volume (−13 dB), foreground application, and Desktop 2 were restored. The user also completed a physical lock/unlock cycle and confirmed that the HUD appears on Desktop 2 afterward. These live checks cover the Modern build on Sonoma 14.5; Ventura and Monterey remain experimental and were not tested on their target operating systems.
