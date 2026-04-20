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

## Autoloads
Four singletons are registered in `project.godot`:
- **GameManager** — current world, progression flags, world-switching API (`switch_to_world`, `toggle_world`)
- **ModManager** — mod registry with `found` / `active` state, emits `mod_found` / `mod_activated` / `mod_deactivated` signals
- **SaveSystem** — save/load API (stub; `save_game()` returns `true`, `load_game()` returns `false`. Real implementation lands after Phase 3.)
- **Aesthetic** — current RPG visual tier (Gameboy / NES / SNES), emits `tier_changed(new_tier)`. See "Aesthetic Tier System" below.

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

## Respecting the User's Scene Layouts
The user arranges objects, collision shapes, sprites, doorways, walls, and other scene-level nodes by hand in the Godot editor. These layouts are the user's creative/design decisions and must be preserved.
- **Do NOT move, resize, reposition, or reorganize** nodes in `.tscn` files the user has arranged, even if something looks "off" compared to an earlier version. That includes `position`, `offset_*`, `size`, `scale`, `rotation`, and the ordering/parenting of nodes.
- **Do NOT "restore" prior positions** from memory, plan files, or git history — if the user moved something, the new location is the canonical one.
- If a task genuinely requires moving something the user has placed (e.g. a new feature only works if a collision shape is resized), **stop and ask for permission first**, describing exactly what needs to move and why.
- Editing scripts, adding new nodes the user hasn't placed, changing `interaction_text` / `interaction_id` / other script-level properties, and fixing obvious bugs are all still fair game without asking.

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

## Pause Menu Pattern
`scenes/ui/pause_menu.tscn` is a shared CanvasLayer instanced in each world. Each world passes its own option list into `pause_menu.open([...])` and listens to `option_selected(id)`. Routing (what "Save" does, whether "Exit RPG" shows) is the caller's responsibility — the menu is just a presenter.

**Important**: the pause menu has `process_mode = PROCESS_MODE_ALWAYS` so it keeps running when the tree is paused. The RPG pauses the tree on open; the Real World disables the player's process mode instead. Both approaches work with the same menu.

`Escape` (bound to the `pause` input action) opens it. `Escape` or `Backspace` while open closes it.

## Communication Style
- The user is a novice — explain what you're doing and why in detail as you work.
- When writing code, explain the purpose of new scripts, functions, and patterns.
- When modifying existing code, explain what changed and how it fits into the bigger picture.
