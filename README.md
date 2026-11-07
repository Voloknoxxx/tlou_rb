# Last Stand

A stealth-survival prototype for Roblox, built around *The Last of Us* style
mechanics: quiet movement, hand-made animations, scavenged weapons, and infected
that hunt you by sight, sound and scent.

Everything in this repo is **code**. There are no uploaded animation assets and
no imported meshes - the R6 rig is animated procedurally at runtime, and the
weapons are assembled from part blueprints. That means you can clone the repo,
build it, and play immediately. If you later want hand-authored assets, the
Blender scripts in `tools/blender` produce drop-in replacements with identical
proportions.

---

## Quick start

```bash
# One-time: install Rojo
cargo install rojo        # or: aftman install

# Build the place file
rojo build default.project.json -o LastStand.rbxlx

# Open LastStand.rbxlx in Roblox Studio and press Play
```

Alternatively, use the Rojo Studio plugin: `rojo serve`, then **Connect** from
the plugin.

### Optional: syntax check without Studio

```bash
./tools/check.sh          # parses every .luau file with the standalone Luau CLI
```

The script downloads nothing; point `LUAU_BIN` at a `luau-analyze` binary if it
is not already at `/tmp/luaubin/luau-analyze`.

---

## Controls

| Action | Key |
| --- | --- |
| Move | `W` `A` `S` `D` |
| Sprint (drains stamina) | `Shift` |
| Jump / vault / mantle | `Space` |
| Crouch | `Ctrl` |
| Prone | `Z` |
| Aim | `F` |
| Fire | Left mouse |
| Reload | `R` |
| Melee (shove) | `V` |
| Interact (pick up, open) | `E` |
| Throw bottle (distraction) | `G` |
| Drop equipped item | `X` |
| Swap shoulder (camera) | `Q` |
| Equip inventory slot | `1` - `6` |

---

## What is implemented

### 1. Movement

* Smooth, momentum-driven locomotion. `Humanoid.WalkSpeed` is ramped toward its
  target rather than snapped, so starting and stopping has weight.
* **Procedural animation** on the R6 rig (see `src/shared/R6Pose.luau`). Idle
  breathing, walk/run cycles, crouch-walk, prone crawl, jump/fall/land, mantle,
  vault, reload, pickups, drawer/cabinet reaches, throw, shove and death are all
  computed from joint angles each frame and blended together.
* **Parkour.** Running into an obstacle below chest height triggers a *vault*;
  pressing jump near a higher ledge triggers a *mantle*. Both are predicted
  locally for responsiveness and reported to the server, which validates the
  destination and emits the noise the climb makes.
* **Stamina.** Sprinting and jumping drain it; it regenerates after a short
  delay. Hitting zero puts you in an exhausted state where sprinting is locked
  until you recover past a threshold.
* **Stances.** Stand / crouch / prone, each with its own speed, animation set,
  noise radius and visibility multiplier.

### 2. Weapons

* Five weapons defined in `src/shared/WeaponData.luau`: `M9` pistol, `.357`
  revolver, `AR-15` rifle, `Remington 870` shotgun and a throwable bottle.
* Each has per-shot **recoil** (camera kick that recovers), **spread bloom**
  that grows while firing and decays when you stop, damage falloff over range,
  headshot multiplier, distinct fire modes (semi / burst / automatic / pump) and
  a per-weapon reload style (magazine, shell-by-shell, cylinder).
* Weapons are **pickups**, not starting kit. They spawn on the ground and on
  shelves, and you pick them up with `E`.
* Held weapons are welded to the hand; the client also draws a view model for
  aiming. Both use the same builder, so the two never disagree about geometry.
* Higher-fidelity meshes: run `tools/blender/build_weapons.py` (see
  `docs/ASSETS.md`).

### 3. Interaction & stealth

* **Pickups with animation.** Reaching to the floor plays `PickupFloor`; taking
  something off a shelf plays `PickupShelf`. The loot spawns into the world after
  the reach animation reaches its grab point.
* **Containers.** Drawers slide open along their front axis; cabinets swing
  their doors on proper hinges. Both play a reach animation - the low drawer
  variant uses a different crouched pose. The server tween is matched by a
  client-side pose, and both emit noise.
* **Stealth model** (`src/shared/Stealth.luau`, shared by HUD and AI so both
  agree): crouching multiplies the time a zombie needs to notice you by `1.5`,
  going prone by `2.0`. Inside grass, sight and scent are effectively cut off
  unless the zombie is within `GrassNoticeRadius` studs.
* **Distraction.** Throwing a bottle (`G`) breaks it on impact, emitting a
  loud noise event that nearby infected investigate - the classic Clicker bait.

### 4. Zombie AI

Three kinds, all in `Config.Zombies.Kinds`:

| Kind | Senses | Behaviour |
| --- | --- | --- |
| **Walker** ("Infected") | sight cone + scent radius | Slow shambling patrol; locks on after a notice delay, then chases and swipes. |
| **Runner** | wide, long sight + scent | Fast and fragile. Closes distance quickly, low damage, short attack cooldown. |
| **Clicker** | **blind** - hearing only | Reacts to noise almost instantly, huge hearing radius, high damage. Navigates toward the last sound it heard. |

The AI is a small state machine (`Idle -> Investigate -> Chase -> Attack`)
driven by a shared `NoiseBus`. Zombies remember where they last sensed you for a
few seconds after losing you, investigate the last noise they heard, and have
stuck-detection that nudges them sideways when they wedge on geometry. Screams
attract other infected.

### 5. Camera & interface

* **Over-the-shoulder camera** with spring-arm collision so it never clips into
  walls. Pressing `Q` glides it to the other shoulder with an eased transition.
  Aiming tightens the FOV, pulls the camera in, and shifts the shoulder offset.
* **Minimalist HUD**: a crosshair whose gap tracks live weapon spread, a health
  bar, a stamina arc, an ammo block with a reserve count and reload state, an
  inventory strip, an interaction prompt, a stealth indicator (eye icon plus
  grass/concealment state), a damage vignette, hit markers and toast messages.
* **Positional audio** driven from gameplay signals (footsteps land on contact
  frames, gunshots match the muzzle flash) with a sound-group mix.

---

## Project layout

```
default.project.json          Rojo project definition
src/
  shared/                     runs on both sides
    Config.luau               every tunable in one place
    WeaponData.luau           weapon stats + part blueprints
    WeaponBuilder.luau        builds weapon models from blueprints
    R6Pose.luau               procedural pose library (all animation)
    R6Animator.luau           blends poses onto the rig's motors each frame
    Stealth.luau              shared visibility / noise maths
    Net.luau                  typed remote-event wrapper with validation
    Util.luau                 small maths + raycast helpers
  server/
    init.server.luau          bootstrap + player configuration
    WorldBuilder.luau         generates the level at runtime
    NoiseBus.luau             publish/subscribe for noise events
    StealthService.luau       authoritative per-player stealth state
    InventoryService.luau     inventory, equipping, held models
    InteractionService.luau   pickups, drawers, cabinets, loot
    CombatService.luau        fire / reload / melee / throw validation
    ZombieService.luau        AI, senses, spawning
  client/
    init.client.luau          bootstrap
    ClientState.luau          shared client-side state
    MovementController.luau   locomotion, stamina, parkour
    CameraController.luau     shoulder camera
    WeaponController.luau     firing, recoil, view model
    InteractionController.luau interaction prompts + animation requests
    HUDController.luau        the whole interface
    SoundController.luau      audio
tools/
  check.sh                    Luau syntax check
  blender/                    optional high-fidelity asset generation
```

---

## Tuning

Almost everything worth tweaking lives in `src/shared/Config.luau`:

* `Config.Movement` - speeds, acceleration, stamina costs, parkour reach.
* `Config.Stealth` - stance multipliers, grass concealment, noise radii.
* `Config.Zombies.Kinds` - per-kind health, speed, damage, senses, notice time.
* `Config.Camera` - distance, shoulder offset, swap timing, FOV, recoil.
* `Config.Items` - interaction ranges and open animations.
* `Config.World` - level size and population counts.

---

## Assets

See [`docs/ASSETS.md`](docs/ASSETS.md) for how to replace the procedural weapons
and animations with Blender-authored ones, and how to import them into Studio.

---

## Notes

* The game is designed for **R6** rigs; the animator assumes the standard R6
  motor names (`Left Shoulder`, `Right Hip`, ...).
* Server scripts validate every client request (fire rate, interaction range,
  equip slots, parkour destinations), so the client is never trusted for
  anything that matters.
