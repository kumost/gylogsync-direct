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
        max_sync_points: 3,
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

            // Apply computed offsets to the manager's gyro source
            let offsets = ctx.computed_offsets.read().clone();
            if offsets.is_empty() {
                set_error("Sync completed but no offsets were computed (video may have insufficient motion)", error_out);
                return -3;
            }

            {
                let mut gyro = ctx.manager.gyro.write();
                gyro.prevent_recompute = true;
                for (timestamp_ms, offset_ms, _cost) in &offsets {
                    let new_ts = ((timestamp_ms - offset_ms) * 1000.0) as i64;
                    gyro.set_offset(new_ts, *offset_ms);
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
