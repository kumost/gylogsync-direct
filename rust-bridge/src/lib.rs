// lib.rs
// Copyright (C) 2026 Kumo, Inc.
// Licensed under the GNU General Public License v3.0
// https://github.com/kumost/GyLogSync

use std::ffi::{CStr, CString};
use std::fs;
use std::io::Cursor;
use std::os::raw::c_char;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

use gyroflow_core::StabilizationManager;
use gyroflow_core::synchronization::{AutosyncProcess, SyncParams};
use parking_lot::RwLock;

/// Opaque context
pub struct GFContext {
    manager: StabilizationManager,
    sync: Option<AutosyncProcess>,
    cancel_flag: Arc<AtomicBool>,
    /// Offsets computed by AutosyncProcess: Vec<(timestamp_ms, offset_ms, cost)>
    computed_offsets: Arc<RwLock<Vec<(f64, f64, f64)>>>,
    /// Original IMU orientation from GCSV (saved before override for autosync)
    original_imu_orientation: Option<String>,
    /// IMU orientation detected by guess_imu_orientation autosync mode
    detected_orientation: Arc<RwLock<Option<String>>>,
}

// ── Helpers ──────────────────────────────────────────

fn set_error(msg: &str, error_out: *mut *mut c_char) {
    if !error_out.is_null() {
        if let Ok(c) = CString::new(msg) {
            unsafe { *error_out = c.into_raw(); }
        }
    }
}

// ── Context lifecycle ────────────────────────────────

#[no_mangle]
pub extern "C" fn gf_context_new() -> *mut GFContext {
    let _ = env_logger::try_init();
    let ctx = Box::new(GFContext {
        manager: StabilizationManager::default(),
        sync: None,
        cancel_flag: Arc::new(AtomicBool::new(false)),
        computed_offsets: Arc::new(RwLock::new(Vec::new())),
        original_imu_orientation: None,
        detected_orientation: Arc::new(RwLock::new(None)),
    });
    Box::into_raw(ctx)
}

#[no_mangle]
pub extern "C" fn gf_context_free(ctx: *mut GFContext) {
    if !ctx.is_null() {
        unsafe { drop(Box::from_raw(ctx)); }
    }
}

#[no_mangle]
pub extern "C" fn gf_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe { drop(CString::from_raw(s)); }
    }
}

// ── Step 1: Initialize with video info ───────────────

#[no_mangle]
pub extern "C" fn gf_init_video(
    ctx: *mut GFContext,
    video_path: *const c_char,
    width: u32,
    height: u32,
    fps: f64,
    duration_ms: f64,
    frame_count: u32,
    error_out: *mut *mut c_char,
) -> i32 {
    if ctx.is_null() { set_error("Context is null", error_out); return -1; }
    let ctx = unsafe { &mut *ctx };

    let video_path_str = match unsafe { CStr::from_ptr(video_path) }.to_str() {
        Ok(s) => s.to_owned(),
        Err(_) => { set_error("Invalid video path", error_out); return -2; }
    };

    ctx.manager.init_from_video_data(
        duration_ms,
        fps,
        frame_count as usize,
        (width as usize, height as usize),
    );

    {
        let mut input_file = ctx.manager.input_file.write();
        input_file.url = video_path_str;
    }

    0
}

// ── Step 2: Load GCSV gyro data ──────────────────────

#[no_mangle]
pub extern "C" fn gf_load_gyro(
    ctx: *mut GFContext,
    gcsv_path: *const c_char,
    error_out: *mut *mut c_char,
) -> i32 {
    if ctx.is_null() { set_error("Context is null", error_out); return -1; }
    let ctx = unsafe { &mut *ctx };

    let gcsv_path_str = match unsafe { CStr::from_ptr(gcsv_path) }.to_str() {
        Ok(s) => s.to_owned(),
        Err(_) => { set_error("Invalid GCSV path", error_out); return -2; }
    };

    let gcsv_data = match fs::read(&gcsv_path_str) {
        Ok(d) => d,
        Err(e) => {
            set_error(&format!("Failed to read GCSV: {}", e), error_out);
            return -3;
        }
    };

    let filesize = gcsv_data.len();
    let mut cursor = Cursor::new(gcsv_data);
    let load_options = gyroflow_core::gyro_source::FileLoadOptions::default();

    if let Err(e) = ctx.manager.load_gyro_data(
        &mut cursor,
        filesize,
        &gcsv_path_str,
        false,
        &load_options,
        |_| {},
        ctx.cancel_flag.clone(),
    ) {
        set_error(&format!("Failed to load GCSV: {:?}", e), error_out);
        return -4;
    }

    0
}

// ── Step 2b: Load lens profile (optional, improves sync accuracy) ──

#[no_mangle]
pub extern "C" fn gf_load_lens_profile(
    ctx: *mut GFContext,
    profile_path: *const c_char,
    error_out: *mut *mut c_char,
) -> i32 {
    if ctx.is_null() { set_error("Context is null", error_out); return -1; }
    let ctx = unsafe { &mut *ctx };

    let path_str = match unsafe { CStr::from_ptr(profile_path) }.to_str() {
        Ok(s) => s.to_owned(),
        Err(_) => { set_error("Invalid profile path", error_out); return -2; }
    };

    match ctx.manager.load_lens_profile(&path_str) {
        Ok(()) => 0,
        Err(e) => {
            set_error(&format!("Failed to load lens profile: {:?}", e), error_out);
            -3
        }
    }
}

// ── Step 3: Start autosync (prepare to receive frames) ──

#[no_mangle]
pub extern "C" fn gf_start_sync(
    ctx: *mut GFContext,
    initial_offset_ms: f64,
    search_size_ms: f64,
    error_out: *mut *mut c_char,
) -> i32 {
    if ctx.is_null() { set_error("Context is null", error_out); return -1; }
    let ctx = unsafe { &mut *ctx };

    // Verify gyro data
    {
        let gyro = ctx.manager.gyro.read();
        if !gyro.has_motion() {
            set_error("No gyro motion data loaded", error_out);
            return -2;
        }
    }

    // Override IMU orientation to XYZ for autosync compatibility.
    // The essential matrix produces estimated_gyro in camera coordinates (XYZ identity).
    // The GCSV orientation (e.g. ZXY) maps sensor axes differently, causing axis mismatch
    // in the correlation cost function. We temporarily use XYZ during sync, then restore.
    {
        let mut gyro = ctx.manager.gyro.write();
        ctx.original_imu_orientation = gyro.imu_transforms.imu_orientation.clone();
        gyro.imu_transforms.imu_orientation = Some("XYZ".to_string());
        gyro.apply_transforms();
    }

    let sync_params = SyncParams {
        initial_offset: initial_offset_ms,
        search_size: search_size_ms,
        calc_initial_fast: true,
        // 5 sync points (was 3): provides enough samples for median-based
        // outlier rejection in gf_finish_sync to survive up to 2 wildly-off
        // points (e.g. a single bad correlation at the end of a 60s clip
        // throwing the entire second half out of sync). Cost is ~1.67x the
        // sync time per clip, but sync is the slow part anyway and the
        // robustness gain is worth it.
        max_sync_points: 5,
        every_nth_frame: 1,
        time_per_syncpoint: 2500.0,
        of_method: 2,      // OpenCV DIS (Dense Inverse Search)
        offset_method: 0,   // essential_matrix
        ..Default::default()
    };

    let num_sync_points = sync_params.max_sync_points;
    let timestamps_fract: Vec<f64> = (0..num_sync_points)
        .map(|i| (i as f64 + 0.5) / num_sync_points as f64)
        .collect();

    match AutosyncProcess::from_manager(
        &ctx.manager,
        &timestamps_fract,
        sync_params,
        "synchronize".into(),
        ctx.cancel_flag.clone(),
    ) {
        Ok(mut sync) => {
            let offsets_store = ctx.computed_offsets.clone();
            sync.on_progress(|progress, detected, total| {
                log::info!("Sync progress: {:.1}% ({}/{})", progress * 100.0, detected, total);
            });
            sync.on_finished(move |result| {
                match result {
                    itertools::Either::Left(offsets) => {
                        log::info!("Sync computed {} offsets", offsets.len());
                        for (ts, off, cost) in &offsets {
                            log::info!("  offset: ts={:.1}ms off={:.3}ms cost={:.4}", ts, off, cost);
                        }
                        *offsets_store.write() = offsets;
                    }
                    itertools::Either::Right(orientation) => {
                        log::info!("Sync returned orientation: {:?}", orientation);
                    }
                }
            });
            ctx.sync = Some(sync);
            0
        }
        Err(_) => {
            set_error("Failed to create AutosyncProcess", error_out);
            -3
        }
    }
}

// ── Step 4: Feed grayscale frames from Swift ─────────

#[no_mangle]
pub extern "C" fn gf_feed_frame(
    ctx: *mut GFContext,
    timestamp_us: i64,
    frame_no: u32,
    width: u32,
    height: u32,
    stride: u32,
    pixels: *const u8,
    pixel_count: u32,
) {
    if ctx.is_null() { return; }
    let ctx = unsafe { &mut *ctx };

    let sync = match &ctx.sync {
        Some(s) => s,
        None => return,
    };

    let pixel_slice = unsafe {
        std::slice::from_raw_parts(pixels, pixel_count as usize)
    };

    sync.feed_frame(
        timestamp_us,
        frame_no as usize,
        width,
        height,
        stride as usize,
        pixel_slice,
    );
}

// ── Step 5: Finish sync and compute offsets ──────────

#[no_mangle]
pub extern "C" fn gf_finish_sync(
    ctx: *mut GFContext,
    error_out: *mut *mut c_char,
) -> i32 {
    if ctx.is_null() { set_error("Context is null", error_out); return -1; }
    let ctx = unsafe { &mut *ctx };

    match ctx.sync.take() {
        Some(sync) => {
            // Catch panics from OpenCV (e.g. findEssentialMat "Model not found"
            // on static scenes can cause SEGV in some OpenCV builds)
            let sync_result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                sync.finished_feeding_frames();
            }));
            drop(sync_result); // ignore panic result, offsets may still have been computed

            // Restore original IMU orientation after sync
            if let Some(ref orig_orient) = ctx.original_imu_orientation {
                let mut gyro = ctx.manager.gyro.write();
                gyro.imu_transforms.imu_orientation = Some(orig_orient.clone());
                gyro.apply_transforms();
            }

            // Apply computed offsets to the manager's gyro source, with
            // median-based outlier rejection AND single-offset enforcement.
            //
            // Real-world testing on 60s clips revealed that gyroflow-core's
            // multi-point sync sometimes produces a wildly off offset at a
            // later sync point (e.g. -9000ms when the others agreed on
            // -2500ms). Even with outlier rejection, multi-point offsets
            // get interpolated across the clip and any small inconsistency
            // between kept points causes the second half of long clips to
            // drift visibly. Forcing a single uniform offset (the median of
            // the kept points) eliminates the drift in exchange for not
            // tracking real clock drift between phone and camera — but for
            // typical recordings (clocks set just before shoot, ≤2 minute
            // clips) actual clock drift is negligible (<1ms).
            let offsets = ctx.computed_offsets.read().clone();
            if offsets.is_empty() {
                set_error("Sync completed but no offsets were computed (video may have insufficient motion)", error_out);
                return -3;
            }

            // Outlier rejection: keep only sync points whose offset is within
            // OUTLIER_THRESHOLD_MS of the initial median. With 5 sync points,
            // this survives up to 2 outliers.
            const OUTLIER_THRESHOLD_MS: f64 = 500.0;
            let mut sorted_offs: Vec<f64> = offsets.iter().map(|(_, off, _)| *off).collect();
            sorted_offs.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
            let initial_median = sorted_offs[sorted_offs.len() / 2];
            let kept: Vec<_> = offsets
                .iter()
                .filter(|(_, off, _)| (off - initial_median).abs() <= OUTLIER_THRESHOLD_MS)
                .cloned()
                .collect();
            let kept = if kept.is_empty() { offsets.clone() } else { kept };

            // Recompute median from kept points only (more robust)
            let mut kept_sorted: Vec<f64> = kept.iter().map(|(_, off, _)| *off).collect();
            kept_sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
            let final_median = kept_sorted[kept_sorted.len() / 2];

            let dropped = offsets.len() - kept.len();
            eprintln!(
                "INFO: Sync offsets: {} computed, {} kept, {} dropped (single-offset mode: applying median={:.3}ms uniformly)",
                offsets.len(),
                kept.len(),
                dropped,
                final_median,
            );
            for (ts, off, cost) in &offsets {
                let kept_marker = if (off - initial_median).abs() <= OUTLIER_THRESHOLD_MS { "kept" } else { "dropped" };
                eprintln!("INFO:   offset: ts={:.1}ms off={:.3}ms cost={:.4} [{}]", ts, off, cost, kept_marker);
            }

            // Single-offset application: set the same final_median offset at
            // every sync point's timestamp. With identical offsets at every
            // anchor, gyroflow's interpolator yields a constant offset across
            // the entire clip — no drift between sync points possible.
            {
                let mut gyro = ctx.manager.gyro.write();
                gyro.prevent_recompute = true;
                for (timestamp_ms, _orig_offset, _cost) in &kept {
                    let new_ts = ((timestamp_ms - final_median) * 1000.0) as i64;
                    gyro.set_offset(new_ts, final_median);
                }
                gyro.prevent_recompute = false;
                gyro.adjust_offsets();
            }

            0
        }
        None => {
            set_error("No sync process active", error_out);
            -2
        }
    }
}

// ── Step 5c: IMU orientation auto-detection ──────────
//
// Runs gyroflow-core's "guess_imu_orientation" AutosyncProcess mode, which
// iterates through 24 axis-remap candidates and selects the one whose IMU
// motion best matches the optical-flow-derived camera motion.
//
// Usage: call gf_start_orientation_guess() → feed all video frames again via
// gf_feed_frame() → call gf_finish_orientation_guess() → retrieve detected
// orientation via gf_get_detected_orientation().
//
// Note: requires a separate frame-feed pass after gf_finish_sync() because
// the AutosyncProcess instance is consumed per-mode.

#[no_mangle]
pub extern "C" fn gf_start_orientation_guess(
    ctx: *mut GFContext,
    _initial_offset_ms: f64,
    _search_size_ms: f64,
    error_out: *mut *mut c_char,
) -> i32 {
    if ctx.is_null() { set_error("Context is null", error_out); return -1; }
    let ctx = unsafe { &mut *ctx };

    // Verify gyro data
    {
        let gyro = ctx.manager.gyro.read();
        if !gyro.has_motion() {
            set_error("No gyro motion data loaded", error_out);
            return -2;
        }
    }

    // Reset previous detection result
    *ctx.detected_orientation.write() = None;

    // Orientation detection runs AFTER gf_finish_sync has applied the computed
    // offsets to `ctx.manager.gyro`, so the gyro is already time-aligned with
    // the video. The guess should only search a small residual window around
    // the already-synced state — a wide search (e.g. the -5000ms bias ± 5000ms
    // we use for sync) lets wrong orientations win by finding a spurious
    // temporal alignment far from the true offset. Desktop's "Auto-detect IMU
    // orientation" behaves this way, hence its reliability vs our earlier runs.
    //
    // We intentionally ignore the initial_offset_ms / search_size_ms args from
    // the caller (kept in the ABI for compat) and hardcode tight values.
    let sync_params = SyncParams {
        initial_offset: 0.0,           // already-synced state → search around zero
        search_size: 500.0,            // ±500ms fine-tune window
        calc_initial_fast: true,
        max_sync_points: 3,
        every_nth_frame: 2,            // skip every other frame for speed
        time_per_syncpoint: 1500.0,    // shorter window than sync mode
        of_method: 2,
        offset_method: 0,
        ..Default::default()
    };

    let num_sync_points = sync_params.max_sync_points;
    let timestamps_fract: Vec<f64> = (0..num_sync_points)
        .map(|i| (i as f64 + 0.5) / num_sync_points as f64)
        .collect();

    match AutosyncProcess::from_manager(
        &ctx.manager,
        &timestamps_fract,
        sync_params,
        "guess_imu_orientation".into(),
        ctx.cancel_flag.clone(),
    ) {
        Ok(mut sync) => {
            let orient_store = ctx.detected_orientation.clone();
            sync.on_progress(|progress, detected, total| {
                log::info!("Orientation guess progress: {:.1}% ({}/{})", progress * 100.0, detected, total);
            });
            sync.on_finished(move |result| {
                match result {
                    itertools::Either::Right(orientation) => {
                        log::info!("Detected IMU orientation: {:?}", orientation);
                        // gyroflow-core returns Option<(String, f64)> where the
                        // f64 is a confidence/cost score. We only need the string.
                        if let Some((orient_str, _cost)) = orientation {
                            *orient_store.write() = Some(orient_str);
                        }
                    }
                    itertools::Either::Left(offsets) => {
                        // Unexpected for guess_imu_orientation mode but log just in case
                        log::warn!("guess_imu_orientation returned offsets unexpectedly: {} pts", offsets.len());
                    }
                }
            });
            ctx.sync = Some(sync);
            0
        }
        Err(_) => {
            set_error("Failed to create AutosyncProcess (orientation mode)", error_out);
            -3
        }
    }
}

#[no_mangle]
pub extern "C" fn gf_finish_orientation_guess(
    ctx: *mut GFContext,
    error_out: *mut *mut c_char,
) -> i32 {
    if ctx.is_null() { set_error("Context is null", error_out); return -1; }
    let ctx = unsafe { &mut *ctx };

    match ctx.sync.take() {
        Some(sync) => {
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                sync.finished_feeding_frames();
            }));
            // Detection result is in ctx.detected_orientation (set by callback)
            0
        }
        None => {
            set_error("No orientation guess process active", error_out);
            -2
        }
    }
}

/// Returns the detected IMU orientation as a malloc'd C string, or null if
/// no orientation was detected. Caller must free via gf_free_string().
#[no_mangle]
pub extern "C" fn gf_get_detected_orientation(
    ctx: *mut GFContext,
) -> *mut c_char {
    if ctx.is_null() { return std::ptr::null_mut(); }
    let ctx = unsafe { &mut *ctx };
    let detected = ctx.detected_orientation.read();
    match detected.as_ref() {
        Some(orient) => {
            match CString::new(orient.as_str()) {
                Ok(c) => c.into_raw(),
                Err(_) => std::ptr::null_mut(),
            }
        }
        None => std::ptr::null_mut(),
    }
}

// ── Step 5b: Set offset directly from timestamp (no optical flow needed) ──

#[no_mangle]
pub extern "C" fn gf_set_offset(
    ctx: *mut GFContext,
    offset_ms: f64,
    error_out: *mut *mut c_char,
) -> i32 {
    if ctx.is_null() { set_error("Context is null", error_out); return -1; }
    let ctx = unsafe { &mut *ctx };

    let params = ctx.manager.params.read();
    let mid_ts_ms = params.duration_ms / 2.0;
    drop(params);

    let mut gyro = ctx.manager.gyro.write();
    let new_ts = ((mid_ts_ms - offset_ms) * 1000.0) as i64;
    gyro.set_offset(new_ts, offset_ms);

    0
}

// ── Step 6: Export .gyroflow file ────────────────────

#[no_mangle]
pub extern "C" fn gf_export(
    ctx: *mut GFContext,
    output_path: *const c_char,
    error_out: *mut *mut c_char,
) -> i32 {
    if ctx.is_null() { set_error("Context is null", error_out); return -1; }
    let ctx = unsafe { &mut *ctx };

    let output_path_str = match unsafe { CStr::from_ptr(output_path) }.to_str() {
        Ok(s) => s.to_owned(),
        Err(_) => { set_error("Invalid output path", error_out); return -2; }
    };

    // Build .gyroflow JSON with embedded gyro data
    let gyro = ctx.manager.gyro.read();
    let params = ctx.manager.params.read();
    let input_file = ctx.manager.input_file.read();
    let offsets = gyro.get_offsets();

    // Compress and embed file_metadata (contains raw IMU data)
    let file_metadata = {
        let fm = gyro.file_metadata.read();
        gyroflow_core::util::compress_to_base91_cbor(&*fm)
            .unwrap_or_default()
    };

    // Get lens profile / calibration data if loaded
    let lens_data = ctx.manager.lens.read();
    let calibration_data = if lens_data.calib_dimension.w > 0 {
        lens_data.get_json_value().ok()
    } else {
        None
    };
    drop(lens_data);

    let mut obj = serde_json::json!({
        "title": "Gyroflow data file",
        "version": 3,
        "app_version": "1.6.3",
        "videofile": input_file.url,
        "video_info": {
            "width": params.size.0,
            "height": params.size.1,
            "rotation": params.video_rotation,
            "num_frames": params.frame_count,
            "fps": params.fps,
            "duration_ms": params.duration_ms,
        },
        "gyro_source": {
            "filepath": gyro.file_url,
            "imu_orientation": "XYZ",
            "integration_method": 2,
            "file_metadata": file_metadata,
        },
        "offsets": offsets,
        "background_color": [0.0, 0.0, 0.0, 1.0],
        "background_mode": 0,
        "background_margin": 0.0,
        "background_margin_feather": 0.0,
        "stabilization": {
            "fov": 1.0,
            "method": "Default",
            "smoothing_params": [
                { "name": "smoothness",       "value": 1.0 },
                { "name": "smoothness_pitch",  "value": 0.5 },
                { "name": "smoothness_yaw",    "value": 0.5 },
                { "name": "smoothness_roll",   "value": 0.5 },
                { "name": "per_axis",          "value": 0.0 },
                { "name": "trim_range_only",   "value": 1.0 },
                { "name": "max_smoothness",    "value": 1.0 },
                { "name": "alpha_0_1s",        "value": 0.1 },
            ],
            "frame_readout_time": 0.0,
            "frame_readout_direction": "TopToBottom",
            "adaptive_zoom_window": 0.0,
            "adaptive_zoom_center_offset": [0.0, 0.0],
            "adaptive_zoom_method": 1,
            "additional_rotation": [0.0, 0.0, 0.0],
            "additional_translation": [0.0, 0.0, 0.0],
            "lens_correction_amount": 0.05,
            "horizon_lock_amount": 0.0,
            "horizon_lock_roll": 0.0,
            "use_gravity_vectors": false,
            "horizon_lock_integration_method": 1,
            "video_speed": 1.0,
            "video_speed_affects_smoothing": true,
            "video_speed_affects_zooming": true,
            "video_speed_affects_zooming_limit": true,
            "max_zoom": 110.0,
            "max_zoom_iterations": 5,
            "frame_offset": 0,
        },
    });

    // Insert calibration_data if lens profile was loaded
    if let Some(cal) = calibration_data {
        if let serde_json::Value::Object(ref mut map) = obj {
            map.insert("calibration_data".to_string(), cal);
        }
    }

    let data = serde_json::to_string_pretty(&obj).unwrap_or("{}".to_string());

    if let Err(e) = fs::write(&output_path_str, data.as_bytes()) {
        set_error(&format!("Failed to write: {}", e), error_out);
        return -4;
    }
    0
}
