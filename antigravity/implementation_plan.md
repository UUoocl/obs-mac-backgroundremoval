# Plan: Video Source & Mask Synchronization with GPU Sharing for OBS Mac Background Removal

## Problem Analysis & Architecture Overview

Currently in [plugin-main.m](file:///Users/jonwood/Github_local_dev/obs-mac-backgroundremoval-0.2.0/src/plugin-main.m):
1. **Source & Mask Out-of-Sync**: Person segmentation via Apple Vision framework (`VNGeneratePersonSegmentationRequest`) runs asynchronously on `mask_queue` (taking ~15–50ms depending on quality/resolution). The render pipeline continues immediately on the graphics thread, pairing the **current** video frame $T$ with an **old** mask from frame $T - k$. This causes visible lag, edge haloing, and silhouette misalignment during movement.
2. **CPU–GPU Pipeline Bottlenecks**: The plugin repeatedly maps GPU textures to CPU memory via `gs_stagesurface_create` and `gs_stagesurface_map`, wraps raw CPU pointers in `CVPixelBufferCreateWithBytes`, and locks CPU memory with `CVPixelBufferLockBaseAddress` before re-uploading to `gs_texture_t`. In addition, `gs_texrender_create` / `destroy` is called every frame.
3. **Missing Sync Controls in UI**: There is currently no UI control for latency alignment or sync modes.

```
       Incoming Frame (ID: N, Time: T)
                     │
         ┌───────────┴───────────┐
         ▼                       ▼
 ┌──────────────┐       ┌──────────────────────┐
 │ GPU Frame    │       │ GPU IOSurface Buffer │
 │ Ring Buffer  │       │ (Zero-Copy to Vision)│
 │ [N-k ... N]  │       └──────────┬───────────┘
 └───────┬──────┘                  ▼
         │             ┌────────────────────────┐
         │             │ Vision Segmentation    │
         │             │ (mask_queue, ANE/GPU)  │
         │             └───────────┬────────────┘
         │                         ▼
         │             ┌────────────────────────┐
         │             │ Ready Mask (ID: N)     │
         │             └───────────┬────────────┘
         ▼                         ▼
   ┌─────────────────────────────────────┐
   │ Sync Matcher (Auto or Manual Delay) │
   │ Matches Frame[N] with Mask[N]       │
   └──────────────────┬──────────────────┘
                      ▼
           ┌──────────────────────┐
           │ Alpha Mask Shader    │
           │ (Perfect Sync Render)│
           └──────────────────────┘
```

---

## Proposed Changes

### 1. GPU-Resident Frame Ring Buffer & Delay Engine
- Implement a circular buffer of GPU textures (`gs_texrender_t` / `gs_texture_t`) allocated during initialization and resized only when source dimensions change.
- Tag each frame with a sequential `uint64_t frame_id` and timestamp `uint64_t timestamp_ns`.
- **Auto Sync Mode**:
  - Automatically match the completed mask with its corresponding buffered source texture by `frame_id`.
  - Continuously track the frame latency $\Delta_{frames} = \text{CurrentID} - \text{MaskID}$ and inference time $\Delta t$.
  - Keep playback smooth while maintaining exact 1:1 temporal alignment between mask and source video.
- **Manual Sync Mode**:
  - Provide a user-configurable source delay (0 to 10 frames or 0 to 200 ms).
  - Delay the rendered source frame by exactly the user's chosen frame offset.
- **Disabled Mode**:
  - Direct passthrough rendering with latest available mask (0 added delay).

### 2. GPU-to-GPU Sharing & Zero-Copy Optimization
- **IOSurface-backed CVPixelBuffer Pool**:
  - Create a reusable pool of `CVPixelBufferRef` instances backed by `IOSurfaceRef` (`kCVPixelBufferIOSurfacePropertiesKey`).
  - IOSurface allocations reside in unified GPU memory on macOS / Apple Silicon, enabling zero-copy ingestion by `VNImageRequestHandler` directly on the Neural Engine / GPU without round-tripping through CPU RAM.
- **Persistent GPU Texrenders**:
  - Allocate and reuse `gs_texrender_t` objects across render cycles, eliminating per-frame allocator churn.
- **Optimized Mask Texture Upload**:
  - Efficiently bind mask pixel buffers to single-channel GPU textures.

### 3. UI Updates & Localization
- **Sync Mode Selector**:
  - `Auto Sync` (Default, recommended)
  - `Manual Delay`
  - `Disabled (0 Delay)`
- **Manual Delay Controls**:
  - Slider for frame delay (0 to 10 frames) and/or millisecond delay (0 to 200 ms).
  - Dynamically shown/hidden based on selected sync mode using OBS property modified callbacks.
- **Quality Selector & Threshold**:
  - Retain Threshold slider and Quality options (Fast, Balanced, Accurate).
- **Localization**:
  - Update `data/locale/en-US.ini` with new localization keys.

---

## File Changes

### [MODIFY] [src/plugin-main.m](file:///Users/jonwood/Github_local_dev/obs-mac-backgroundremoval-0.2.0/src/plugin-main.m)
- Add frame ring buffer structures and state (`struct frame_buffer_item`, ring buffer management).
- Add sync mode enum (`SYNC_MODE_AUTO`, `SYNC_MODE_MANUAL`, `SYNC_MODE_DISABLED`), manual delay settings, and latency trackers.
- Implement IOSurface-backed `CVPixelBufferPool` for GPU-to-GPU sharing with Vision framework.
- Update `vision_render` to render into the GPU ring buffer, dispatch Vision requests with `frame_id`, and composite the synchronized source texture with the matching mask texture.
- Update `vision_properties`, `vision_defaults`, `vision_update`, and `vision_create` / `vision_destroy` to manage lifecycle and dynamic property visibility.

### [MODIFY] [data/locale/en-US.ini](file:///Users/jonwood/Github_local_dev/obs-mac-backgroundremoval-0.2.0/data/locale/en-US.ini)
- Add localization strings:
  - `SyncMode="Sync Mode"`
  - `SyncMode.Auto="Auto Sync (Recommended)"`
  - `SyncMode.Manual="Manual Delay"`
  - `SyncMode.Disabled="Disabled (Low Latency)"`
  - `ManualDelayFrames="Manual Delay (Frames)"`
  - `ManualDelayMs="Manual Delay (ms)"`

---

## Verification Plan

### Automated / Build Verification
- Compile and build the plugin using `.github/scripts/build-macos.zsh -c RelWithDebInfo` or direct CMake Ninja invocation.
- Verify zero compiler warnings with `-Wall`.

### Manual & Functional Verification
- Verify that when `Auto Sync` is active, subject movement no longer produces silhouette lag or ghosting between the video and mask.
- Verify `Manual Delay` slider adjusts frame delay in real-time.
- Verify GPU memory usage remains constant without memory leaks or texture leaks.
