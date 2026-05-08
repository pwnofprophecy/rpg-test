# RPGTest — Godot 2D Project

## Project Overview
A 2D RPG game built with Godot 4.6 (GDScript).

## Engine & Tooling
- **Godot version**: 4.6
- **Renderer**: Forward Plus (D3D12 on Windows)
- **Language**: GDScript (`.gd` files)
- **Scene format**: `.tscn` (text-based), `.scn` (binary — avoid)

## Project Structure Conventions
```
res://
├── scenes/
│   ├── main.tscn        # Root SceneManager — swaps worlds in/out at runtime
│   ├── main.gd
│   ├── player/          # Player scenes/scripts (shared between worlds where applicable)
│   ├── real_world/      # All Real World (house) scenes: rooms, floors, interactables
│   ├── rpg/             # All RPG scenes: overworld, shell, battle, towns, dungeons
│   └── battle/          # Legacy — will be merged into scenes/rpg/ in Phase 2
├── scripts/             # Standalone .gd scripts not attached to a scene
├── assets/
│   ├── sprites/         # .png / .svg sprite sheets and individual sprites
│   ├── audio/           # .ogg / .wav files
│   └── fonts/
├── autoloads/           # Singleton scripts — registered under [autoload] in project.godot
│   ├── game_manager.gd  # Tracks current world + progression flags
│   ├── mod_manager.gd   # Manages all mods (found/active state, signals)
│   └── save_system.gd   # Save/load persistent game state
└── resources/           # .tres custom Resource files (stats, items, etc.)
```

## Two-World Architecture
The game is split across two "worlds":
- **Real World** (`scenes/real_world/`) — a top-down house the player explores
- **RPG** (`scenes/rpg/`) — the game-within-a-game accessed via the PC

The SceneManager (`scenes/main.gd`) is the root scene and swaps between them based on `GameManager.current_world`. Autoloads persist across world switches, so global state survives transitions.

### RPG Sub-Locations
The RPG world has multiple "places" the player can be in: the overworld map, towns, dungeons, etc. These are tracked separately from the World layer via `GameManager.rpg_location` (an `RPGLocation` enum: `OVERWORLD`, `TOWN`, `DUNGEON`). When `GameManager.switch_rpg_location()` fires, `main.gd` swaps the active RPG sub-scene — but only if the player is currently in the RPG world. If they're in the Real World, the new location is queued for the next time they enter the RPG via the PC.

`GameManager.overworld_return_position` is the bridge for "where do I respawn when I leave a sub-location?" When entering a town/dungeon from the overworld, the trigger handler stashes `player.global_position` here. When the overworld scene reloads, its `_ready()` consumes that position and resets it to `Vector2.ZERO` (the "no saved position, use the default spawn" sentinel). This means a fresh RPG entry from the Real World always uses the scene's hand-placed default spawn, while round-trips to towns/dungeons preserve where the player was standing.

Adding a new RPG sub-location: add an enum entry to `RPGLocation`, a `preload` constant in `main.gd`, and a match arm in `main.gd`'s `_rpg_scene_for_location()`. Build the scene's `.tscn` mirroring the structure of `rpg_town.tscn` — root Node2D with the location script, plus `TierOverlayLayer`, `HintLayer`, `PauseMenu`, `DialogueBox`, and Player+Camera2D children. The location script handles its own pause menu wiring, save flow, and interactable routing — for now this is duplicated from `rpg_overworld.gd` / `rpg_town.gd` rather than factored into a base class. Refactor to a shared base when a third location lands.

## Autoloads
Five singletons are registered in `project.godot`:
- **GameManager** — current world, progression flags, world-switching API (`switch_to_world`, `toggle_world`)
- **ModManager** — mod registry with `found` / `active` state, emits `mod_found` / `mod_activated` / `mod_deactivated` signals
- **SaveSystem** — save/load API (stub; `save_game()` returns `true`, `load_game()` returns `false`. Real implementation lands after Phase 3.)
- **Aesthetic** — current RPG visual tier (Gameboy / NES / SNES), emits `tier_changed(new_tier)`. See "Aesthetic Tier System" below.
- **RPGState** — Hero's runtime stats (hp/mp/attack/defense/speed/xp/gold/status_effects) plus `character_name`. Seeded from `res://resources/hero_stats.tres` on `_ready()` via `reset_from_template()`. Emits `stats_changed`. See "Hero Stats Pattern" below.

## Coding Conventions
- Use `class_name` declarations for scripts that are reused across scenes.
- Prefer signals over direct node references for loose coupling between systems.
- Autoloads (singletons) for global state — see "Autoloads" section above. Reference them by their registered name (e.g. `GameManager.switch_to_world(...)`).
- Use `@export` variables for designer-tunable values.
- Snake_case for variables and functions; PascalCase for class names and node names.
- Keep scene scripts focused — split large scripts into composable child nodes.

## Common Patterns
- **Player input**: Use `Input.get_vector()` / `Input.is_action_pressed()` with the Input Map.
- **State machines**: Implement as an enum + match block, or a dedicated `StateMachine` node.
- **Saving/loading**: Use `ResourceSaver`/`ResourceLoader` or JSON via `FileAccess`.
- **UI**: Use `CanvasLayer` with `Control` nodes; bind data via signals, not polling.

## What NOT to Do
- Don't edit `.import` files or `project.godot` manually unless necessary.
- Don't use `get_node()` string paths when `@onready` + typed references work.
- Don't use `_process()` for things that only need to run on state changes — use signals.
- Avoid binary `.scn` files; keep scenes as `.tscn` for version control readability.
- Don't use git worktrees — work directly on the main repository.

## Division of Work: Code vs. Scenes
The user and Claude split responsibilities cleanly:

**Claude handles all code:** `.gd` scripts, autoloads, shaders, `.tres` resource definitions, `project.godot` settings, `CLAUDE.md`, and any other text-based logic. Write/edit these directly without asking.

**The user handles all scene/content building in the Godot editor:** `.tscn` files, scene trees, node placement, collision shapes, doorways, walls, room layouts, NPC placement, prop instances, and any creative/design decisions about how the world looks and is laid out.

When new scene content is needed (a town, a room, an NPC, a dungeon, props, etc.), **do NOT create or modify the `.tscn` file directly**. Instead, give the user step-by-step instructions for building it in the Godot editor:
- What nodes to add and what types they should be (e.g. "Add an Area2D as a child of Interactables")
- What scripts to attach (e.g. "Attach `scripts/interactable.gd`")
- What Inspector properties to set (e.g. "Set `interaction_id` to `npc_blacksmith`, `hint_text` to `[Interact] to talk`, fill in `interaction_pages` with the dialogue lines below")
- How nodes should be parented and roughly where they should sit (let the user pick exact positions)
- Any group memberships, signal connections, or collision layer settings that aren't auto-handled by the code

Provide concrete suggested values (positions, sizes, colors, dialogue text) so the user has something to start from, but frame them as suggestions the user can adjust to taste.

**Exceptions where Claude may still touch `.tscn` files directly:**
- Fixing concrete bugs in scene metadata (e.g. the invalid-UID warning fix on `tree.tscn`)
- Tweaks the user explicitly asks for ("change this NPC's color to red")
- Trivial property updates that don't affect layout (e.g. updating an `interaction_id` string)

If unclear whether a task is "code" or "scene work", ask. Default to instructing the user when in doubt.

## Godot UID Cache & New Files
Godot 4 maintains a `.godot/uid_cache.bin` file mapping every resource's UID to its file path. When the user creates a file through the Godot editor (e.g. via the FileSystem dock), the editor auto-registers it in the cache. **When Claude creates a new `.gd`, `.tres`, or `.tscn` via the Write tool, Godot doesn't know about it yet** — the file exists on disk but isn't in the cache.

This causes a noisy startup warning the next time something references the new file by UID:
```
W ext_resource, invalid UID: uid://... — using text path instead: res://...
```

The fallback (text path lookup) works fine, so the game runs. But the warning is noise and we want a clean console.

**Workflow when Claude adds new files:** After Claude reports that new `.gd` / `.tres` / `.tscn` files have been created, the user should run **Project → Reload Current Project** in the Godot editor (or close and reopen the project). That triggers a filesystem rescan, registers any new `.uid` sidecar files, and updates `uid_cache.bin`. Subsequent boots are warning-free.

**If a UID warning still appears after reload:** Strip the `uid="..."` attribute from the offending `ext_resource` line. Godot will fall back to path-based loading, no warning, and the next time the file is saved through the editor it'll re-add a UID that's properly cached. This is the fix we used on `tree.tscn`, `bandit.tres`, and `slime.tres`.

## Respecting the User's Scene Layouts
Even when Claude does touch a `.tscn` (per the exceptions above), the user's hand-placed layout is canonical:
- **Do NOT move, resize, reposition, or reorganize** nodes in `.tscn` files the user has arranged, even if something looks "off" compared to an earlier version. That includes `position`, `offset_*`, `size`, `scale`, `rotation`, and the ordering/parenting of nodes.
- **Do NOT "restore" prior positions** from memory, plan files, or git history — if the user moved something, the new location is the canonical one.
- If a task genuinely requires moving something the user has placed (e.g. a new feature only works if a collision shape is resized), **stop and ask for permission first**, describing exactly what needs to move and why.

## Aesthetic Tier System
The RPG (not the Real World) has a **visual tier** that controls its look: Gameboy, NES, or SNES. The system is designed so that both Phase 2 code and future assets/mods hook in the same way.

**Data flow**:
1. Each tier is an `AestheticTier` Resource (`res://resources/aesthetic_tier.gd`) with palette, pixel scale, and scanline params. Instances live at `res://resources/tiers/gameboy.tres`, `nes.tres`, `snes.tres`.
2. The `Aesthetic` autoload holds `current_tier` (enum) and maps each tier to its Resource. Emits `tier_changed(new_tier)` on change.
3. The RPG overworld (`scenes/rpg/rpg_overworld.gd`) listens to `tier_changed`, reads the active tier's Resource from `Aesthetic.get_palette()`, and pushes palette + shader params into the full-screen `TierOverlay` ColorRect's ShaderMaterial.
4. The overlay shader (`res://scenes/rpg/shaders/tier_overlay.gdshader`) pixelates, palette-quantizes, and scanlines the entire RPG image every frame — this is the single mechanism that makes tiers visually distinct.

**Changing tier at runtime**: call `Aesthetic.set_tier(Aesthetic.Tier.NES)`. No-op if already on that tier. Debug keys `F1`/`F2`/`F3` cycle through tiers for Phase 2 testing (remove in Phase 4 once mods control tier).

**Adding a new tier later**: create a new `.tres` under `res://resources/tiers/`, add an enum entry in `autoloads/aesthetic.gd`, add it to the `_TIER_RESOURCES` dictionary. No other code changes.

**When real sprite/tile assets arrive**: extend `AestheticTier` with `@export var tileset: TileSet`, `@export var font: Font`, etc. The signal + autoload pattern doesn't change — new fields just mean more data on each tier change.

**Shader limits**: the overlay shader's palette array is fixed at 16 entries (GLSL compile-time requirement). Palettes with more entries are clipped with a warning. Palettes with fewer are fine.

## Hero Stats Pattern
The Hero's stats live on the **RPGState** autoload (runtime state) and are seeded from **`res://resources/hero_stats.tres`** (template/starting values).

**Why split template from runtime?**
- The `.tres` is the "new game" default. It's Inspector-editable (double-click in the FileSystem dock) — designers tune starting HP/attack/etc. there without code.
- The autoload holds the live values that battles and abilities mutate during play. Resetting to template is a one-line call: `RPGState.reset_from_template()`.
- SaveSystem (post-Phase 3) will serialize the autoload's fields directly, ignoring the `.tres` once a save exists.

**Fields** (both on `HeroStats` Resource and RPGState autoload): `character_name`, `max_hp`/`hp`, `max_mp`/`mp`, `attack`, `defense`, `speed`, `intelligence` (scales spell power + MP pool), `luck` (crit chance + loot drops), `level`, `xp`, `gold`, `status_effects: Array[String]`.

**Status effects**: plumbing-only until battles are wired. Use `add_status(name)` / `remove_status(name)` / `has_status(name)` / `clear_statuses()` on RPGState — they emit `stats_changed` so UI refreshes without polling.

**Name entry**: `RPGState.character_name == ""` is the sentinel for "hasn't been named yet." `scenes/rpg/name_entry.tscn` is shown by `rpg_overworld.gd` on first RPG entry, writes the name into RPGState, and self-removes. Empty input falls back to `"HERO"`.

## Pause Menu Pattern
`scenes/ui/pause_menu.tscn` is a shared CanvasLayer instanced in each world. Each world passes its own option list into `pause_menu.open([...])` and listens to `option_selected(id)`. Routing (what "Save" does, whether "Exit RPG" shows) is the caller's responsibility — the menu is just a presenter.

**Important**: the pause menu has `process_mode = PROCESS_MODE_ALWAYS` so it keeps running when the tree is paused. The RPG pauses the tree on open; the Real World disables the player's process mode instead. Both approaches work with the same menu.

`Escape` (bound to the `pause` input action) opens it. `Escape` while open closes it. (`ui_cancel` is also bound to Escape as of Phase 3a so that LineEdit-based inputs like the name entry prompt can use Backspace for text editing.)

## Combat Sandbox (Debug)
`scenes/rpg/combat_sandbox.tscn` is a debug-only scene for iterating on the combat system. Press **F5** anywhere in the game to enter it; the sandbox stashes the world you came from in `GameManager.previous_world` and an "Exit Sandbox" button returns you there.

The sandbox lets you live-edit Hero stats, pick an enemy from a dropdown of every `.tres` in `res://resources/enemies/`, toggle every registered mod on/off (bypassing the "must be found" gate), and launch a battle. Battles launched from the sandbox return to the sandbox (via `GameManager.battle_returns_to_sandbox`) so iteration is fast.

Adding a new enemy: drop a `.tres` into `res://resources/enemies/`, fill in the `EnemyStats` fields in the Inspector, and it appears in the sandbox's dropdown next time you load it. No code changes.

Adding a new player stat: append an entry to `_STAT_FIELDS` in `combat_sandbox.gd`. The SpinBox row generates automatically.

## Damage Formula
Phase 3.5 introduces the unified damage formula used by all attacks (physical, magical, weapon, spell):

```
EffectiveAttack = A + Power
RawDamage = (2 × EffectiveAttack / D + 2) × Critical × Random
Damage = max(1, floor(RawDamage))
```

Where:
- **A** — `attack` for physical attacks, `intelligence` for magic
- **Power** — attacker's `base_power` (or weapon/spell Power once equipped/cast)
- **D** — defender's `defense` (clamped at 1)
- **Critical** — `1.5x` on crit, `1.0` otherwise. Crit chance = `luck × 1%`, capped at 50%
- **Random** — uniform `0.85..1.0` variance roll

The full math lives in `battle.gd::_calculate_damage()`. Tuning constants (`STAT_COEFFICIENT`, `CRIT_MULTIPLIER`, etc.) are `const` at the top of `battle.gd` for now — extract to a `CombatBalance` Resource if Inspector tuning becomes valuable later.

`HeroStats` and `EnemyStats` both have a `base_power: int` field. Set to 0 means raw stats only (unarmed). Weapons/spells eventually override this with their own Power values when equipped or cast.

## Enemy Templates
Enemies are defined as `EnemyStats` Resource `.tres` files in `res://resources/enemies/`. Each has the standard combat stats (max_hp, attack, defense, speed, intelligence, luck, base_power) plus reward fields (xp_reward, gold_reward) for future use.

`battle.gd` reads enemy stats from `GameManager.pending_battle_enemy` (an `EnemyStats` Resource) when set, and falls back to the @export defaults on the battle node otherwise. The combat sandbox uses this — it sets `pending_battle_enemy` before launching the battle. The random-encounter path on the overworld currently uses the @export defaults; later it'll set `pending_battle_enemy` based on the encounter table.

## Equipment System
The Hero has three equipment slots: **Weapon**, **Armor**, **Accessory**. Each holds at most one `Equipment` Resource. Equipment templates live as `.tres` files in `res://resources/equipment/`.

**Resource shape** (`resources/equipment.gd`): `item_name`, `slot` (Slot enum: WEAPON/ARMOR/ACCESSORY), `description`, plus `*_bonus` fields for each stat the equipment can boost (`hp_bonus`, `mp_bonus`, `attack_bonus`, `defense_bonus`, `speed_bonus`, `intelligence_bonus`, `luck_bonus`, `power_bonus`).

**RPGState API**:
- `equip(item)` — auto-routes to the correct slot based on `item.slot`
- `unequip(slot)` — clears that slot
- `get_equipped(slot)` — read what's currently in a slot
- `get_effective_<stat>()` — returns `<stat> + sum of equipment bonuses`. Used by `battle.gd` and any HUD that wants the "real" value.

**Bonus stacking**: All three slots' bonuses for a given stat sum together. So a Wooden Sword (+2 attack) + Lucky Charm (+1 attack hypothetical) would give +3 effective attack on top of base.

**`Reset to Defaults` clears equipment too** — `RPGState.reset_from_template()` with `include_name=true` (the public reset path) also nulls all three slots, since a "new game" should start unarmed.

**Adding a new piece of equipment**: drop a `.tres` into `res://resources/equipment/`, fill in the Inspector fields. The combat sandbox auto-discovers it next time it loads (sorted by name within its slot).

**Adding a new bonus stat type**: add an `@export var foo_bonus: int = 0` to `equipment.gd`, add a `get_effective_foo()` method to `RPGState` (calling `_equipment_bonus("foo_bonus")`), then update `battle.gd` to read through the effective getter where appropriate.

**Adding a new slot type** (e.g. HELMET): add an enum entry to `Equipment.Slot`, a slot field to `RPGState`, match arms in `equip`/`unequip`/`get_equipped`, and an entry in `combat_sandbox.gd`'s `_EQUIPMENT_SLOTS` array.

## Battle Integration
Random encounters are triggered by `rpg_overworld.gd`'s distance-based stepper. When the step counter hits zero, the overworld stashes the player's current position into `GameManager.overworld_return_position`, sets `GameManager.rpg_battle_return_location` to whatever location triggered the battle (currently always `OVERWORLD`; dungeons will set `DUNGEON` later), and switches to `RPGLocation.BATTLE`. `main.gd` swaps in `scenes/rpg/battle/battle.tscn`.

The battle scene reads player stats from `RPGState` (max_hp, hp, attack, character_name) and writes damage back to `RPGState.hp` so HP carries over between battles. Enemy stats stay on the battle node as `@export` vars (`enemy_name`, `enemy_max_hp`, `enemy_atk_min/max`) — Phase 4's enemy variety mod will replace those defaults with per-encounter data.

End-of-battle states (`WIN`, `LOSE`, `ESCAPE`) display a message and wait for the player to press `ui_accept` (handled in `battle.gd`'s `_unhandled_input`) before calling `_finish_battle_and_return()`, which switches back to `rpg_battle_return_location`. On loss, HP is restored to max as a placeholder game-over until SaveSystem-backed checkpoints land.

**Toggling encounters for testing**: `rpg_overworld.gd` exposes `encounters_enabled` as an `@export bool` (default true). Flip it in the Inspector to disable encounters for a play session, or press **F4** at runtime to toggle on the fly (debug action `debug_toggle_encounters`). The stepper also auto-pauses while the dialogue box is open so conversations don't accidentally rack up steps.

## Debug Keys
| Key | Action | Action name |
|---|---|---|
| Tab | Toggle Real World ↔ RPG | `debug_toggle_world` |
| F1 / F2 / F3 | Set RPG tier to Gameboy / NES / SNES | `debug_tier_*` |
| F4 | Toggle random encounters on/off (overworld only) | `debug_toggle_encounters` |
| F5 | Open the Combat Sandbox (debug scene) | `debug_combat_sandbox` |

These will be removed once mods/UI control these states properly. Defined in `project.godot`'s `[input]` section.

## Communication Style
- The user is a novice — explain what you're doing and why in detail as you work.
- When writing code, explain the purpose of new scripts, functions, and patterns.
- When modifying existing code, explain what changed and how it fits into the bigger picture.
