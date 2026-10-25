# Recovering when Focusrite Control 2 loses the interface (v1.1.4)

## Symptom

Volume keys, the HUD, and Focusrite Control 2's own slider keep moving, but the speakers stay at the same level. Restarting FC2 fixes it. This is a problem in FC2 itself, not in this app: every way of changing the volume, including dragging FC2's slider by hand, stops working.

## What actually happens

FC2 controls a Scarlett 4th Gen interface by sending commands over USB. Audio playback uses a separate path and keeps working. In the failure state, the interface stops acknowledging FC2's commands. FC2's system log shows `Timeout waiting for DCP acknowlegement`, followed by `Error transmitting request to device: -7` (a USB timeout) for every request.

On the Mac where this was investigated (FC2 1.1081, Scarlett Solo 4th Gen, firmware 2.0.2417), FC2's log recorded five outages between August and October 2026, lasting from 28 minutes to 18 hours. During one six-hour outage, not one of roughly 24,000 USB requests succeeded, including 123 volume changes. Each outage ended only when FC2 was relaunched or the interface was reconnected. The trigger is unknown; one outage began during heavy, rapid audio start/stop activity on the interface, and the interface was connected through a shared USB hub.

FC2's slider still shows the new value during an outage. Before v1.1.4, the Dock therefore showed a level the interface never received.

## Detection

While the connection is lost, FC2 writes a failed meter read to `~/Library/Logs/Focusrite/Focusrite Control 2/fc2.log` about every nine seconds:

```
[pal] ERROR: error fetching peaks: Encountered an error whilst fetching peaks: 1
```

The app reads only new lines in that file. Three timeout errors (code `1`) within 30 seconds count as an outage. Code `11` errors, which accompany unplugging, and isolated errors (about one a day in practice) are ignored. The outage ends when FC2 logs `Device mounted`.

## Recovery

1. The Dock shows **—** instead of FC2's slider value.
2. The app quits FC2, forcing it after three seconds if necessary, relaunches it without activating it, and minimizes its window.
3. Volume presses during the relaunch update the HUD but are held, so a half-started FC2 is never brought to the front.
4. After FC2 reopens the interface, the app reapplies the most recent volume you chose and switches FC2 back to its Direct view.

Restarts have a two-minute cooldown and are limited to three per hour. They happen only while a Focusrite interface is the Mac's sound output. **Auto-Restart Focusrite Control 2** in Preferences turns restarts off; the Dock still shows **—** during an outage.

## Verification

Unit tests cover the detection threshold, ignored errors, recovery on remount, cooldown and hourly limits, reading only appended log lines, the Dock value, and holding then reapplying volume changes made during a relaunch. A real outage cannot be triggered on demand, so the installed app was tested by appending clearly marked simulated errors to FC2's log: FC2 restarted in about two seconds, stayed minimized, the user's foreground app kept focus, and a volume change pressed mid-restart was the level applied afterward.

## Prevention

If outages recur, connect the interface directly to the Mac rather than through a hub, and check for Focusrite Control 2 and firmware updates.
