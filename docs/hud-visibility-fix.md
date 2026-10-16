# HUD missing on another desktop

Fixed in v1.1.2 · October 15, 2026

Volume changes could still reach Focusrite Control 2 while the HUD was missing on another Mission Control desktop. The window already had the correct physical-display coordinates and `canJoinAllSpaces`; the missing behavior was independent of the audio write path.

The HUD uses `NSPanel`, which defaults to hiding when its application deactivates. The app did not override that default. In the reproduced case, the panel was ordered, had full opacity, and belonged to the active Space, but was occluded and absent from the onscreen window list while its app was inactive. Making it a floating panel alone did not fix visibility. Disabling hiding on deactivation did.

The fix explicitly sets `hidesOnDeactivate = false` and `canHide = false` for the HUD. Existing all-Spaces and fullscreen behavior, pointer-display placement, click-through behavior, window level, and dismissal timing are preserved. Showing the HUD does not activate the app or make the panel a key window.

An isolated native comparison reproduced the original failure and verified the corrected HUD on both Desktop 1 and Desktop 2 with its app inactive, without changing interface volume. A regression test also checks actual onscreen visibility while the app is inactive, all-Spaces membership, and that showing the HUD does not activate the app or take keyboard focus.

All 21 tests passed for each source variant on Sonoma 14.5. The installed Modern app was also checked on both desktops while hidden and inactive: real media keys changed FC2's volume and the HUD appeared onscreen. The exact starting volume, app visibility, and Desktop 2 were restored afterward. Ventura and Monterey remain experimental and were not tested on their target operating systems.

Apple references: [panel hiding behavior](https://developer.apple.com/documentation/appkit/nswindow/hidesondeactivate), [all-Spaces behavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces), and [active-Space membership](https://developer.apple.com/documentation/appkit/nswindow/isonactivespace).
