#!/bin/bash
set -euo pipefail

MAIN="src/main.py"
[ -f "$MAIN" ] || { echo "❌ $MAIN not found. Run from repo root."; exit 1; }

python3 - << 'PY'
from pathlib import Path
import re

p = Path("src/main.py")
s = p.read_text()

# 1) Make rebuild_zone_overlay() a no-op (if present). If missing, inject a no-op.
if "def rebuild_zone_overlay" in s:
    s = re.sub(
        r"def\s+rebuild_zone_overlay\([^)]*\):[\s\S]*?(?=\n\S|$)",
        "def rebuild_zone_overlay():\n    \"\"\"Server overlay disabled; front-end draws Stage/Track/Cal.\"\"\"\n    return\n",
        s, count=1
    )
else:
    # Insert a no-op near the top (after constants)
    ins_at = s.find("LOST_FRAMES_LIMIT")
    ins_at = s.find("\n", ins_at) + 1 if ins_at != -1 else 0
    s = s[:ins_at] + "\n\ndef rebuild_zone_overlay():\n    \"\"\"Server overlay disabled; front-end draws Stage/Track/Cal.\"\"\"\n    return\n\n" + s[ins_at:]

# 2) Ensure any zone_overlay usage doesn’t alter the frame.
# Replace `disp = cv2.add(frame.copy(), zone_overlay)` → `disp = frame.copy()`
s = re.sub(
    r"disp\s*=\s*cv2\.add\(\s*frame\.copy\(\)\s*,\s*zone_overlay\s*\)",
    "disp = frame.copy()",
    s
)

# Also cover variants like: disp = cv2.add(disp, zone_overlay) and similar
s = re.sub(
    r"disp\s*=\s*cv2\.add\(\s*disp\s*,\s*zone_overlay\s*\)",
    "disp = disp",
    s
)

# 3) Prevent creating/maintaining a heavy overlay image: make any `zone_overlay = np.zeros_like(first_frame)` harmless.
s = re.sub(
    r"zone_overlay\s*=\s*np\.zeros_like\(\s*first_frame\s*\)",
    "zone_overlay = None  # server overlay disabled",
    s
)

# 4) Guard any accidental later uses like cv2.add(..., zone_overlay) -> just pass through
s = re.sub(
    r"cv2\.add\(\s*([a-zA-Z_][\w]*)\s*,\s*zone_overlay\s*\)",
    r"\1  # server overlay disabled",
    s
)

# 5) Optional: comment out explicit draw_zone/draw_calibration_line calls if any slipped in (keep imports harmless)
s = re.sub(
    r"^\s*draw_zone\([^)]*\)\s*$",
    "# draw_zone() skipped (server overlay disabled)",
    s, flags=re.M
)

# 6) Keep mask overlay behavior; if you want it gone too, toggle show_mask=false in settings.json

p.write_text(s)
print("✅ Server overlays stripped (boxes/lines now front-end only).")
PY

echo "ℹ️ If you also want to disable the grayscale mask overlay, set \"show_mask\": false in settings.json."
