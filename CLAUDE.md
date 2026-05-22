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
Enemies are defined as `EnemyStats` Resource `.tres` files in `res://resources/enemies/`. Each has the standard combat stats (max_hp, attack, defense, speed, intelligence, luck, base_power), `status_immunities: Array[String]`, plus reward fields (xp_reward, gold_reward) for future use.

`battle.gd` reads enemy roster from `GameManager.pending_battle_enemies` (an `Array` of `EnemyStats` Resources). Each entry spawns one enemy on screen, in array order, left-to-right. The combat sandbox sets this from its 4 slot dropdowns before launching the battle. Random encounters from the overworld leave the array empty, in which case `battle.gd` synthesizes a single-enemy fight from the `@export` defaults.

## Multi-Enemy Battles
A battle can host any number of enemies (sandbox lets you pick up to 4 via slot dropdowns). Per-enemy state lives in the `BattleEnemy` inner class on `battle.gd` — bundles the EnemyStats template, mutable runtime fields (hp, statuses, immunities) and refs to the on-screen widgets (sprite + HP bar VBox + status label + target indicator).

**Layout**: enemy sprites lay out in a horizontal row centered on `ENEMY_ROW_CENTER_X`, spaced evenly across `ENEMY_ROW_TOTAL_WIDTH`. Each enemy has its own HP bar VBox (name, bar, current/max text, status label, ▼ target indicator) anchored above its spawn position via `ENEMY_HP_BAR_OFFSET_Y`. The HP bar widgets live on the BattleUI CanvasLayer so they stay put during camera shake / lunges. Enemy sprites are smaller (`ENEMY_SPRITE_SCALE = 3,3` vs the original 4,4) and the player sprite was moved down to `(200, 470)` to make room above for HP bar widgets.

**Targeting**: after the player picks Attack, `BattleState.TARGET_SELECT` runs. Left/Right arrows cycle through living enemies, Enter confirms, Escape/Backspace cancels back to the action menu. The currently-targeted enemy gets a gold sprite tint plus a ▼ indicator floating above their HP bar. `_target_index` holds the current selection; `_run_player_attack` consumes it.

**Turn order**: player goes first, then each living enemy takes a turn in left-to-right order via `_run_enemy_turn` looping over `_enemies` and calling `_take_enemy_turn(be)`. Dead enemies are skipped. WIN triggers when `_all_enemies_defeated()` returns true; LOSE triggers immediately if `RPGState.hp` hits 0 mid-loop.

**Adding a new enemy template**: drop a `.tres` into `res://resources/enemies/`, fill in the EnemyStats fields. The combat sandbox auto-discovers it and populates all four slot dropdowns the next time it loads.

**Per-enemy sprites**: currently every enemy uses the same `enemy_placeholder.svg` texture defined as `ENEMY_TEXTURE` in `battle.gd`. Adding `@export var sprite: Texture2D` to `EnemyStats` and reading it in `_spawn_enemy_sprite` would make sprites per-enemy.

## Status Effect System
Status effects are stored as plain `String` tags so the system stays simple to extend.
- **Player statuses** live on `RPGState.status_effects: Array[String]`. Mutate via `add_status(name)` / `remove_status(name)` / `has_status(name)` / `clear_statuses()`. These helpers all emit `stats_changed` so listeners (battle UI, sandbox checkboxes) refresh automatically.
- **Enemy statuses** live per-enemy on each `BattleEnemy.statuses: Array[String]` instance (per-battle, not persisted). Seeded from `GameManager.pending_battle_enemy_statuses` on battle `_ready` so the sandbox can spawn pre-statused enemies. The pending list is applied to EVERY enemy in the roster (filtered through each enemy's individual immunities).

**Tick timing**: status effects fire at the START of a combatant's turn, before their action runs.
- Player: in `_on_action_selected`, after the action is chosen, before transitioning to TARGET_SELECT / SUB_MENU / ESCAPE. The `back` cancel doesn't burn a turn so it skips the tick.
- Enemy: at the top of each enemy's `_take_enemy_turn`, before their attack rolls. Multi-enemy fights tick each living enemy separately as their turn comes up.
- If a tick drops HP to 0, the turn ends immediately with WIN/LOSE — the action does not run.

**Currently implemented**:
- **Poisoned**: `max(1, floor(max_hp × 0.05))` damage per turn. Visual: green damage popup, HP bar drains, message "*Name* is hurt by poison!", ~1.2s read pause. See `STATUS_POISONED`, `POISON_PERCENT_DAMAGE`, `POISON_POPUP_COLOR` constants in `battle.gd`. Two tick variants exist: `_tick_poison_player()` and `_tick_poison_enemy(be)` — they share the formula but write to different state (RPGState vs BattleEnemy).

**Adding a new status effect**:
1. Add a `STATUS_<NAME>: String` const + tuning constants to `battle.gd`.
2. Add `_tick_<name>_player()` and `_tick_<name>_enemy(be)` helpers modeled on the poison pair.
3. Add a match arm to `_apply_status_tick` (player) and `_apply_status_tick_for_enemy` (enemy) routing the new status name to its tick helper.
4. Add the status name to `_KNOWN_STATUSES` in `combat_sandbox.gd` so it gets a sandbox toggle.
5. (Optional) Color the damage popup distinctly via `DamagePopup.spawn_status(parent, pos, damage, color)`.

The status display in battle is a small purple `[Status1, Status2]` label — under the player's HP bar (created in `battle_ui.gd::_ready`), and under each enemy's HP bar (created in `battle.gd::_spawn_enemy_hp_bar`). Updated via `battle_ui.set_player_statuses(list)` for the player and `_refresh_enemy_status_label(be)` for each enemy. Empty lists hide the label.

**Status immunities**: Both `EnemyStats` and `Equipment` have a `status_immunities: Array[String]` field.
- **Enemy immunities** are inherent and edited per-enemy in the `.tres` (Skeleton.tres → `["Poisoned"]`, e.g.). Each spawned `BattleEnemy` copies its immunities to `BattleEnemy.immunities` at spawn and filters incoming statuses through them.
- **Player immunities** come from equipped gear — `RPGState.get_status_immunities()` unions across all three slots. `RPGState.add_status()` checks immunities before applying and returns `bool` so callers can detect rejection. `RPGState.equip()` also calls `_purge_immunized_statuses()` so equipping an Antidote Ring while poisoned actually cures the poison — equipment grants both prevention AND cure.

The combat sandbox auto-bounces a status checkbox back to false when an immunity blocks the toggle (player or enemy side), and filters out incompatible statuses when switching enemies in the dropdown — so you always see what's actually going to apply.

## Magic System
Spells are MP-fueled abilities the Hero can cast in battle via the "Magic" action menu (formerly "Cast"). Each spell is a `Spell` Resource `.tres` file in `res://resources/spells/`, auto-discovered by `battle.gd` at battle start.

**`Spell` Resource shape** (`resources/spell.gd`):
- `spell_name`, `description`, `mp_cost`
- `effect_kind: EffectKind` enum (DAMAGE / HEAL_HP / CURE_STATUS — last two are reserved but not yet wired)
- `power: int` — bonus added onto Intelligence in the damage formula (same role weapon `power_bonus` plays for physical attacks)
- `status_name: String` — for future CURE_STATUS spells
- `popup_color: Color` — per-spell damage popup tint so each spell reads distinctly (Firebolt orange, future ice spells blue, etc.). Default white falls back to `MAGIC_DAMAGE_DEFAULT_COLOR` (magenta) in `battle.gd`.

**Damage formula for magic** — same shape as physical damage, just substitute Intelligence for Attack:
```
EffectiveAttack = Intelligence + spell.power
RawDamage = (2 × EffectiveAttack / D + 2) × Critical × Random
Damage = max(1, floor(RawDamage))
```
Crit still rolls off `luck × 1%`. Magic damage uses `RPGState.get_effective_intelligence()` so equipment intelligence bonuses apply.

**MP scaling**: Max MP is purely derived from Intelligence via the formula `intelligence × MP_PER_INT_LEVEL + equipment.mp_bonus`. The constant lives on `RPGState` and defaults to 2 (i.e. 2 MP per Intelligence point). The `max_mp` field is still present in `HeroStats` / `RPGState` but is no longer consulted by `get_effective_max_mp()` — it's left in the Resource shape in case a future class system wants a flat per-class MP cap on top of the Int scaling.

**Battle flow when player picks Magic**:
1. `_on_action_selected("magic")` → `MAGIC_SELECT` state
2. `battle_ui.show_magic_menu(_available_spells, RPGState.mp)` renders the list with MP costs; spells the player can't afford are visually dimmed
3. Player picks a spell:
   - **Insufficient MP**: rejected with "Not enough MP!" message; menu stays open
   - **Sufficient MP**: stashed as `_pending_spell` → `TARGET_SELECT` (cursor defaults per `effect_kind` — damage spells go to first living enemy, future heals would go to player)
4. Player confirms target → status tick → `_use_spell(spell, target_idx)`:
   - Pays MP up-front (even if effect is no-op like curing a non-existent status)
   - Runs effect via `_apply_spell_damage` for DAMAGE; reserved branches placeholder for HEAL_HP / CURE_STATUS
   - Plays popup + hit effect + camera shake; crits screen-flash like physical attacks
   - Transitions to ENEMY_TURN (or WIN/LOSE)

**Cancel routing**: cancelling TARGET_SELECT during spell targeting returns to MAGIC_SELECT (pick a different spell). Cancelling MAGIC_SELECT returns to PLAYER_MENU. Status tick has not fired yet at either cancel point, so backing out is free (matches the item flow).

**Adding a new spell**: drop a `.tres` into `res://resources/spells/`, fill in Inspector fields. Auto-discovered next battle. No code changes for DAMAGE spells; HEAL_HP / CURE_STATUS need a match arm in `_use_spell` before the placeholder message goes away.

**Sandbox Max MP display**: the sandbox doesn't have a Max MP SpinBox (since it's purely derived). Instead there's a read-only "Max MP (derived): N" Label under the editable stats that updates via `stats_changed` when Intelligence or equipment changes.

## Item System
Items are consumable resources the Hero carries in inventory. Each item is an `Item` Resource `.tres` file in `res://resources/items/`. The sandbox auto-discovers them like enemies and equipment.

**`Item` Resource shape** (`resources/item.gd`):
- `item_name`, `description`
- `effect_kind: EffectKind` enum (HEAL_HP / HEAL_MP / CURE_STATUS / DAMAGE_FIXED)
- `amount: int` — used by HEAL_HP, HEAL_MP, DAMAGE_FIXED
- `status_name: String` — used by CURE_STATUS

**No target field on the Resource.** Every item goes through target selection, and the *default* cursor placement is inferred from `effect_kind`:
- HEAL_*, CURE_STATUS → defaults to the player
- DAMAGE_FIXED → defaults to the first living enemy

The player can override the default before confirming, so beneficial items can be aimed at enemies and vice versa (future-proofing for mechanics like "cure the enemy's Berserk to weaken them"). Currently both directions just resolve mechanically — the AI doesn't know to refuse a heal.

**Inventory on `RPGState`**:
- `inventory: Dictionary` — keyed by Item Resource, value = int quantity
- Mutate via `add_to_inventory(item, qty)`, `remove_from_inventory(item, qty)`, `set_inventory_count(item, count)` (set 0 to erase the entry)
- Read with `get_inventory_count(item)` and `has_any_items()` for "is empty?" checks
- Reset to Defaults clears inventory along with name/stats/equipment

**Battle flow when player picks Item**:
1. `_on_action_selected("item")` → status tick (once per turn) → `ITEM_SELECT` state
2. `battle_ui.show_item_menu(RPGState.inventory)` renders a list with current counts; mouse hover / click and arrow-key / Enter both work
3. Player picks an item → `_pending_item` is stashed → `TARGET_SELECT` (cursor defaults per effect_kind)
4. Player confirms target → `_use_item(item, target_idx)` runs the effect, decrements inventory, plays popup + drain, transitions to ENEMY_TURN

**Target index encoding**: `_target_index = -1` (the constant `TARGET_INDEX_PLAYER`) means the player, `0..N-1` means `_enemies[i]`. `_valid_targets()` returns living enemies, plus the player when an item is pending. Regular attacks (no pending item) exclude the player from the cycle.

**Cancel routing**: cancelling TARGET_SELECT during item targeting returns to ITEM_SELECT (pick a different item) rather than all the way back to PLAYER_MENU. Cancelling ITEM_SELECT goes back to the action menu. Status tick stays applied across cancels — `_player_ticked_this_turn` ensures it only fires once per turn, no matter how many sub-menus the player bounces through.

**Damage popups** for items use distinct colors so the effect type reads at a glance: green for HEAL_HP, blue for HEAL_MP, orange for DAMAGE_FIXED. (Normal attack damage stays white; crits stay gold; poison ticks stay green-yellow.)

**Adding a new item**: drop a `.tres` into `res://resources/items/`, fill in the Inspector fields. The combat sandbox auto-discovers it next time it loads — a SpinBox appears in the Inventory section. No code changes.

**Adding a new effect kind**: add an entry to `Item.EffectKind`, add a match arm in `battle.gd::_use_item`, and (optionally) define a new popup color constant in `battle.gd`. The default-target-for-item lookup also needs a match arm if the new effect's default target isn't the player.

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
