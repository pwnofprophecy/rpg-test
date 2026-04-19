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
Three singletons are registered in `project.godot`:
- **GameManager** — current world, progression flags, world-switching API (`switch_to_world`, `toggle_world`)
- **ModManager** — mod registry with `found` / `active` state, emits `mod_found` / `mod_activated` / `mod_deactivated` signals
- **SaveSystem** — save/load API (stub until Phase 2+)

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

## Communication Style
- The user is a novice — explain what you're doing and why in detail as you work.
- When writing code, explain the purpose of new scripts, functions, and patterns.
- When modifying existing code, explain what changed and how it fits into the bigger picture.
