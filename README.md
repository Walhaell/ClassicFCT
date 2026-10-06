[![](http://img.youtube.com/vi/gNMEFNtfaEQ/0.jpg)](http://www.youtube.com/watch?v=gNMEFNtfaEQ "Youtube link")
# ClassicFCT [![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/Y8Y66XZTG)
Highly customizable "Floating Combat Text" addon with text anti-overlap behavior similiar to that of WoW Classic.
 

Use "/cfct" command to open the options interface.
 
Currently there are 2 configuration presets built-in: "Classic" and "Mists of Pandaria".
Users can create their own presets.
 
## WoW: Forever

Forever runs on the retail UI engine with the retail addon restrictions, so it
gets its own `ClassicFCT-Camelot.toc` and its own combat text reader:

- The deprecated `CombatLogGetCurrentEventInfo` global is gone, but the combat
  log itself is not: `COMBAT_LOG_EVENT_UNFILTERED` fires and the payload is read
  through `C_CombatLogInternal`, `C_CombatLogSecure` or `C_CombatLog`. That is the
  source the addon prefers, because it is the only one that carries the spell
  behind a hit, and the only one that keeps answering while Blizzard's own text
  is hidden. Unit identity is a secret value there, so who cast a spell is taken
  from the actor flags instead of from GUIDs.
- `COMBAT_TEXT_UPDATE` + `C_CombatText.GetCurrentEventInfo()` stays as the
  fallback: it reports the player's own hits only while Blizzard's text is
  visible, and never carries a spell. `/cfct source auto|cleu|text` picks one by
  hand, and the "Hide Blizzard Text" option now makes Blizzard's frame
  transparent instead of hiding it, so the fallback keeps working.
- The amounts are secret values: they cannot be compared, added up or turned
  into keys, only handed to a client formatter. ClassicFCT therefore converts
  every amount to a string before anything else touches it, or passes the amount
  straight to the text if this build keeps it secret.
- The width of a secret amount cannot be measured either, so on that client the
  anti-overlap grid is laid out with the width of a five character sample
  ("1,200", "-1.2K") instead of the real one. Text is never cut off and heights
  are exact, but very long amounts can sit a little closer to their neighbour
  than on the other clients, and the anti-overlap spacing sliders tune that.
- Because of that, these options do nothing on that client and are hidden from
  the options panel: damage thresholds (absolute, relative, average), event
  merging, sorting by amount, attaching text to nameplates, and the thousands
  separator (the client formatter follows the game locale instead).
- Spell ids, spell icons, damage type colors, the spell id blacklist, damage
  over time, pet events and spell crits depend on what the combat log hands over
  as a plain value. The options panel shows them once an event has been read,
  and `/cfct diag` reports what that build actually returned.
- Everything else, including every animation, behaves as usual.

Keep Blizzard's *Combat > Enable floating combat text* setting **on**: it is the
event source for the fallback. The "Hide Blizzard Text" option only hides their
text.

Diagnostics for that client:

- `/cfct diag` prints what the running client reports, including which combat
  log reader exists and whether the spell id, damage school and crit flag come
  back plain or secret.
- `/cfct trace` prints every event as it arrives from both sources, with the
  shape of its data (an amount is reported as secret, since it cannot be read
  back).
- `/cfct cleu internal|secure|namespace|global` picks which combat log reader to
  use, without restarting the client.
- `/cfct source auto|cleu|text` picks the source.
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
