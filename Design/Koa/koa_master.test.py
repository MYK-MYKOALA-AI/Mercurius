"""Blender integration check: the saved master must reproduce every original clip frame.

blender -b --python-exit-code 1 -P Design/Koa/koa_master.test.py -- Design/Koa/koa_build.py Design/Koa/koa.blend
"""
import math
import os
import runpy
import sys

import bpy

args = sys.argv[sys.argv.index("--") + 1:]
assert len(args) == 2, "expected generator and master scene paths"
source, master = map(os.path.abspath, args)
# The renderer's normal invocation builds the character without rendering or saving.
sys.argv = [sys.argv[0]]
generator = runpy.run_path(source)
rig = {key: bpy.data.objects[name] for key, name in (
    ("root", "Root"), ("body", "BodyPivot"), ("head", "HeadPivot"),
    ("armL", "ArmPivotL"), ("armR", "ArmPivotR"), ("earL", "EarPivotL"), ("earR", "EarPivotR"),
    ("lidL", "LidPivotL"), ("lidR", "LidPivotR"), ("eyeL", "EyePivotL"), ("eyeR", "EyePivotR"),
    ("mouth", "MouthPivot"), ("sweat", "Sweat"))}
expected = {"pop_in": 12, "listen_calm": 48, "listen_loud": 48, "think": 48, "happy": 19, "oops": 19, "shrug": 14}


def snapshot():
    bpy.context.view_layer.update()
    return ({o.name: (tuple(v for row in o.matrix_world for v in row), o.hide_render) for o in bpy.data.objects},
            bpy.data.materials["MicLight"].node_tree.nodes["Principled BSDF"].inputs["Emission Strength"].default_value)


reference, markers = [], []
for name, count in expected.items():
    assert generator["pose"](rig, name, 1) == count
    markers.append((name, len(reference) + 1))
    for frame in range(1, count + 1):
        bpy.context.scene.frame_set(frame)
        reference.append(snapshot())
bpy.ops.wm.open_mainfile(filepath=master)
scene = bpy.context.scene
assert scene.frame_start == 1 and scene.frame_end == 208 and scene.render.fps == 24
assert scene.render.film_transparent
assert [(m.name, m.frame) for m in scene.timeline_markers] == markers
for name in expected:
    assert any(a.name.startswith(f"Koa.{name}.") and a.use_fake_user for a in bpy.data.actions), name
for frame, (objects, emission) in enumerate(reference, 1):
    scene.frame_set(frame)
    actual, actual_emission = snapshot()
    assert actual.keys() == objects.keys(), frame
    for name, (matrix, hidden) in objects.items():
        other, other_hidden = actual[name]
        assert all(math.isclose(a, b, abs_tol=0.00001) for a, b in zip(matrix, other)), (frame, name, "pose mismatch")
        assert hidden == other_hidden, (frame, name, "visibility mismatch")
    assert math.isclose(emission, actual_emission, abs_tol=0.00001), (frame, "mic light mismatch")
print("PASS: master matches all 208 source frames, seven named actions, visibility and mic light")
