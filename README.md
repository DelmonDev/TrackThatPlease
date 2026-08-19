# TrackThatPlease

An ArcheAge Classic addon that tracks the buffs and debuffs you care about as
icon bars above your character and your target — with timers, stacks, and an
expiring-soon blink.

Pick what matters to you out of the full game index, and stop squinting at the
default frames to find out whether your buff is still up.

![The TrackThatPlease settings window, showing the Display, Timers and Position, Player Bar and Tracking panels above the buff list](https://github.com/user-attachments/assets/0c02eae3-9c16-486b-8ec1-bef2c5f38343)

---

## What's new in 3.2

- **The static bar** — a second bar for your own buffs, pinned to a fixed
  screen spot, with its **own watched list**: a buff can be on either bar, or
  on both. Everything about it lives in one popup behind
  **PLAYER BAR → Static Bar** — an **Enabled/Disabled** switch, **Move
  bar** placement, its own **icon size**, and an **Edit list** shortcut that
  jumps the TRACKING panel to the new **Static bar** track type.
- **Per-bar icon sizes** — the single icon-size slider split into **Player
  icons** and **Target icons**, and the static bar sizes itself from its own
  popup slider.
- **Placed bars stay put** — a pinned bar (the static bar, or the player bar
  in Fixed screen) now comes back to the exact spot you dropped it: across
  relogs and `/reload`, and when buffs come and go — pinned bars keep a
  constant footprint instead of re-centring on however many icons happen to
  be up, and the box you drag is the bar's real footprint.
- **Wider offsets** — the player/target vertical offsets now run **−100 to
  +100**, so a bar can sit below its anchor point, not only above it.
- **Nicer sliders** — click anywhere on a slider track to jump straight to
  that value, fine-step with the −/+ buttons, or roll the mouse wheel over
  it.
- **The whole settings window at every UI scale** — panels, buttons,
  sliders, dropdowns, the scrollbar and the buff list draw their lines in
  device pixels now, so they stay crisp at 80% and don't go chunky at 130%.
- **One border, not two** — the bar icons dropped the engine's slot frame
  and wear a single one-pixel border instead, green for buffs and red for
  debuffs, the same thickness at every UI scale.

## What's new in 3.1

- **UI-scale fix** — the bars now look and sit the same at every UI scale (the
  client offers 40–160% now). Before, the bar shifted hard away from your
  character when the scale wasn't 100 and the nametag toggle was on, and the
  icon size and vertical offset grew and shrank with the scale option. The
  screen math mixed device pixels with the UI's own coordinate space; it now
  converts the way the client itself does, and the bar geometry — icon size,
  spacing, text, borders, offsets — is fixed in on-screen pixels, so "icon
  size 30" means the same 30 pixels at 80% and at 160%. The old per-scale
  nudge table and the stored `UIScale` value are gone, and a stray NaN from
  the game's screen-projection during mount/dismount can no longer glitch the
  bar's position tracking.
- **Crash-proof settings** — your configuration now lives in its own file pair
  (`TrackThatPlease_settings.lua` plus a backup mirror, next to the game's
  `addon_settings` file) instead of the shared store that every addon writes.
  A client crash could truncate that shared file mid-write, and the game then
  silently reset **every** addon to defaults on the next launch.
  TrackThatPlease now survives that: it restores from its own files, heals a
  corrupted copy from the mirror, and migrates your existing settings
  (any schema version) automatically on first launch. Your watched lists also
  now survive addon updates and reinstalls.

## Install

1. Download the latest release and extract it into `Documents/AAClassic/Addon/`.
   The zip already contains the correctly named `TrackThatPlease/` folder, so
   there is nothing to rename.
2. Make sure `TrackThatPlease` is listed in `Documents/AAClassic/Addon/addons.txt`.
3. Log in. The addon announces itself in chat when it loads.

## Opening the settings

Any of these:

- **ESC menu** → **Addon Options** → **TrackThatPlease**
- the **addon manager's** settings button
- type **`ttp`** in chat

![The in-game ESC menu with the Addon Options panel open beside it, listing TrackThatPlease among the installed addons](https://github.com/user-attachments/assets/dbd031e9-f91e-4090-961c-261d109810e7)

---

## Choosing what to track

The **TRACKING** panel drives everything.

![The TRACKING panel: Track type and Buff category dropdowns, a search box, and the list scope and sharing buttons](https://github.com/user-attachments/assets/1069b56e-39dd-43f8-8890-4661f378228c)

| Control | What it does |
|---|---|
| **Track type** | Whether your clicks apply to the **Player** bar, the **Target** bar, or **Both** at once |
| **Buff category** | Browse the full game index, buffs the logger has seen in play, or just your watched list |
| **Search** | Filter by name or by id |
| **Start logging** | Records every buff that appears on you or your target while active |

Each row's icon is outlined **green for a buff** and **red for a debuff** — known
for every entry in the index, including ones you have never seen in play.

Unticking a buff keeps it in your Watched list so you can re-tick it later
without hunting for it again. The red **x** on a row is what removes it for good.

**Start logging** is the easy way in: turn it on, go play, and every buff that
lands on you or your target gets collected. Afterwards they are all waiting
under *All logged buffs*, so you can build a list by playing rather than by
searching a 13,000-entry index.

---

## Sharing lists

- **Export** writes the list you are using to `TrackThatPlease/watchlist.txt`.
- **Import** reads that same file and *adds* its entries to your list — it never
  removes anything you already watch.

Send the file as-is; no renaming needed. If an Export would overwrite a list
somebody sent you, the previous file is kept as `watchlist_previous.txt`.

## Per-character or shared lists

Display settings are always shared across your characters.

Watched lists are shared by default. **List: Character** gives the current
character its own copy, and the button beside it copies a list into the other
scope either way — *To global* or *To character*, two clicks to confirm, since
it overwrites a list that may hold hundreds of buffs.

---

## The player bar

![The PLAYER BAR panel, with the Position button and the Nametag toggle beside it](https://github.com/user-attachments/assets/f478fe4e-dad0-4231-80e1-9c71f9c6a143)

Two positions, cycled with the **Position** button:

- **Above head** — follows your character in the world.
- **Fixed screen** — pinned wherever you drag it with **Move bar**, immune to
  everything.

Alongside them, a **Nametag** toggle. Turn it on if your own character's
nameplate is showing: the game anchors overhead UI to the nameplate, so with it
on the reported position wanders and the bar jitters along with it. The toggle
cancels that wander and holds the bar steady — jumps, gliding and abrupt
movement skills leave it where it is. With no nameplate, leave it off; plain
Above head is already correct.

---

## The static bar

A second bar for your own buffs, independent of the one above your head — the
same buff can be tracked on either bar, or on both. It only ever uses a fixed
screen position, so nothing in the world can move it.

Everything about it lives behind **PLAYER BAR → Static Bar**:

- **Enabled/Disabled** — the bar's switch. It only appears while Enabled AND
  its list has buffs.
- **Move bar** — shows the bar as a colored box you can drag anywhere; click
  again to lock it in place. Placing works with the bar disabled too, so it
  can be set up first and enabled when wanted.
- **Icon size** — the static bar's own size, independent of the DISPLAY
  sliders.
- **Edit list** — jumps the TRACKING panel to the **Static bar** track type;
  tick buffs there like on any other list.

---

## Display

Separate icon sizes for the player and target bars (the static bar has its
own slider in its popup), spacing, text size, and how many icons a bar shows,
plus separate warn times for buffs and debuffs — the point at which an icon
starts blinking to tell you it is about to drop. Offsets move each bar up or
down independently, anywhere from −100 to +100.

---

## Credits

    Dehling (Delmon)
      With idea implementation from Myke and Fortuno

This addon is free. If you find it useful, in-game donations are appreciated but
never expected — **character: Dehling**.
