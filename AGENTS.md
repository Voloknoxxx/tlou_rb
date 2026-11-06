# AGENTS.md

Repository-specific knowledge for the TLoU mechanics pack for Roblox.

## What this repo is

A self-contained Roblox mechanics pack recreating The Last of Us style
movement, gunplay, weapons and visuals. **No external assets** — no mesh
IDs, no asset IDs, no uploaded images. Every weapon model, arm, effect
and GUI element is built in code so the pack works in any place the
moment it is opened.

## Layout

- `src/shared/`   → `ReplicatedStorage.TLoU.Shared` (Config, Weapons, WeaponModels, Net, Util)
- `src/server/`   → `ServerScriptService.TLoU.Server` (Bootstrap + Modules/)
- `src/client/`   → `StarterPlayerScripts.TLoU.Client` (Bootstrap + Controllers/)
- `default.project.json` → Rojo mapping for the tree above
- `generate_place.py` → emits `TLoUMechanics.rbxlx` (openable place file)
- `run_tests.py` → inlines the pure modules and runs them on the Luau CLI
- `TLoUMechanics.rbxlx` → generated, committed so the place opens with no tooling

## Build / verify commands

```bash
# Syntax check every Lua file (needs the Luau CLI at /tmp/luaubin)
for f in $(find src -name '*.lua'); do /tmp/luaubin/luau-compile --binary "$f" >/dev/null; done

# Run the unit/integration suite (768 assertions)
python3 run_tests.py

# Rebuild the openable place file
python3 generate_place.py
```

Get the Luau CLI:

```bash
curl -L -o luau.zip https://github.com/luau-lang/luau/releases/latest/download/luau-ubuntu.zip
python3 -c "import zipfile; zipfile.ZipFile('luau.zip').extractall('/tmp/luaubin')"
chmod +x /tmp/luaubin/*
```

`unzip` is not installed in this container — use Python's `zipfile`.

## Architecture rules (do not break these)

1. **Client owns feel, server owns truth.** The client fires instantly and
   draws its own tracer/recoil; the server validates ammo, cooldown, and
   the raycast, then broadcasts `FireResult`. Never let the client decide
   damage or hits.
2. **Controllers never `require` each other at load time.** They share
   `State` and the `Signal` bus (recoil goes out on `State.Signals.Fired`
   and the camera listens). `WeaponController`, `NetworkController` and
   `HUDController` lazily `require` `EffectsController` *inside callbacks*,
   which is safe. Keep it that way to avoid require cycles.
3. **Weapons are data.** Adding a weapon is a `Weapons.lua` entry plus an
   id in `defaultLoadout()`. The model builder, HUD, ammo and poses are
   all driven from that table. Do not hardcode per-weapon branches in
   controllers.
4. **Viewmodel parenting.** The viewmodel is parented to the **Camera**
   (a child of Workspace) so welds simulate and it stays local-only. The
   root part is anchored and driven every frame from `camera.CFrame`.
   Do not parent it to the camera expecting welds to work — the Camera is
   not a physics container in the same way Workspace is; parenting to
   `workspace.CurrentCamera` is the pattern used here and it works because
   the Camera lives inside Workspace.
5. **AutoRotate is off.** The camera controller drives the character's
   yaw. `Humanoid.AutoRotate` must stay `false` or the two fight.
6. **Jump is rebound.** `MovementController` binds Space at high priority
   via `ContextActionService:BindActionAtPriority` so it can choose vault
   vs jump. Do not also handle Space in `UserInputService`.
7. **Health is custom.** Server keeps its own health table and gives the
   Humanoid a huge pool; death only happens through
   `CombatService.killPlayer`. Do not read `Humanoid.Health` for gameplay.

## Roblox gotchas hit while building this

- `Humanoid.MaxHealth = math.huge` is unreliable. Use a large finite
  number (1e6).
- Parts welded to an anchored part only follow it if they are inside
  Workspace (the Camera qualifies).
- `CanCollide = false` disables `Touched`, so thrown projectiles that
  need `Touched` must stay collidable.
- Destroying the whole `PlayerModule` kills WASD movement. Only disable
  `PlayerScripts.CameraScript`.
- `task.spawn` in a bare Luau environment does not forward varargs unless
  the stub does — the test harness stub must use `function(f, ...)`.
- The Luau CLI has no `io`/`readfile`; generate self-contained test files
  by inlining modules (see `run_tests.py`).

## Testing notes

`run_tests.py` inlines `Config`, `Weapons`, `Util`, `Signal` and
`WeaponModels` into one generated file with Roblox API stubs, then runs it.
The stub `require` is patched so `WeaponModels`'s
`require(script.Parent.Weapons)` resolves. If you add a module that calls
`require` at load time, extend the stub section accordingly.

The suite asserts data invariants and that every weapon model builds with
a Handle, a Muzzle, all parts welded, and nothing collidable. Add
assertions there when adding mechanics.

## Style

- Luau with `--!strict` on all modules.
- Tabs for indentation in Lua files (matches Roblox convention).
- Comments explain *why* (an invariant, a workaround, a trade-off), not
  what the code plainly does. Keep them sparse.
- Section banners (`-- Firing ---`) separate logical blocks in long files.
