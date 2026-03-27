# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

PuttTracker: a headless, camera-based golf putting tracker. An overhead camera detects a golf ball via HSV color masking, measures speed (px/s → mph via calibration) and horizontal launch angle (HLA), then POSTs shot data to a configurable server (e.g., GSPro). All UI is browser-based (no OpenCV windows).

## Running

```bash
# Install
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# On Raspberry Pi also: sudo apt install -y v4l-utils

# Run (from repo root)
python src/main.py
# Web UI: http://localhost:8080
```

There are no tests or linters configured.

## Architecture

### State Machine (in `src/main.py`)
The core loop runs a state machine: **IDLE → STAGED → TRACKING → FINALIZE → COOLDOWN**.
- Ball enters the **Stage** zone → arms the tracker (STAGED)
- Ball crosses into the **Track** zone → begins velocity tracking (TRACKING)
- After a configurable delay (`tracking_delay_post_time`), transitions to FINALIZE
- FINALIZE computes speed/HLA from first and last tracked positions, POSTs the shot, then enters COOLDOWN (1s)

### Settings Flow
- `settings.json` (repo root) is read once at boot by `src/settings.py` into an in-memory dict
- `src/utils/runtime_cfg.py` provides global access to this dict (`set_cfg`/`get_cfg`)
- Web UI changes go through two paths:
  - **Preview** (`POST /settings/preview`): deep-merges into the in-memory dict, applies immediately (camera controls, zones, etc.) — no disk write
  - **Save** (`POST /settings/save`): same as preview, then atomically writes to `settings.json`
- See `SettingsExamples/` for reference configs (Pi camera, debug, Mac, etc.)

### Camera Backends
Two camera classes in `src/camera/capture.py`:
- `Camera` (OpenCV/V4L2): threaded reader for live USB cameras, sequential for video files. Supports `apply_controls()` for brightness/contrast/exposure/etc.
- `PiCam2Camera` (Picamera2/libcamera): for Raspberry Pi HQ Camera at high FPS (e.g., 120fps). Selected when `camera.type` is `"picam2"` in settings.

### Web UI (`src/ui/webui.py`)
FastAPI server running in a daemon thread. Key endpoints:
- `GET /video.mjpg` — MJPEG stream of raw frames (no server-drawn overlays)
- `WS /ws` — telemetry push at 20Hz (ball position, state, speed, HLA, FPS, dims)
- `POST /pick/ball` — click-to-pick ball color from stream (computes HSV window)
- `POST /calibration/line` — drag calibration line, computes px_per_yard

All visual overlays (stage/track boxes, ball marker, calibration line) are drawn client-side in `web/static/app.js` on a canvas over the MJPEG `<img>`.

### Ball Detection (`src/tracking/ball_detector.py`)
HSV mask → erode/dilate → find largest contour → minEnclosingCircle. Refreshes HSV bounds from runtime config on every frame. Detection runs only within the union of stage+track zones (optionally downscaled via `detect.scale`).

### Shot Posting (`src/services/gspro.py`)
HTTP POST to configurable endpoint with `ballData` payload (`BallSpeed`, `TotalSpin`, `LaunchDirection`). Target is typically a GSPro or similar golf simulator API.

## Platform Notes
- macOS: AVFoundation ignores most camera control setters — camera sliders will show zeros. This is expected; camera controls work on Pi via V4L2.
- Raspberry Pi: use `opencv-python-headless` instead of `opencv-python` in requirements.txt.
