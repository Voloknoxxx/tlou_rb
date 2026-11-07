#!/usr/bin/env python3
"""
generate_place.py

Builds TLoUMechanics.rbxlx - a self-contained Roblox place file that
opens directly in Roblox Studio with the whole mechanics pack wired up.

No Rojo required. Every Lua source file under src/ is embedded into the
correct service, and a small playable test map is generated so you can
try the movement, gunplay and visuals immediately.
"""

import os
import xml.sax.saxutils as sax

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "src")
OUT = os.path.join(ROOT, "TLoUMechanics.rbxlx")

_referent = 0


def ref():
    global _referent
    _referent += 1
    return f"RBX{_referent}"


def esc(text: str) -> str:
    return sax.escape(text, {'"': "&quot;"})


def read(path: str) -> str:
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def v3(name, x, y, z):
    return (f'<Vector3 name="{name}"><X>{x}</X><Y>{y}</Y><Z>{z}</Z></Vector3>')


def cframe(x=0.0, y=0.0, z=0.0, r=None):
    r = r or (1, 0, 0, 0, 1, 0, 0, 0, 1)
    return (
        '<CoordinateFrame name="CFrame">'
        f"<X>{x}</X><Y>{y}</Y><Z>{z}</Z>"
        f"<R00>{r[0]}</R00><R01>{r[1]}</R01><R02>{r[2]}</R02>"
        f"<R10>{r[3]}</R10><R11>{r[4]}</R11><R12>{r[5]}</R12>"
        f"<R20>{r[6]}</R20><R21>{r[7]}</R21><R22>{r[8]}</R22>"
        "</CoordinateFrame>"
    )


def color3(name, r, g, b):
    return (f'<Color3 name="{name}"><R>{r}</R><G>{g}</G><B>{b}</B></Color3>')


def rgb(r, g, b):
    return (r / 255.0, g / 255.0, b / 255.0)


MATERIALS = {
    "Plastic": 256,
    "SmoothPlastic": 272,
    "Neon": 288,
    "Wood": 512,
    "WoodPlanks": 528,
    "Marble": 784,
    "Slate": 800,
    "Concrete": 816,
    "Granite": 832,
    "Brick": 848,
    "Sand": 1296,
    "Fabric": 1312,
    "Grass": 1280,
    "Metal": 1088,
    "CorrodedMetal": 1040,
    "Glass": 1568,
    "Ground": 1360,
    "Cobblestone": 880,
    "Rock": 896,
}


def part(name, size, pos, color, material="Concrete", anchored=True,
         cancollide=True, shape=None, transparency=None, rot=None,
         extra="", cls="Part"):
    props = [
        f'<string name="Name">{esc(name)}</string>',
        v3("size", size[0], size[1], size[2]),
        cframe(pos[0], pos[1], pos[2], rot),
        color3("Color", *color),
        f'<token name="Material">{MATERIALS.get(material, 816)}</token>',
        f'<bool name="Anchored">{"true" if anchored else "false"}</bool>',
        f'<bool name="CanCollide">{"true" if cancollide else "false"}</bool>',
        '<token name="TopSurface">0</token>',
        '<token name="BottomSurface">0</token>',
        '<token name="LeftSurface">0</token>',
        '<token name="RightSurface">0</token>',
        '<token name="FrontSurface">0</token>',
        '<token name="BackSurface">0</token>',
    ]
    if shape is not None:
        props.append(f'<token name="shape">{shape}</token>')
    if transparency is not None:
        props.append(f'<float name="Transparency">{transparency}</float>')
    props.append(extra)
    return (f'<Item class="{cls}" referent="{ref()}"><Properties>'
            + "".join(props) + "</Properties></Item>")


def folder(name, children):
    return (f'<Item class="Folder" referent="{ref()}"><Properties>'
            f'<string name="Name">{esc(name)}</string>'
            f'</Properties>{children}</Item>')


def script_item(name, source, kind="Script"):
    return (f'<Item class="{kind}" referent="{ref()}"><Properties>'
            f'<string name="Name">{esc(name)}</string>'
            f'<ProtectedString name="Source">{esc(source)}</ProtectedString>'
            f'</Properties></Item>')


def module_item(name, source):
    return (f'<Item class="ModuleScript" referent="{ref()}"><Properties>'
            f'<string name="Name">{esc(name)}</string>'
            f'<ProtectedString name="Source">{esc(source)}</ProtectedString>'
            f'</Properties></Item>')


def service(class_name, name, children, extra_props=""):
    return (f'<Item class="{class_name}" referent="{ref()}"><Properties>'
            f'<string name="Name">{esc(name)}</string>{extra_props}'
            f'</Properties>{children}</Item>')


def load_folder(path):
    """Every .lua file in a directory becomes a ModuleScript."""
    items = []
    if not os.path.isdir(path):
        return ""
    for entry in sorted(os.listdir(path)):
        full = os.path.join(path, entry)
        if os.path.isfile(full) and entry.endswith(".lua"):
            items.append(module_item(entry[:-4], read(full)))
    return "".join(items)


# ---------------------------------------------------------------------
# Test map
# ---------------------------------------------------------------------
def build_map():
    parts = []

    # Ground
    parts.append(part("Ground", (512, 16, 512), (0, -8, 0),
                      rgb(64, 62, 56), "Ground", transparency=None))

    # Spawn
    parts.append(part("SpawnLocation", (12, 1, 12), (0, 0.5, 0),
                      rgb(70, 72, 70), "Concrete",
                      transparency=0.6, cancollide=False,
                      cls="SpawnLocation",
                      extra='<bool name="Neutral">true</bool>'))

    # A ruined two-room building to the north.
    bx, bz = 0, -60
    wall = rgb(118, 112, 100)
    parts.append(part("WallN", (48, 16, 2), (bx, 8, bz - 16), wall, "Concrete"))
    parts.append(part("WallS1", (20, 16, 2), (bx - 14, 8, bz + 16), wall, "Concrete"))
    parts.append(part("WallS2", (20, 16, 2), (bx + 14, 8, bz + 16), wall, "Concrete"))
    parts.append(part("WallE", (2, 16, 34), (bx + 24, 8, bz), wall, "Concrete"))
    parts.append(part("WallW", (2, 16, 34), (bx - 24, 8, bz), wall, "Concrete"))
    # Interior divider with a gap.
    parts.append(part("Divider", (2, 16, 22), (bx, 8, bz - 4), rgb(104, 98, 88), "Brick"))
    # Roofless beams.
    parts.append(part("Beam", (50, 1, 2), (bx, 15.5, bz), rgb(80, 62, 42), "Wood"))

    # Vaultable low walls (3-4 studs high) scattered around.
    vault_color = rgb(120, 116, 104)
    for (x, z, w, d) in [(-40, -20, 10, 3), (40, -20, 3, 10),
                         (-60, 20, 3, 12), (60, 20, 12, 3),
                         (0, 40, 14, 3), (-25, -110, 12, 3),
                         (30, -110, 3, 12)]:
        parts.append(part("LowWall", (w, 3.5, d), (x, 1.75, z),
                          vault_color, "Concrete"))

    # Crates (climbable).
    crate = rgb(122, 92, 56)
    for (x, z, h) in [(-18, -20, 4), (-15, -18, 4), (-16, -21, 7),
                      (22, -30, 4), (25, -33, 8), (-45, -60, 4),
                      (48, 40, 5), (-70, -40, 6)]:
        parts.append(part("Crate", (5, h, 5), (x, h / 2, z), crate, "WoodPlanks"))

    # A raised catwalk / balcony to test climb + vault.
    parts.append(part("Catwalk", (40, 1, 8), (-90, 9, 0), rgb(96, 96, 100), "Metal"))
    parts.append(part("CatwalkRail", (40, 3, 1), (-90, 10.5, 4), rgb(70, 70, 74), "Metal"))
    parts.append(part("CatwalkSupportA", (2, 9, 2), (-108, 4.5, 0), rgb(70, 70, 74), "Metal"))
    parts.append(part("CatwalkSupportB", (2, 9, 2), (-72, 4.5, 0), rgb(70, 70, 74), "Metal"))

    # Abandoned cars for cover.
    car = rgb(96, 44, 40)
    for (x, z, rot) in [(70, -70, 0.0), (-70, 70, 1.57), (100, 30, 0.5)]:
        parts.append(part("CarBody", (6, 3, 14), (x, 2.2, z), car, "CorrodedMetal"))
        parts.append(part("CarTop", (5.2, 2, 6), (x, 4.6, z - 1), rgb(60, 30, 28), "CorrodedMetal"))

    # Trees (simple trunk + canopy) for atmosphere.
    for (x, z) in [(-120, -90), (120, -90), (-120, 90), (120, 90),
                   (-150, 0), (150, 0), (0, 150), (0, -150),
                   (90, 120), (-90, 120), (140, -40), (-140, -40)]:
        parts.append(part("Trunk", (3, 20, 3), (x, 10, z), rgb(74, 56, 40), "Wood"))
        parts.append(part("Canopy", (18, 14, 18), (x, 24, z), rgb(48, 72, 42), "Grass"))

    return "".join(parts)


# ---------------------------------------------------------------------
# Lighting - moody, overcast, Last of Us feel
# ---------------------------------------------------------------------
LIGHTING_PROPS = (
    color3("Ambient", *rgb(58, 58, 62))
    + color3("OutdoorAmbient", *rgb(94, 96, 100))
    + color3("ColorShift_Top", *rgb(120, 116, 104))
    + color3("FogColor", *rgb(122, 124, 120))
    + '<float name="Brightness">2</float>'
    + '<float name="ClockTime">16.4</float>'
    + '<float name="GeographicLatitude">41</float>'
    + '<bool name="GlobalShadows">true</bool>'
    + '<float name="FogEnd">620</float>'
    + '<float name="FogStart">120</float>'
    + '<float name="EnvironmentDiffuseScale">0.35</float>'
    + '<float name="EnvironmentSpecularScale">0.35</float>'
    + '<token name="Technology">2</token>'
)

STARTER_PLAYER_PROPS = (
    '<bool name="EnableMouseLockOption">false</bool>'
    '<float name="CharacterWalkSpeed">14</float>'
    '<float name="CharacterJumpPower">42</float>'
    '<token name="CameraMode">0</token>'
    '<float name="CameraMaxZoomDistance">12</float>'
    '<float name="CameraMinZoomDistance">0.5</float>'
    # Force the classic R6 body. GameSettingsAvatar is the place's avatar
    # type (Enum.GameAvatarType, where R6 = 0). This is the setting that
    # decides which rig every player spawns with.
    '<token name="GameSettingsAvatar">0</token>'
    # Do not apply the player's saved avatar: we want the plain R6 rig,
    # not layered clothing built for R15.
    '<bool name="LoadCharacterAppearance">false</bool>'
    # Turn off the Avatar Joint Upgrade (Enum.RolloutState, Disabled = 1).
    #
    # With this at Default, the engine replaces every Motor6D in a spawned
    # character with an AnimationConstraint plus a BallSocketConstraint. That
    # is opt-out as of the Phase 2 rollout, so a place that says nothing gets
    # the new joints - and any script that looks for Motor6D stops finding
    # them. Our animator handles both classes, but the pack also relies on the
    # classic rigid R6 feel, so we opt out here and keep the old behaviour.
    '<token name="AvatarJointUpgrade">1</token>'
)


def build():
    shared = load_folder(os.path.join(SRC, "shared"))

    server_modules = load_folder(os.path.join(SRC, "server", "Modules"))
    server_bootstrap = script_item(
        "Bootstrap",
        read(os.path.join(SRC, "server", "Bootstrap.server.lua")),
        "Script",
    )
    server_children = folder("Modules", server_modules) + server_bootstrap

    client_controllers = load_folder(os.path.join(SRC, "client", "Controllers"))
    client_bootstrap = script_item(
        "Bootstrap",
        read(os.path.join(SRC, "client", "Bootstrap.client.lua")),
        "LocalScript",
    )
    client_children = folder("Controllers", client_controllers) + client_bootstrap

    workspace_children = build_map() + (
        '<Item class="Terrain" referent="%s"><Properties>'
        '<string name="Name">Terrain</string>'
        "</Properties></Item>" % ref()
    )

    xml = ['<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" '
           'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
           'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" '
           'version="4">']

    xml.append(service("Workspace", "Workspace", workspace_children,
                       '<bool name="StreamingEnabled">false</bool>'))
    xml.append(service("Lighting", "Lighting", "", LIGHTING_PROPS))
    xml.append(service("ReplicatedStorage", "ReplicatedStorage",
                       folder("TLoU", folder("Shared", shared))))
    xml.append(service("ServerScriptService", "ServerScriptService",
                       folder("TLoU", folder("Server", server_children))))
    xml.append(service(
        "StarterPlayer", "StarterPlayer",
        service("StarterPlayerScripts", "StarterPlayerScripts",
                folder("TLoU", folder("Client", client_children))),
        STARTER_PLAYER_PROPS,
    ))
    xml.append(service("Players", "Players", "",
                       '<float name="RespawnTime">4</float>'
                       '<bool name="CharacterAutoLoads">true</bool>'))
    xml.append(service("SoundService", "SoundService", "",
                       '<bool name="RespectFilteringEnabled">true</bool>'))
    xml.append(service("StarterGui", "StarterGui", "",
                       '<bool name="ResetPlayerGuiOnSpawn">true</bool>'))

    xml.append("</roblox>")

    with open(OUT, "w", encoding="utf-8") as handle:
        handle.write("".join(xml))

    size_kb = os.path.getsize(OUT) / 1024
    print(f"Wrote {OUT} ({size_kb:.1f} KB)")


if __name__ == "__main__":
    build()
