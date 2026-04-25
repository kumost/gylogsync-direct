// gyroflow_bridge.h
// Copyright (C) 2026 Kumo, Inc.
// Licensed under the GNU General Public License v3.0
// https://github.com/kumost/gylogsync-direct

#ifndef GYROFLOW_BRIDGE_H
#define GYROFLOW_BRIDGE_H

#include <stdint.h>

// Opaque handle to a processing context
typedef void* GFContext;

// Create/free context
GFContext gf_context_new(void);
void gf_context_free(GFContext ctx);
void gf_free_string(char* s);

// Step 1: Initialize with video metadata (from AVFoundation)
int32_t gf_init_video(
    GFContext ctx,
    const char* video_path,
    uint32_t width,
    uint32_t height,
    double fps,
    double duration_ms,
    uint32_t frame_count,
    char** error_out
);

// Step 2: Load GCSV gyro data
int32_t gf_load_gyro(
    GFContext ctx,
    const char* gcsv_path,
    char** error_out
);

// Step 2b: Load lens profile (optional)
int32_t gf_load_lens_profile(
    GFContext ctx,
    const char* profile_path,
    char** error_out
);

// Step 3: Start autosync (prepare to receive frames)
int32_t gf_start_sync(
    GFContext ctx,
    double initial_offset_ms,
    double search_size_ms,
    char** error_out
);

// Step 4: Feed a grayscale frame (call for each decoded frame)
void gf_feed_frame(
    GFContext ctx,
    int64_t timestamp_us,
    uint32_t frame_no,
    uint32_t width,
    uint32_t height,
    uint32_t stride,
    const uint8_t* pixels,
    uint32_t pixel_count
);

// Step 5: Finish sync and compute offsets
int32_t gf_finish_sync(
    GFContext ctx,
    char** error_out
);

// Step 5b: Set offset directly (no optical flow needed)
int32_t gf_set_offset(
    GFContext ctx,
    double offset_ms,
    char** error_out
);

// Step 5c: IMU orientation auto-detection
// Run gyroflow-core's "guess_imu_orientation" autosync mode.
// Workflow:
//   1. gf_start_orientation_guess()  ← initialize new AutosyncProcess
//   2. gf_feed_frame() × N            ← feed all video frames again
//   3. gf_finish_orientation_guess() ← compute best-match orientation
//   4. gf_get_detected_orientation()  ← retrieve result string (caller frees)
//
// Returns 0 on success.
int32_t gf_start_orientation_guess(
    GFContext ctx,
    double initial_offset_ms,
    double search_size_ms,
    char** error_out
);

int32_t gf_finish_orientation_guess(
    GFContext ctx,
    char** error_out
);

// Returns the detected IMU orientation as a malloc'd C string (e.g. "ZYx",
// "XYZ", "xyZ"), or NULL if no orientation was detected. Caller must free
// the returned pointer via gf_free_string().
char* gf_get_detected_orientation(
    GFContext ctx
);

// Step 6: Export .gyroflow file
int32_t gf_export(
    GFContext ctx,
    const char* output_path,
    char** error_out
);

#endif // GYROFLOW_BRIDGE_H
