# PuttTracker (Headless + Web UI)

PuttTracker is a lightweight, camera‑based putting tracker written in Python. It detects a (white-by-default) golf ball from an overhead camera, measures its **speed** and **direction (HLA)** as it travels through a defined **Stage** → **Track** workflow, and can post the shot data to a local server.

The app is **headless** (no OpenCV windows). All interaction happens in the **Web UI** that streams MJPEG video and overlays Stage/Track boxes you can **drag** directly on the video. Live changes preview instantly; clicking **Save** persists them to `settings.json`.

---

## Features

- Headless capture (USB cam or MP4 loop), web-based UI
- Ball detection with HSV mask (color pick on stream)
- Stage/Track state machine (IDLE → STAGED → TRACKING → COOLDOWN)
- Speed computation using calibration (pixels → yards) and dt
- Direction (HLA): left negative, right positive, clamped \[-60°, +60°]
- HTTP POST of shot data to your server
- Live camera controls (brightness/contrast/saturation/sharpness/gain/exposure/WB) with **V4L2 fallback** on Linux/Raspberry Pi
- Settings: **preview** (in-memory) vs **save** (to disk)

---

## Requirements

- Python 3.10+ (tested on macOS for dev; Raspberry Pi OS for deployment)
- OpenCV (`opencv-python`), NumPy
- FastAPI + Uvicorn (web server)
- On Raspberry Pi (Linux):
  - `v4l2-ctl` (`sudo apt install v4l-utils`) for robust camera control
  - Raspberry Pi HQ Camera (or V4L2-compatible UVC camera)

> macOS note: AVFoundation ignores many camera setters in OpenCV. Expect camera controls to show as zeros in debug there — the same code works on Pi via V4L2.

---

## Install

```bash
python -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install opencv-python numpy fastapi uvicorn starlette requests
```

(If you see `zsh: no matches found: uvicorn[standard]`, just install `uvicorn` without extras as shown above.)

On Raspberry Pi:
```bash
sudo apt update && sudo apt install -y v4l-utils
```

---

## Run

```bash
# From repo root
python src/main.py
```

Then open the Web UI in your browser:

```
http://localhost:8080
```

If running the backend on a Pi and opening the UI from another machine, use the Pi’s IP address instead of `localhost`.

---

## Quick Start (Web UI)

1. **Video feed** appears at the top (MJPEG).  
2. **Drag Stage/Track** rectangles directly on the video (or use the sliders).  
3. **Pick Ball Color** → click on the ball in the stream.  
4. **Calibrate px→yard** → drag the yellow line to match a yard stick, then **Save**.  
5. Adjust **Camera** sliders (brightness, exposure, WB, etc.). Changes preview live.  
6. Click **Save** to persist everything to `settings.json`.  
7. Putt: when a ball enters **Stage**, the system arms. When it crosses into **Track**, it **tracks** and exits to **COOLDOWN** after reporting speed & direction.

---

## Settings

All settings are read **once** on startup and kept in memory. Live changes are applied via `/settings/preview`; **Save** persists to `settings.json`.

### Example `settings.json`

```json
{
  "target_width": 960,
  "min_report_mph": 1.0,
  "show_mask": false,
  "input": {
    "source": "camera",               // "camera" | "video"
    "video_path": "testdata/my_putt.mp4",
    "loop": true,
    "playback_speed": 1.0
  },
  "zones": {
    "stage_roi": {"x1": 320, "y1": 200, "x2": 640, "y2": 360},
    "track_roi": {"x1": 320, "y1": 360, "x2": 640, "y2": 520}
  },
  "ball_hsv": { "lower": [21,161,172], "upper": [45,255,255] },
  "calibration": {
    "px_per_yard": 500.0,
    "line": {"x1": 100, "y1": 400, "x2": 600, "y2": 400}
  },
  "camera": {
    "brightness": 172,
    "contrast": 45,
    "saturation": 128,
    "sharpness": 128,
    "gain": 116,
    "exposure": 200,
    "wb_temp": 4500,
    "exposure_auto": 0,   // 1=auto, 0=manual (applied before manual exposure)
    "wb_auto": 0          // 1=auto WB, 0=manual
  },
  "post": {
    "enabled": true,
    "host": "10.10.10.23",
    "port": 8888,
    "path": "/putting",
    "timeout_sec": 2.5
  }
}
```

> **Note:** `camera` controls live-apply on preview. On Linux, we try OpenCV first, then a **V4L2** fallback (`v4l2-ctl`) for better compatibility.

---

## Web Endpoints (Frontend)

The Web UI uses these endpoints:

### Live video & telemetry
- `GET /video.mjpg` – MJPEG stream of raw frames (no server-drawn overlays).
- `GET /settings` – Returns the current in-memory settings (plus stream `dims`).
- `WS /ws` – WebSocket delivering telemetry JSON about the current frame:
  ```json
  {
    "stage": {"x1":..., "y1":..., "x2":..., "y2":...},
    "track": {"x1":..., "y1":..., "x2":..., "y2":...},
    "ball":  {"x":..., "y":..., "r":...} | null,
    "state": "IDLE|STAGED|TRACKING|COOLDOWN",
    "mph": 0.0,
    "yps": 0.0,
    "hla": 0.0,
    "fps": 30.0,
    "dims": {"w":1280, "h":720}
  }
  ```

### Settings (preview vs save)
- `POST /settings/preview` – Merge partial settings into the in-memory config and **apply immediately** (e.g., camera controls, zone rectangles, calibration value). *Does NOT write to disk.*  
  Example body:
  ```json
  { "zones": { "stage_roi": {"x1":330,"y1":210,"x2":650,"y2":370} } }
  ```

- `POST /settings/save` – Same as preview, then **persist** merged config to `settings.json`.  
  Body includes whatever you want to persist (zones, input.playback_speed, camera, calibration, etc.).

### Color & Calibration
- `POST /pick/ball` – Click-to-pick HSV from stream; updates `ball_hsv` live.
  ```json
  { "x": 512, "y": 420 }
  ```

- `POST /calibration/line` – Drag endpoints on stream; gets `px_per_yard`.
  ```json
  { "x1":120, "y1":400, "x2":620, "y2":400, "yards":1.0, "save": true }
  ```

> Optional (if enabled): `/camera/debug` could return the current hardware caps for display; otherwise watch console logs for `[PUTTTRACKER] Camera caps now: { ... }` after preview changes.

### Posting Shot Data (to your server)
When a putt finishes (exits Track with sufficient speed), we POST:
```
POST http://<host>:<port>/putting
```
Body:
```json
{
  "ballData": {
    "BallSpeed": "12.34",
    "TotalSpin": 0,
    "LaunchDirection": "-3.21"
  }
}
```

---

## UI Concepts

- **Stage**: area where placing the ball arms the tracker (**STAGED**).  
- **Track**: area that the moving ball enters to begin velocity tracking (**TRACKING**).  
- **COOLDOWN**: 1s pause after a shot before re-arming.  
- **Mask**: optional grayscale overlay of the binary mask used to find the ball (debug; toggle in settings).  
- **Color pick**: compute an HSV window around the clicked pixel (median of a small patch).  
- **Calibration**: pixels per yard computed from your drawn line; affects speed readouts (yd/s → mph).

---

## Tips & Performance

- Use **`input.source: "video"`** to test with a looping MP4. Control pacing with `input.playback_speed`.
- For best results on Pi, run a **1280×720 @ 60 fps** MJPEG stream if your camera supports it.
- Keep `detect.scale` ≤ 1.0; values like 0.6–0.8 speed up detection by downscaling the ROI union.
- If you see false positives, narrow the HSV window (ball color) and/or refine the Stage/Track layout.
- If your camera controls don’t change on macOS, test on the Raspberry Pi where V4L2 applies them.

---

## Troubleshooting

- **Saving works but preview doesn’t change**: ensure `/settings/preview` calls apply camera controls; see console log: `[PUTTTRACKER] Camera caps now: {...}`.
- **Camera caps show all zeros on macOS**: expected AVFoundation behavior. Validate on Pi with V4L2.
- **v4l2-ctl not found**: `sudo apt install v4l-utils` on Pi.
- **Video too fast** (MP4): adjust `input.playback_speed` (e.g., 0.5 for half-speed, 1.0 normal).
- **No ball detected**: turn on **Mask** to visualize the binary mask; tweak `ball_hsv` or lighting.
- **High CPU**: lower `target_width`, reduce `detect.scale`, narrow Stage/Track area.

---

## Dev Notes

- The backend draws **no boxes/lines**; overlays are rendered in the browser (canvas).
- The app reads `settings.json` once at boot; all live edits happen in memory until **Save**.
- Minimal per-frame allocations: static overlays removed; zones are only stored and sent as telemetry.

---

## Directory Layout (key files)

```
src/
  camera/
    capture.py         # Camera capture + apply_controls (OpenCV + V4L2 fallback)
  services/
    gspro.py           # post_shot(...) to your server
  tracking/
    ball_detector.py   # HSV mask, contour/circle find
    motion_tracker.py  # velocity, dt mgmt
  ui/
    webui.py           # FastAPI server: /video.mjpg, /ws, /settings, /pick/ball, /calibration/line
  utils/
    draw_utils.py      # (server overlays disabled), misc drawing helpers for mask, etc.
    logger.py          # log(...)
    runtime_cfg.py     # in-memory cfg sharing
main.py                # headless loop + WebUI wiring
settings.json          # persisted config
web/static/
  index.html           # Web UI
  app.js               # Front-end logic (sliders, drag, color pick, calibration, save)
```

---

## License

MIT (or your choice).

---

## Acknowledgements

Built for quick iteration on a Raspberry Pi HQ camera setup. Have fun, and PRs welcome!
