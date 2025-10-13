#!/bin/bash
set -e

if [ ! -f "src/main.py" ]; then
  echo "❌ Couldn't find src/main.py. Run from your project root."
  exit 1
fi

python3 - << 'PY'
from pathlib import Path
import re

p = Path("src/main.py")
txt = p.read_text()

# 1) Ensure we compute vid_fps and wait_ms alongside the dt override
if "wait_ms" not in txt:
    txt = re.sub(
        r"(tracker\s*=\s*MotionTracker\(\)\s*\n\s*# Use video FPS for timing when source=video, for correct speeds\s*\n\s*if inp.get\(\"source\"\) == \"video\":\s*\n\s*cap_tmp = cv2\.VideoCapture\(inp.get\(\"video_path\", \"testdata/my_putt.mp4\"\)\)\s*\n\s*fps = cap_tmp\.get\(cv2\.CAP_PROP_FPS\) or 30\.0\s*\n\s*cap_tmp\.release\(\)\s*\n\s*try:\s*\n\s*tracker\.set_dt_override\(1\.0 / float\(fps\)\)\s*\n\s*except Exception:\s*\n\s*pass\s*\n\s*else:\s*\n\s*try:\s*\n\s*tracker\.set_dt_override\(None\)\s*\n\s*except Exception:\s*\n\s*pass)",
        r"""tracker = MotionTracker()
    # Use video FPS for timing when source=video, for correct speeds
    is_video = (inp.get("source") == "video")
    vid_fps = 30.0
    wait_ms = 1
    if is_video:
        cap_tmp = cv2.VideoCapture(inp.get("video_path", "testdata/my_putt.mp4"))
        vid_fps = cap_tmp.get(cv2.CAP_PROP_FPS) or 30.0
        cap_tmp.release()
        try:
            tracker.set_dt_override(1.0 / float(vid_fps))
        except Exception:
            pass
        # throttle UI loop to video FPS
        try:
            wait_ms = max(1, int(round(1000.0 / float(vid_fps))))
        except Exception:
            wait_ms = 33
    else:
        try:
            tracker.set_dt_override(None)
        except Exception:
            pass
        wait_ms = 1""",
        txt,
        flags=re.DOTALL
    )

# 2) Replace cv2.waitKey(1) with cv2.waitKey(wait_ms)
txt = txt.replace("cv2.waitKey(1)", "cv2.waitKey(wait_ms)")

p.write_text(txt)
print("✅ Throttling added: UI now waits ~1/fps per frame for video sources.")
PY

echo "Done. Now run:  source .venv/bin/activate && python3 src/main.py"
