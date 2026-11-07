#!/usr/bin/env python3
"""
build_weapons.py
================================================================================
Generates high-fidelity weapon meshes in Blender that match the proportions
defined in src/shared/WeaponData.luau, then exports them for Roblox.

Why this exists
---------------
The game runs out of the box with the procedural Roblox-built weapons in
WeaponBuilder.luau. This script is the upgrade path: it produces proper
bevelled, subdivided meshes with the exact same silhouette and origin, so
swapping them in does not change the gameplay feel at all.

Usage
-----
    # Headless, all weapons, OBJ + FBX into build/weapons/
    blender --background --python tools/blender/build_weapons.py

    # Just one weapon
    blender --background --python tools/blender/build_weapons.py -- --only AR15

    # Different output directory
    blender --background --python tools/blender/build_weapons.py -- --out /tmp/w

Importing into Roblox
---------------------
Roblox wants one mesh per part, not a whole model, so each blueprint part is
exported as its own object. In Studio use MeshImporter (or the Asset Manager's
"Bulk Import") and keep the object names - they match the blueprint part names,
which is what WeaponBuilder looks up.

Units: 1 Blender unit == 1 Roblox stud. Export with "Apply Unit Scale" off.
"""

import math
import os
import sys

try:
    import bpy
    import bmesh
    from mathutils import Vector, Euler
except ImportError:  # pragma: no cover - only runs inside Blender
    print("This script must be run inside Blender (bpy not found).")
    sys.exit(1)


# ---------------------------------------------------------------------------
# Weapon blueprints. Keep these in sync with WeaponData.luau: the numbers are
# identical on purpose so the Blender asset is a drop-in replacement.
#
# Each entry: name -> (size, offset, rotation_degrees, shape, colour)
#   size      (x, y, z) in studs, matching Part.Size
#   offset    (x, y, z) position in the weapon's local space
#   rotation  (rx, ry, rz) in degrees
#   shape     "box" | "cylinder"
#   colour    (r, g, b) 0..1
# ---------------------------------------------------------------------------

STEEL = (0.17, 0.18, 0.20)
DARK = (0.10, 0.11, 0.12)
WOOD = (0.31, 0.22, 0.15)
TAN = (0.40, 0.34, 0.24)
GREEN = (0.31, 0.42, 0.36)
BRASS = (0.62, 0.50, 0.22)


def blueprint_pistol():
    return {
        "Frame": ((0.34, 0.9, 2.2), (0, 0.35, -0.7), (0, 0, 0), "box", STEEL),
        "Slide": ((0.32, 0.34, 2.3), (0, 0.86, -0.72), (0, 0, 0), "box", STEEL),
        "Barrel": ((0.2, 0.2, 0.7), (0, 0.72, -2.0), (0, 90, 0), "cylinder", DARK),
        "Grip": ((0.3, 1.15, 0.42), (0, -0.45, 0.32), (-12, 0, 0), "box", STEEL),
        "Trigger": ((0.16, 0.34, 0.16), (0, -0.02, 0.16), (0, 0, 0), "box", DARK),
        "TriggerGuard": ((0.18, 0.12, 0.7), (0, -0.2, -0.06), (0, 0, 0), "box", DARK),
        "Magazine": ((0.26, 1.0, 0.5), (0, -0.42, 0.18), (0, 0, 0), "box", DARK),
        "SightRear": ((0.3, 0.16, 0.12), (0, 1.06, 0.1), (0, 0, 0), "box", DARK),
        "SightFront": ((0.12, 0.18, 0.1), (0, 1.08, -1.72), (0, 0, 0), "box", DARK),
    }


def blueprint_revolver():
    return {
        "Frame": ((0.36, 1.0, 2.4), (0, 0.3, -0.6), (0, 0, 0), "box", STEEL),
        "Barrel": ((0.28, 0.28, 2.6), (0, 0.66, -1.7), (0, 90, 0), "cylinder", STEEL),
        "BarrelRib": ((0.18, 0.16, 2.6), (0, 0.98, -1.7), (0, 0, 0), "box", DARK),
        "Cylinder": ((0.62, 0.62, 0.9), (0, 0.34, -0.15), (0, 90, 0), "cylinder", DARK),
        "Grip": ((0.34, 1.35, 0.5), (0, -0.55, 0.55), (-22, 0, 0), "box", WOOD),
        "Trigger": ((0.16, 0.34, 0.16), (0, -0.16, 0.18), (0, 0, 0), "box", STEEL),
        "TriggerGuard": ((0.18, 0.12, 0.7), (0, -0.34, -0.04), (0, 0, 0), "box", STEEL),
        "Hammer": ((0.16, 0.34, 0.2), (0, 0.78, 0.42), (18, 0, 0), "box", DARK),
        "SightRear": ((0.32, 0.16, 0.12), (0, 1.06, 0.4), (0, 0, 0), "box", DARK),
        "SightFront": ((0.1, 0.2, 0.1), (0, 1.1, -2.85), (0, 0, 0), "box", DARK),
    }


def blueprint_rifle():
    return {
        "Receiver": ((0.42, 1.0, 3.2), (0, 0.4, -1.0), (0, 0, 0), "box", STEEL),
        "Upper": ((0.36, 0.3, 3.2), (0, 0.98, -1.0), (0, 0, 0), "box", STEEL),
        "Barrel": ((0.22, 0.22, 3.6), (0, 0.62, -4.1), (0, 90, 0), "cylinder", DARK),
        "Handguard": ((0.44, 0.5, 2.0), (0, 0.5, -3.0), (0, 0, 0), "box", TAN),
        "Stock": ((0.4, 0.85, 2.0), (0, 0.3, 1.5), (-4, 0, 0), "box", STEEL),
        "StockTube": ((0.3, 0.3, 0.9), (0, 0.42, 0.9), (0, 90, 0), "cylinder", TAN),
        "Grip": ((0.32, 1.1, 0.44), (0, -0.3, 0.35), (-14, 0, 0), "box", STEEL),
        "Trigger": ((0.16, 0.32, 0.16), (0, 0.02, 0.2), (0, 0, 0), "box", DARK),
        "TriggerGuard": ((0.2, 0.12, 0.75), (0, -0.16, -0.02), (0, 0, 0), "box", DARK),
        "Magazine": ((0.34, 1.5, 0.8), (0, -0.6, -0.85), (6, 0, 0), "box", TAN),
        "Scope": ((0.36, 0.36, 1.6), (0, 1.35, -1.2), (0, 90, 0), "cylinder", STEEL),
        "ScopeMount": ((0.16, 0.3, 0.3), (0, 1.16, -0.7), (0, 0, 0), "box", DARK),
        "ChargingHandle": ((0.5, 0.14, 0.24), (0.28, 1.06, 0.35), (0, 0, 0), "box", DARK),
        "Muzzle": ((0.3, 0.3, 0.5), (0, 0.62, -5.9), (0, 90, 0), "cylinder", DARK),
    }


def blueprint_shotgun():
    return {
        "Receiver": ((0.5, 1.05, 2.6), (0, 0.35, -0.7), (0, 0, 0), "box", STEEL),
        "Barrel": ((0.3, 0.3, 5.0), (0, 0.72, -3.4), (0, 90, 0), "cylinder", STEEL),
        "MagTube": ((0.26, 0.26, 4.2), (0, 0.3, -3.0), (0, 90, 0), "cylinder", DARK),
        "Pump": ((0.46, 0.6, 1.5), (0, 0.35, -2.6), (0, 0, 0), "box", WOOD),
        "Stock": ((0.42, 0.95, 2.2), (0, 0.22, 1.6), (-6, 0, 0), "box", WOOD),
        "Grip": ((0.34, 1.15, 0.5), (0, -0.4, 0.3), (-16, 0, 0), "box", WOOD),
        "Trigger": ((0.16, 0.32, 0.16), (0, -0.06, 0.16), (0, 0, 0), "box", DARK),
        "TriggerGuard": ((0.22, 0.12, 0.8), (0, -0.24, -0.06), (0, 0, 0), "box", DARK),
        "ShellHolder": ((0.22, 0.7, 0.5), (0.32, 0.05, 0.5), (0, 0, 8), "box", TAN),
        "Bead": ((0.1, 0.14, 0.1), (0, 0.94, -5.7), (0, 0, 0), "box", BRASS),
    }


def blueprint_bottle():
    return {
        "Body": ((0.7, 1.6, 0.7), (0, 0, 0), (0, 90, 0), "cylinder", GREEN),
        "Neck": ((0.34, 0.8, 0.34), (0, 1.05, 0), (0, 90, 0), "cylinder", GREEN),
        "Cap": ((0.38, 0.24, 0.38), (0, 1.55, 0), (0, 90, 0), "cylinder", BRASS),
    }


WEAPONS = {
    "M9": blueprint_pistol,
    "Python": blueprint_revolver,
    "AR15": blueprint_rifle,
    "Remington": blueprint_shotgun,
    "Bottle": blueprint_bottle,
}

# How much to bevel/round each part. Weapons look like cheap blocks without it.
BEVEL_WIDTH = 0.045
BEVEL_SEGMENTS = 2


def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for block in (bpy.data.meshes, bpy.data.materials, bpy.data.objects):
        for item in list(block):
            block.remove(item)


def make_material(name, colour, metallic=0.85, roughness=0.45):
    mat = bpy.data.materials.get(name)
    if mat:
        return mat
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        bsdf.inputs["Base Color"].default_value = (colour[0], colour[1], colour[2], 1.0)
        bsdf.inputs["Metallic"].default_value = metallic
        bsdf.inputs["Roughness"].default_value = roughness
    return mat


def add_box(name, size, offset, rotation, material):
    bpy.ops.mesh.primitive_cube_add(size=1.0)
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = (size[0], size[1], size[2])
    obj.rotation_euler = Euler([math.radians(a) for a in rotation], "XYZ")
    obj.location = Vector(offset)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    obj.data.materials.append(material)
    return obj


def add_cylinder(name, size, offset, rotation, material):
    # Roblox cylinder parts are a cylinder along local X whose "size" is
    # (length, diameter, diameter).
    length, diameter = size[0], size[1]
    bpy.ops.mesh.primitive_cylinder_add(vertices=24, radius=diameter / 2.0, depth=length)
    obj = bpy.context.active_object
    obj.name = name
    # Blender cylinders are along Z; rotate to X before applying the blueprint
    # rotation so the two conventions line up.
    obj.rotation_euler = Euler((0, math.radians(90), 0), "XYZ")
    obj.rotation_euler = Euler([math.radians(a) for a in rotation], "XYZ")
    obj.location = Vector(offset)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    obj.data.materials.append(material)
    return obj


def bevel(obj):
    """Adds a small bevel so edges catch light like real metal."""
    modifier = obj.modifiers.new(name="Bevel", type="BEVEL")
    modifier.width = BEVEL_WIDTH
    modifier.segments = BEVEL_SEGMENTS
    modifier.limit_method = "ANGLE"
    modifier.angle_limit = math.radians(30)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=modifier.name)


def build_weapon(weapon_id, out_dir):
    print(f"[build_weapons] building {weapon_id}")
    clear_scene()
    blueprint = WEAPONS[weapon_id]()

    collection = bpy.data.collections.new(weapon_id)
    bpy.context.scene.collection.children.link(collection)

    for part_name, (size, offset, rotation, shape, colour) in blueprint.items():
        material = make_material(f"{weapon_id}_{part_name}_mat", colour)
        if shape == "cylinder":
            obj = add_cylinder(part_name, size, offset, rotation, material)
        else:
            obj = add_box(part_name, size, offset, rotation, material)
        bevel(obj)
        # Move into the weapon's collection.
        for coll in list(obj.users_collection):
            coll.objects.unlink(obj)
        collection.objects.link(obj)

    export_dir = os.path.join(out_dir, weapon_id)
    os.makedirs(export_dir, exist_ok=True)

    # OBJ keeps the per-part names, which is what Roblox mesh import keys off.
    obj_path = os.path.join(export_dir, f"{weapon_id}.obj")
    bpy.ops.object.select_all(action="DESELECT")
    for obj in collection.objects:
        obj.select_set(True)
    bpy.ops.wm.obj_export(
        filepath=obj_path,
        export_selected_objects=True,
        apply_modifiers=True,
        export_materials=True,
        forward_axis="Y",
        up_axis="Z",
    )

    # FBX as an alternative for people who prefer it.
    fbx_path = os.path.join(export_dir, f"{weapon_id}.fbx")
    try:
        bpy.ops.export_scene.fbx(
            filepath=fbx_path,
            use_selection=True,
            apply_scale_options="FBX_SCALE_NONE",
            object_types={"MESH"},
        )
    except Exception as exc:  # pragma: no cover
        print(f"[build_weapons] FBX export skipped for {weapon_id}: {exc}")

    print(f"[build_weapons]   -> {obj_path}")


def parse_args():
    argv = sys.argv
    if "--" in argv:
        argv = argv[argv.index("--") + 1:]
    else:
        argv = []
    out_dir = os.path.join(os.getcwd(), "build", "weapons")
    only = None
    i = 0
    while i < len(argv):
        if argv[i] == "--out" and i + 1 < len(argv):
            out_dir = argv[i + 1]
            i += 2
        elif argv[i] == "--only" and i + 1 < len(argv):
            only = argv[i + 1]
            i += 2
        else:
            i += 1
    return out_dir, only


def main():
    out_dir, only = parse_args()
    os.makedirs(out_dir, exist_ok=True)
    targets = [only] if only else list(WEAPONS.keys())
    for weapon_id in targets:
        if weapon_id not in WEAPONS:
            print(f"[build_weapons] unknown weapon '{weapon_id}'")
            continue
        build_weapon(weapon_id, out_dir)
    print(f"[build_weapons] done -> {out_dir}")


if __name__ == "__main__":
    main()
