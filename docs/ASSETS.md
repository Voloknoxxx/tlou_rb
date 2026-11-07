# Assets

The game ships with **zero imported assets** - weapons are assembled from part
blueprints and every animation is generated procedurally at runtime. That keeps
the repo self-contained and lets you play it the moment you build it.

When you want higher-fidelity content, the scripts in `tools/blender` generate
drop-in replacements. They read the *same* numbers that the Luau uses, so the
silhouettes, origins and grip positions match exactly.

---

## Weapons

`tools/blender/build_weapons.py` builds each weapon from the blueprint in
`src/shared/WeaponData.luau`, adds a bevel so edges catch light, and exports one
mesh per part.

```bash
blender --background --python tools/blender/build_weapons.py
blender --background --python tools/blender/build_weapons.py -- --only AR15
blender --background --python tools/blender/build_weapons.py -- --out /tmp/w
```

Output lands in `build/weapons/<WeaponId>/` as both `.obj` and `.fbx`.

**Importing into Studio**

1. Open **Asset Manager** and use **Bulk Import**, or drag the files onto the
   viewport and use **MeshImporter**.
2. Keep the exported object names - they match the blueprint part names, which is
   what `WeaponBuilder` looks up.
3. Roblox wants one mesh per part, so import the parts individually rather than
   as a single merged mesh.
4. Swap the import in by editing `WeaponBuilder.makePart` to use a `MeshPart`
   with the imported `MeshId` instead of a `Part`, keyed by part name.

Units: **1 Blender unit = 1 Roblox stud.** The exporter is configured for that
(`FBX_SCALE_NONE`, no unit scaling), so imported meshes need no resizing.

---

## Animations

`tools/blender/build_animations.py` bakes the procedural clips into real Blender
actions on an R6 rig and exports them as FBX, for anyone who wants to hand-edit
the motion.

```bash
blender --background --python tools/blender/build_animations.py
blender --background --python tools/blender/build_animations.py -- --fps 30 --clip Walk
```

Output: `build/animations/<Clip>.fbx`, one file per clip.

The clip definitions in that script are a direct translation of
`src/shared/R6Pose.luau`. If you change one, change the other.

**Importing into Studio**

1. Open the **Animation Editor** on an R6 rig.
2. **Import from file** and pick the clip's FBX.
3. Publish the animation and note the asset id.
4. To use it at runtime instead of the procedural pose, load it into an
   `AnimationController` on the character and play it through the R6 `Animator`
   in place of the matching `R6Animator` clip.

Because the exported rig hierarchy uses Roblox's R6 naming (`Torso`,
`Left Arm`, ...), the clips bind straight onto a standard R6 character.

---

## Sound

`src/client/SoundController.luau` references Roblox sound asset ids that are
placeholders. Replace the `LIBRARY` table's ids with ones you own; every call
site keeps working, and playback is wrapped so a missing asset is silent rather
than fatal.
