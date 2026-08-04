# TrackThatPlease

An ArcheAge Classic addon that tracks the buffs and debuffs you care about as
icon bars above your character and your target — with timers, stacks, and an
expiring-soon blink.

Pick what matters to you out of the full game index, and stop squinting at the
default frames to find out whether your buff is still up.

---

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

---

## Choosing what to track

The **TRACKING** panel drives everything.

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

## Display

Icon size, spacing, text size, and how many icons a bar shows, plus separate
warn times for buffs and debuffs — the point at which an icon starts blinking to
tell you it is about to drop. Offsets move each bar up or down independently.

---

## Credits

    Dehling (Delmon)
      With idea implementation from Myke

This addon is free. If you find it useful, in-game donations are appreciated but
never expected — **character: Dehling**.
