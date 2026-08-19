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
#include <stdatomic.h>

#include <plugin-support.h>

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE(PLUGIN_NAME, "en-US")

#define RING_BUFFER_SIZE 128

enum sync_mode {
    SYNC_MODE_AUTO = 0,
    SYNC_MODE_MANUAL = 1,
    SYNC_MODE_BUFFERED_EXACT = 2,
    SYNC_MODE_DISABLED = 3,
};

struct ring_entry {
    gs_texture_t *texture;
    gs_texture_t *mask_texture;
    uint32_t width;
    uint32_t height;
    enum gs_color_format format;
    uint32_t mask_width;
    uint32_t mask_height;
    uint64_t frame_id;
    bool valid;
    bool has_mask;
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
    enum sync_mode sync_mode;
    uint32_t manual_delay_frames;
    uint32_t buffer_frames;
    uint32_t auto_delay;

    gs_texrender_t *render;
    gs_stagesurf_t *cached_stagesurf;
    uint32_t stagesurf_width;
    uint32_t stagesurf_height;
    enum gs_color_format stagesurf_format;

    uint64_t current_frame_id;
    struct ring_entry ring_buffer[RING_BUFFER_SIZE];

    gs_texture_t *latest_mask_texture;
    uint32_t latest_mask_width;
    uint32_t latest_mask_height;

    dispatch_queue_t mask_queue;
    _Atomic bool is_processing;
    pthread_mutex_t mask_mutex;
    uint8_t *mask_data;
    size_t mask_data_size;
    uint32_t mask_width;
    uint32_t mask_height;
    uint32_t mask_linesize;
    uint64_t mask_frame_id;
    bool mask_updated;

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

    NSDictionary *poolAttributes = @{(id) kCVPixelBufferPoolMinimumBufferCountKey: @(4)};
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
        if (filter->ring_buffer[i].texture) {
            gs_texture_destroy(filter->ring_buffer[i].texture);
            filter->ring_buffer[i].texture = NULL;
        }
        if (filter->ring_buffer[i].mask_texture) {
            gs_texture_destroy(filter->ring_buffer[i].mask_texture);
            filter->ring_buffer[i].mask_texture = NULL;
        }
        filter->ring_buffer[i].valid = false;
        filter->ring_buffer[i].has_mask = false;
        filter->ring_buffer[i].frame_id = 0;
    }
}

static void vision_render(void *filter_ptr, gs_effect_t *unused_effect)
{
    (void) unused_effect;
    struct vision_data *filter = filter_ptr;

    obs_source_t *target = obs_filter_get_target(filter->context);
    obs_source_t *parent = obs_filter_get_parent(filter->context);
    if (!target || !parent) {
        obs_source_skip_video_filter(filter->context);
        return;
    }

    uint32_t width = obs_source_get_base_width(target);
    uint32_t height = obs_source_get_base_height(target);
    if (!width || !height) {
        obs_source_skip_video_filter(filter->context);
        return;
    }

    uint32_t target_flags = obs_source_get_output_flags(target);
    bool custom_draw = (target_flags & OBS_SOURCE_CUSTOM_DRAW) != 0;
    bool async_source = (target_flags & OBS_SOURCE_ASYNC) != 0;

    /* 1. Render source frame into dedicated texrender ONCE */
    if (!filter->render) {
        filter->render = gs_texrender_create(GS_BGRA, GS_ZS_NONE);
    }
    gs_texrender_reset(filter->render);

    gs_blend_state_push();
    gs_blend_function(GS_BLEND_ONE, GS_BLEND_ZERO);
    if (gs_texrender_begin(filter->render, width, height)) {
        struct vec4 clear_color;
        vec4_zero(&clear_color);
        gs_clear(GS_CLEAR_COLOR, &clear_color, 0.0f, 0);
        gs_ortho(0.0f, (float) width, 0.0f, (float) height, -100.0f, 100.0f);
        if (target == parent && !custom_draw && !async_source) {
            obs_source_default_render(target);
        } else {
            obs_source_video_render(target);
        }
        gs_texrender_end(filter->render);
    }
    gs_blend_state_pop();

    gs_texture_t *source_texture = gs_texrender_get_texture(filter->render);
    if (!source_texture) {
        obs_source_skip_video_filter(filter->context);
        return;
    }
    enum gs_color_format format = gs_texture_get_color_format(source_texture);

    /* 2. Save copy of current frame texture to ring buffer slot */
    uint64_t this_frame_id = ++filter->current_frame_id;
    size_t ring_slot = (size_t) (this_frame_id % RING_BUFFER_SIZE);
    struct ring_entry *entry = &filter->ring_buffer[ring_slot];

    if (!entry->texture || entry->width != width || entry->height != height || entry->format != format) {
        if (entry->texture)
            gs_texture_destroy(entry->texture);
        entry->texture = gs_texture_create(width, height, format, 1, NULL, GS_RENDER_TARGET);
        entry->width = width;
        entry->height = height;
        entry->format = format;
    }
    if (entry->texture) {
        gs_copy_texture(entry->texture, source_texture);
        entry->frame_id = this_frame_id;
        entry->valid = true;
        entry->has_mask = false;
    }

    /* 3. Dispatch frame for Vision neural network inference if not busy */
    if (!atomic_load(&filter->is_processing)) {
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

            gs_stagesurface_unmap(filter->cached_stagesurf);

            if (pixelBufferIn) {
                atomic_store(&filter->is_processing, true);
                VNGeneratePersonSegmentationRequestQualityLevel qLevel = filter->qualityLevel;
                dispatch_async(filter->mask_queue, ^{
                    @autoreleasepool {
                        VNGeneratePersonSegmentationRequest *req = filter->request;
                        req.qualityLevel = qLevel;
                        NSDictionary *options = @ {};
                        VNImageRequestHandler *handler =
                            [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixelBufferIn options:options];
                        NSError *err = nil;
                        if ([handler performRequests:@[req] error:&err]) {
                            VNPixelBufferObservation *obs = req.results.firstObject;
                            if (obs && obs.pixelBuffer) {
                                CVPixelBufferRef maskPB = obs.pixelBuffer;
                                CVPixelBufferLockBaseAddress(maskPB, kCVPixelBufferLock_ReadOnly);
                                uint32_t mw = (uint32_t) CVPixelBufferGetWidth(maskPB);
                                uint32_t mh = (uint32_t) CVPixelBufferGetHeight(maskPB);
                                uint32_t mls = (uint32_t) CVPixelBufferGetBytesPerRow(maskPB);
                                const uint8_t *mb = (const uint8_t *) CVPixelBufferGetBaseAddress(maskPB);
                                size_t required_size = (size_t) mls * mh;

                                pthread_mutex_lock(&filter->mask_mutex);
                                if (filter->mask_data_size < required_size) {
                                    filter->mask_data = brealloc(filter->mask_data, required_size);
                                    filter->mask_data_size = required_size;
                                }
                                memcpy(filter->mask_data, mb, required_size);
                                filter->mask_width = mw;
                                filter->mask_height = mh;
                                filter->mask_linesize = mls;
                                filter->mask_frame_id = this_frame_id;
                                filter->mask_updated = true;
                                pthread_mutex_unlock(&filter->mask_mutex);

                                CVPixelBufferUnlockBaseAddress(maskPB, kCVPixelBufferLock_ReadOnly);
                            }
                        } else if (err) {
                            obs_log(LOG_WARNING, "Vision request failed: %s", err.localizedDescription.UTF8String);
                        }

                        CVPixelBufferRelease(pixelBufferIn);
                        atomic_store(&filter->is_processing, false);
                    }
                });
            }
        }
    }

    /* 4. Upload completed mask into matching ring buffer slot and latest cache */
    pthread_mutex_lock(&filter->mask_mutex);
    if (filter->mask_updated && filter->mask_data) {
        uint32_t mw = filter->mask_width;
        uint32_t mh = filter->mask_height;
        uint32_t mls = filter->mask_linesize;
        const uint8_t *mb = filter->mask_data;
        uint64_t completed_id = filter->mask_frame_id;

        /* Update latest fallback mask texture */
        if (!filter->latest_mask_texture || filter->latest_mask_width != mw || filter->latest_mask_height != mh) {
            if (filter->latest_mask_texture)
                gs_texture_destroy(filter->latest_mask_texture);
            filter->latest_mask_texture = gs_texture_create(mw, mh, GS_A8, 1, &mb, GS_DYNAMIC);
            filter->latest_mask_width = mw;
            filter->latest_mask_height = mh;
        } else {
            gs_texture_set_image(filter->latest_mask_texture, mb, mls, false);
        }

        /* Store mask into the exact ring buffer entry matching completed_id */
        size_t completed_slot = (size_t) (completed_id % RING_BUFFER_SIZE);
        struct ring_entry *m_entry = &filter->ring_buffer[completed_slot];
        if (m_entry->valid && m_entry->frame_id == completed_id) {
            if (!m_entry->mask_texture || m_entry->mask_width != mw || m_entry->mask_height != mh) {
                if (m_entry->mask_texture)
                    gs_texture_destroy(m_entry->mask_texture);
                m_entry->mask_texture = gs_texture_create(mw, mh, GS_A8, 1, &mb, GS_DYNAMIC);
                m_entry->mask_width = mw;
                m_entry->mask_height = mh;
            } else {
                gs_texture_set_image(m_entry->mask_texture, mb, mls, false);
            }
            m_entry->has_mask = true;
        }

        /* Update measured inference latency for Auto Sync */
        if (completed_id > 0 && this_frame_id >= completed_id) {
            uint64_t latency = this_frame_id - completed_id;
            if (latency > 0 && latency < (RING_BUFFER_SIZE - 2)) {
                filter->auto_delay = (uint32_t) latency;
            }
        }

        filter->mask_updated = false;
    }
    pthread_mutex_unlock(&filter->mask_mutex);

    /* 5. Select synchronized source frame and matching mask according to sync mode */
    gs_texture_t *render_source_texture = source_texture;
    gs_texture_t *render_mask_texture = filter->latest_mask_texture;

    uint32_t delay = 0;
    if (filter->sync_mode == SYNC_MODE_BUFFERED_EXACT) {
        delay = filter->buffer_frames;
    } else if (filter->sync_mode == SYNC_MODE_AUTO) {
        delay = filter->auto_delay;
    } else if (filter->sync_mode == SYNC_MODE_MANUAL) {
        delay = filter->manual_delay_frames;
    }

    if (delay > 0 && this_frame_id > delay) {
        uint64_t target_id = this_frame_id - delay;
        size_t target_slot = (size_t) (target_id % RING_BUFFER_SIZE);
        struct ring_entry *target_entry = &filter->ring_buffer[target_slot];

        if (target_entry->valid && target_entry->frame_id == target_id && target_entry->texture) {
            render_source_texture = target_entry->texture;

            /* Pair with the exact mask corresponding to target_id (or closest prior mask) */
            if (target_entry->has_mask && target_entry->mask_texture) {
                render_mask_texture = target_entry->mask_texture;
            } else {
                for (size_t offset = 1; offset < 16; offset++) {
                    if (target_id >= offset) {
                        size_t s = (size_t) ((target_id - offset) % RING_BUFFER_SIZE);
                        if (filter->ring_buffer[s].valid && filter->ring_buffer[s].frame_id == (target_id - offset) &&
                            filter->ring_buffer[s].has_mask && filter->ring_buffer[s].mask_texture) {
                            render_mask_texture = filter->ring_buffer[s].mask_texture;
                            break;
                        }
                    }
                }
            }
        }
    }

    /* 6. Render composite shader with synchronized source texture and matching mask */
    if (render_mask_texture && obs_source_process_filter_begin(filter->context, format, OBS_NO_DIRECT_RENDERING)) {
        gs_effect_set_texture_srgb(filter->src_param, render_source_texture);
        gs_effect_set_texture(filter->mask_param, render_mask_texture);
        gs_effect_set_float(filter->threshold_param, filter->threshold);

        gs_blend_state_push();
        gs_blend_function(GS_BLEND_ONE, GS_BLEND_INVSRCALPHA);
        obs_source_process_filter_tech_end(filter->context, filter->effect, 0, 0, "Draw");
        gs_blend_state_pop();
    } else {
        obs_source_skip_video_filter(filter->context);
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
    obs_property_t *buffer_prop = obs_properties_get(props, "buffer_frames");
    if (buffer_prop) {
        obs_property_set_visible(buffer_prop, mode == SYNC_MODE_BUFFERED_EXACT);
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
    obs_property_list_add_int(sync_list, obs_module_text("SyncMode.BufferedExact"), SYNC_MODE_BUFFERED_EXACT);
    obs_property_list_add_int(sync_list, obs_module_text("SyncMode.Manual"), SYNC_MODE_MANUAL);
    obs_property_list_add_int(sync_list, obs_module_text("SyncMode.Disabled"), SYNC_MODE_DISABLED);
    obs_property_set_modified_callback(sync_list, sync_mode_modified);

    obs_properties_add_int_slider(props, "buffer_frames", obs_module_text("BufferFrames"), 5, 60, 1);
    obs_properties_add_int_slider(props, "manual_delay", obs_module_text("ManualDelayFrames"), 0, 15, 1);

    return props;
}

static void vision_defaults(obs_data_t *settings)
{
    obs_data_set_default_double(settings, "threshold", 0.9);
    obs_data_set_default_int(settings, "quality", VNGeneratePersonSegmentationRequestQualityLevelBalanced);
    obs_data_set_default_int(settings, "sync_mode", SYNC_MODE_AUTO);
    obs_data_set_default_int(settings, "buffer_frames", 20);
    obs_data_set_default_int(settings, "manual_delay", 2);
}

static void vision_update(void *filter_ptr, obs_data_t *settings)
{
    struct vision_data *filter = filter_ptr;

    filter->threshold = (float) obs_data_get_double(settings, "threshold");
    filter->qualityLevel = (VNGeneratePersonSegmentationRequestQualityLevel) obs_data_get_int(settings, "quality");
    filter->sync_mode = (enum sync_mode) obs_data_get_int(settings, "sync_mode");
    filter->buffer_frames = (uint32_t) obs_data_get_int(settings, "buffer_frames");
    filter->manual_delay_frames = (uint32_t) obs_data_get_int(settings, "manual_delay");
}

static void *vision_create(obs_data_t *settings, struct obs_source *source)
{
    struct vision_data *filter = bzalloc(sizeof(struct vision_data));
    filter->context = source;
    filter->request = [[VNGeneratePersonSegmentationRequest alloc] init];
    filter->auto_delay = 2;
    filter->buffer_frames = 20;
    atomic_init(&filter->is_processing, false);
    pthread_mutex_init(&filter->mask_mutex, NULL);

    filter->mask_queue = dispatch_queue_create("Filter mask dispatch queue", DISPATCH_QUEUE_SERIAL);

    obs_enter_graphics();
    char *file = obs_module_file("alpha_mask.effect");
    filter->effect = gs_effect_create_from_file(file, NULL);
    bfree(file);
    if (filter->effect) {
        filter->src_param = gs_effect_get_param_by_name(filter->effect, "source_image");
        filter->mask_param = gs_effect_get_param_by_name(filter->effect, "mask");
        filter->threshold_param = gs_effect_get_param_by_name(filter->effect, "threshold");
    }
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

    pthread_mutex_destroy(&filter->mask_mutex);
    bfree(filter->mask_data);
    filter->mask_data = NULL;

    if (filter->pixelBufferPool) {
        CVPixelBufferPoolRelease(filter->pixelBufferPool);
        filter->pixelBufferPool = NULL;
    }

    obs_enter_graphics();
    if (filter->render) {
        gs_texrender_destroy(filter->render);
        filter->render = NULL;
    }

    free_ring_buffer(filter);

    if (filter->cached_stagesurf) {
        gs_stagesurface_destroy(filter->cached_stagesurf);
        filter->cached_stagesurf = NULL;
    }

    if (filter->latest_mask_texture) {
        gs_texture_destroy(filter->latest_mask_texture);
        filter->latest_mask_texture = NULL;
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
