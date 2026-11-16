"""Build Koa (CursusVox's koala mascot) in Blender 5.2 and render clips.

Koa v4: soft organic forms (metaballs), plush fur shading with short strand fur and fluffy ear
tufts, glossy eyes that blink, a big satin nose, a mouth that talks, and an orange headset whose
mic light glows while Koa listens. Three-point studio light, AgX colour.

Run headless:
  blender -b -P koa_build.py -- --still out.png [--clip NAME --frame N]   # one test frame
  blender -b -P koa_build.py -- --clips outdir [names..]                  # PNG sequences per clip
  blender -b -P koa_build.py -- --save koa.blend                          # all actions in one master
Then encode: swift encode.swift <frames-dir> ../../Resources/Koa
"""
import math
import os
import sys

import bpy
from mathutils import Vector

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
FPS = 24
SIZE = int(ARGS[ARGS.index("--size") + 1]) if "--size" in ARGS else 512


def srgb(hex_):
    """'#rrggbb' to linear RGB."""
    c = [int(hex_[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    return tuple(x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c)


FUR = srgb("#78858a")          # koala grey with a cool blue cast
FUR_DEEP = srgb("#6e7586")
CREAM = srgb("#f6e4cf")         # belly, muzzle, inner ears
NOSE = srgb("#2b2f38")
EYE = srgb("#15171c")
IRIS = srgb("#634323")          # warm brown iris
ORANGE = srgb("#ff5b18")        # MyKoala orange
CUSHION = srgb("#2e3036")
METAL = srgb("#9aa0aa")
BLUSH = srgb("#ff8f8f")
MOUTH = srgb("#5a1f24")
TONGUE = srgb("#ff7a7f")


# ---------------- Scene ----------------
def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_EEVEE"
    sc.render.film_transparent = True
    sc.render.resolution_x = sc.render.resolution_y = SIZE
    sc.render.fps = FPS
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGBA"
    sc.view_settings.view_transform = "AgX"
    try:
        sc.view_settings.look = "AgX - Punchy"
    except TypeError:
        pass
    ee = sc.eevee
    for attr, value in (("taa_render_samples", 64), ("use_raytracing", True), ("use_shadows", True),
                        ("shadow_ray_count", 2), ("shadow_step_count", 8), ("use_gtao", True),
                        ("gtao_distance", 0.4), ("use_fast_gi", True)):
        try:
            setattr(ee, attr, value)
        except (AttributeError, TypeError):
            pass
    world = bpy.data.worlds.new("World")
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs[0].default_value = (*srgb("#d9dde6"), 1)
    bg.inputs[1].default_value = 0.18
    sc.world = world
    return sc


# ---------------- Materials ----------------
MATS = {}


def principled(name, color, rough=0.5, coat=0.0, sheen=0.0, sheen_tint=(1, 1, 1), sss=0.0, emission=None,
               bump=0.0, bump_scale=300.0, alpha=1.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    p = nt.nodes["Principled BSDF"]
    p.inputs["Base Color"].default_value = (*color, 1)
    p.inputs["Roughness"].default_value = rough
    p.inputs["Coat Weight"].default_value = coat
    p.inputs["Coat Roughness"].default_value = 0.08
    p.inputs["Sheen Weight"].default_value = sheen
    p.inputs["Sheen Roughness"].default_value = 0.35
    p.inputs["Sheen Tint"].default_value = (*sheen_tint, 1)
    p.inputs["Subsurface Weight"].default_value = sss
    p.inputs["Subsurface Radius"].default_value = (0.08, 0.05, 0.04)
    p.inputs["Subsurface Scale"].default_value = 0.1
    if emission:
        p.inputs["Emission Color"].default_value = (*emission[0], 1)
        p.inputs["Emission Strength"].default_value = emission[1]
    if alpha < 1:
        p.inputs["Alpha"].default_value = alpha
        try:
            m.surface_render_method = "BLENDED"
        except AttributeError:
            pass
    if bump:
        # Fine fibre texture: makes the plush read as fur, not plastic.
        tc = nt.nodes.new("ShaderNodeTexCoord")
        noise = nt.nodes.new("ShaderNodeTexNoise")
        noise.inputs["Scale"].default_value = bump_scale
        noise.inputs["Detail"].default_value = 6
        b = nt.nodes.new("ShaderNodeBump")
        b.inputs["Strength"].default_value = bump
        nt.links.new(tc.outputs["Object"], noise.inputs["Vector"])
        nt.links.new(noise.outputs["Fac"], b.inputs["Height"])
        nt.links.new(b.outputs["Normal"], p.inputs["Normal"])
    MATS[name] = m
    return m


def hair_material(name, color, root_dark=0.55):
    """Strand fur: darker at the root, the fur colour at the tip."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    p = nt.nodes["Principled BSDF"]
    p.inputs["Roughness"].default_value = 0.55
    p.inputs["Sheen Weight"].default_value = 0.6
    info = nt.nodes.new("ShaderNodeHairInfo")
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (*(c * root_dark for c in color), 1)
    ramp.color_ramp.elements[1].color = (*color, 1)
    nt.links.new(info.outputs["Intercept"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], p.inputs["Base Color"])
    MATS[name] = m
    return m


def make_materials():
    principled("Fur", FUR, rough=0.84, sheen=0.65, sheen_tint=srgb("#e8ecf5"), sss=0.10, bump=0.045, bump_scale=110)
    principled("Cream", CREAM, rough=0.82, sheen=0.6, sheen_tint=(1, 1, 1), sss=0.12, bump=0.035, bump_scale=130)
    principled("Nose", NOSE, rough=0.32, coat=0.7, bump=0.05, bump_scale=60)
    principled("Eye", EYE, rough=0.04, coat=1.0)
    principled("Iris", IRIS, rough=0.2, coat=0.6, emission=(IRIS, 0.15))
    principled("Catch", (1, 1, 1), rough=0.0, emission=((1, 1, 1), 6.0))
    principled("Orange", ORANGE, rough=0.28, coat=0.6)
    principled("Cushion", CUSHION, rough=0.85, sheen=0.4)
    principled("Metal", METAL, rough=0.25)
    principled("MicLight", ORANGE, rough=0.3, emission=(ORANGE, 0.0))
    principled("Blush", BLUSH, rough=0.9, alpha=0.55)
    principled("Brow", FUR_DEEP, rough=0.85)
    principled("Mouth", MOUTH, rough=0.6)
    principled("Tongue", TONGUE, rough=0.5, sss=0.3)
    principled("Sweat", srgb("#9fd4ff"), rough=0.05, coat=1.0, alpha=0.8)
    hair_material("FurHair", FUR)
    hair_material("CreamHair", CREAM, root_dark=0.8)


# ---------------- Building blocks ----------------
def link(o):
    bpy.context.collection.objects.link(o)
    return o


def empty(name, loc, parent=None):
    e = link(bpy.data.objects.new(name, None))
    place(e, loc, parent)
    return e


def place(o, loc, parent):
    """Put o at world position loc; parents are never rotated or scaled at build time."""
    if parent:
        bpy.context.view_layer.update()
        o.parent = parent
        o.location = Vector(loc) - parent.matrix_world.translation
    else:
        o.location = loc


def blob(name, elements, mat, parent=None, origin=(0, 0, 0), center=None, target=None, resolution=0.04, subdiv=1):
    """A soft organic form from metaball elements: [(type, (x,y,z), radius, (sx,sy,sz), stiffness)].
    Metaball surfaces land at an unpredictable fraction of their nominal size, so the mesh is then
    fitted to an exact `target` size around `center` (world units), keeping the blended shape."""
    mb = bpy.data.metaballs.new(name + "Meta")
    mb.resolution = resolution
    mb.render_resolution = resolution
    mb.threshold = 0.6
    for kind, co, radius, size, stiff in elements:
        e = mb.elements.new()
        e.type = kind
        e.co = Vector(co) - Vector(origin)
        e.radius = radius
        e.stiffness = stiff
        if kind == "ELLIPSOID":
            e.size_x, e.size_y, e.size_z = size
    o = link(bpy.data.objects.new(name, mb))
    bpy.context.view_layer.objects.active = o
    for other in bpy.context.selected_objects:
        other.select_set(False)
    o.select_set(True)
    bpy.ops.object.convert(target="MESH")
    o = bpy.context.active_object
    o.name = name
    if target:
        vs = [v.co for v in o.data.vertices]
        lo = Vector([min(v[i] for v in vs) for i in range(3)])
        hi = Vector([max(v[i] for v in vs) for i in range(3)])
        mid, dim = (lo + hi) / 2, hi - lo
        want = Vector(center) - Vector(origin)
        for v in o.data.vertices:
            v.co = Vector(((v.co[i] - mid[i]) * target[i] / dim[i] + want[i]) for i in range(3))
    bpy.ops.object.shade_smooth()
    if subdiv:
        m = o.modifiers.new("Smooth", "SUBSURF")
        m.levels = m.render_levels = subdiv
    o.data.materials.append(MATS[mat])
    place(o, origin, parent)
    return o


def sphere(name, loc, scale, mat, parent=None, segs=48, rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segs, ring_count=segs // 2, radius=1, location=(0, 0, 0))
    o = bpy.context.active_object
    o.name = name
    o.scale = scale
    o.rotation_euler = rot
    bpy.ops.object.shade_smooth()
    o.data.materials.append(MATS[mat])
    place(o, loc, parent)
    return o


def fur(o, mat, count, length, rough=0.004, clump=0.25, children=0, density_group=None):
    """Short strand fur on a mesh, for a soft, fuzzy silhouette."""
    o.data.materials.append(MATS[mat])
    ps = o.modifiers.new("Fur", "PARTICLE_SYSTEM").particle_system
    s = ps.settings
    s.type = "HAIR"
    s.count = count
    s.hair_length = length
    s.use_advanced_hair = False   # length comes from hair_length, not emission velocity
    s.material = len(o.data.materials)
    s.root_radius = 0.002
    s.tip_radius = 0.0
    s.radius_scale = 0.35
    s.display_step = s.render_step = 3
    s.roughness_2 = rough
    s.roughness_endpoint = rough * 2
    s.child_type = "INTERPOLATED" if children else "NONE"
    if children:
        for attr in ("child_percent", "child_nbr", "rendered_child_count"):
            if hasattr(s, attr):
                setattr(s, attr, children)
        s.clump_factor = clump
    if density_group:
        ps.vertex_group_density = density_group
    return ps


# ---------------- Koa ----------------
def build():
    make_materials()
    R = {}
    root = R["root"] = empty("Root", (0, 0, 0))
    body = R["body"] = empty("BodyPivot", (0, 0, 0.35), root)

    # Body: a soft pear with a cream belly and stubby feet.
    R["bodymesh"] = blob("Body", [
        ("ELLIPSOID", (0, 0, 0.62), 1.0, (0.5, 0.44, 0.58), 2.0),
        ("BALL", (0, -0.05, 0.92), 0.42, (1, 1, 1), 2.0),
        ("ELLIPSOID", (-0.2, -0.12, 0.3), 0.7, (0.24, 0.28, 0.17), 2.0),
        ("ELLIPSOID", (0.2, -0.12, 0.3), 0.7, (0.24, 0.28, 0.17), 2.0),
    ], "Fur", body, origin=(0, 0, 0.35), center=(0, 0, 0.68), target=(1.0, 0.85, 1.12))
    # Fine felt shading keeps the body readable at the 144px display size.
    sphere("Belly", (0, -0.3, 0.66), (0.32, 0.14, 0.4), "Cream", body)
    for s in (-1, 1):
        side = "L" if s < 0 else "R"
        arm = R[f"arm{side}"] = empty(f"ArmPivot{side}", (0.42 * s, -0.02, 0.98), body)
        sphere(f"Arm{side}", (0.5*s, -0.08, 0.76), (0.16,0.16,0.31), "Fur", arm)
        sphere(f"Paw{side}", (0.5*s, -0.13, 0.53), (0.17,0.17,0.18), "Fur", arm)

    # Head: broad and round, wider at the cheeks like a koala, with a cream muzzle patch.
    head = R["head"] = empty("HeadPivot", (0, 0, 1.25), body)
    R["headmesh"] = blob("Head", [
        ("ELLIPSOID", (0, 0, 1.82), 1.0, (0.92, 0.8, 0.78), 2.0),
        ("ELLIPSOID", (-0.4, -0.12, 1.68), 0.8, (0.46, 0.44, 0.38), 2.0),
        ("ELLIPSOID", (0.4, -0.12, 1.68), 0.8, (0.46, 0.44, 0.38), 2.0),
    ], "Fur", head, origin=(0, 0, 1.25), center=(0, 0, 1.78), target=(1.9, 1.45, 1.45))
    # Dense face strands alias into dots after downsampling; keep fur on the silhouette.
    sphere("Muzzle", (0, -0.6, 1.47), (0.34, 0.13, 0.24), "Cream", head)

    # Ears: big round discs with long cream tufts spilling out of the inner ear.
    for s in (-1, 1):
        side = "L" if s < 0 else "R"
        ear = R[f"ear{side}"] = empty(f"EarPivot{side}", (0.66 * s, 0.05, 2.2), head)
        e = sphere(f"Ear{side}", (0.93 * s, 0.1, 2.36), (0.38, 0.15, 0.35), "Fur", ear, rot=(0, math.radians(-18 * s), 0))
        fur(e, "FurHair", 3500, 0.045, rough=0.008)
        inner = sphere(f"EarInner{side}", (0.93 * s, 0.0, 2.34), (0.26, 0.07, 0.24), "Cream", ear,
                       rot=(0, math.radians(-18 * s), 0))
        fur(inner, "CreamHair", 900, 0.065, rough=0.015, clump=0.35, children=3)

    # Eyes: glossy, with an iris, two catchlights and a lid that closes to blink.
    for s in (-1, 1):
        side = "L" if s < 0 else "R"
        eye = R[f"eye{side}"] = empty(f"EyePivot{side}", (0.36 * s, -0.6, 1.86), head)
        sphere(f"Eye{side}", (0.36 * s, -0.6, 1.86), (0.16, 0.11, 0.18), "Eye", eye)
        sphere(f"Iris{side}", (0.36 * s, -0.69, 1.84), (0.1, 0.035, 0.115), "Iris", eye, segs=32)
        sphere(f"Catch1{side}", (0.36 * s + 0.055, -0.725, 1.92), (0.029, 0.012, 0.029), "Catch", eye, segs=16)
        sphere(f"Catch2{side}", (0.36 * s - 0.05, -0.725, 1.79), (0.012, 0.006, 0.012), "Catch", eye, segs=12)
        sphere(f"Brow{side}", (0.36*s,-0.65,2.10), (0.12,0.04,0.028), "Brow", head, segs=24,
               rot=(0,math.radians(-8*s),0))
        lid = R[f"lid{side}"] = empty(f"LidPivot{side}", (0.36 * s, -0.6, 1.86), head)
        bpy.ops.mesh.primitive_uv_sphere_add(segments=40, ring_count=20, radius=1, location=(0, 0, 0))
        cap = bpy.context.active_object
        cap.name = f"Lid{side}"
        cap.scale = (0.175, 0.125, 0.195)
        bpy.ops.object.shade_smooth()
        cap.data.materials.append(MATS["Fur"])
        # Keep only the upper half: rotating the pivot down closes the eye.
        bpy.ops.object.mode_set(mode="EDIT")
        import bmesh
        bm = bmesh.from_edit_mesh(cap.data)
        bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.co.z < 0.0], context="VERTS")
        bmesh.update_edit_mesh(cap.data)
        bpy.ops.object.mode_set(mode="OBJECT")
        place(cap, (0.36 * s, -0.6, 1.86), lid)
        R[f"lidmesh{side}"] = cap
        sphere(f"Blush{side}", (0.6 * s, -0.5, 1.6), (0.13, 0.05, 0.08), "Blush", head, segs=24)

    # The big koala nose: tall, rounded and satin.
    sphere("Nose", (0, -0.74, 1.6), (0.17, 0.13, 0.24), "Nose", head)
    # Mouth: a small dark opening (scaled open to talk) with a tongue.
    mouth = R["mouth"] = empty("MouthPivot", (0, -0.745, 1.34), head)
    sphere("MouthInside", (0, -0.745, 1.34), (0.105, 0.035, 0.055), "Mouth", mouth, segs=24)
    sphere("Tongue", (0, -0.765, 1.32), (0.06, 0.03, 0.022), "Tongue", mouth, segs=24)
    mouth.scale = (1, 1, 0.25)

    # Headset: glossy orange band and cups with dark cushions; a boom mic whose light glows.
    bpy.ops.mesh.primitive_torus_add(major_radius=0.99, minor_radius=0.06, major_segments=72, minor_segments=18,
                                     location=(0, 0, 0), rotation=(math.radians(90), 0, 0))
    band = bpy.context.active_object
    band.name = "Band"
    bpy.ops.object.transform_apply(rotation=True)
    import bmesh
    bm = bmesh.new()
    bm.from_mesh(band.data)
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.co.z < -0.05], context="VERTS")
    bm.to_mesh(band.data)
    bm.free()
    bpy.ops.object.shade_smooth()
    band.data.materials.append(MATS["Orange"])
    place(band, (0, 0.02, 1.64), head)
    for s in (-1, 1):
        side = "L" if s < 0 else "R"
        for nm, rad, depth, off, mat in (("Cup", 0.25, 0.16, 0.0, "Orange"), ("Cushion", 0.21, 0.08, -0.09, "Cushion")):
            bpy.ops.mesh.primitive_cylinder_add(vertices=48, radius=rad, depth=depth, location=(0, 0, 0),
                                                rotation=(0, math.radians(90), math.radians(-18 * s)))
            o = bpy.context.active_object
            o.name = f"{nm}{side}"
            bev = o.modifiers.new("Bevel", "BEVEL")
            bev.width = 0.05
            bev.segments = 5
            bpy.ops.object.shade_smooth()
            o.data.materials.append(MATS[mat])
            place(o, (0.99 * s + off * s, -0.05, 1.64), head)
    p0, p1 = Vector((1.0, -0.27, 1.55)), Vector((0.3, -0.7, 1.33))
    bpy.ops.mesh.primitive_cylinder_add(vertices=16, radius=0.024, depth=(p1 - p0).length, location=(p0 + p1) / 2)
    boom = bpy.context.active_object
    boom.name = "Boom"
    boom.rotation_mode = "QUATERNION"
    boom.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(p1 - p0)
    bpy.ops.object.shade_smooth()
    boom.data.materials.append(MATS["Metal"])
    place(boom, (p0 + p1) / 2, head)
    R["mic"] = sphere("Mic", tuple(p1), (0.065, 0.065, 0.06), "MicLight", head, segs=24)

    R["sweat"] = sphere("Sweat", (-0.8, -0.45, 2.2), (0.07, 0.045, 0.11), "Sweat", head, segs=24)
    R["sweat"].hide_render = True
    return R


def lights_camera():
    sc = bpy.context.scene

    def area(name, energy, size, loc, rot, color):
        light = bpy.data.lights.new(name, "AREA")
        light.energy = energy
        light.size = size
        light.color = color
        o = link(bpy.data.objects.new(name, light))
        o.location = loc
        o.rotation_euler = [math.radians(a) for a in rot]
        return o

    area("Key", 600, 3.0, (-3.2, -4.2, 4.2), (52, 0, -38), (1.0, 0.96, 0.9))
    area("Fill", 145, 4.0, (4.0, -3.5, 1.8), (75, 0, 48), (0.85, 0.9, 1.0))
    area("Rim", 800, 2.5, (1.5, 4.5, 4.0), (-55, 0, 162), (1.0, 0.92, 0.85))
    area("Kicker", 500, 2.0, (-3.5, 3.0, 2.0), (-70, 0, -130), (0.9, 0.95, 1.0))
    cam = bpy.data.cameras.new("Cam")
    cam.lens = 85
    co = link(bpy.data.objects.new("Cam", cam))
    co.location = (1.8, -8.0, 2.1)
    target = Vector((0, 0, 1.5))
    co.rotation_euler = (target - co.location).to_track_quat("-Z", "Y").to_euler()
    sc.camera = co
    return co


# ---------------- Animation ----------------
def key(o, path, frame, value):
    setattr(o, path, value)
    o.keyframe_insert(data_path=path, frame=frame)


BASE = {}


def clear_anim(R):
    for o in bpy.data.objects:
        o.animation_data_clear()
        BASE.setdefault(o.name, (o.location.copy(), o.rotation_euler.copy(), o.scale.copy()))
        o.location, o.rotation_euler, o.scale = (v.copy() for v in BASE[o.name])
    R["sweat"].hide_render = True
    MATS["MicLight"].node_tree.nodes["Principled BSDF"].inputs["Emission Strength"].default_value = 0.0
    if MATS["MicLight"].node_tree.animation_data:
        MATS["MicLight"].node_tree.animation_data_clear()


def lids(R, f, closed):
    """0 open, 1 closed: the upper lid rotates down over the eye."""
    for s, side in ((-1, "L"), (1, "R")):
        # The lid is the upper half of a dome: +90 degrees brings it down over the front of the eye,
        # -70 tucks it back into the head.
        key(R[f"lid{side}"], "rotation_euler", f, (math.radians(-70 + 160 * closed), 0, 0))


def blink(R, f, dur=4):
    lids(R, f - 1, 0); lids(R, f + dur // 2, 1); lids(R, f + dur, 0)


def ears(R, f, angle, perk=0):
    for s, side in ((-1, "L"), (1, "R")):
        key(R[f"ear{side}"], "rotation_euler", f, (math.radians(perk), math.radians(-angle * s), math.radians(angle * 0.4 * s)))


def arms(R, f, l, r):
    key(R["armL"], "rotation_euler", f, [math.radians(a) for a in l])
    key(R["armR"], "rotation_euler", f, [math.radians(a) for a in r])


def mouth(R, f, open_):
    key(R["mouth"], "scale", f, (1 + 0.15 * open_, 1, 0.25 + 1.1 * open_))


def mic(f, strength):
    inp = MATS["MicLight"].node_tree.nodes["Principled BSDF"].inputs["Emission Strength"]
    inp.default_value = strength
    inp.keyframe_insert("default_value", frame=f)


def look(R, f, dx, dz):
    for s, side in ((-1, "L"), (1, "R")):
        key(R[f"eye{side}"], "location", f, BASE[f"EyePivot{side}"][0] + Vector((dx, 0, dz)))


# Arm rotations (degrees): Y raises an arm out to the side (+ for the left arm, - for the right);
# negative X swings it forward; Z then turns a forward arm in (+ left, - right) towards the face.
REST_L, REST_R = (0, 8, 0), (0, -8, 0)


def body_pose(R, frame, pitch=0, lean=0, turn=0, lift=0):
    """Move the torso around its seated pivot, leaving the root scale stable."""
    key(R["body"], "rotation_euler", frame,
        tuple(math.radians(a) for a in (pitch, lean, turn)))
    key(R["body"], "location", frame,
        BASE["BodyPivot"][0] + Vector((0, 0, lift)))


def clip_pop_in(R):
    r, h = R["root"], R["head"]
    for f, z, tilt in ((1, -0.35, -12), (5, 0.045, 6), (9, -0.015, -2), (12, 0, 0)):
        key(r, "location", f, (0, 0, z))
        key(h, "rotation_euler", f, (math.radians(tilt), 0, 0))
    for f, lean, lift in ((1,-8,-0.04),(5,7,0.03),(8,-4,0),(12,0,0)):
        body_pose(R,f,lean=lean,lift=lift)
    ears(R, 1, 15); ears(R, 6, -6); ears(R, 12, 0)
    arms(R, 1, REST_L, REST_R); arms(R, 6, REST_L, (-30, -60, -10)); arms(R, 12, REST_L, REST_R)
    lids(R, 1, 0.35); lids(R, 5, 0); lids(R, 12, 0)
    mouth(R, 1, 0.05); mouth(R, 12, 0.15); mic(1, 0); mic(12, 3)
    return 12


def clip_listen(R, loud=False):
    r, h = R["root"], R["head"]
    for f in range(1, 50, 3):
        t = (f - 1) / 48 * 2 * math.pi
        key(r, "scale", f, (1, 1, 1 + 0.007 * math.sin(t)))
        key(h, "rotation_euler", f, (math.radians((4 if loud else 2) * math.sin(t)),
            math.radians((7 if loud else 3) * math.sin(t)), math.radians(2 * math.sin(t*2))))
        ears(R, f, (9 if loud else 3) * math.sin(t), perk=-4 if loud else 0)
        look(R, f, (0.018 if loud else 0.009) * math.sin(t), 0)
        mouth(R, f, 0.12 if loud else 0.05)
        mic(f, 4 + (3 if loud else 1) * (1+math.sin(t*2))/2)
    # Lean toward the speaker and cup one ear; the loud loop adds a second nod.
    for f, pitch, lean in ((1,0,0),(10,7,-5),(22,4,-3),(34,8 if loud else 5,4),(43,3,2),(49,0,0)):
        body_pose(R,f,pitch=pitch,lean=lean)
    arms(R,1,REST_L,REST_R)
    arms(R,10,(-55,65,12) if loud else (-20,30,8),(-20,-18,-8))
    arms(R,30,(-65,70,8) if loud else (-25,35,10),(-30,-25,-10))
    arms(R,42,(-25,30,5),REST_R); arms(R,49,REST_L,REST_R)
    lids(R, 1, 0); blink(R, 27 if loud else 31, 4); lids(R, 49, 0)
    return 48


def clip_think(R):
    h = R["head"]
    for f, pitch, turn in ((1,0,0),(10,-9,-12),(26,-7,-10),(40,-3,-5),(49,0,0)):
        key(h, "rotation_euler", f, (math.radians(pitch),0,math.radians(turn)))
    arms(R, 1, REST_L, REST_R); arms(R, 10, (-100,0,30), REST_R); arms(R, 34, (-100,0,30),REST_R); arms(R,49,REST_L,REST_R)
    for f,pitch,lean in ((1,0,0),(10,-4,-7),(26,-2,-5),(38,3,4),(49,0,0)):
        body_pose(R,f,pitch=pitch,lean=lean)
    arms(R,20,(-110,12,35),(-35,-25,-15))
    arms(R,34,(-100,5,30),(-45,-35,-15))
    look(R,1,0,0); look(R,10,-0.025,0.025); look(R,35,-0.025,0.025); look(R,49,0,0)
    lids(R,1,0); lids(R,12,0.22); blink(R,29,4); lids(R,49,0)
    ears(R,1,0); ears(R,20,8); ears(R,49,0)
    mouth(R,1,0.05); mouth(R,49,0.05); mic(1,2); mic(49,2)
    return 48


def clip_happy(R):
    h = R["head"]
    for f, pitch, turn in ((1,0,0),(6,9,-4),(12,-3,4),(19,0,0)):
        key(h,"rotation_euler",f,(math.radians(pitch),0,math.radians(turn)))
    arms(R,1,REST_L,REST_R); arms(R,7,(-15,60,0),(-15,-75,0)); arms(R,12,(-15,60,0),(-15,-60,-15)); arms(R,19,REST_L,REST_R)
    for f,lean,lift in ((1,0,0),(4,-8,-0.025),(7,8,0.07),(11,-7,0.025),(15,4,0),(19,0,0)):
        body_pose(R,f,lean=lean,lift=lift)
    arms(R,4,(-25,30,10),(-25,-30,-10))
    arms(R,9,(-25,85,15),(-25,-95,-25))
    arms(R,14,(-15,65,-10),(-15,-85,20))
    ears(R,1,0); ears(R,7,-12,perk=-8); ears(R,19,0)
    lids(R,1,0); blink(R,8,4); lids(R,19,0)
    mouth(R,1,0.1); mouth(R,7,0.75); mouth(R,19,0.15)
    mic(1,5); mic(19,2)
    return 19


def clip_oops(R):
    h = R["head"]
    R["sweat"].hide_render = False
    sw = R["sweat"]
    base = BASE["Sweat"][0]
    key(sw, "location", 1, base + Vector((0, 0, 0.1))); key(sw, "location", 19, base - Vector((0, 0, 0.18)))
    key(h, "rotation_euler", 1, (0, 0, 0)); key(h, "rotation_euler", 8, (math.radians(7), math.radians(-10), 0))
    key(h, "rotation_euler", 19, (math.radians(9), math.radians(-8), 0))
    ears(R, 1, 0); ears(R, 10, 30, perk=8); ears(R, 19, 28, perk=8)
    arms(R, 1, REST_L, REST_R); arms(R, 10, REST_L, (-110, 0, -35)); arms(R, 19, REST_L, (-110, 0, -35))
    lids(R, 1, 0); lids(R, 10, 0.1); mouth(R, 1, 0.1); mouth(R, 10, 0.45); mouth(R, 19, 0.35)
    arms(R, 19, REST_L, REST_R); ears(R, 19, 0); key(h,"rotation_euler",19,(0,0,0)); lids(R,19,0)
    for f,pitch,lean,lift in ((1,0,0,0),(5,-8,7,-0.045),(10,-4,-6,-0.02),(15,3,3,0),(19,0,0,0)):
        body_pose(R,f,pitch=pitch,lean=lean,lift=lift)
    arms(R,5,(-20,55,15),(-20,-55,-15))
    mic(1, 4); mic(19, 0)
    return 19


def clip_shrug(R):
    h, b = R["head"], R["body"]
    arms(R, 1, REST_L, REST_R); arms(R, 6, (-20, 70, 0), (-20, -70, 0)); arms(R, 14, (-20, 65, 0), (-20, -65, 0))
    key(h, "rotation_euler", 1, (0, 0, 0)); key(h, "rotation_euler", 6, (0, math.radians(13), 0)); key(h, "rotation_euler", 14, (0, math.radians(11), 0))
    key(b, "location", 1, BASE["BodyPivot"][0]); key(b, "location", 6, BASE["BodyPivot"][0] + Vector((0, 0, 0.07)))
    key(b, "location", 14, BASE["BodyPivot"][0])
    lids(R, 1, 0); blink(R, 7, 4); mouth(R, 1, 0.1); mouth(R, 14, 0.1)
    arms(R,14,REST_L,REST_R); key(h,"rotation_euler",14,(0,0,0)); lids(R,14,0)
    for f,lean,lift in ((1,0,0),(4,-8,0.045),(8,8,0.065),(11,-3,0.02),(14,0,0)):
        body_pose(R,f,lean=lean,lift=lift)
    arms(R,4,(-50,85,20),(-50,-85,-20))
    arms(R,9,(-35,75,-15),(-35,-75,15))
    mic(1, 3); mic(14, 2)
    return 14


CLIPS = {
    "pop_in": clip_pop_in, "listen_calm": lambda R: clip_listen(R, False), "listen_loud": lambda R: clip_listen(R, True),
    "think": clip_think, "happy": clip_happy, "oops": clip_oops, "shrug": clip_shrug,
}
LOOPS = ("listen_calm", "listen_loud", "think")


def all_fcurves():
    datablocks = [o for o in bpy.data.objects] + [m.node_tree for m in MATS.values()]
    for d in datablocks:
        ad = d.animation_data
        if not ad or not ad.action:
            continue
        try:
            yield from ad.action.fcurves
        except AttributeError:
            for layer in ad.action.layers:
                for strip in layer.strips:
                    for bag in strip.channelbags:
                        yield from bag.fcurves


def finish_curves(name):
    for fc in all_fcurves():
        for kp in fc.keyframe_points:
            kp.interpolation = "BEZIER"
            kp.easing = "AUTO"
        if name in LOOPS:
            # The unrendered frame49 repeats frame1, giving the 48-frame loop a continuous seam.
            fc.keyframe_points.insert(49, fc.evaluate(1), options={"REPLACE"})
            fc.modifiers.new("CYCLES")


def pose(R, name, frame):
    clear_anim(R)
    n = CLIPS[name](R)
    finish_curves(name)
    bpy.context.scene.frame_set(min(frame, n))
    return n


def render_clip(R, name, outdir):
    sc = bpy.context.scene
    n = pose(R, name, 1)
    sc.frame_start, sc.frame_end = 1, n
    d = os.path.join(outdir, name)
    os.makedirs(d, exist_ok=True)
    sc.render.filepath = os.path.join(d, "f_")
    bpy.ops.render.render(animation=True)


def save_master(R, path):
    """Keep each clip's editable actions and a single timeline of the complete mascot."""
    sc = bpy.context.scene
    controls = [o for o in R.values() if o.type == "EMPTY" or o == R["sweat"]]
    light = MATS["MicLight"].node_tree.nodes["Principled BSDF"].inputs["Emission Strength"]
    samples, markers = [], []
    for name in CLIPS:
        count = pose(R, name, 1)
        markers.append((name, len(samples) + 1, count))
        for owner in [*bpy.data.objects, MATS["MicLight"].node_tree]:
            if owner.animation_data and owner.animation_data.action:
                action = owner.animation_data.action
                action.name = f"Koa.{name}.{owner.name}"
                action.use_fake_user = True
        for frame in range(1, count + 1):
            sc.frame_set(frame)
            transforms = [(o, o.location.copy(), o.rotation_euler.copy(), o.scale.copy()) for o in controls]
            samples.append((transforms, R["sweat"].hide_render, light.default_value))

    clear_anim(R)
    sc.timeline_markers.clear()
    for name, start, count in markers:
        sc.timeline_markers.new(name, frame=start)
    for frame, (transforms, hidden, emission) in enumerate(samples, 1):
        for owner, location, rotation, scale in transforms:
            for channel, value in (("location", location), ("rotation_euler", rotation), ("scale", scale)):
                key(owner, channel, frame, value)
        key(R["sweat"], "hide_render", frame, hidden)
        light.default_value = emission
        light.keyframe_insert("default_value", frame=frame)
    for owner in [*controls, MATS["MicLight"].node_tree]:
        owner.animation_data.action.name = f"KoaMaster.{owner.name}"
    for curve in all_fcurves():
        for point in curve.keyframe_points:
            point.interpolation = "LINEAR"
    sc.frame_start, sc.frame_end = 1, len(samples)
    sc["koa_clips"] = ";".join(f"{name}:{start}:{count}" for name, start, count in markers)
    sc.frame_set(1)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(path))


def main():
    reset()
    R = build()
    lights_camera()
    if "--still" in ARGS:
        clip = ARGS[ARGS.index("--clip") + 1] if "--clip" in ARGS else "listen_calm"
        frame = int(ARGS[ARGS.index("--frame") + 1]) if "--frame" in ARGS else 1
        pose(R, clip, frame)
        bpy.context.scene.render.filepath = ARGS[ARGS.index("--still") + 1]
        bpy.ops.render.render(write_still=True)
    if "--clips" in ARGS:
        i = ARGS.index("--clips")
        outdir = ARGS[i + 1]
        names = []
        for a in ARGS[i + 2:]:
            if a.startswith("--"):
                break
            names.append(a)
        for nme in names or list(CLIPS):
            render_clip(R, nme, outdir)
    if "--save" in ARGS:
        save_master(R, ARGS[ARGS.index("--save") + 1])


main()
