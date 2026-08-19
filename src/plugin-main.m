/*
OBS Vision Filter
Copyright (C) 2023 Sebastian Beckmann

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License along
with this program. If not, see <https://www.gnu.org/licenses/>
*/

#include <obs-module.h>
#include <util/threading.h>
#include <util/platform.h>
#include <Vision/Vision.h>
#include <CoreVideo/CoreVideo.h>

#include <plugin-support.h>

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE(PLUGIN_NAME, "en-US")

#define RING_BUFFER_SIZE 32

enum sync_mode {
    SYNC_MODE_AUTO = 0,
    SYNC_MODE_MANUAL = 1,
    SYNC_MODE_DISABLED = 2,
};

struct frame_buffer_entry {
    gs_texrender_t *render;
    uint64_t frame_id;
    uint64_t timestamp_ns;
    uint32_t width;
    uint32_t height;
    bool valid;
};

struct vision_data {
    obs_source_t *context;
    VNGeneratePersonSegmentationRequest *request;
    gs_effect_t *effect;
    gs_eparam_t *src_param;
    gs_eparam_t *mask_param;
    gs_eparam_t *threshold_param;
    float threshold;

    VNGeneratePersonSegmentationRequestQualityLevel qualityLevel;
    gs_texture_t *mask_texture;
    uint32_t mask_texture_width;
    uint32_t mask_texture_height;

    dispatch_queue_t mask_queue;
    pthread_mutex_t pixelBufferMutex;
    CVPixelBufferRef pixelBufferOut;
    uint64_t mask_frame_id;
    bool mask_ready;

    /* Sync and buffer management */
    enum sync_mode sync_mode;
    uint32_t manual_delay_frames;
    uint64_t current_frame_id;
    struct frame_buffer_entry ring_buffer[RING_BUFFER_SIZE];

    /* Cached stage surface and IOSurface buffer pool for GPU-to-GPU sharing */
    gs_stagesurf_t *cached_stagesurf;
    uint32_t stagesurf_width;
    uint32_t stagesurf_height;
    enum gs_color_format stagesurf_format;
    CVPixelBufferPoolRef pixelBufferPool;
    uint32_t pool_width;
    uint32_t pool_height;
};

static const char *vision_get_name(void *unused)
{
    (void) unused;
    return obs_module_text("Name");
}

static void update_pixel_buffer_pool(struct vision_data *filter, uint32_t width, uint32_t height)
{
    if (filter->pixelBufferPool && filter->pool_width == width && filter->pool_height == height)
        return;

    if (filter->pixelBufferPool) {
        CVPixelBufferPoolRelease(filter->pixelBufferPool);
        filter->pixelBufferPool = NULL;
    }

    NSDictionary *poolAttributes = @{(id) kCVPixelBufferPoolMinimumBufferCountKey: @(8)};
    NSDictionary *pixelBufferAttributes = @{
        (id) kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id) kCVPixelBufferWidthKey: @(width),
        (id) kCVPixelBufferHeightKey: @(height),
        (id) kCVPixelBufferIOSurfacePropertiesKey: @ {},
        (id) kCVPixelBufferMetalCompatibilityKey: @(YES)
    };

    CVPixelBufferPoolCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef) poolAttributes,
                            (__bridge CFDictionaryRef) pixelBufferAttributes, &filter->pixelBufferPool);
    filter->pool_width = width;
    filter->pool_height = height;
}

static void free_ring_buffer(struct vision_data *filter)
{
    for (size_t i = 0; i < RING_BUFFER_SIZE; i++) {
        if (filter->ring_buffer[i].render) {
            gs_texrender_destroy(filter->ring_buffer[i].render);
            filter->ring_buffer[i].render = NULL;
        }
        filter->ring_buffer[i].valid = false;
        filter->ring_buffer[i].frame_id = 0;
    }
}

static void vision_render(void *filter_ptr, gs_effect_t *unused_effect)
{
    (void) unused_effect;
    struct vision_data *filter = filter_ptr;

    obs_source_t *target = obs_filter_get_target(filter->context);
    obs_source_t *parent = obs_filter_get_parent(filter->context);

    uint32_t width = obs_source_get_base_width(target);
    uint32_t height = obs_source_get_base_height(target);
    if (!width || !height) {
        obs_source_skip_video_filter(filter->context);
        return;
    }

    uint32_t target_flags = obs_source_get_output_flags(target);
    bool custom_draw = (target_flags & OBS_SOURCE_CUSTOM_DRAW) != 0;
    bool async_source = (target_flags & OBS_SOURCE_ASYNC) != 0;

    /* STEP ONE: Advance frame ID and prepare GPU ring buffer slot */
    uint64_t this_frame_id = ++filter->current_frame_id;
    size_t current_slot = (size_t) (this_frame_id % RING_BUFFER_SIZE);

    struct frame_buffer_entry *entry = &filter->ring_buffer[current_slot];
    if (!entry->render || entry->width != width || entry->height != height) {
        if (entry->render)
            gs_texrender_destroy(entry->render);
        entry->render = gs_texrender_create(GS_BGRA, GS_ZS_NONE);
        entry->width = width;
        entry->height = height;
    }

    /* STEP TWO: Render target into the current GPU ring buffer slot */
    gs_blend_state_push();
    gs_blend_function(GS_BLEND_ONE, GS_BLEND_ZERO);
    if (gs_texrender_begin(entry->render, width, height)) {
        struct vec4 clear_color;
        vec4_zero(&clear_color);
        gs_clear(GS_CLEAR_COLOR, &clear_color, 0, 0);
        gs_ortho(0, width, 0, height, -100, 100);
        if (target == parent && !custom_draw && !async_source) {
            obs_source_default_render(target);
        } else {
            obs_source_video_render(target);
        }
        gs_texrender_end(entry->render);
    }
    gs_blend_state_pop();

    entry->frame_id = this_frame_id;
    entry->timestamp_ns = os_gettime_ns();
    entry->valid = true;

    gs_texture_t *source_texture = gs_texrender_get_texture(entry->render);
    if (!source_texture) {
        obs_source_skip_video_filter(filter->context);
        return;
    }
    enum gs_color_format format = gs_texture_get_color_format(source_texture);

    /* STEP THREE: Stage and dispatch source frame for Vision inference (GPU-backed IOSurface) */
    if (!filter->cached_stagesurf || filter->stagesurf_width != width || filter->stagesurf_height != height ||
        filter->stagesurf_format != format) {
        if (filter->cached_stagesurf)
            gs_stagesurface_destroy(filter->cached_stagesurf);
        filter->cached_stagesurf = gs_stagesurface_create(width, height, format);
        filter->stagesurf_width = width;
        filter->stagesurf_height = height;
        filter->stagesurf_format = format;
    }

    gs_stage_texture(filter->cached_stagesurf, source_texture);
    uint8_t *data = NULL;
    uint32_t linesize = 0;
    if (gs_stagesurface_map(filter->cached_stagesurf, &data, &linesize)) {
        update_pixel_buffer_pool(filter, width, height);

        CVPixelBufferRef pixelBufferIn = NULL;
        if (filter->pixelBufferPool) {
            CVReturn err =
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, filter->pixelBufferPool, &pixelBufferIn);
            if (err == kCVReturnSuccess && pixelBufferIn) {
                CVPixelBufferLockBaseAddress(pixelBufferIn, 0);
                void *dst = CVPixelBufferGetBaseAddress(pixelBufferIn);
                size_t dst_bytes_per_row = CVPixelBufferGetBytesPerRow(pixelBufferIn);
                if (dst_bytes_per_row == linesize) {
                    memcpy(dst, data, (size_t) linesize * height);
                } else {
                    for (uint32_t r = 0; r < height; r++) {
                        memcpy((uint8_t *) dst + r * dst_bytes_per_row, data + r * linesize, linesize);
                    }
                }
                CVPixelBufferUnlockBaseAddress(pixelBufferIn, 0);
            }
        }

        if (!pixelBufferIn) {
            CVPixelBufferCreateWithBytes(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, data, linesize,
                                         nil, nil, nil, &pixelBufferIn);
        }

        gs_stagesurface_unmap(filter->cached_stagesurf);

        if (pixelBufferIn) {
            VNGeneratePersonSegmentationRequestQualityLevel qLevel = filter->qualityLevel;
            VNGeneratePersonSegmentationRequest *req = filter->request;
            dispatch_async(filter->mask_queue, ^{
                req.qualityLevel = qLevel;
                NSDictionary *empty = [[NSDictionary alloc] init];
                VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixelBufferIn
                                                                                              options:empty];
                NSArray *requests = [[NSArray alloc] initWithObjects:req, nil];
                [handler performRequests:requests error:nil];

                pthread_mutex_lock(&filter->pixelBufferMutex);
                if (filter->pixelBufferOut)
                    CVPixelBufferRelease(filter->pixelBufferOut);
                VNPixelBufferObservation *obs = req.results.firstObject;
                filter->pixelBufferOut = obs.pixelBuffer;
                if (filter->pixelBufferOut) {
                    CVPixelBufferRetain(filter->pixelBufferOut);
                    filter->mask_frame_id = this_frame_id;
                    filter->mask_ready = true;
                }
                pthread_mutex_unlock(&filter->pixelBufferMutex);

                CVPixelBufferRelease(pixelBufferIn);
            });
        }
    }

    /* STEP FOUR: Check for available mask */
    pthread_mutex_lock(&filter->pixelBufferMutex);
    CVPixelBufferRef currentMaskPB = filter->pixelBufferOut;
    uint64_t currentMaskFrameID = filter->mask_frame_id;
    bool hasMask = (currentMaskPB != NULL);
    if (hasMask) {
        CVPixelBufferRetain(currentMaskPB);
    }
    pthread_mutex_unlock(&filter->pixelBufferMutex);

    if (!hasMask) {
        obs_source_skip_video_filter(filter->context);
        return;
    }

    /* STEP FIVE: Update mask GPU texture */
    uint32_t mask_w = (uint32_t) CVPixelBufferGetWidth(currentMaskPB);
    uint32_t mask_h = (uint32_t) CVPixelBufferGetHeight(currentMaskPB);

    CVPixelBufferLockBaseAddress(currentMaskPB, kCVPixelBufferLock_ReadOnly);
    const uint8_t *base_address = (const uint8_t *) CVPixelBufferGetBaseAddress(currentMaskPB);

    if (!filter->mask_texture || filter->mask_texture_width != mask_w || filter->mask_texture_height != mask_h) {
        if (filter->mask_texture)
            gs_texture_destroy(filter->mask_texture);
        filter->mask_texture = gs_texture_create(mask_w, mask_h, GS_A8, 1, &base_address, GS_DYNAMIC);
        filter->mask_texture_width = mask_w;
        filter->mask_texture_height = mask_h;
    } else {
        gs_texture_set_image(filter->mask_texture, base_address, (uint32_t) CVPixelBufferGetBytesPerRow(currentMaskPB),
                             false);
    }
    CVPixelBufferUnlockBaseAddress(currentMaskPB, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferRelease(currentMaskPB);

    /* STEP SIX: Select synchronized video source frame based on Sync Mode */
    gs_texture_t *render_source_texture = source_texture;

    if (filter->sync_mode == SYNC_MODE_AUTO) {
        /* Auto Sync: Find the exact source frame matching the mask frame ID */
        uint64_t target_id = currentMaskFrameID;
        bool found = false;
        for (size_t i = 0; i < RING_BUFFER_SIZE; i++) {
            if (filter->ring_buffer[i].valid && filter->ring_buffer[i].frame_id == target_id) {
                gs_texture_t *matched_tex = gs_texrender_get_texture(filter->ring_buffer[i].render);
                if (matched_tex) {
                    render_source_texture = matched_tex;
                    found = true;
                    break;
                }
            }
        }
        /* Fallback to closest available older valid frame if exact ID is not in ring */
        if (!found) {
            uint64_t best_diff = UINT64_MAX;
            size_t best_idx = current_slot;
            for (size_t i = 0; i < RING_BUFFER_SIZE; i++) {
                if (filter->ring_buffer[i].valid && filter->ring_buffer[i].frame_id <= target_id) {
                    uint64_t diff = target_id - filter->ring_buffer[i].frame_id;
                    if (diff < best_diff) {
                        best_diff = diff;
                        best_idx = i;
                    }
                }
            }
            if (filter->ring_buffer[best_idx].render) {
                gs_texture_t *fallback_tex = gs_texrender_get_texture(filter->ring_buffer[best_idx].render);
                if (fallback_tex)
                    render_source_texture = fallback_tex;
            }
        }
    } else if (filter->sync_mode == SYNC_MODE_MANUAL) {
        /* Manual Delay: Look back by fixed manual_delay_frames */
        uint32_t delay = filter->manual_delay_frames;
        if (delay > 0 && this_frame_id > delay) {
            uint64_t target_id = this_frame_id - delay;
            bool found = false;
            for (size_t i = 0; i < RING_BUFFER_SIZE; i++) {
                if (filter->ring_buffer[i].valid && filter->ring_buffer[i].frame_id == target_id) {
                    gs_texture_t *delayed_tex = gs_texrender_get_texture(filter->ring_buffer[i].render);
                    if (delayed_tex) {
                        render_source_texture = delayed_tex;
                        found = true;
                        break;
                    }
                }
            }
            if (!found) {
                size_t target_slot = (current_slot + RING_BUFFER_SIZE - (delay % RING_BUFFER_SIZE)) % RING_BUFFER_SIZE;
                if (filter->ring_buffer[target_slot].valid && filter->ring_buffer[target_slot].render) {
                    gs_texture_t *delayed_tex = gs_texrender_get_texture(filter->ring_buffer[target_slot].render);
                    if (delayed_tex)
                        render_source_texture = delayed_tex;
                }
            }
        }
    }

    /* STEP SEVEN: Render composite with synchronized source texture and mask */
    if (obs_source_process_filter_begin(filter->context, format, OBS_ALLOW_DIRECT_RENDERING)) {
        gs_effect_set_texture_srgb(filter->src_param, render_source_texture);
        gs_effect_set_texture_srgb(filter->mask_param, filter->mask_texture);
        gs_effect_set_float(filter->threshold_param, filter->threshold);

        gs_blend_state_push();
        obs_source_process_filter_tech_end(filter->context, filter->effect, 0, 0, "Draw");
        gs_blend_state_pop();
    }
}

static bool sync_mode_modified(obs_properties_t *props, obs_property_t *p, obs_data_t *settings)
{
    (void) p;
    int64_t mode = obs_data_get_int(settings, "sync_mode");
    obs_property_t *delay_prop = obs_properties_get(props, "manual_delay");
    if (delay_prop) {
        obs_property_set_visible(delay_prop, mode == SYNC_MODE_MANUAL);
    }
    return true;
}

static obs_properties_t *vision_properties(void *unused)
{
    (void) unused;
    obs_properties_t *props = obs_properties_create();
    obs_properties_add_float_slider(props, "threshold", obs_module_text("Threshold"), 0.0, 1.0, 0.05);

    obs_property_t *quality_list = obs_properties_add_list(props, "quality", obs_module_text("Quality"),
                                                           OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_INT);
    obs_property_list_add_int(quality_list, obs_module_text("Quality.Balanced"),
                              VNGeneratePersonSegmentationRequestQualityLevelBalanced);
    obs_property_list_add_int(quality_list, obs_module_text("Quality.Fast"),
                              VNGeneratePersonSegmentationRequestQualityLevelFast);

    obs_property_t *sync_list = obs_properties_add_list(props, "sync_mode", obs_module_text("SyncMode"),
                                                        OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_INT);
    obs_property_list_add_int(sync_list, obs_module_text("SyncMode.Auto"), SYNC_MODE_AUTO);
    obs_property_list_add_int(sync_list, obs_module_text("SyncMode.Manual"), SYNC_MODE_MANUAL);
    obs_property_list_add_int(sync_list, obs_module_text("SyncMode.Disabled"), SYNC_MODE_DISABLED);
    obs_property_set_modified_callback(sync_list, sync_mode_modified);

    obs_properties_add_int_slider(props, "manual_delay", obs_module_text("ManualDelayFrames"), 0, 15, 1);

    return props;
}

static void vision_defaults(obs_data_t *settings)
{
    obs_data_set_default_double(settings, "threshold", 0.9);
    obs_data_set_default_int(settings, "quality", VNGeneratePersonSegmentationRequestQualityLevelBalanced);
    obs_data_set_default_int(settings, "sync_mode", SYNC_MODE_AUTO);
    obs_data_set_default_int(settings, "manual_delay", 2);
}

static void vision_update(void *filter_ptr, obs_data_t *settings)
{
    struct vision_data *filter = filter_ptr;

    filter->threshold = (float) obs_data_get_double(settings, "threshold");
    filter->qualityLevel = (VNGeneratePersonSegmentationRequestQualityLevel) obs_data_get_int(settings, "quality");
    filter->sync_mode = (enum sync_mode) obs_data_get_int(settings, "sync_mode");
    filter->manual_delay_frames = (uint32_t) obs_data_get_int(settings, "manual_delay");
}

static void *vision_create(obs_data_t *settings, struct obs_source *source)
{
    struct vision_data *filter = bzalloc(sizeof(struct vision_data));
    filter->context = source;
    filter->request = [[VNGeneratePersonSegmentationRequest alloc] init];
    pthread_mutex_init(&filter->pixelBufferMutex, NULL);

    filter->mask_queue = dispatch_queue_create("Filter mask dispatch queue", NULL);

    obs_enter_graphics();
    char *file = obs_module_file("alpha_mask.effect");
    filter->effect = gs_effect_create_from_file(file, NULL);
    bfree(file);
    filter->src_param = gs_effect_get_param_by_name(filter->effect, "image");
    filter->mask_param = gs_effect_get_param_by_name(filter->effect, "mask");
    filter->threshold_param = gs_effect_get_param_by_name(filter->effect, "threshold");
    obs_leave_graphics();

    vision_update(filter, settings);
    return filter;
}

static void vision_destroy(void *filter_ptr)
{
    struct vision_data *filter = filter_ptr;
    if (!filter)
        return;

    if (filter->mask_queue) {
        dispatch_sync(filter->mask_queue, ^ {
                      });
        filter->mask_queue = nil;
    }

    if (filter->request) {
        filter->request = nil;
    }

    pthread_mutex_lock(&filter->pixelBufferMutex);
    if (filter->pixelBufferOut) {
        CVPixelBufferRelease(filter->pixelBufferOut);
        filter->pixelBufferOut = NULL;
    }
    pthread_mutex_unlock(&filter->pixelBufferMutex);
    pthread_mutex_destroy(&filter->pixelBufferMutex);

    if (filter->pixelBufferPool) {
        CVPixelBufferPoolRelease(filter->pixelBufferPool);
        filter->pixelBufferPool = NULL;
    }

    obs_enter_graphics();
    free_ring_buffer(filter);

    if (filter->cached_stagesurf) {
        gs_stagesurface_destroy(filter->cached_stagesurf);
        filter->cached_stagesurf = NULL;
    }

    if (filter->mask_texture) {
        gs_texture_destroy(filter->mask_texture);
        filter->mask_texture = NULL;
    }

    if (filter->effect) {
        gs_effect_destroy(filter->effect);
        filter->effect = NULL;
    }
    obs_leave_graphics();

    bfree(filter);
}

bool obs_module_load(void)
{
    struct obs_source_info info = {.id = "mac_vision_filter",
                                   .type = OBS_SOURCE_TYPE_FILTER,
                                   .output_flags = OBS_SOURCE_VIDEO | OBS_SOURCE_SRGB,
                                   .get_name = vision_get_name,
                                   .create = vision_create,
                                   .destroy = vision_destroy,
                                   .video_render = vision_render,
                                   .get_defaults = vision_defaults,
                                   .get_properties = vision_properties,
                                   .update = vision_update};
    obs_register_source(&info);
    obs_log(LOG_INFO, "Loaded successfully (version %s)", PLUGIN_VERSION);
    return true;
}

void obs_module_unload(void)
{
    obs_log(LOG_INFO, "plugin unloaded");
}
