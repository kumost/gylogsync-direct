# GyLog Sync Direct (β)

End-to-end macOS utility for processing mirrorless footage together
with GyLog gyro logs, producing ready-to-use `.gyroflow` projects that
can be loaded directly into Gyroflow Desktop or the Gyroflow OFX plugin
for DaVinci Resolve.

This tool is part of the **GyLog** ecosystem by [Kumo Inc.](https://kumoinc.com).

## Features

- Slice master GCSV by video `creation_time` + duration (±5 s buffer
  absorbs camera/phone clock drift)
- Trim audio to match video clips
- Embed per-frame PTS timestamps into the `.gyroflow` for OFX plugin
  precision
- Auto-apply `install_angle` from the gcsv note to `gyro_source.rotation`
  so Gyroflow opens with the mirrorless rig's mount pitch/roll
  pre-compensated
- Pre-set `gyro_source.imu_orientation` to `ZYx` — the axis remap
  Gyroflow Desktop's gcsv Android Motion Logger loader uses internally,
  so the emitted `.gyroflow` opens with correct axes out of the box
  (assuming the default USB-C-on-right mount; see
  [Mount orientation](#mount-orientation) below)

Lens profiles are not bundled — load whichever profile matches your
mirrorless lens inside Gyroflow Desktop (or DaVinci via the OFX plugin)
after the `.gyroflow` project is generated.

## Workflow

1. Drop mirrorless clips + master GCSV into the app, hit **Sync**
2. Each clip gets a paired `.gcsv` (sliced) and `.gyroflow` (project)
3. Open the `.gyroflow` in Gyroflow Desktop (or DaVinci via OFX)
4. Load the lens profile for your camera/lens combo
5. Click **Auto sync** in Gyroflow to establish per-clip sync points
6. Export stabilized footage

The app does not attempt to embed sync offsets in the `.gyroflow` —
Gyroflow's own `Auto sync` is more accurate and runs in seconds per clip.

## Mount orientation

The `imu_orientation` defaults to `ZYx`, verified for this mount:
- Sony Xperia / similar Android phone
- USB-C socket on the **right**
- Screen facing **up**

For other mounts (USB-C on left, phone vertical, selfie-mode, etc.),
change the *IMU orientation* field in Gyroflow Desktop. A future update
to this tool will auto-detect the axis remap from the gravity vector
that GyLog v1.0.4+ records during Calibrate Mount.

## Companion Apps

This tool pairs with the GyLog mobile loggers:

- GyLog for Android — Android IMU logger, the primary companion for
  mirrorless rigs (Play Store release in progress)
- [GyLog for iOS](https://apps.apple.com/) — iPhone IMU logger

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
