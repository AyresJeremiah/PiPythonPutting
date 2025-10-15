#!/bin/bash
set -euo pipefail

CAP="src/camera/capture.py"
MAIN="src/main.py"

[ -f "$CAP" ]  || { echo "❌ $CAP not found"; exit 1; }
[ -f "$MAIN" ] || { echo "❌ $MAIN not found"; exit 1; }

#############################################
# 1) Insert apply_controls() into capture.py
#############################################
python3 - "$CAP" << 'PY'
from pathlib import Path
import re as _re
p = Path(__import__("sys").argv[1])
s = p.read_text()

# If method already exists, leave it.
if "def apply_controls(self, cam_cfg:" in s:
    print("ℹ️ apply_controls() already present in capture.py")
else:
    # Find insertion point INSIDE class Camera:, just before def negotiated(...) if present,
    # otherwise before last method or append at end of class.
    m_class = _re.search(r'^class\s+Camera\s*:\s*$', s, flags=_re.M)
    if not m_class:
        raise SystemExit("❌ Could not find `class Camera:`")

    # Prefer to insert before negotiated() to keep helpers grouped.
    m_neg = _re.search(r'^[ \t]+def\s+negotiated\(', s, flags=_re.M)
    insert_at = m_neg.start() if m_neg else None

    # Fallback: insert before the last method inside the class by scanning from class start.
    if insert_at is None:
        # Find the block for the class (naive: from class line to EOF)
        insert_at = len(s)

    method = """
    # -------- camera controls (V4L2/OpenCV) --------
    def apply_controls(self, cam_cfg: dict):
        \"\"\"
        Apply V4L2-style controls using OpenCV properties.

        cam_cfg example:
          {
            "brightness": 128,   # 0-255
            "contrast":   128,   # 0-255
            "saturation": 128,   # 0-255
            "sharpness":  128,   # 0-255 (may map to GAMMA)
            "gain":       0,     # 0-255 (driver-specific)
            "exposure_auto": 1,  # 1=auto, 0=manual (mapping varies)
            "exposure":    200,  # manual exposure (backend units)
            "wb_auto":     1,    # 1=auto WB, 0=manual
            "wb_temp":     4500  # 2000-8000 (often only when wb_auto=0)
          }
        \"\"\"
        if not hasattr(self, "_cap") or self._cap is None:
            return

        cap = self._cap

        def _set(prop, val):
            try:
                cap.set(prop, float(val))
            except Exception:
                pass

        import cv2

        # Core controls
        if "brightness" in cam_cfg:
            _set(cv2.CAP_PROP_BRIGHTNESS, cam_cfg.get("brightness"))
        if "contrast" in cam_cfg:
            _set(cv2.CAP_PROP_CONTRAST,   cam_cfg.get("contrast"))
        if "saturation" in cam_cfg:
            _set(cv2.CAP_PROP_SATURATION, cam_cfg.get("saturation"))

        # Sharpness (or GAMMA as fallback)
        if "sharpness" in cam_cfg:
            if hasattr(cv2, "CAP_PROP_SHARPNESS"):
                _set(cv2.CAP_PROP_SHARPNESS, cam_cfg.get("sharpness"))
            elif hasattr(cv2, "CAP_PROP_GAMMA"):
                _set(cv2.CAP_PROP_GAMMA, cam_cfg.get("sharpness"))

        # Exposure auto/manual (OpenCV often maps 0.25 manual / 0.75 auto)
        if "exposure_auto" in cam_cfg and hasattr(cv2, "CAP_PROP_AUTO_EXPOSURE"):
            use_auto = 1 if cam_cfg.get("exposure_auto") else 0
            _set(cv2.CAP_PROP_AUTO_EXPOSURE, 0.75 if use_auto else 0.25)

        if "exposure" in cam_cfg and hasattr(cv2, "CAP_PROP_EXPOSURE"):
            _set(cv2.CAP_PROP_EXPOSURE, cam_cfg.get("exposure"))

        if "gain" in cam_cfg and hasattr(cv2, "CAP_PROP_GAIN"):
            _set(cv2.CAP_PROP_GAIN, cam_cfg.get("gain"))

        # White balance
        if "wb_auto" in cam_cfg and hasattr(cv2, "CAP_PROP_AUTO_WB"):
            _set(cv2.CAP_PROP_AUTO_WB, 1 if cam_cfg.get("wb_auto") else 0)

        if "wb_temp" in cam_cfg and hasattr(cv2, "CAP_PROP_WB_TEMPERATURE"):
            _set(cv2.CAP_PROP_WB_TEMPERATURE, cam_cfg.get("wb_temp"))
"""

    # Ensure correct indentation under class (4 spaces)
    # We assume class body uses 4 spaces (as per your file). If tabs are used, Python will still accept consistent 4 spaces here.
    s = s[:insert_at] + method + s[insert_at:]
    p.write_text(s)
    print("✅ Inserted apply_controls() into capture.py")
PY

#############################################
# 2) Wire calls in main.py
#############################################
python3 - "$MAIN" << 'PY'
from pathlib import Path
import re as _re
p = Path(__import__("sys").argv[1])
s = p.read_text()

# A) After creating the Camera(), call camera.apply_controls(...)
if "camera.apply_controls(cfg.get('camera', {}))" not in s:
    s = _re.sub(
        r"(camera\s*=\s*Camera\([^\)]*\)\s*\)\s*)",
        r"\1\n    # Apply camera controls from settings (best-effort)\n"
        r"    try:\n"
        r"        camera.apply_controls(cfg.get('camera', {}))\n"
        r"    except Exception:\n"
        r"        pass\n",
        s, count=1
    )

# B) Inside _rebuild_from_cfg(), re-apply on preview changes
if "def _rebuild_from_cfg(" in s and "camera.apply_controls(" not in s.split("def _rebuild_from_cfg",1)[1]:
    s = _re.sub(
        r"(def _rebuild_from_cfg\(\):[\s\S]*?)(\n\s*# refresh pacing|\n\s*is_video\s*=|\n\s*# ---------- Web UI ----------)",
        r"\1\n        # camera controls (live preview)\n"
        r"        try:\n"
        r"            camera.apply_controls(cfg.get('camera', {}))\n"
        r"        except Exception:\n"
        r"            pass\n\2",
        s, count=1
    )

Path(__import__("sys").argv[1]).write_text(s)
print("✅ Wired camera.apply_controls() in main.py")
PY

echo "🎉 Done. Restart your app and adjust camera sliders in the Web UI (preview live, save to persist)."
