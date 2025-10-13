import json, os
from typing import Any, Dict

SETTINGS_PATH = os.path.join(os.path.dirname(os.path.dirname(__file__)), "settings.json")

_DEFAULTS: Dict[str, Any] = {
    "ball_color": "white",                 # named fallback ('white', 'yellow', etc.)
    "ball_hsv": {"lower": None, "upper": None},  # custom HSV overrides if set
    "min_ball_radius_px": 3,
    "show_mask": False,
    "target_width": 960,
    "min_report_mph": 1.0,
    "roi": {"startx": None, "endx": None, "starty": None, "endy": None},
    "calibration": {
        "px_per_yard": None,
        "yards_length": 1.0,
        "line": {"x1": 100, "y1": 100, "x2": 400, "y2": 100}
    },
    "post": {
        "enabled": True,
        "host": "10.10.10.23",
        "port": 8888,
        "path": "/putting",
        "timeout_sec": 2.5
    }
}

_cache: Dict[str, Any] = None

def _merge(d, defaults):
    for k, v in defaults.items():
        if k not in d:
            d[k] = v
        elif isinstance(v, dict) and isinstance(d[k], dict):
            _merge(d[k], v)
    return d

def load() -> Dict[str, Any]:
    global _cache
    if _cache is not None:
        return _cache
    if os.path.exists(SETTINGS_PATH):
        with open(SETTINGS_PATH, "r") as f:
            try:
                data = json.load(f)
            except Exception:
                data = {}
    else:
        data = {}
    _cache = _merge(data, _DEFAULTS.copy())
    return _cache

def save():
    if _cache is None:
        return
    with open(SETTINGS_PATH, "w") as f:
        json.dump(_cache, f, indent=2)

def set_value(path, value):
    """path like 'show_mask' or 'roi.startx' or 'ball_hsv.lower'."""
    s = load()
    parts = path.split(".")
    ref = s
    for p in parts[:-1]:
        ref = ref[p]
    ref[parts[-1]] = value
    save()

def set_roi(x1, y1, x2, y2):
    s = load()
    s["roi"]["startx"] = int(min(x1, x2))
    s["roi"]["endx"]   = int(max(x1, x2))
    s["roi"]["starty"] = int(min(y1, y2))
    s["roi"]["endy"]   = int(max(y1, y2))
    save()

def ensure_roi_initialized(width: int, height: int):
    s = load()
    roi = s["roi"]
    if None in (roi["startx"], roi["endx"], roi["starty"], roi["endy"]):
        roi["startx"] = 0
        roi["starty"] = 0
        roi["endx"]   = int(width)
        roi["endy"]   = int(height)
        save()

def clamp_roi(width: int, height: int):
    s = load()
    r = s["roi"]
    r["startx"] = max(0, min(int(r["startx"]), width-1))
    r["endx"]   = max(1, min(int(r["endx"]), width))
    r["starty"] = max(0, min(int(r["starty"]), height-1))
    r["endy"]   = max(1, min(int(r["endy"]), height))
    if r["startx"] >= r["endx"]:
        r["endx"] = min(width, r["startx"] + 1)
    if r["starty"] >= r["endy"]:
        r["endy"] = min(height, r["starty"] + 1)
    save()

def clamp_calibration(width:int, height:int):
    s = load()
    L = s["calibration"]["line"]
    for k in ("x1","x2"):
        L[k] = max(0, min(int(L[k]), width-1))
    for k in ("y1","y2"):
        L[k] = max(0, min(int(L[k]), height-1))
    yl = float(s["calibration"].get("yards_length", 1.0))
    if yl <= 0: s["calibration"]["yards_length"] = 1.0
    save()
