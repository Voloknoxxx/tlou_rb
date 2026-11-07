#!/usr/bin/env python3
"""
build_animations.py
================================================================================
Bakes the game's procedural animation clips into real Blender actions and
exports them as FBX, for anyone who wants hand-editable animation assets.

Why this exists
---------------
The shipped game animates entirely in code (see src/shared/R6Pose.luau), which
is what lets it run with zero uploaded assets. If you would rather author or
tweak the animations in Blender, this script gives you a starting point that is
pixel-identical to the in-game motion: it evaluates the same pose maths and
writes the result as keyframes on a real R6 rig.

The clip definitions below are the Python translation of R6Pose.luau. If you
change one, change the other - or better, treat this as the "export my
procedural animation to FBX" tool and re-run it after editing the Luau.

Usage
-----
    blender --background --python tools/blender/build_animations.py
    blender --background --python tools/blender/build_animations.py -- --fps 30 --clip Walk

Output
------
    build/animations/<Clip>.fbx      one file per clip, 24 fps by default

Roblox import
-------------
Import the FBX as an Animation (Animation Editor -> Import from file). The rig
hierarchy matches Roblox's R6 naming (Torso, Left Arm, ...), so the clips bind
straight onto a standard R6 character.
"""

import math
import os
import sys

try:
    import bpy
    from mathutils import Euler, Vector
except ImportError:  # pragma: no cover
    print("This script must be run inside Blender (bpy not found).")
    sys.exit(1)


# ---------------------------------------------------------------------------
# R6 rig description. (name, size, parent, joint_offset_from_parent)
# ---------------------------------------------------------------------------
R6_PARTS = [
    ("HumanoidRootPart", (2.0, 2.0, 1.0), None, (0.0, 0.0, 0.0)),
    ("Torso", (2.0, 2.0, 1.0), "HumanoidRootPart", (0.0, 0.0, 0.0)),
    ("Head", (2.0, 1.0, 1.0), "Torso", (0.0, 1.5, 0.0)),
    ("Left Arm", (1.0, 2.0, 1.0), "Torso", (-1.5, 0.0, 0.0)),
    ("Right Arm", (1.0, 2.0, 1.0), "Torso", (1.5, 0.0, 0.0)),
    ("Left Leg", (1.0, 2.0, 1.0), "Torso", (-0.5, -2.0, 0.0)),
    ("Right Leg", (1.0, 2.0, 1.0), "Torso", (0.5, -2.0, 0.0)),
]

JOINTS = [p[0] for p in R6_PARTS]

DEFAULT_FPS = 24


# ---------------------------------------------------------------------------
# Pose maths - a direct translation of the axis conventions in R6Pose.luau:
#   rx > 0  swings the limb forward
#   rz > 0  abducts a right-side limb outward
# Each clip returns {joint: (rx_degrees, ry_degrees, rz_degrees)}.
# ---------------------------------------------------------------------------

def _zero():
    return {j: [0.0, 0.0, 0.0] for j in JOINTS}


def clip_idle(t, _rate=1.0):
    pose = _zero()
    breath = math.sin(t * 1.7)
    sway = math.sin(t * 0.9)
    look = math.sin(t * 0.37)
    pose["Torso"] = [-2 + breath * 1.1, sway * 1.6, sway * 0.9]
    pose["Head"] = [2 - breath * 0.8, look * 9, sway * -1.2]
    pose["Left Arm"] = [-4 + breath * 1.4, 0, -3 - abs(sway) * 1.6]
    pose["Right Arm"] = [-4 + breath * 1.4, 0, 3 + abs(sway) * 1.6]
    pose["Left Leg"] = [1, 0, -1]
    pose["Right Leg"] = [-1, 0, 1]
    return pose


def clip_locomotion(t, rate=1.0, intensity=0.7):
    pose = _zero()
    phase = t * rate * math.pi * 2
    i = max(0.0, min(1.0, intensity))
    leg_swing = 22 + 30 * i
    arm_swing = 16 + 34 * i
    lean = 3 + 9 * i
    left = math.sin(phase)
    right = math.sin(phase + math.pi)
    left_fold = max(0.0, -left) * (8 + 10 * i)
    right_fold = max(0.0, -right) * (8 + 10 * i)
    pose["Torso"] = [lean + abs(left) * 1.5, left * 4 * i, left * 2 * i]
    pose["Head"] = [-lean * 0.6 + math.sin(phase * 2) * 1.2, -left * 5 * i, 0]
    pose["Left Arm"] = [-arm_swing * left - 4, 0, -6 - 4 * i]
    pose["Right Arm"] = [-arm_swing * right - 4, 0, 6 + 4 * i]
    pose["Left Leg"] = [leg_swing * left + left_fold, 0, -2 - 2 * i]
    pose["Right Leg"] = [leg_swing * right + right_fold, 0, 2 + 2 * i]
    return pose


def clip_crouch_locomotion(t, rate=1.0):
    pose = _zero()
    phase = t * rate * math.pi * 2
    left = math.sin(phase)
    right = math.sin(phase + math.pi)
    pose["Torso"] = [17 + abs(left) * 2, left * 5, left * 2.5]
    pose["Head"] = [-15, -left * 6, 0]
    pose["Left Arm"] = [24 - 12 * left, 0, -8]
    pose["Right Arm"] = [22 - 12 * right, 0, 8]
    pose["Left Leg"] = [-16 + 20 * left, 0, -4]
    pose["Right Leg"] = [-16 + 20 * right, 0, 4]
    return pose


def clip_prone_crawl(t, rate=1.0):
    pose = _zero()
    phase = t * rate * math.pi * 2
    left = math.sin(phase)
    right = math.sin(phase + math.pi)
    pose["Torso"] = [-90 + abs(left) * 2.5, left * 4, 0]
    pose["Head"] = [48, -left * 8, 0]
    pose["Left Arm"] = [-62 + 18 * left, 0, -14 - 6 * left]
    pose["Right Arm"] = [-58 + 18 * right, 0, 14 + 6 * right]
    pose["Left Leg"] = [6 - 10 * right, 0, -4]
    pose["Right Leg"] = [4 - 10 * left, 0, 4]
    return pose


def _one_shot(fn):
    """Wraps an alpha-driven clip as a fixed-length sampler."""
    def sampler(t, _rate=1.0):
        alpha = max(0.0, min(1.0, t))
        return fn(alpha)
    return sampler


@_one_shot
def clip_mantle(alpha):
    pose = _zero()
    reach = max(0.0, min(1.0, alpha / 0.4))
    pull = max(0.0, min(1.0, (alpha - 0.4) / 0.35))
    step = max(0.0, min(1.0, (alpha - 0.75) / 0.25))
    crouch = math.sin(pull * math.pi) * 0.9 + (1 - step) * 0.4
    pose["Torso"] = [4 + reach * 26 - step * 10, 0, 0]
    pose["Head"] = [-6 - reach * 18 + step * 20, 0, 0]
    pose["Left Arm"] = [-30 - reach * 120 + pull * 40, 0, -14 - reach * 6]
    pose["Right Arm"] = [-30 - reach * 120 + pull * 40, 0, 14 + reach * 6]
    pose["Left Leg"] = [-6 + pull * 70 - step * 60 + crouch * 12, 0, -6]
    pose["Right Leg"] = [-10 + pull * 30 - step * 20, 0, 6]
    return pose


@_one_shot
def clip_vault(alpha):
    pose = _zero()
    plant = math.sin(max(0.0, min(1.0, alpha)) * math.pi)
    tuck = math.sin(alpha * math.pi * 0.8)
    pose["Torso"] = [20 + plant * 34, 0, 0]
    pose["Head"] = [-14 - plant * 6, 0, 0]
    pose["Left Arm"] = [-50 - plant * 70, 0, -20]
    pose["Right Arm"] = [-50 - plant * 70, 0, 20]
    pose["Left Leg"] = [20 + tuck * 70, 0, -14]
    pose["Right Leg"] = [-10 - tuck * 50, 0, 14]
    return pose


@_one_shot
def clip_reload(alpha):
    pose = _zero()
    dip = math.sin(max(0.0, min(1.0, alpha)) * math.pi)
    insert = max(0.0, min(1.0, (alpha - 0.45) / 0.35))
    tap = math.sin(max(0.0, min(1.0, (alpha - 0.82) / 0.18)) * math.pi) * 8
    pose["Torso"] = [6 * dip, 6 * dip, 0]
    pose["Head"] = [10 * dip, -8 * dip, 0]
    pose["Left Arm"] = [-92 + dip * 18 - insert * 12 - tap, 0, -24 - dip * 8]
    pose["Right Arm"] = [-62 + dip * 16 - insert * 8, 0, 12 + dip * 6]
    return pose


@_one_shot
def clip_pickup_floor(alpha):
    pose = _zero()
    reach = math.sin(max(0.0, min(1.0, alpha)) * math.pi * 0.9)
    pose["Torso"] = [reach * 62, -reach * 10, 0]
    pose["Head"] = [-reach * 18, reach * 6, 0]
    pose["Left Arm"] = [-reach * 20, 0, -6]
    pose["Right Arm"] = [-reach * 105, 0, 12 - reach * 6]
    pose["Left Leg"] = [-reach * 24, 0, -6]
    pose["Right Leg"] = [-reach * 30, 0, 6]
    return pose


@_one_shot
def clip_death(alpha):
    pose = _zero()
    a0 = max(0.0, min(1.0, alpha))
    sag = math.sin(a0 * math.pi * 0.5)
    pose["Torso"] = [-sag * 88, sag * 12, sag * 6]
    pose["Head"] = [sag * 34, 0, sag * 10]
    pose["Left Arm"] = [sag * 70, 0, -sag * 30]
    pose["Right Arm"] = [sag * 62, 0, sag * 26]
    pose["Left Leg"] = [sag * 40, 0, -sag * 10]
    pose["Right Leg"] = [sag * 28, 0, sag * 10]
    return pose


# name -> (sampler, duration_seconds, loop)
CLIPS = {
    "Idle": (lambda t, r=1.0: clip_idle(t, r), 4.0, True),
    "Walk": (lambda t, r=1.0: clip_locomotion(t, r, 0.35), 1.0, True),
    "Run": (lambda t, r=1.0: clip_locomotion(t, r, 1.0), 0.75, True),
    "CrouchWalk": (clip_crouch_locomotion, 1.2, True),
    "ProneCrawl": (clip_prone_crawl, 1.4, True),
    "Mantle": (clip_mantle, 0.55, False),
    "Vault": (clip_vault, 0.42, False),
    "Reload": (clip_reload, 2.3, False),
    "PickupFloor": (clip_pickup_floor, 0.85, False),
    "Death": (clip_death, 1.4, False),
}


# ---------------------------------------------------------------------------
# Blender plumbing
# ---------------------------------------------------------------------------

def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for block in (bpy.data.meshes, bpy.data.armatures, bpy.data.actions, bpy.data.objects):
        for item in list(block):
            block.remove(item)


def build_rig():
    """Creates the R6 part hierarchy as plain objects parented in a chain."""
    objects = {}
    for name, size, parent, offset in R6_PARTS:
        bpy.ops.mesh.primitive_cube_add(size=1.0)
        obj = bpy.context.active_object
        obj.name = name
        obj.scale = size
        bpy.ops.object.transform_apply(scale=True)
        objects[name] = obj
    for name, _size, parent, offset in R6_PARTS:
        if parent:
            obj = objects[name]
            obj.parent = objects[parent]
            obj.location = Vector(offset)
    return objects


def bake_clip(objects, clip_name, sampler, duration, fps):
    """Samples a clip every frame and writes rotation keyframes."""
    frame_count = max(2, int(round(duration * fps)))
    bpy.context.scene.frame_start = 1
    bpy.context.scene.frame_end = frame_count

    action = bpy.data.actions.new(clip_name)
    for name in JOINTS:
        obj = objects.get(name)
        if not obj:
            continue
        obj.animation_data_create()
        obj.animation_data.action = action

    for frame in range(1, frame_count + 1):
        t = (frame - 1) / fps
        pose = sampler(t)
        bpy.context.scene.frame_set(frame)
        for joint, (rx, ry, rz) in pose.items():
            obj = objects.get(joint)
            if not obj:
                continue
            obj.rotation_mode = "XYZ"
            obj.rotation_euler = Euler((math.radians(rx), math.radians(ry), math.radians(rz)), "XYZ")
            obj.keyframe_insert(data_path="rotation_euler", frame=frame)
    return action


def export_fbx(objects, path):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects.values():
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects.get("Torso")
    bpy.ops.export_scene.fbx(
        filepath=path,
        use_selection=True,
        apply_scale_options="FBX_SCALE_NONE",
        object_types={"MESH", "EMPTY"},
        bake_anim=True,
        bake_anim_use_all_bones=False,
        bake_anim_use_nla_strips=False,
        bake_anim_use_all_actions=True,
        bake_anim_simplify_factor=0.0,
    )


def parse_args():
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []
    out_dir = os.path.join(os.getcwd(), "build", "animations")
    fps = DEFAULT_FPS
    only = None
    i = 0
    while i < len(argv):
        if argv[i] == "--out" and i + 1 < len(argv):
            out_dir = argv[i + 1]
            i += 2
        elif argv[i] == "--fps" and i + 1 < len(argv):
            fps = int(argv[i + 1])
            i += 2
        elif argv[i] == "--clip" and i + 1 < len(argv):
            only = argv[i + 1]
            i += 2
        else:
            i += 1
    return out_dir, fps, only


def main():
    out_dir, fps, only = parse_args()
    os.makedirs(out_dir, exist_ok=True)
    bpy.context.scene.render.fps = fps

    targets = [only] if only else list(CLIPS.keys())
    for clip_name in targets:
        if clip_name not in CLIPS:
            print(f"[build_animations] unknown clip '{clip_name}'")
            continue
        sampler, duration, loop = CLIPS[clip_name]
        clear_scene()
        objects = build_rig()
        bake_clip(objects, clip_name, sampler, duration, fps)
        path = os.path.join(out_dir, f"{clip_name}.fbx")
        export_fbx(objects, path)
        print(f"[build_animations] {clip_name:<14} {duration:>5.2f}s "
              f"{'loop' if loop else 'one-shot'} -> {path}")

    print(f"[build_animations] done -> {out_dir}")


if __name__ == "__main__":
    main()
