#!/usr/bin/env python3
"""Checks the converted eye contact model against the original TensorFlow graph.

The original model code (flx.py, tf_utils.py, transformation.py from the pinned commit of
github.com/chihfanhsu/gaze_correction) is downloaded and run in TensorFlow's 1.x mode on the same
random inputs as the Core ML model; the flows and light weights must agree.

With --fixture, it also writes the warp-and-light fixture the Swift tests use: random small images,
flows and light weights, and the image the original transformation code makes of them.

Usage: python3 scripts/gaze-model/verify.py [--model App/GazeModel/GazeWarp.mlpackage]
                                            [--weights build/gaze-weights] [--fixture PATH]
"""

import argparse
import json
import pathlib
import sys
import types
import urllib.request

import numpy as np
import tensorflow as tf
import coremltools as ct

SOURCE = "https://raw.githubusercontent.com/chihfanhsu/gaze_correction/7cc76e4ccaf76c950730c593ffa22bed30c807a4/gaze_correction_system"


def original_modules(folder: pathlib.Path):
    folder.mkdir(parents=True, exist_ok=True)
    for name in ("flx.py", "tf_utils.py", "transformation.py"):
        target = folder / name
        if not target.exists():
            urllib.request.urlretrieve(f"{SOURCE}/{name}", target)
    tf.compat.v1.disable_eager_execution()
    sys.modules["tensorflow"] = tf.compat.v1
    sys.path.insert(0, str(folder))
    import flx
    import transformation
    return flx, transformation


def random_inputs(rng):
    patch = rng.uniform(0, 1, (1, 48, 64, 3)).astype(np.float32)
    points = [(10, 26), (22, 18), (36, 17), (50, 25), (37, 31), (22, 32)]
    anchors = np.concatenate(
        [np.stack(np.meshgrid(np.arange(64) - x, np.arange(48) - y), axis=-1) for x, y in points], axis=-1
    ).astype(np.float32)[None]
    angle = np.array([[rng.uniform(5, 20), rng.uniform(-5, 5)]], dtype=np.float32)
    return patch, anchors, angle


def reference(flx, weights: pathlib.Path, side, patch, anchors, angle):
    graph = tf.Graph()
    with graph.as_default():
        conf = types.SimpleNamespace(height=48, width=64, channel=3, ef_dim=12, agl_dim=2, encoded_agl_dim=16)
        img = tf.compat.v1.placeholder(tf.float32, [None, 48, 64, 3])
        fp = tf.compat.v1.placeholder(tf.float32, [None, 48, 64, 12])
        agl = tf.compat.v1.placeholder(tf.float32, [None, 2])
        train = tf.compat.v1.placeholder(tf.bool)
        prediction, flow_raw, light = flx.inference(img, fp, agl, train, conf)
        session = tf.compat.v1.Session(graph=graph)
        tf.compat.v1.train.Saver().restore(session, str(weights / side / side))
        return session.run([tf.tanh(flow_raw), light, prediction], {img: patch, fp: anchors, agl: angle, train: False})


def fixture(transformation, flx, rng, path: pathlib.Path):
    cases = []
    graph = tf.Graph()
    with graph.as_default(), tf.compat.v1.Session(graph=graph) as session:
        for _ in range(4):
            image = rng.uniform(0, 1, (1, 6, 8, 3)).astype(np.float32)
            flow = rng.uniform(-0.4, 0.4, (1, 6, 8, 2)).astype(np.float32)
            logits = rng.normal(0, 1, (1, 6, 8, 2)).astype(np.float32)
            light = np.exp(logits) / np.exp(logits).sum(axis=-1, keepdims=True)
            warped = transformation.apply_transformation(flows=tf.constant(flow), img=tf.constant(image), num_channels=3)
            result = session.run(flx.apply_lcm(batch_img=warped, light_weight=tf.constant(light)))
            cases.append({
                "height": 6, "width": 8,
                "image": image[0].reshape(-1).tolist(),
                "flow": flow[0].reshape(-1).tolist(),
                "light": light[0].reshape(-1).tolist(),
                "expected": result[0].reshape(-1).tolist(),
            })
    path.write_text(json.dumps({"layout": "row-major height x width x channels", "cases": cases}))
    print(f"Wrote {path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="App/GazeModel/GazeWarp.mlpackage")
    parser.add_argument("--weights", default="build/gaze-weights")
    parser.add_argument("--fixture")
    arguments = parser.parse_args()
    flx, transformation = original_modules(pathlib.Path(arguments.weights) / "original")
    rng = np.random.default_rng(7)
    if arguments.fixture:
        fixture(transformation, flx, rng, pathlib.Path(arguments.fixture))
    model = ct.models.MLModel(arguments.model)
    worst = {"flow": 0.0, "light": 0.0}
    for _ in range(5):
        left, right = random_inputs(rng), random_inputs(rng)
        angle = left[2]
        outputs = model.predict({
            "left_patch": left[0].transpose(0, 3, 1, 2), "left_anchors": left[1].transpose(0, 3, 1, 2),
            "right_patch": right[0].transpose(0, 3, 1, 2), "right_anchors": right[1].transpose(0, 3, 1, 2),
            "angle": angle,
        })
        for side, inputs, prefix in (("L", left, "left"), ("R", right, "right")):
            flow, light, _ = reference(flx, pathlib.Path(arguments.weights), side, inputs[0], inputs[1], angle)
            worst["flow"] = max(worst["flow"], float(np.abs(outputs[f"{prefix}_flow"].transpose(0, 2, 3, 1) - flow).max()))
            worst["light"] = max(worst["light"], float(np.abs(outputs[f"{prefix}_light"].transpose(0, 2, 3, 1) - light).max()))
    # A flow error of 0.01 moves a pixel by a third of a pixel in a 64-pixel-wide patch.
    print(f"largest difference: flow {worst['flow']:.5f}, light {worst['light']:.5f}")
    sys.exit(0 if worst["flow"] < 0.01 and worst["light"] < 0.01 else 1)


if __name__ == "__main__":
    main()
