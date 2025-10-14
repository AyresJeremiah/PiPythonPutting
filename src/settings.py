import json, os
from typing import Any, Dict

SETTINGS_PATH = os.path.join(os.path.dirname(os.path.dirname(__file__)), "settings.json")

_DEFAULTS: Dict[str, Any] = {
    "ball_color": "white",
    "ball_hsv": {"lower": None, "upper": None},
    "min_ball_radius_px": 3,
    "show_mask": False,
    "target_width": 960,
    "min_report_mph": 1.0,
    "roi": {"startx": None, "endx": None, "starty": None, "endy": None},  # legacy (kept)
    "zones": {
        # NEW: two-zone trigger
        "stage_roi": {"x1": None, "y1": None, "x2": None, "y2": None},
        "track_roi": {"x1": None, "y1": None, "x2": None, "y2": None}
    },
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
    },
    "input": {
        "source": "camera",
        "video_path": "testdata/my_putt.mp4",
        "loop": True
    },
    "gate": {  # kept for compatibility but unused now
        "enabled": False,
        "line": {"x1": 0, "y1": 0, "x2": 0, "y2": 0}
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
    """path like 'zones.stage_roi.x1', 'show_mask', 'min_report_mph'."""
    s = load()
    parts = path.split(".")
    ref = s
    for p in parts[:-1]:
        ref = ref[p]
    ref[parts[-1]] = value
    save()

def ensure_roi_initialized(width: int, height: int):
    s = load()
    r = s["roi"]
    if None in (r["startx"], r["endx"], r["starty"], r["endy"]):
        r["startx"], r["starty"], r["endx"], r["endy"] = 0, 0, width, height
        save()

def clamp_roi(width: int, height: int):
    s = load()
    r = s["roi"]
    r["startx"] = max(0, min(int(r["startx"]), width-1))
    r["endx"]   = max(1, min(int(r["endx"]),   width))
    r["starty"] = max(0, min(int(r["starty"]), height-1))
    r["endy"]   = max(1, min(int(r["endy"]),   height))
    if r["startx"] >= r["endx"]:  r["endx"]  = min(width,  r["startx"] + 1)
    if r["starty"] >= r["endy"]:  r["endy"]  = min(height, r["starty"] + 1)
    save()

# NEW: init/clamp for zones
def ensure_zones_initialized(width:int, height:int):
    s = load()
    z = s["zones"]
    st = z["stage_roi"]; tr = z["track_roi"]
    if None in (st["x1"], st["y1"], st["x2"], st["y2"]):
        # default small box near bottom-left
        st["x1"], st["y1"] = int(width*0.10), int(height*0.70)
        st["x2"], st["y2"] = int(width*0.30), int(height*0.95)
    if None in (tr["x1"], tr["y1"], tr["x2"], tr["y2"]):
        # default tracking lane across the mat
        tr["x1"], tr["y1"] = int(width*0.15), int(height*0.25)
        tr["x2"], tr["y2"] = int(width*0.85), int(height*0.75)
    save()

def clamp_zone_rect(rect, width:int, height:int):
    rect["x1"] = max(0, min(int(rect["x1"]), width-1))
    rect["x2"] = max(1, min(int(rect["x2"]), width))
    rect["y1"] = max(0, min(int(rect["y1"]), height-1))
    rect["y2"] = max(1, min(int(rect["y2"]), height))
    if rect["x1"] >= rect["x2"]: rect["x2"] = min(width, rect["x1"]+1)
    if rect["y1"] >= rect["y2"]: rect["y2"] = min(height, rect["y1"]+1)

def clamp_zones(width:int, height:int):
    s = load()
    clamp_zone_rect(s["zones"]["stage_roi"], width, height)
    clamp_zone_rect(s["zones"]["track_roi"], width, height)
    save()
