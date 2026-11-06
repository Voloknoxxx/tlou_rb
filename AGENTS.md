# AGENTS.md

Repository-specific knowledge for the TLoU mechanics pack for Roblox.

## What this repo is

A self-contained Roblox mechanics pack recreating The Last of Us style
movement, gunplay, weapons and visuals. **No external assets** — no mesh
IDs, no asset IDs, no uploaded images, and **no uploaded animations**.
Every weapon model, effect, GUI element and *character animation* is
built in code so the pack works in any place the moment it is opened.

The place is an **R6** game rendered in **third person over the shoulder**,
with a fully procedural animator driving `Motor6D.Transform`.

## Layout

- `src/shared/`   → `ReplicatedStorage.TLoU.Shared` (Config, Weapons, WeaponModels,
  AnimationSystem, R6Rig, Net, Util)
- `src/server/`   → `ServerScriptService.TLoU.Server` (Bootstrap + Modules/)
- `src/client/`   → `StarterPlayerScripts.TLoU.Client` (Bootstrap + Controllers/)
- `default.project.json` → Rojo mapping for the tree above
- `generate_place.py` → emits `TLoUMechanics.rbxlx` (openable place file)
- `run_tests.py` → inlines the pure modules and runs them on the Luau CLI
- `TLoUMechanics.rbxlx` → generated, committed so the place opens with no tooling.
  Generated with R6 forced (`GameSettingsAvatar = 0`) and character appearance off.

## Build / verify commands

```bash
# Syntax check every Lua file (needs the Luau CLI at /tmp/luaubin)
for f in $(find src -name '*.lua'); do /tmp/luaubin/luau-compile --binary "$f" >/dev/null; done

# Run the unit/integration suite (888 assertions)
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
4. **Weapons live in the character's hand, not on the camera.** Third
   person means you must see your own weapon in the world exactly as
   others do. `WeaponController` welds the model to the character's
   `Right Arm`; `WeaponVisualController` does the same for *other* players
   from the `EquippedWeapon` attribute. Do not reintroduce a
   camera-parented viewmodel — it clips through walls and diverges from
   what everyone else sees.
5. **Animation writes `Motor6D.Transform`, never `C0`.** `Transform` is
   the non-replicated extra transform on top of `C0`/`C1`. Using it means
   every client poses every character independently, the rest pose is
   never lost, and the physics is untouched. Writing `C0` would replicate
   from the server, fight the client animator, and permanently deform the
   rig. See `R6Rig.applyPose` / `resetPose`.
6. **Animation must run on every client for every character.** Speed and
   turn rate are derived from each character's own parts (visible to all),
   and the richer state (stance, aiming, vaulting, downed, sprinting) is
   replicated as **attributes on the character**. Add a new state by
   adding an attribute, not a remote.
7. **The animator writes poses in `RunService.PreSimulation`.** The
   Animator rewrites every `Motor6D.Transform` between `PreAnimation` and
   `Stepped`, and the transform batch is applied right after `Stepped`.
   `Heartbeat` is `PostSimulation`, so a write there lands *after* the
   batch and is discarded before it is ever used: the character stays in
   its rest pose with no error and no warning. `PreSimulation` and
   `Stepped` both run in the right window. `run_tests.py` enforces this.
8. **The stock `Animate` script must be stopped on the client, not only
   the server.** `Animate` is a `LocalScript`, so it can start on a client
   before the server's `Destroy` replicates, and the `AnimationTrack`s it
   leaves behind outlive it. One playing track is enough to make the
   Animator rewrite every `Transform` each frame. `AnimatorController`
   therefore destroys `Animate` and stops playing tracks on every client,
   and `RigService` also watches `ChildAdded` because the script is
   parented a moment after the character spawns.
9. **R6 is enforced in three places.** The generated place sets the avatar
   type to R6; `RigService` converts any R15 body that slips through and
   disables the stock `Animate` script. `Config.Rig.ForceR6` is the switch.
10. **`HipHeight` stays 0 on R6.** Crouch and prone are *poses* (the
    animator lowers the torso), not physics. Raising `HipHeight` lifts the
    whole character off the floor.
11. **AutoRotate is off.** The camera controller drives the character's
    yaw. `Humanoid.AutoRotate` must stay `false` or the two fight.
12. **Regenerate the place after editing `src/`.** The place embeds a copy
    of every script. `run_tests.py` fails with `place copy differs from
    src/` if the two drift apart, so a fix can never be committed and
    silently missing from the place.
13. **Jump is rebound.** `MovementController` binds Space at high priority
   via `ContextActionService:BindActionAtPriority` so it can choose vault
   vs jump. Do not also handle Space in `UserInputService`.
14. **Health is custom.** Server keeps its own health table and gives the
   Humanoid a huge pool; death only happens through
   `CombatService.killPlayer`. Do not read `Humanoid.Health` for gameplay.

## Roblox gotchas hit while building this

- **`Motor6D.Transform` is a per-frame scratch value, not a place to
  store a pose.** The Animator overwrites it between `PreAnimation` and
  `Stepped`, and the batch that applies it runs right after `Stepped`.
  Write it in `PreSimulation` (or `Stepped`); a write in `Heartbeat` is
  discarded before it is used, with no error.
- **A `LocalScript` in the character can outlive the server's `Destroy`
  of it.** `Animate` starts on the client on its own schedule, so the
  client has to stop it too, and the `AnimationTrack`s it leaves behind
  keep the Animator busy even after the script is gone.
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

`run_tests.py` inlines `Config`, `Weapons`, `Util`, `Signal`,
`WeaponModels`, `AnimationSystem` and `R6Rig` into one generated file with
Roblox API stubs, then runs it. The stub `require` is patched so the
modules' `require(script.Parent.X)` resolves. If you add a module that
calls `require` at load time, extend the stub section accordingly.

The stubs carry **real maths**, not identity fallbacks: `CFrame` has a
working 3x3 matrix (`CFrame.fromEulerAnglesYXZ`, `fromAxisAngle`,
`ToEulerAnglesYXZ`, `*`), and `Instance` supports recursive
`FindFirstChild`, `BasePart` in `IsA`, and `Motor6D.Transform`. The
animation tests depend on this — a stub that always returns identity
would make every pose assertion vacuous.

The suite asserts data invariants, that every weapon model builds with a
Handle, a Muzzle, all parts welded and nothing collidable, the animation
pose maths (stride, turn-in-place stepping, stances, arm carry/aim), and
the R6 rig (joint layout, `Transform` application and reset). Add
assertions there when adding mechanics.

The `Enum` stub is **strict**: it is built from `tests/roblox_enums.json`,
which is generated from Roblox's API dump, and raises on an unknown type
or member. This matters because real Roblox raises too, and an error while
a module is loading kills the whole script that required it. That is how
`Enum.Material.Polymer` (not a real material) once took down the entire
client bootstrap: no camera, no weapons, no movement, only the map. Do not
relax the stub to return a value for any name.

After the Luau run, `run_tests.py` also runs three static guards over the
whole tree, not just the inlined modules:

- every `.lua` in `src/` compiles (the inlined run only covers a subset);
- every `Enum.X.Y` in `src/` must exist in the vendored enum table;
- `TLoUMechanics.rbxlx` must parse, keep every property inside
  `<Properties>`, and contain a `SpawnLocation`.

The place guard exists because the generator's `service()` helper takes
children as its third argument, so passing properties there silently
emits them *after* `</Properties>`. Roblox tolerates it by dropping the
property, which is invisible in Studio. Run `python3 generate_place.py`
before `run_tests.py` so the guard sees the current place.

`roblox_enums.json` is regenerated with:

```
curl -sL https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/roblox/API-Dump.json -o API-Dump.json
python3 - <<'PY'
import json
d = json.load(open("API-Dump.json"))
enums = {e["Name"]: {i["Name"]: i["Value"] for i in e["Items"]} for e in d["Enums"]}
json.dump(enums, open("tests/roblox_enums.json", "w"), separators=(",", ":"), sort_keys=True)
PY
```

## Style

- Luau with `--!strict` on all modules.
- Tabs for indentation in Lua files (matches Roblox convention).
- Comments explain *why* (an invariant, a workaround, a trade-off), not
  what the code plainly does. Keep them sparse.
- Section banners (`-- Firing ---`) separate logical blocks in long files.
