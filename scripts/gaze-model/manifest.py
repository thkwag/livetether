#!/usr/bin/env python3
"""Writes where each weight sits in the published gaze-warping checkpoints.

The app downloads the checkpoint data files from the original repository at a pinned commit and
reads each weight from its byte offset; this manifest holds those offsets, shapes and the files'
SHA-256 digests. It holds no weight values. Offsets are found by locating each tensor's bytes in the
data file, and every tensor must occur exactly once.

Requires Python 3.11 with tensorflow 2.15.
Usage: python3 scripts/gaze-model/manifest.py [--weights build/gaze-weights] [--out PATH]
"""

import argparse
import hashlib
import json
import pathlib
import urllib.request

import numpy as np
import tensorflow as tf

COMMIT = "7cc76e4ccaf76c950730c593ffa22bed30c807a4"
SOURCE = f"https://github.com/chihfanhsu/gaze_correction/raw/{COMMIT}/gaze_correction_system/weights/warping_model/flx/12"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", default="build/gaze-weights")
    parser.add_argument("--out", default="Packages/LumixKit/Sources/LumixVideo/Resources/gaze-weights.json")
    arguments = parser.parse_args()
    manifest = {"source": SOURCE, "commit": COMMIT, "files": {}}
    for side in ("L", "R"):
        folder = pathlib.Path(arguments.weights) / side
        folder.mkdir(parents=True, exist_ok=True)
        data_name = f"{side}.data-00000-of-00001"
        for name in (f"{side}.index", data_name):
            if not (folder / name).exists():
                urllib.request.urlretrieve(f"{SOURCE}/{side}/{name}", folder / name)
        data = (folder / data_name).read_bytes()
        reader = tf.train.load_checkpoint(str(folder / side))
        tensors = {}
        for name, shape in sorted(reader.get_variable_to_shape_map().items()):
            if not name.startswith("warping_model/") or "Adam" in name:
                continue
            raw = reader.get_tensor(name).astype("<f4").tobytes()
            offset = data.find(raw)
            assert offset >= 0 and data.find(raw, offset + 1) < 0, f"{name} is not found exactly once"
            tensors[name.removeprefix("warping_model/")] = {"offset": offset, "shape": list(shape)}
        manifest["files"][side] = {
            "path": f"{side}/{data_name}",
            "size": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "tensors": tensors,
        }
    out = pathlib.Path(arguments.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(manifest, indent=1, sort_keys=True))
    print(f"Wrote {out}: {sum(len(f['tensors']) for f in manifest['files'].values())} tensors")


if __name__ == "__main__":
    main()
