# macOS Background Removal Filter for OBS Studio

A native macOS background removal filter plugin for [OBS Studio](https://obsproject.com/) leveraging Apple Silicon and macOS Vision framework neural network person segmentation (`VNGeneratePersonSegmentationRequest`).

---

## Features

- **Native macOS Vision Framework**: Hardware-accelerated real-time background removal utilizing the Apple Neural Engine and GPU with minimal CPU impact.
- **Configurable Quality Modes**:
  - **Balanced**: Refined segmentation and smooth edges.
  - **Fast**: High-performance segmentation designed for 60 FPS streams.
- **Customizable Threshold & Feathering**: Fine-tune edge sharpness and soft blending transitions.
- **Advanced Frame Synchronization**: Multiple sync strategies including a configurable FIFO pipeline buffer to guarantee zero edge ghosting or desync during rapid motion.

---

## Filter Settings

Once added to any source under **Filters > Effect Filters > macOS Background Removal**, the following settings are available:

| Setting | Options / Range | Description |
| :--- | :--- | :--- |
| **Threshold** | `0.00` – `1.00` (Default: `0.90`) | Controls the confidence cutoff for person segmentation. Lower values (`0.75`–`0.80`) preserve more edge details and gestures. |
| **Quality** | `Balanced` (Default)<br>`Fast` | • **Balanced**: High-accuracy segmentation with refined edge detail.<br>• **Fast**: High-throughput mode (~10ms/frame) designed for 60 FPS real-time capture. |
| **Sync Mode** | `Auto Sync`<br>`Buffered Exact Sync`<br>`Manual Delay`<br>`Disabled` | Controls how video frames are synchronized with the asynchronous segmentation mask (see details below). |
| **Buffer Depth** | `5` – `60` frames (Default: `20`) | Configures the FIFO video queue depth when **Buffered Exact Sync** is selected. |
| **Manual Delay** | `0` – `15` frames (Default: `2`) | Configures the number of buffer frames to delay the video feed when **Manual Delay** is selected. |

### Frame Synchronization Modes

Neural network inference takes a few milliseconds to process asynchronously. This plugin provides four synchronization strategies tailored for different streaming and broadcast needs:

1. **Auto Sync (Adaptive Frame Match)** *(Default)*:
   - Dynamically tracks live Neural Engine inference latency and delays the video feed by the measured frame offset ($2$–$3$ frames).
   - Provides low latency with automatic synchronization.

2. **Buffered Exact Sync (Configurable FIFO Buffer)** *(Recommended for Fast Motion)*:
   - Places video frames into a dedicated GPU FIFO queue (configurable from `5` to `60` frames, default `20` frames / ~333ms @ 60 FPS).
   - Guarantees the Neural Engine has completely finished processing the segmentation mask before the matching video frame is outputted.
   - Eliminates 100% of mask lag and edge tearing during rapid hand waving or head movements.
   - *Tip*: Set a matching audio sync offset on your microphone in OBS under **Edit > Advanced Audio Properties** ($\text{Delay (ms)} = \frac{\text{Buffer Frames}}{\text{FPS}} \times 1000$).

3. **Manual Delay**:
   - Applies a user-defined fixed frame delay (`0` to `15` frames) to the video feed.
   - Useful for fixed-latency broadcast pipelines or capture cards.

4. **Disabled (Low Latency / No Delay)**:
   - Immediately applies the newest available mask to the live incoming video frame with zero buffer delay.
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

### Prerequisites
- macOS 12.0+ (Universal build supports Apple Silicon & Intel)
- Xcode 14+ / Command Line Tools
- CMake 3.28+

### Build Steps

```bash
# 1. Configure
cmake --preset macos

# 2. Compile Universal Binary with Debug Symbols
cmake --build build_macos --config RelWithDebInfo

# 3. Install to OBS plugins directory
cp -R build_macos/RelWithDebInfo/obs-mac-backgroundremoval.plugin "$HOME/Library/Application Support/obs-studio/plugins/"
cp -R build_macos/RelWithDebInfo/obs-mac-backgroundremoval.plugin.dSYM "$HOME/Library/Application Support/obs-studio/plugins/"
```

---

## License

GNU General Public License v2.0 or later.
