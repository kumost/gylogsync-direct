# Third-Party Licenses

GyLogSync Direct links against or redistributes several third-party
components. This file lists each one with its copyright holder and
license. Consult the upstream project's own `LICENSE` file for the full
legal text.

## Linked as GPL-3.0 (dictates this project's license)

### Gyroflow (gyroflow-core)
- Copyright © 2021–present AdrianEddy and contributors
- License: GNU General Public License v3.0
- Source: https://github.com/gyroflow/gyroflow

## Statically linked dependencies

These libraries are included as prebuilt static archives in
`lib_static/`. They are transitive dependencies pulled in by
`gyroflow-core`.

### OpenCV
- Copyright © 2000–present OpenCV.org and contributors
- License: Apache License 2.0
- Source: https://github.com/opencv/opencv
- Components: `libopencv_core.a`, `libopencv_imgproc.a`,
  `libopencv_calib3d.a`, `libopencv_features2d.a`, `libopencv_flann.a`,
  `libopencv_video.a`, `libopencv_dnn.a`, `libopencv_imgcodecs.a`,
  `libopencv_ximgproc.a`, `libopencv_optflow.a`

### ADE (OpenCV Graph Framework)
- Copyright © Intel Corporation
- License: Apache License 2.0
- Source: https://github.com/opencv/ade
- Component: `libade.a`

### Arm KleidiCV
- Copyright © Arm Limited and contributors
- License: Apache License 2.0
- Source: https://gitlab.arm.com/kleidi/kleidicv
- Components: `libkleidicv.a`, `libkleidicv_hal.a`,
  `libkleidicv_thread.a`, `libtegra_hal.a`

### Intel oneTBB (Threading Building Blocks)
- Copyright © Intel Corporation
- License: Apache License 2.0
- Source: https://github.com/uxlfoundation/oneTBB
- Components: `libtbb.a`, `libtbbmalloc.a`

### Intel ITT (Instrumentation and Tracing Technology)
- Copyright © Intel Corporation
- License: 3-Clause BSD License
- Source: https://github.com/intel/ittapi
- Component: `libittnotify.a`

## Rust crate dependencies (compiled into `lib/libgylogsync_bridge.a`)

The Rust bridge pulls in many crates via Cargo. Their licenses are
predominantly MIT or Apache-2.0 — see `rust-bridge/Cargo.lock` for the
full resolved dependency graph. Direct dependencies as declared in
`rust-bridge/Cargo.toml`:

| Crate             | Typical license   |
|-------------------|-------------------|
| `gyroflow-core`   | GPL-3.0           |
| `serde_json`      | MIT OR Apache-2.0 |
| `parking_lot`     | MIT OR Apache-2.0 |
| `log`             | MIT OR Apache-2.0 |
| `env_logger`      | MIT OR Apache-2.0 |
| `libc`            | MIT OR Apache-2.0 |
| `itertools`       | MIT OR Apache-2.0 |

## Apple SDK Frameworks

This macOS app uses AVFoundation, CoreMedia, CoreVideo, VideoToolbox,
and AppKit — all bundled with macOS and covered by the Apple SDK
License Agreement. No redistribution of Apple code is performed by
this project.

## Notes on GPL compatibility

All statically linked dependencies above are license-compatible with
GPL-3.0. Apache-2.0 and BSD are permissive and may be combined with
GPL-3.0. The transitive `gyroflow-core` inclusion is what dictates
this project's GPL-3.0 license.
