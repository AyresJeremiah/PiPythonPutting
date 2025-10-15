#!/bin/bash
set -e
[ -f "src/main.py" ] || { echo "❌ src/main.py not found"; exit 1; }

python3 - <<'PY'
from pathlib import Path

p = Path("src/main.py")
s = p.read_text().splitlines()

def looks_like_fps_val_defined(recent_lines):
    return any("fps_val" in ln for ln in recent_lines[-8:])

out = []
for i, line in enumerate(s):
    # Replace any "'fps': float(getattr(tracker, 'fps', 0.0))" (single or double quotes)
    line = line.replace("float(getattr(tracker, 'fps', 0.0))", "fps_val")
    line = line.replace('float(getattr(tracker, "fps", 0.0))', "fps_val")

    # When we see a telemetry dict starting, ensure fps_val is defined just above it
    if "tele = {" in line and not looks_like_fps_val_defined(out):
        out.append("        fps_val = getattr(tracker, 'fps', None)")
        out.append("        try:")
        out.append("            fps_val = 0.0 if fps_val is None else float(fps_val)")
        out.append("        except (TypeError, ValueError):")
        out.append("            fps_val = 0.0")
    out.append(line)

p.write_text("\n".join(out))
print("✅ Patched telemetry: safe fps_val used in all tele dicts.")
PY
