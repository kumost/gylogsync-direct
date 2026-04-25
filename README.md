# GyLog Sync Direct (v2.0-beta)

End-to-end macOS utility for processing mirrorless footage together
with GyLog gyro logs, producing ready-to-use `.gyroflow` projects that
load directly into the Gyroflow OFX plugin for DaVinci Resolve — with
no manual sync, no lens profile loading, and no Gyroflow Desktop step
required.

This tool is part of the **GyLog** ecosystem by [Kumo, Inc.](https://kumoinc.com)
(public-facing brand: NagiLab).

## What it does

For each video clip in your batch, GyLog Sync Direct:

1. Slices the master `.gcsv` to the clip's time range
2. Auto-detects mount tilt (`install_angle`) from the gcsv header and
   writes it to `gyro_source.rotation`
3. Applies the IMU axis remap based on the **Phone connector side**
   selector (USB-C/Lightning right → `ZYx`, left → `zYX`)
4. Embeds the optical-flow sync offset (median of 5 sync points,
   outliers >500ms rejected, then applied uniformly across the clip
   for drift-free correction on long takes)
5. Optionally embeds your lens profile's `calibration_data` so DaVinci
   OFX applies lens distortion correction automatically
6. Optionally overrides the rolling-shutter `frame_readout_time` with
   a value you supply (e.g. from
   [horshack-dpreview's RS database](https://horshack-dpreview.github.io/RollingShutter/))
7. Exports a per-clip `.gyroflow` project file ready for OFX consumption
8. Writes a per-folder CSV processing report so you have a record of
   what was processed with what settings

## Workflow

1. Drop mirrorless clips + master GCSV (+ optional lens profile) into
   the app, set Phone connector side and (optional) Rolling Shutter
   value, hit **Sync**
2. Each clip gets a paired `{name}.gcsv` (sliced) and `{name}.gyroflow`
   project; if RS override was set, the file is named
   `{name}_RS{value}ms.gyroflow` so multiple RS attempts can coexist
3. Drop the video clip into a DaVinci Resolve timeline, apply the
   **Gyroflow OFX** plugin on the Color page — it auto-loads the
   matching `.gyroflow` from the same folder and applies stabilization
4. Adjust FOV / smoothness in OFX as needed and export

## Advanced Options

- **Camera Clock Drift (sec)** — manual offset if your camera and
  phone clocks weren't synced at shoot time (rare, ≤2-minute clips
  rarely need this)
- **Sync search range (ms)** — how far the optical-flow sync looks for
  the true offset; default 5000ms
- **Phone connector side** — Right (USB-C/Lightning on right of camera,
  the default Xperia mount) or Left
- **IMU orientation override (advanced)** — force a specific 3-letter
  axis code (e.g. `ZYx`, `XyZ`) for unusual mounts (vertical phone,
  upside-down, screen-down, etc.). Find the right value with Gyroflow
  Desktop's *Auto-detect IMU orientation* on one clip
- **Rolling Shutter (ms)** — manual `frame_readout_time` override.
  Look up your camera at horshack-dpreview's RS DB or measure
  empirically with Gyroflow Desktop's Frame Readout Time slider
- **Lens profile** — file picker for a Gyroflow lens profile JSON.
  When set, embedded as `calibration_data` so DaVinci applies lens
  correction without a manual "Load lens profile" step

## Mount orientation

The IMU axis remap defaults to:
- **Right** (default) → `ZYx` — verified for Sony Xperia / similar
  Android phone with USB-C on the right of the camera and screen up
- **Left** → `zYX` — phone flipped 180° around its long axis (USB-C
  on the left)

Mount **tilt** (forward/back pitch, left/right roll) is automatically
captured by GyLog's *Calibrate Mount* feature and embedded as
`install_angle:R{roll}_P{pitch}` in the gcsv header. The full Euler
range is supported: flat-on-top (~0°), tilted forward (e.g. -52° in
the standard A7R II + Xperia rig), or even vertical (~±90°).

For unusual mounts (vertical phone parallel to the camera back,
upside-down, etc.), use the *IMU orientation override* field.

iPhone-on-mirrorless rigs (with `install_angle` from Calibrate Mount)
share the same Right/Left selector as Android. iPhone *standalone*
(no install_angle, recording with the iPhone's own camera) is detected
automatically and uses `XYZ` (IMU axes match camera axes on the same
device).

## Companion apps

- **GyLog for iOS** — iPhone IMU logger and standalone gyro recorder
  ([App Store](https://apps.apple.com/app/id6759689665))
- **GyLog for Android** — Android IMU logger, primary companion for
  mirrorless rigs (Play Store release in progress)

## Requirements

- macOS 13 (Ventura) or later
- Apple Silicon (Rust bridge built for `arm64`)
- DaVinci Resolve with the [Gyroflow OFX plugin](https://github.com/gyroflow/gyroflow-plugins/releases)
  for the final stabilization

## Building from source

```bash
# Install Rust + librsvg (for app icon generation):
brew install rust librsvg

# Build the Rust bridge + Swift app:
bash build_app.sh

# Build only (skip code signing + notarization, for development):
SKIP_SIGN=1 bash build_app.sh
```

The Rust bridge requires a one-time `cargo` build of `gyroflow-core`
which pulls in OpenCV and FFmpeg (~10 minutes on first build).

## License

Licensed under the **GNU General Public License v3.0** — see
[`LICENSE`](./LICENSE).

This project incorporates `gyroflow-core` from the
[Gyroflow](https://gyroflow.xyz) project (© 2021–present AdrianEddy and
contributors, GPL-3.0). Any binary distribution of this tool must make
the corresponding source code available under the same license — this
GitHub repository fulfills that obligation.

## Acknowledgements

- [Gyroflow](https://github.com/gyroflow/gyroflow) — the stabilization
  engine this tool wraps (GPL-3.0). Please consider
  [supporting Gyroflow](https://gyroflow.xyz/donate) if you find this
  workflow valuable.
- [OpenCV](https://opencv.org/) — optical flow analysis (Apache-2.0)
- [Arm KleidiCV](https://gitlab.arm.com/kleidi/kleidicv) — ARM-optimized
  image primitives (Apache-2.0)
- [Intel oneTBB](https://github.com/uxlfoundation/oneTBB) — parallelism
  framework (Apache-2.0)
- [horshack-dpreview Rolling Shutter Database](https://horshack-dpreview.github.io/RollingShutter/)
  — community reference for camera RS timing

Full dependency list with copyright and license details:
[`THIRD_PARTY_LICENSES.md`](./THIRD_PARTY_LICENSES.md)

## Reporting bugs

Open a [GitHub issue](https://github.com/kumost/gylogsync-direct/issues)
with:
- macOS version + Mac model
- Camera + phone model + mount orientation
- A short clip + gcsv that reproduces the issue (if file size allows)
- The CSV processing report (`GyLogDirect_*.csv`) generated next to the
  clips

---

© 2026 Kumo, Inc.
