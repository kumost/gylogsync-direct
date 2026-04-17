# GyLog Sync Direct (β)

End-to-end macOS utility for processing Sony/iPhone mirrorless footage
together with Android/iOS gyro logs, producing ready-to-use `.gyroflow`
projects that can be loaded directly into Gyroflow Desktop or the
Gyroflow OFX plugin for DaVinci Resolve.

This tool is part of the **GyLog** ecosystem by [Kumo Inc.](https://kumoinc.com).

## Features

- Slice master GCSV by video `creation_time` + duration
- Trim audio to match video clips
- Perform optical-flow-based sync against the video (via `gyroflow-core`
  Rust FFI bridge, crash-isolated in a subprocess)
- Embed per-frame PTS timestamps into the `.gyroflow` for OFX plugin
  precision
- Automatic lens profile embedding (iPhone 17 Pro 24mm bundled)

## Companion Apps

This tool pairs with the GyLog mobile loggers:

- [GyLog for iOS](https://apps.apple.com/) — iPhone IMU logger
- GyLog for Android — Android IMU logger (forthcoming Play Store release)

## Requirements

- macOS 13 (Ventura) or later
- Apple Silicon recommended (Rust bridge built for `arm64` + `x86_64`)

## License

Licensed under the **GNU General Public License v3.0** — see
[`LICENSE`](./LICENSE).

This project incorporates `gyroflow-core` from the
[Gyroflow](https://gyroflow.xyz) project (© 2021–present AdrianEddy and
contributors, GPL-3.0). Any binary distribution of this tool must make
the corresponding source code available under the same license.

## Acknowledgements

- [Gyroflow](https://github.com/gyroflow/gyroflow) — the stabilization
  engine this tool wraps (GPL-3.0)
- [OpenCV](https://opencv.org/) — optical flow analysis (Apache-2.0)
- [Arm KleidiCV](https://gitlab.arm.com/kleidi/kleidicv) —
  ARM-optimized image primitives (Apache-2.0)
- [Intel oneTBB](https://github.com/uxlfoundation/oneTBB) —
  parallelism framework (Apache-2.0)

Full dependency list with copyright and license details:
[`THIRD_PARTY_LICENSES.md`](./THIRD_PARTY_LICENSES.md)

---

© 2026 Kumo Inc. — contact via [GitHub Issues](https://github.com/kumost/gylogsync-direct/issues)
