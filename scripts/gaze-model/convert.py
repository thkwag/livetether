#!/usr/bin/env python3
"""Builds the Core ML model behind eye contact correction from the published gaze-warping weights.

The network is the warping model of "Look at Me! Correcting Eye Gaze in Live Video Communication"
(Hsu et al., ACM TOMM 2019; code and weights BSD-3-Clause, github.com/chihfanhsu/gaze_correction).
Its training data is offered for non-commercial use only, so neither the weights nor the converted
model are committed: this script downloads the weights and writes the model to a git-ignored path.

The model takes, per eye, a 64x48 BGR patch scaled to 0...1, twelve anchor maps (for six eye
landmarks, column minus landmark x and row minus landmark y, in patch pixels) and the redirection
angle (vertical, horizontal) in degrees. It returns, per eye, the warp flow in normalized patch
coordinates and the two light-correction weights; the app applies both.

Requires Python 3.11 with tensorflow 2.15 (to read the checkpoints) and coremltools 8.

Usage: python3 scripts/gaze-model/convert.py [--out App/GazeModel] [--weights DIR]
"""

import argparse
import pathlib
import urllib.request

import numpy as np
import tensorflow as tf
import coremltools as ct
from coremltools.converters.mil import Builder as mb

SOURCE = "https://github.com/chihfanhsu/gaze_correction/raw/7cc76e4ccaf76c950730c593ffa22bed30c807a4/gaze_correction_system/weights/warping_model/flx/12"
HEIGHT, WIDTH = 48, 64
EPSILON = 1e-5


def download(weights: pathlib.Path):
    for side in ("L", "R"):
        folder = weights / side
        folder.mkdir(parents=True, exist_ok=True)
        for name in (f"{side}.index", f"{side}.data-00000-of-00001"):
            target = folder / name
            if not target.exists():
                urllib.request.urlretrieve(f"{SOURCE}/{side}/{name}", target)


class Weights:
    def __init__(self, path: pathlib.Path):
        self.reader = tf.train.load_checkpoint(str(path))

    def __getitem__(self, name):
        return self.reader.get_tensor("warping_model/" + name).astype(np.float32)


def conv_block(x, w, scope, relu=True):
    """Convolution without bias, then ReLU and batch normalization, as the original cnn_blk."""
    kernel = w[f"{scope}/kernel" if not relu else f"{scope}/cnn/kernel"]
    y = mb.conv(x=x, weight=np.transpose(kernel, (3, 2, 0, 1)), pad_type="same")
    if not relu:
        return y
    y = mb.relu(x=y)
    return mb.batch_norm(
        x=y,
        mean=w[f"{scope}/bn_layer/moving_mean"],
        variance=w[f"{scope}/bn_layer/moving_variance"],
        gamma=w[f"{scope}/bn_layer/gamma"],
        beta=w[f"{scope}/bn_layer/beta"],
        epsilon=EPSILON,
    )


def trans_module(x, w, scope):
    b0 = conv_block(x, w, f"{scope}/cnn_blk_0")
    b1 = conv_block(b0, w, f"{scope}/cnn_blk_1")
    b2 = conv_block(mb.concat(values=[b0, b1], axis=1), w, f"{scope}/cnn_blk_2")
    b3 = conv_block(mb.concat(values=[b0, b1, b2], axis=1), w, f"{scope}/cnn_blk_3")
    return conv_block(b3, w, f"{scope}/cnn_4", relu=False)


def eye(patch, anchors, angle, w):
    encoded = angle
    for index in range(3):
        name = f"encoder/dnn_blk_{index}/dnn"
        encoded = mb.relu(x=mb.linear(x=encoded, weight=w[f"{name}/kernel"].T, bias=w[f"{name}/bias"]))
    angle_map = mb.tile(x=mb.reshape(x=encoded, shape=[1, 16, 1, 1]), reps=[1, 1, HEIGHT, WIDTH])
    inputs = mb.concat(values=[patch, anchors, angle_map], axis=1)
    small = mb.avg_pool(x=inputs, kernel_sizes=[2, 2], strides=[2, 2], pad_type="valid")
    coarse = mb.tanh(x=trans_module(small, w, "warping_module/coarse_level"))
    coarse = mb.upsample_nearest_neighbor(x=coarse, scale_factor_height=2, scale_factor_width=2)
    # TensorFlow's SAME average pooling with stride 1 pads the bottom and right edge and leaves the
    # padding out of the average.
    coarse = mb.pad(x=coarse, pad=[0, 0, 0, 0, 0, 1, 0, 1], mode="replicate")
    coarse = mb.avg_pool(x=coarse, kernel_sizes=[2, 2], strides=[1, 1], pad_type="valid")
    fine = trans_module(mb.concat(values=[inputs, coarse], axis=1), w, "warping_module/fine_level")
    flow, light = mb.split(x=fine, num_splits=2, axis=1)
    l0 = conv_block(light, w, "lcm_module/cnn_blk_0")
    l1 = conv_block(l0, w, "lcm_module/cnn_blk_1")
    light = mb.softmax(x=conv_block(l1, w, "lcm_module/cnn_2", relu=False), axis=1)
    return mb.tanh(x=flow), light


def build(weights: pathlib.Path, precision):
    left, right = Weights(weights / "L" / "L"), Weights(weights / "R" / "R")
    spec = lambda channels: mb.TensorSpec(shape=(1, channels, HEIGHT, WIDTH))

    @mb.program(input_specs=[spec(3), spec(12), spec(3), spec(12), mb.TensorSpec(shape=(1, 2))])
    def program(left_patch, left_anchors, right_patch, right_anchors, angle):
        left_flow, left_light = eye(left_patch, left_anchors, angle, left)
        right_flow, right_light = eye(right_patch, right_anchors, angle, right)
        return (
            mb.identity(x=left_flow, name="left_flow"),
            mb.identity(x=left_light, name="left_light"),
            mb.identity(x=right_flow, name="right_flow"),
            mb.identity(x=right_light, name="right_light"),
        )

    return ct.convert(
        program,
        convert_to="mlprogram",
        compute_precision=precision,
        minimum_deployment_target=ct.target.macOS14,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default="App/GazeModel")
    parser.add_argument("--weights", default="build/gaze-weights")
    parser.add_argument("--float16", action="store_true", help="16-bit weights; faster, but the flow drifts by up to 0.05")
    arguments = parser.parse_args()
    weights = pathlib.Path(arguments.weights)
    download(weights)
    precision = ct.precision.FLOAT16 if arguments.float16 else ct.precision.FLOAT32
    model = build(weights, precision)
    model.short_description = "Eye gaze warping (Hsu et al. 2019, BSD-3-Clause; trained on non-commercial data)"
    out = pathlib.Path(arguments.out)
    out.mkdir(parents=True, exist_ok=True)
    model.save(str(out / "GazeWarp.mlpackage"))
    print(f"Wrote {out / 'GazeWarp.mlpackage'}")


if __name__ == "__main__":
    main()
