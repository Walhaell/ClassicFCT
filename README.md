[![](http://img.youtube.com/vi/gNMEFNtfaEQ/0.jpg)](http://www.youtube.com/watch?v=gNMEFNtfaEQ "Youtube link")
# ClassicFCT [![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/Y8Y66XZTG)
Highly customizable "Floating Combat Text" addon with text anti-overlap behavior similiar to that of WoW Classic.
 

Use "/cfct" command to open the options interface.
 
Currently there are 2 configuration presets built-in: "Classic" and "Mists of Pandaria".
Users can create their own presets.
 
## WoW: Forever

Forever runs on the retail UI engine with the retail addon restrictions, so it
gets its own `ClassicFCT-Camelot.toc` and its own combat text reader:

- The combat log is closed to addons there, not just renamed: registering
  `COMBAT_LOG_EVENT_UNFILTERED` is refused by the client with
  `ADDON_ACTION_FORBIDDEN`, and the deprecated `CombatLogGetCurrentEventInfo`
  global does not exist. Combat text is therefore read from `COMBAT_TEXT_UPDATE`
  + `C_CombatText.GetCurrentEventInfo()`, which is the only event source there.
- That event reports the player's own hits only while Blizzard's own text frame
  is visible, so "Hide Blizzard Text" makes that frame transparent instead of
  hiding it. A few invisible FontStrings cost nothing and the player's damage
  keeps showing with the option on.
- The amounts that event returns are secret values: they cannot be compared,
  added up or turned into keys, only handed to a client formatter. ClassicFCT
  therefore converts every amount to a string before anything else touches it,
  or passes the amount straight to the text if this build keeps it secret.
- The width of a secret amount cannot be measured either, so on that client the
  anti-overlap grid is laid out with the width of a five character sample
  ("1,200", "-1.2K") instead of the real one. Text is never cut off and heights
  are exact, but very long amounts can sit a little closer to their neighbour
  than on the other clients, and the anti-overlap spacing sliders tune that.
- The payload of that event carries no spell, no damage school and no actor, so
  these options have nothing to work with there and are hidden from the options
  panel: damage thresholds (absolute, relative, average), event merging, sorting
  by amount, spell ids (icons and the two spell id dropdowns), colors by damage
  school, attaching text to nameplates, and the damage over time and pet event
  groups. Damage over time is reported as a normal spell hit, and a crit is
  reported the same way whether a swing or a spell caused it, so crits use the
  auto attack crit style.
- Everything else, including every animation, behaves as usual.

Keep Blizzard's *Combat > Enable floating combat text* setting **on**: it is the
event source. The "Hide Blizzard Text" option only hides their text.

Diagnostics for that client:

- `/cfct diag` prints what the running client reports.
- `/cfct trace` prints every combat text event as it arrives, with the shape of
  its data (an amount is reported as secret, since it cannot be read back). It
  is the only way to see which message types a given fight produces, for example
  whether damage over time arrives under a type of its own.
- `/cfct unit <token>` watches another unit than the player, to see which events
  the client reports for it.


Text display area can be positioned in 3 ways: 
- to screen center (with x, y offsets)
- to the target nameplate
- to every individual nameplate (anti-overlap doesnt work in this mode courtesy of Blizzard)

If no nameplate is available (in case the target dies or moves off-screen), text display area can fall back to screen center.
Text can be displayed behind or in front of nameplates and their children.

Animations:
- Fade In, Fade Out
- Directional Scroll
- Pow (a 2 stage scale animation for crits)

Configurable variables include:
- animation timing, scale and duration.
- text font, style, size, custom color or by damage type.
- anti-overlap spacing
- spell icons for each damage/heal event.
- filtering, sorting, merging
