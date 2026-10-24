# Copyright (c) 2026, Modular Inc. All rights reserved.
# Adapted for Quenderin from test_weights_capi.py at revision
# 527d069ee11a41ac5320af1f9402db0a66b2b868.
# Licensed under Apache-2.0 WITH LLVM-exception; see ../vendor/.
"""Export a four-element CPU graph; no pretrained model or network is used."""

import os
import pathlib
import sys

# The supervisor must establish isolation before Python imports MAX.
if (os.environ.get("QUENDERIN_MAX_ISOLATED") != "1"
        or os.environ.get("MODULAR_TELEMETRY_ENABLED") != "0"
        or os.environ.get("MODULAR_CRASH_REPORTING_ENABLED") != "0"):
    raise RuntimeError("Isolated MAX runtime with both telemetry opt-outs required")

import numpy as np
from max import engine
from max.driver import CPU
from max.dtype import DType
from max.graph import DeviceRef, Graph, TensorType, ops


def main() -> None:
    target = pathlib.Path(sys.argv[1])
    if not target.is_absolute() or target.suffix != ".mef" or target.exists():
        raise ValueError("New absolute MEF target required")
    tensor_type = TensorType(dtype=DType.float32, shape=(4,), device=DeviceRef.CPU())
    with Graph("quenderin_cpu_weighted_multiply", input_types=(tensor_type,)) as graph:
        weight = ops.constant_external("weight", tensor_type)
        graph.output(graph.inputs[0].tensor * weight)
    session = engine.InferenceSession(devices=[CPU()])
    compiled = session.compile(graph)
    model = session.init(compiled, weights_registry={"weight": np.zeros(4, dtype=np.float32)})
    model._export_mef(str(target))
    if not target.is_file() or not 4 <= target.stat().st_size <= 64 * 1024 * 1024:
        raise RuntimeError("MEF exceeded the finite graph artifact budget")


if __name__ == "__main__":
    main()
