[![](http://img.youtube.com/vi/gNMEFNtfaEQ/0.jpg)](http://www.youtube.com/watch?v=gNMEFNtfaEQ "Youtube link")
# ClassicFCT [![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/Y8Y66XZTG)
Highly customizable "Floating Combat Text" addon with text anti-overlap behavior similiar to that of WoW Classic.
 

Use "/cfct" command to open the options interface.
 
Currently there are 2 configuration presets built-in: "Classic" and "Mists of Pandaria".
Users can create their own presets.
 
## WoW: Forever

Forever runs on the retail UI engine with the retail addon restrictions, so it
gets its own `ClassicFCT-Camelot.toc` and its own combat text reader:

- Addons cannot read the combat log there (`CombatLogGetCurrentEventInfo` does
  not exist), so combat text is read from `COMBAT_TEXT_UPDATE` +
  `C_CombatText.GetCurrentEventInfo()`.
- The amounts that event returns are secret values: they cannot be compared,
  added up or turned into keys, only handed to a client formatter. ClassicFCT
  therefore converts every amount to a string before anything else touches it.
- Because of that, these options do nothing on that client and are hidden from
  the options panel: damage thresholds (absolute, relative, average), event
  merging, sorting by amount, spell ids (icons and the two spell id dropdowns),
  colors by damage school, attaching text to nameplates, and the damage over
  time and pet event groups. Damage over time is reported as a normal spell hit,
  and a crit is reported the same way whether a swing or a spell caused it, so
  crits use the auto attack crit style.
- Everything else, including every animation, behaves as usual.

Keep Blizzard's *Combat > Enable floating combat text* setting **on**: it is the
event source. The "Hide Blizzard Text" option only hides their text.

`/cfct diag` prints what the running client reports.


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
