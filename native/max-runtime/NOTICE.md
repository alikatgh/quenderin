The CPU graph exporter is adapted from Modular Inc.'s
[test_weights_capi.py](https://github.com/modular/modular/blob/527d069ee11a41ac5320af1f9402db0a66b2b868/max/examples/capi/test_weights_capi.py).
The C lifecycle is based on its
[weights_example.c](https://github.com/modular/modular/blob/527d069ee11a41ac5320af1f9402db0a66b2b868/max/examples/capi/weights_example.c)
and [C headers](https://github.com/modular/modular/tree/527d069ee11a41ac5320af1f9402db0a66b2b868/max/include/max/c).
Copyright (c) 2026, Modular Inc. All rights reserved. Those source files carry
the Apache License v2.0 with LLVM Exceptions, reproduced in
`vendor/Apache-2.0-WITH-LLVM-exception.txt`.

This source attribution does not license the binary SDK. The SDK packages
published for 26.7.0 identify `LicenseRef-MAX-Platform-Software-License` in
official PyPI metadata. Their exact embedded terms must be inspected and
recorded before runtime execution. The older Community License in the source
tag is not substituted for those binary terms. This repository redistributes
no MAX binary, compiler, pretrained model, or model weights.

The portable model-adapter boundary in `include/quenderin_max_model.h`,
`src/quenderin_max_model.c` and its fixtures is original Quenderin code. It
copies no Modular source, links no vendor runtime and contains no model
semantics; a separately reviewed runner supplies those.
