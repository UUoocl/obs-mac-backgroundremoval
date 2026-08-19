# OBS macOS Background Removal

## Introduction

This plugin provides an effect filter to remove a person's background using Apple's built-in [Vision](https://developer.apple.com/documentation/vision) framework and Neural Engine acceleration on macOS.

### Requirements
- **macOS 12.0** or newer
- **OBS Studio 28.0** or newer
- Apple Silicon (M1/M2/M3/M4) or Intel Mac

---

## Features

- **Hardware-Accelerated Person Segmentation**: Uses macOS Vision API (`VNGeneratePersonSegmentationRequest`) running asynchronously on the Apple Neural Engine and GPU.
- **GPU-to-GPU Pipeline**: High-performance IOSurface buffer pool with Metal compatibility.
- **Advanced Frame Synchronization**: Prevents mask lag and edge "ghosting" when subjects move quickly by matching inference masks to the exact corresponding video frames.

---

## Filter Settings

Once added to any source under **Filters > Effect Filters > macOS Background Removal**, the following settings are available:

| Setting | Options / Range | Description |
| :--- | :--- | :--- |
| **Threshold** | `0.00` – `1.00` (Default: `0.90`) | Controls the confidence cutoff for person segmentation. Higher values yield tighter outlines; lower values preserve more edge details. |
| **Quality** | `Balanced` (Default)<br>`Fast` | • **Balanced**: Higher accuracy segmentation with refined edges.<br>• **Fast**: Lower compute overhead for high frame-rate or resource-constrained setups. |
| **Sync Mode** | `Auto Sync`<br>`Manual Delay`<br>`Disabled` | Controls how video frames are synchronized with the asynchronous segmentation mask (see details below). |
| **Manual Delay** | `0` – `15` frames (Default: `2`) | Configures the number of buffer frames to delay the video feed when **Manual Delay** sync mode is selected. |

### Frame Synchronization Modes

Because neural network inference takes a few milliseconds to process, asynchronous masks can lag 1–3 frames behind the real-time camera feed. This plugin includes multiple sync strategies:

1. **Auto Sync (Match Frames)** *(Recommended / Default)*:
   - Uses an internal GPU ring buffer to match each completed segmentation mask to the exact source video frame that generated it.
   - Eliminates subject edge tearing and trailing artifacts during fast head/hand movements.
   - Automatically falls back to the closest valid frame if an exact frame timestamp is not in the buffer.

2. **Manual Delay**:
   - Applies a user-defined fixed frame delay (`0` to `15` frames) to the video feed.
   - Useful for specialized broadcast pipelines, fixed-latency capture cards, or custom AV sync requirements.

3. **Disabled (Low Latency / No Delay)**:
   - Immediately applies the newest available mask to the current incoming video frame without frame buffering.
   - Provides minimal latency at the expense of potential edge jitter during fast motion.

---

## Getting Started

1. Download the latest installer `.pkg` or `.zip` from the [Releases](https://github.com/UUoocl/obs-mac-backgroundremoval/releases) page.
2. Run the installer package. If prompted about an unidentified developer, right-click the package and select **Open**.
3. Launch OBS Studio.
4. Right-click your video source (e.g., Video Capture Device, Media Source) and choose **Filters**.
5. Under **Effect Filters**, click **+** and select **macOS Background Removal**.

---

## Building from Source

This project uses CMake and follows the [OBS Plugin Template](https://github.com/obsproject/obs-plugintemplate).

```bash
# Configure for macOS Universal (Apple Silicon & Intel)
cmake --preset macos -B build_macos

# Build
cmake --build build_macos --config RelWithDebInfo
```

---

## License and Credits

- Licensed under the **GNU General Public License v2.0** (see [LICENSE](LICENSE)).
- Originally created by [Sebastian Beckmann](https://github.com/gxalpha/obs-mac-backgroundremoval).
- Thanks to [pkviet](https://github.com/obsproject/obs-studio) from OBS for earlier reference implementations of GPU background filters.
