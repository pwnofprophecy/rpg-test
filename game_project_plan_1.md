# Project Plan: *[Working Title: BOOT.EXE]*
**Engine:** Godot 4.6 (GDScript) | **Platform:** PC | **Target Playtime:** 10+ hrs

---

## 1. Game Summary

The player wakes at their desk to find their house has changed — doors are locked, drawers are sealed, and the game on their monitor is one they don't recognize. The game is a meta-RPG split across two layers: the **Real World** (a top-down house to explore) and **The RPG** (a classic fantasy turn-based RPG accessed via the PC). The RPG grows increasingly impossible, forcing the player to return to the Real World to find **Mods** (floppy disks) that fundamentally alter how the RPG functions. The house itself contains puzzles solved using knowledge gained both in and outside the RPG. Something sinister connects both worlds.

---

## 2. Existing Codebase Assessment

### Keep As-Is
- All project infrastructure: `project.godot`, `CLAUDE.md`, GitHub/LFS setup, `.gitignore`, `.gitattributes`
- `player.gd` — movement via `Input.get_vector()` + `move_and_slide()` is correct
- Battle system state machine architecture (enum + match block pattern) — this is the right foundation
- All established design conventions (signals, `@export`, no autoloads yet, `.tscn` only, naming conventions)
- The 2×2 battle menu layout and HP bar system

### Refactor / Repurpose
- `main.tscn` — currently a placeholder grass world; repurpose as the **RPG Overworld** scene (it's already the right orientation). Rename to `rpg_overworld.tscn`.
- `scenes/world/` folder — rename to `scenes/rpg/` and expand to hold all RPG content
- The battle scene — keep the logic, but the visual style will need to be replaced with real assets once sourced

### Add (Next Steps)
- `scenes/real_world/` — new folder for all Real World content
- Three Autoloads: `GameManager`, `ModManager`, `SaveSystem` (see Architecture section)
- A new root scene (`main.tscn`) that acts as the top-level scene manager, not a game world itself

### Nothing to Scrap
The foundation is clean. No bad patterns were introduced.

---

## 3. Core Architecture

### Scene Hierarchy
```
main.tscn (SceneManager root)
├── real_world/
│   ├── ground_floor.tscn
│   ├── second_floor.tscn
│   ├── basement.tscn
│   └── attic.tscn
└── rpg/
    ├── rpg_shell.tscn         ← the "monitor frame" wrapper
    ├── rpg_overworld.tscn     ← world map + zone navigation
    ├── rpg_battle.tscn        ← battle scene (driven by ModManager)
    └── rpg_town.tscn          ← reusable town template
```

### The Three Autoloads

**GameManager** — Global state and world-switching
- Tracks which world is active (REAL_WORLD or RPG)
- Handles transition signal: `Real World PC → RPG Shell` and back
- Stores Real World progression flags (which locks are open, which floppy disks collected)
- Stores RPG progression flags (which zones cleared, current story state)

**ModManager** — The heart of the game
- Maintains a dictionary of all mods: `{ mod_id: { name, description, active, found } }`
- Emits `mod_activated(mod_id)` and `mod_deactivated(mod_id)` signals
- Battle scene, RPG UI, and overworld all listen to ModManager and reconfigure themselves based on active mods
- Each mod is implemented as a feature flag + associated system class (e.g., `SpellsMod`, `ItemsMod`, `ATBMod`)

**SaveSystem** — Persistent game state
- Serializes and deserializes: RPG character data, RPG world state (enemy HP, position, flags), active/inactive mods, Real World state (lock states, items collected)
- RPG state is saved manually via the in-game menu's "Save" option before exiting to Real World
- Real World state auto-saves on room transitions

### The Mod System (Technical Approach)
Each mod is a self-contained class that registers itself with ModManager. When activated, it injects its behavior into the relevant systems via signals. Example: activating `ItemsMod` causes the battle menu to gain an "Item" option, and the RPG inventory system to become active. This signal-driven approach means the battle scene never needs to know which mods are loaded — it just responds to what ModManager broadcasts.

---

## 4. Development Phases

---

### Phase 0 — Architecture Refactor
*Goal: Lay the foundation that all future work builds on. Claude Code handles this entirely.*

- [ ] Create `GameManager`, `ModManager`, `SaveSystem` autoloads (stubs are fine)
- [ ] Restructure scenes folder: add `real_world/`, rename `world/` to `rpg/`
- [ ] Create a new `main.tscn` as the root SceneManager (no game content, just scene-switching logic)
- [ ] Update `CLAUDE.md` with the new folder structure and autoload conventions
- [ ] Rename `main.tscn` (current) to `rpg_overworld.tscn`

**Deliverable:** A project that boots and can switch between a placeholder Real World scene and the existing RPG overworld.

---

### Phase 1 — Real World: Ground Floor
*Goal: The player can move through the house and interact with objects.*

**Rooms:** Living Room, Kitchen, Office (with PC), Bathroom

- [ ] Ground floor scene with room-to-room transitions via doorways
- [ ] Interactable object system (press action key near object → interaction)
- [ ] The PC in the Office: interacting with it transitions to the RPG shell
- [ ] Floppy disk pickup: find a disk → it appears in the Mod Management UI
- [ ] Mod Management UI: accessible when in Real World, shows all found floppy disks, toggle active/inactive
- [ ] One locked object (a locked drawer or cabinet) with a visible-but-unsolvable lock, to be solved later
- [ ] Placeholder pixel art assets (can be simple colored rectangles at this stage)

**Deliverable:** Player can walk the ground floor, find their first floppy disk, open the Mod UI, and sit at the PC to enter the RPG.

---

### Phase 2 — RPG Shell + Aesthetic System
*Goal: The RPG looks and feels distinct from the Real World, and its visual tier can change.*

- [ ] RPG Shell scene: the monitor frame that wraps all RPG content (letterboxed, styled as a CRT/monitor)
- [ ] Aesthetic tier system: `GAMEBOY`, `NES`, `SNES` — controlled by ModManager
  - Gameboy tier: limited palette, low resolution feel, minimal UI chrome
  - NES tier: expanded palette, tile-based look
  - SNES tier: richer color, more UI detail
- [ ] The existing battle scene and overworld scene are re-skinned by the active aesthetic tier
- [ ] "Return to Desktop" option in the RPG in-game menu: prompts to Save, then exits to Real World

**Deliverable:** The RPG visually reads as a game-within-a-game. Switching tiers visually changes the presentation.

---

### Phase 3 — RPG Zone 1 + Baseline Battle System
*Goal: A complete, playable first zone of the RPG that reaches an intentional difficulty wall.*

**Zone 1 concept:** A starting area, one town, and a short overworld path leading to a dungeon with a boss.

**Baseline RPG (no mods):**
- [ ] Player character with name entry
- [ ] Overworld navigation to Zone 1 area
- [ ] Town with 2–3 NPCs (simple dialogue system)
- [ ] Random encounters on the overworld and in the dungeon
- [ ] Zone 1 dungeon (3–4 rooms + boss room)
- [ ] Boss that is beatable but introduces a mechanic the player can't handle without a Mod (e.g., a status effect with no cure, since there are no Items yet)
- [ ] Zone 1 boss defeat triggers an RPG cutscene hint that sends the player to the Real World

**Deliverable:** The player can complete Zone 1 (or hit the wall), be prompted toward the Real World, and understand the loop.

---

### Phase 4 — First Wave of Mods (6–8 Mods)
*Goal: The Mod system is fully functional and the first set of mods meaningfully changes gameplay.*

**Suggested first wave:**
| Mod | Effect |
|---|---|
| Items Mod | Adds usable items (potions, etc.) to battles and the item menu |
| Spells Mod | Unlocks the Cast menu; player can use MP-costing spells |
| Gold & Shops Mod | NPCs become merchants; gold drops from enemies |
| Save Points Mod | Adds save crystals to the world (until then, manual exit-only saves) |
| Enemy Variety Mod | Adds a second tier of enemies to Zone 1 area |
| Status Effects Mod | Adds poison/sleep/stun to both player and enemies |
| XP & Levels Mod | Adds experience, leveling, and stat growth |
| Run Mod | Makes the Run command actually work |

- [ ] Implement ModManager signal plumbing for each mod
- [ ] Floppy disks for each mod placed in the Ground Floor of the Real World
- [ ] Each mod activates/deactivates cleanly with full RPG state preservation

**Deliverable:** Player can experiment with combinations of mods, meaningfully altering Zone 1 combat feel.

---

### Phase 5 — Cross-Layer Puzzle System
*Goal: The Real World and RPG are informationally linked.*

- [ ] Clue/flag system: RPG events can set flags that GameManager stores (e.g., `edgar_surname_learned = "Voss"`)
- [ ] Real World lock system: combination locks, number pads, keyholes — each checks GameManager flags or inventory
- [ ] Ground Floor puzzles (2–3 puzzles using Zone 1 RPG clues)
- [ ] Solving a Real World puzzle unlocks a new Mod or a new area of the house

**Deliverable:** The player must play RPG Zone 1 to get information they need to solve at least two Real World puzzles.

---

### Phase 6 — Real World: Full House + Remaining Floors
*Goal: All four floors of the house are accessible and puzzle-complete.*

**Second Floor:** Two bedrooms, two bathrooms
**Attic:** One large room — tone should be most unsettling; major Mod or story beat lives here
**Basement:** One large room — dark, puzzle-heavy; possibly where the final Real World revelation lives

- [ ] Room-to-room transitions for all floors (stairs, locked doors that open progressively)
- [ ] Each floor contributes at least 2–3 floppy disks and 1–2 puzzles
- [ ] Environmental storytelling: notes, objects, and visual details hint at the mystery
- [ ] Attic and Basement are initially locked — unlocked via progression milestones

**Deliverable:** The full house is explorable and every Mod has a physical location in the world.

---

### Phase 7 — RPG Zones 2–5 + Advanced Mods
*Goal: The full RPG campaign is completable.*

**Zone 2–4:** Each zone introduces new enemy types and a new mechanic that requires a corresponding Mod.
**Zone 5 (Final Zone):** Ties together all mechanics; final boss designed to reward players who understand the Mod system.

**Advanced Mod suggestions:**
| Mod | Effect |
|---|---|
| Active Time Battle (ATB) Mod | Replaces strict turn order with a real-time gauge system |
| Party System Mod | Adds party members; enables multi-character strategies |
| Timed Actions Mod | Adds timing windows for attacks/blocks (Paper Mario style) |
| Equipment Mod | Adds weapons/armor slots and equipment shops |
| Elemental System Mod | Adds elemental weaknesses/resistances to enemies |
| NPC Memory Mod | NPCs remember if they've been "deleted" and comment on it |
| Overworld Events Mod | Adds visible overworld enemies instead of random encounters |
| Bestiary Mod | Tracks enemy data; gives hints about weaknesses after first encounter |

- [ ] RPG narrative across all 5 zones (dialogue, cutscenes, story flags)
- [ ] Final boss fight designed around the full Mod ecosystem
- [ ] Credits sequence and campaign completion flag set

**Deliverable:** A completable 10+ hour campaign.

---

### Phase 8 — Aesthetic Evolution Tie-In
*Goal: The visual tier of the RPG advances naturally during the campaign.*

- [ ] Gameboy tier: Zones 1–2 (early game feel)
- [ ] NES tier: Zones 2–3 (unlocked by a specific Mod or story beat)
- [ ] SNES tier: Zones 4–5 (unlocked late game)
- [ ] Transition effect between tiers (brief shimmer or "update" animation on the monitor)
- [ ] NPCs react to the visual upgrades with meta-commentary if NPC Memory Mod is active

**Deliverable:** The RPG visually evolves alongside the story, reinforcing the sense of something being built.

---

### Phase 9 — Audio
*Goal: Music and SFX are layered in without blocking other development.*

*Note: Audio is a late addition. Source assets from itch.io or similar.*

- [ ] Real World ambient audio (house sounds, faint hum of the PC)
- [ ] RPG music per zone (3 tiers of quality matching Gameboy/NES/SNES aesthetic)
- [ ] Battle music (varies by tier)
- [ ] SFX for Mod activation/deactivation, lock puzzles, transitions
- [ ] Audio system that responds to ModManager (music style can shift based on active mods)

---

### Phase 10 — Roguelite Mode
*Goal: Post-game mode fully within the RPG for players who want more.*

*This is implemented last, after the campaign is complete.*

- [ ] Roguelite mode flag: unlocked after campaign completion
- [ ] Mode entry: new RPG start with no mods active
- [ ] After each major encounter (boss or milestone), present a pick-one-of-three Mod draft
- [ ] Drafted mods persist for that run only
- [ ] Procedural or semi-randomized enemy encounters
- [ ] Run ends on party wipe; leaderboard/score tracking (time, mods drafted, zone reached)
- [ ] No narrative — purely mechanical

---

### Phase 11 — Polish & Release Prep
- [ ] Full playthrough pass: pacing, difficulty tuning, puzzle clarity
- [ ] Accessibility options (text speed, key rebinding)
- [ ] Main menu, settings screen, credits
- [ ] Godot export configuration for Windows PC
- [ ] Final bug pass

---

## 5. Working with Claude Code

### How to Give Instructions
Claude Code works best with clear, scoped tasks. Before each session, copy the relevant phase tasks from this plan and paste them as the starting context. Example opener:

> *"We're working on Phase 1. Today's goal is to build the ground floor scene with room transitions and the interactable object system. Here's the current project state: [paste any relevant notes]."*

### When to Consult vs. Let It Decide
**Let Claude Code decide autonomously:**
- How to structure any individual script or class
- Which signals to use and when
- How to organize data (dictionaries vs. Resources vs. exported variables)
- Performance optimizations

**You should be consulted on:**
- Any decision that affects the player-facing feel of a Mod (e.g., "how should ATB feel when combined with Turn-Based?")
- Any narrative or puzzle content (dialogue, clue placement, lock solutions)
- Visual/audio asset choices

### Mod Implementation Pattern to Give Claude Code
When implementing a new Mod, instruct Claude Code to follow this pattern:
1. Add the mod ID to `ModManager`'s dictionary
2. Create a `mods/[mod_name]_mod.gd` class with `activate()` and `deactivate()` methods
3. Have the relevant scenes (battle, overworld, UI) listen to `ModManager.mod_activated` and update accordingly
4. Place the corresponding floppy disk object in the Real World at the intended location

### Session Hygiene
- Start each Claude Code session by asking it to read `CLAUDE.md` first
- End sessions by asking Claude Code to update `CLAUDE.md` with any new conventions or decisions made
- Keep this project plan document updated manually as phases complete

---

## 6. Open Design Questions (To Revisit)

These are intentionally left unresolved for now:

- **The mystery's resolution:** What exactly is the RPG doing to the player character's house? Who or what is responsible?
- **Mutually exclusive mods:** Will ATB + Turn-Based create a hybrid, or will one override the other? To be tested during Phase 7.
- **Total mod count:** Targeting "dozens" — a final count of 30–40 mods is a reasonable goal.
- **RPG protagonist's name/story:** The player names them, but what is their canonical arc?
- **Real World protagonist identity:** Are there hints in the house about who they are? What do the locked rooms reveal?
- **Game title:** *BOOT.EXE* is a working title only.
