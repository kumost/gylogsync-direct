# GyLog Sync Direct — Tutorial

A step-by-step guide for going from a mirrorless rig + phone to a
stabilized DaVinci Resolve clip without touching Gyroflow Desktop.

This document is intentionally text-only — the GitHub source obligation
makes the tutorial available alongside the code. Screenshots, diagrams,
and a YouTube companion video will be added later. If something is
unclear because of the lack of visuals, please open a
[GitHub issue](https://github.com/kumost/gylogsync-direct/issues) and
we'll prioritize that section.

> **Audience**: someone who has shot mirrorless video before and used
> DaVinci Resolve, but is new to Gyroflow-based stabilization.

---

## What you need

### Hardware

- **Mirrorless camera** that records video your editor can read (most
  Sony A7 / FX, Panasonic GH/S, Fuji X-T, Canon R, Nikon Z). The user
  this tool was tuned on shoots with a **Sony A7R II**, ProRes/H.264
  modes.
- **Smartphone** running [GyLog](#1-install-the-gylog-app):
  - Android: any device with a hardware gyroscope (most phones since
    2018). Tested on Sony Xperia.
  - iPhone: iPhone XS or later (any device that supports
    [CMMotionManager](https://developer.apple.com/documentation/coremotion/cmmotionmanager)
    at 100 Hz).
- **Hot-shoe / cage mount** to attach the phone rigidly to the
  camera. The phone must move *with* the camera — any independent
  movement breaks the optical-flow sync. SmallRig, Ulanzi, and
  TilTPro all sell phone clamps that fit a standard 1/4" or
  hot-shoe mount. Make sure the clamp grips the phone *tight*: a
  loose phone introduces phantom motion that corrupts the gyro
  reading.
- (Optional) **Calibration board** for making lens profiles. Gyroflow
  recommends an asymmetric chessboard you can print at home. See
  [making a lens profile](#step-3-make-a-lens-profile-once-per-lens).

### Software

- **macOS 13 (Ventura) or later** on Apple Silicon.
- **GyLog Sync Direct** (this tool) — get the signed and notarized
  binary from [kumoinc.com/gylog-direct](https://kumoinc.com/gylog-direct)
  or build from source (see the README).
- **DaVinci Resolve** (free or Studio) — for the final stabilization.
- **Gyroflow OFX plugin** — install from
  [github.com/gyroflow/gyroflow-plugins/releases](https://github.com/gyroflow/gyroflow-plugins/releases).
  This is the plugin DaVinci uses to apply your `.gyroflow` files.
- **Gyroflow Desktop** (optional but recommended for setup) — used
  *one time* to create your lens profile and (optionally) measure
  your camera's rolling shutter value. Download from
  [gyroflow.xyz](https://gyroflow.xyz).

---

## The big picture

There are two phases:

```
ONE-TIME SETUP (do once per camera + lens)
├─ 1. Install GyLog on your phone
├─ 2. Mount phone to camera + run Calibrate Mount
├─ 3. Make a lens profile in Gyroflow Desktop
└─ 4. (Optional) Find rolling-shutter value for your camera

EVERY SHOOT (do once per shooting session)
├─ 5. Start GyLog before recording
├─ 6. Shoot normally
├─ 7. Stop GyLog after the last clip
├─ 8. Transfer files to Mac
├─ 9. Process with GyLog Sync Direct
└─ 10. Edit in DaVinci with the Gyroflow OFX plugin
```

The setup phase takes about 30 minutes the first time. Each shoot adds
~5 minutes of admin (start GyLog, transfer files, run the batch).

---

## ONE-TIME SETUP

### Step 1: Install the GyLog app

GyLog is the companion app that records the gyro/accelerometer log
while you shoot. The motion data ends up in a `.gcsv` file your Mac
later reads alongside the video.

- iOS: [App Store link](https://apps.apple.com/app/id6759689665)
- Android: Google Play release in progress; sideload from
  [kumoinc.com/gylog-android](https://kumoinc.com/gylog-android) for now

Open the app once, give it motion-sensor permission, and confirm it
shows live gyro readings. That's it.

### Step 2: Mount phone to camera + run Calibrate Mount

This is the most important physical step. Get the geometry right and
the rest of the workflow is auto-detected. Get it wrong and you'll
either fight the IMU orientation field or recompute install_angle on
every shoot.

**Goal**: phone rigidly attached to camera with a known orientation
relative to the lens.

#### Standard mount (recommended)

The default that GyLog Sync Direct ships for is:

- Phone is **landscape** (long edge horizontal)
- **USB-C / Lightning connector points to the right** of the camera
  (right when you're behind the camera looking forward through the
  lens)
- Phone screen faces **up** when the camera is held horizontally

```
        ┌─────────────────────────┐
        │     ●         GyLog     │   ← phone screen (facing up)
        │                         │
        └─────────────────────[▣]─┘   ← USB-C on the right
                                  │
       [▲▲▲ camera body ▲▲▲]      │
        │  ◯  Lens                │
        └─────────────────────────┘
                                  ↑
                        photographer's right
```

This corresponds to **Phone connector side: Right** in the app
(default), which writes `imu_orientation: ZYx` into every `.gyroflow`.

#### Other mounts

If the phone is mirrored — USB-C on the *left* — flip the **Phone
connector side** selector to **Left**. The app will write
`imu_orientation: zYX` instead. Tilt is still auto-detected (see next
step), so this is the only setting that needs flipping.

For exotic mounts (phone vertical against the camera back, screen
facing down, upside-down, etc.) the connector-side selector doesn't
cover them. Use the *IMU orientation override (advanced)* field with a
3-letter axis code. To find the right code, run **Auto-detect IMU
orientation** in Gyroflow Desktop on one clip from your rig, copy the
3-letter result, and paste it into the override field.

#### Calibrate Mount (in GyLog)

After the phone is mounted, the camera and phone almost certainly
aren't perfectly level — the phone is tilted forward, back, or sideways
relative to the lens axis. You don't need to align them physically;
GyLog records the offset for you.

1. Set up the camera + mounted phone on a tripod. Make the camera
   level (use a bubble level or your tripod head's built-in level).
   The lens should be pointing horizontally — at the horizon, or at
   the wall, just not up or down.
2. Open GyLog and tap **Calibrate Mount**.
3. Hold still for the few seconds the app prompts.
4. The app reads the gravity vector at that moment, computes the
   pitch and roll the phone is offset by, and bakes that into every
   subsequent `.gcsv` log as `install_angle:R{roll}_P{pitch}` in the
   header.

You only need to do this **once per physical mount setup**. If you
remove the phone and re-attach it the same way, you don't need to
recalibrate. If you change the phone clamp angle, the rig, or the
camera body, run Calibrate Mount again.

GyLog Sync Direct reads `install_angle` from the gcsv header
automatically and applies it to `gyro_source.rotation` in the
`.gyroflow` output, so DaVinci sees a level horizon as soon as the
plugin loads.

### Step 3: Make a lens profile (once per lens)

Lens profiles tell Gyroflow how your specific lens distorts the image,
which lets the stabilizer correct the distortion as it warps the
frame. Without a lens profile, you can still stabilize, but you'll see
a slight "warping" of straight lines near the frame edges.

Lens profiles are made in **Gyroflow Desktop's Calibrator**, not in
GyLog Sync Direct. This is a one-time process per lens.

1. Open Gyroflow Desktop.
2. Open the Calibrator tool (top menu → "Calibrator" or similar).
3. Print or display an
   [asymmetric chessboard pattern](https://docs.gyroflow.xyz/app/calibration/calibration-target).
4. Mount the camera with the lens you want to calibrate. Set it to
   the resolution and frame rate you typically shoot at (e.g. 4K 24p
   for the A7R II + Zeiss CP.2 25mm).
5. Record a 30–60 second clip while moving the camera so the
   chessboard fills different parts of the frame from different angles.
   Gyroflow's documentation walks through this with diagrams.
6. Drop the clip into the Calibrator. It auto-detects the chessboard
   in each frame and computes the camera matrix.
7. Save the profile as a `.json` file somewhere you'll remember
   (e.g. `~/LensProfiles/sony_a7r2_zeiss_cp2_25mm.json`).

Re-use that JSON file every time you shoot with the same lens at the
same resolution / frame rate.

> **Multi-resolution caveat**: a profile calibrated at 4K may not
> match perfectly when you shoot at FHD. Gyroflow's profile format
> supports `compatible_settings` for multiple fps at the same
> resolution, but cross-resolution use is best avoided. Shoot at the
> resolution you calibrated at.

### Step 4: (Optional) Find your rolling-shutter value

Most rolling shutters introduce a small per-pixel time delay as the
sensor reads top-to-bottom (or bottom-to-top). Gyroflow can compensate
for this if you provide the **frame readout time** in milliseconds.

You can skip this step initially and come back to it only if your
stabilized footage shows a "wobble" or "jello" effect that doesn't
match the camera's actual movement. That wobble is rolling shutter
the stabilizer didn't know about.

#### Where to get the value

**Database lookup** (fastest):
- Visit [horshack-dpreview.github.io/RollingShutter](https://horshack-dpreview.github.io/RollingShutter/).
- Search for your camera model.
- Find the row matching your resolution and frame rate.
- Copy the "Sensor Readout Time" value in milliseconds.
  - Example: Sony A7R II at 4K 24p ≈ 31 ms.

**Empirical measurement** (most accurate for your specific copy):
1. In Gyroflow Desktop, load one of your synced clips with its lens
   profile.
2. Run **Auto sync**.
3. Move the **Frame Readout Time** slider in the Stabilization tab.
4. Watch the preview as you scrub: a too-low value shows a wobble
   that *opposes* camera motion, a too-high value shows wobble that
   *follows* camera motion. Center it where the preview is steadiest.
5. Note the value.

#### Where to enter it

In GyLog Sync Direct, type the value into the **Rolling Shutter (ms)**
field in Advanced Options. Leave it blank to use the lens profile's
embedded value (if present), or to skip rolling-shutter correction
entirely.

> Rolling shutter is **per camera body + per resolution + per fps**,
> *not* per lens. A lens profile and a rolling-shutter value are
> different things, even though both end up in the `.gyroflow` file.

---

## EVERY SHOOT

Now the fun part — what you actually do on a shoot day.

### Step 5: Start GyLog before recording

1. Mount the phone (already calibrated).
2. Open GyLog on the phone. The phone's clock should be roughly
   synced with the camera's clock (within a few seconds). If you're
   paranoid, both can be set to NTP / network time before the shoot.
3. Tap **Start logging**. The app records gyro + accelerometer at
   100 Hz and writes a single continuous `.gcsv` file for the entire
   session.
4. Lock the phone screen (or set the app to keep the screen on with
   the display dimmed). The screen state doesn't affect logging — IMU
   data keeps streaming.

### Step 6: Shoot normally

Roll the camera. Cut. Roll again. The phone keeps logging through
every take and every pause. You don't need to start/stop GyLog per
clip — one master `.gcsv` covers them all, and GyLog Sync Direct
slices the master log to each clip's time range automatically.

> Don't move the phone in its mount during the shoot. If you bump it
> hard or the clamp slips, the install_angle is now wrong for every
> subsequent take. Run Calibrate Mount again.

### Step 7: Stop GyLog after the last clip

In GyLog, tap **Stop**. The app saves the `.gcsv` file to local
storage. The filename includes the start timestamp, e.g.
`GyroLog_20260421_114634.gcsv`.

### Step 8: Transfer files to Mac

You need:
- All the `.MP4` / `.mov` clips from the camera (transfer the entire
  card folder is fine; Direct ignores files that don't have matching
  gyro overlap).
- The single master `.gcsv` from GyLog.
- (Optional) Your lens profile `.json` (from Step 3).

Drop everything into one folder on your Mac. The `.gyroflow` outputs
will be written into the same folder.

### Step 9: Process with GyLog Sync Direct

1. Launch the app. The first time, right-click → Open to bypass the
   first-launch warning, then on subsequent launches double-click
   normally.
2. Drag your video files + master `.gcsv` into the drop zone.
3. Open **Advanced Options**:
   - **Phone connector side**: leave at **Right** unless your phone
     is mirror-mounted.
   - **Lens profile**: click *Choose…* and select your `.json`.
   - **Rolling Shutter (ms)**: leave blank, or paste your value from
     Step 4. (Recommended: try blank first, fill in only if needed.)
   - **IMU orientation override**: leave blank unless you have an
     unusual mount that the connector side selector doesn't cover.
4. Hit **Sync**.
5. Watch the progress bar. Sync runs the optical-flow analysis on
   each clip (a few seconds per clip on M2 Max). Output appears in
   the source folder as `{clip_name}.gcsv` (sliced gyro) and
   `{clip_name}.gyroflow` (or `{clip_name}_RS{value}ms.gyroflow` if
   you set a Rolling Shutter value).
6. After the batch, a CSV processing report named
   `GyLogDirect_P{pitch}_R{roll}_{date}.csv` is written to each
   source folder. It records every clip's status, timing fix,
   IMU orientation used, and so on. Keep this for your records or
   to attach to bug reports.

### Step 10: Edit in DaVinci with the Gyroflow OFX plugin

1. Drag the source video clips (NOT the `.gyroflow` files) into a
   DaVinci timeline.
2. Switch to the Color page.
3. Select the clip in the timeline.
4. In the OpenFX panel (right side), drag the **Gyroflow** plugin
   onto the clip's node tree.
5. The OFX plugin auto-loads the matching `.gyroflow` file from the
   clip's source folder. You should see "Loaded project:
   {clip}.gyroflow" in the plugin's Info section.
6. Play back. The clip should be stabilized. If it isn't:
   - Check the **Loaded lens profile** field shows your lens.
   - Check the plugin's Info section for any error.
   - See [Troubleshooting](#troubleshooting).
7. Adjust **Smoothness** (default 49) and **Zoom limit** if you want
   tighter or looser stabilization.
8. Render the timeline as usual. The plugin warps the clip in real
   time during playback and during export.

---

## Troubleshooting

### Stabilization isn't kicking in

Symptoms: clip plays back unstabilized in DaVinci even though OFX is
applied.

Checklist:
1. Is the clip's source folder the same as where the `.gyroflow`
   was written? OFX only auto-loads from the clip's parent folder.
2. Open the `.gyroflow` file in a text editor. Confirm:
   - `gyro_source.imu_orientation` is set (e.g. `"ZYx"`).
   - `offsets` is non-empty (sync ran).
   - `gyro_source.filepath` points at an existing `.gcsv`.
3. Make sure the `.gcsv` is also in the same folder. If you moved
   files after processing, update the path inside the `.gyroflow`
   manually or re-process.

### Stabilization works for the first half but the second half drifts

This was a bug in v1.x and earlier v2.0 builds. v2.0-beta uses a
single uniform offset across the clip (median of 5 sync points,
outliers rejected) which prevents this. If you're seeing it on
v2.0-beta, please open a bug report with the CSV processing report
and a short clip sample.

### Stabilization is "too much" or rotates wildly

Most likely IMU orientation is wrong (right axes, wrong signs).
Symptoms:
- Stabilization fights the camera motion (warps the wrong way).
- Frame jitters violently.

Try:
1. Flip **Phone connector side** between Right and Left.
2. If neither works, your mount probably isn't a "screen up" mount.
   Run Gyroflow Desktop's *Auto-detect IMU orientation* on one clip
   and paste the resulting 3-letter code into **IMU orientation
   override** in GyLog Sync Direct.

### "Failed to load the selected file" or PermissionDenied dialog in Gyroflow Desktop

GyLog Sync Direct v2.1-beta and later embed a macOS file bookmark in
each `.gyroflow` so Gyroflow Desktop can resolve the source video and
gcsv even on external volumes. Most files should now open cleanly.

You may still see a non-fatal **"Filesystem error … PermissionDenied"**
dialog when opening a `.gyroflow` in Gyroflow Desktop. This is a
known Gyroflow Desktop / macOS TCC quirk that fires on load even when
the project loads successfully. Click **Ok** — the preview, motion
data, and stabilization sliders will all work normally.

If the file genuinely fails to load (no preview, no motion data),
open System Settings → Privacy & Security → Full Disk Access and
add `Gyroflow.app`, then reopen.

DaVinci Resolve's OFX plugin doesn't show or trigger this dialog.

### "No log overlap" for some clips

Some clips were recorded outside the gcsv log's time range. Check:
- Did GyLog stop logging mid-shoot (battery, app crash, manual stop)?
- Is the camera's clock several hours off from the phone's clock?
  GyLog Sync Direct only handles ±5 seconds of drift automatically.
  For larger drift, set the **Camera Clock Drift (sec)** field
  manually in Advanced Options.

### iPhone-on-mirrorless doesn't stabilize correctly

iPhone-on-mirrorless uses the same Phone connector side selector as
Android. **This combination is not extensively tested in v2.0-beta.**
If it doesn't work:
1. Confirm Calibrate Mount was run with the iPhone in its mount.
2. Try the IMU orientation override field.
3. File a bug — we want to add iPhone-on-mirrorless presets if needed.

### Random crashes during sync

Optical-flow sync is the slowest and most fragile step. If a clip
crashes the sync subprocess (you'll see "Sync crashed (signal …)" in
the log), the app falls back to a timestamp-only export. The fallback
output works in DaVinci but doesn't have an embedded sync offset
(you'd need to use Gyroflow Desktop's Auto sync to refine it).

Most common cause: the clip has very low motion (camera locked off
on a tripod for the whole take). Optical flow can't find features to
correlate. This is a known limitation of the underlying gyroflow-core
algorithm, not specific to GyLog Sync Direct.

---

## FAQ

### Do I need GyLog if my camera has built-in stabilization (IBIS)?

Yes. IBIS is mechanical sensor-shift stabilization done at capture
time. GyLog + Gyroflow is software stabilization done in post.
They're complementary: IBIS handles small high-frequency jitter
(handheld micro-movement), Gyroflow handles larger movement (walking,
running, panning). GyLog records the gyro data Gyroflow needs.

### Why not just use Resolve's built-in stabilizer?

Resolve's stabilizer estimates motion from optical flow alone — it
sees pixels move and tries to reverse the motion. With low-light
footage, motion blur, or scenes with little detail, optical-flow
stabilizers fail or introduce warps. Gyroflow uses the actual phone
gyro data, which is independent of the image content, and is much
more reliable for fast pans, low light, and complex scenes.

### Can I use this without a lens profile?

Yes, but distortion correction won't be applied. Stabilization still
works. Straight lines near the frame edges may bow slightly during
heavy stabilization. For most casual use you won't notice.

### My phone has a different connector position than your defaults

The connector side selector covers the two most common landscape
mounts. For everything else, find the right IMU orientation in
Gyroflow Desktop and paste the 3-letter code into the override field.
We'll add more presets as we collect feedback.

### How long can a clip be?

Tested up to ~3 minutes. Longer clips should work but optical-flow
sync time scales linearly. If you have very long takes (5+ minutes),
expect proportionally longer processing.

### Where's the YouTube tutorial?

Coming. This text guide is the source material.

---

## Sharing .gyroflow files publicly

Each `.gyroflow` written by GyLog Sync Direct contains a macOS file
bookmark for the source video and gcsv (in `videofile_bookmark` and
`gyro_source.filepath_bookmark`). These bookmarks let Gyroflow Desktop
reopen the project on the same machine without manually re-locating
files, and follow the same on-disk format Gyroflow Desktop itself
writes.

The bookmark blobs include local filesystem context the OS uses to
resolve the file: the volume UUID, the absolute file path, and your
macOS user account (via the home directory). If you plan to **share a
`.gyroflow` file publicly** (forum attachment, GitHub issue, sample
download, blog post), be aware that this information is included in
the file. There's no realistic security risk — bookmarks can't be
"replayed" to access your files from a different machine — but if
you'd rather not leak your username or folder layout, regenerate the
project with anonymized paths or strip the bookmark fields before
sharing.

## Reporting bugs

If something doesn't work the way this tutorial says it should, please
open a [GitHub issue](https://github.com/kumost/gylogsync-direct/issues).
Include:

- macOS version + Mac model.
- Camera + phone model + how the phone is mounted.
- The CSV processing report (`GyLogDirect_*.csv`) generated next to
  the clips.
- A short clip + gcsv that reproduces the issue (Dropbox / WeTransfer
  link is fine).
- The terminal output if you launched the app from a terminal:

  ```bash
  /Applications/GyLogSync_Direct.app/Contents/MacOS/GyLogSync_Direct
  ```

---

© 2026 Kumo, Inc. — released under the GNU General Public License v3.0.
