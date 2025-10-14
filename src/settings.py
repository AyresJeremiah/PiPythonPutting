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
    "roi": {"startx": 0, "starty": 0, "endx": 0, "endy": 0},  # legacy
    "zones": {
        "stage_roi": {"x1": 0, "y1": 0, "x2": 0, "y2": 0},
        "track_roi": {"x1": 0, "y1": 0, "x2": 0, "y2": 0}
    },
    "calibration": {
        "px_per_yard": None,
        "yards_length": 1.0,
        "line": {"x1": 100, "y1": 100, "x2": 400, "y2": 100}
    },
    "post": { "enabled": True, "host": "10.10.10.23", "port": 8888, "path": "/putting", "timeout_sec": 2.5 },
    "input": { "source": "camera", "video_path": "testdata/my_putt.mp4", "loop": True, "playback_speed": 1.0, "speed_affects_metrics": False }
}

_cache: Dict[str, Any] | None = None  # in-memory settings
_dirty: bool = False                   # if we need to flush to disk (we only write on change)

def _merge(dst, defaults):
    for k, v in defaults.items():
        if k not in dst:
            dst[k] = v
        elif isinstance(v, dict) and isinstance(dst[k], dict):
            _merge(dst[k], v)
    return dst

def load() -> Dict[str, Any]:
    """Read settings.json ONCE and keep an in-memory cache. Subsequent calls return the same dict (no disk IO)."""
    global _cache
    if _cache is not None:
        return _cache
    if os.path.exists(SETTINGS_PATH):
        try:
            with open(SETTINGS_PATH, "r") as f:
                data = json.load(f)
        except Exception:
            data = {}
    else:
        data = {}
    _cache = _merge(data, _DEFAULTS.copy())
    return _cache

def _save_if_dirty():
    global _dirty
    if not _dirty or _cache is None:
        return
    with open(SETTINGS_PATH, "w") as f:
        json.dump(_cache, f, indent=2)
    _dirty = False

def set_value(path: str, value):
    """
    Update a value in the cached settings and WRITE TO DISK ONLY IF it actually changed.
    path examples: 'zones.stage_roi.x1', 'show_mask', 'min_report_mph'
    """
    global _dirty
    s = load()
    parts = path.split(".")
    ref = s
    for p in parts[:-1]:
        ref = ref[p]
    key = parts[-1]
    if key in ref and ref[key] == value:
        return  # no change → no write
    ref[key] = value
    _dirty = True
    _save_if_dirty()

def ensure_roi_initialized(width: int, height: int):
    s = load()
    r = s["roi"]
    if r["endx"] == 0 and r["endy"] == 0:
        r["startx"], r["starty"], r["endx"], r["endy"] = 0, 0, width, height
        set_value("roi.startx", r["startx"]); set_value("roi.starty", r["starty"])
        set_value("roi.endx", r["endx"]);     set_value("roi.endy", r["endy"])

def clamp_roi(width: int, height: int):
    s = load(); r = s["roi"]
    r["startx"] = max(0, min(int(r["startx"]), width-1))
    r["endx"]   = max(1, min(int(r["endx"]),   width))
    r["starty"] = max(0, min(int(r["starty"]), height-1))
    r["endy"]   = max(1, min(int(r["endy"]),   height))
    if r["startx"] >= r["endx"]:  r["endx"]  = min(width,  r["startx"] + 1)
    if r["starty"] >= r["endy"]:  r["endy"]  = min(height, r["starty"] + 1)

def ensure_zones_initialized(width:int, height:int):
    s = load()
    st = s["zones"]["stage_roi"]; tr = s["zones"]["track_roi"]
    if st["x1"] == 0 and st["x2"] == 0 and st["y1"] == 0 and st["y2"] == 0:
        st.update({"x1": int(width*0.10), "y1": int(height*0.70), "x2": int(width*0.30), "y2": int(height*0.95)})
    if tr["x1"] == 0 and tr["x2"] == 0 and tr["y1"] == 0 and tr["y2"] == 0:
        tr.update({"x1": int(width*0.15), "y1": int(height*0.25), "x2": int(width*0.85), "y2": int(height*0.75)})

def _clamp_rect(rc, w, h):
    rc["x1"] = max(0, min(int(rc["x1"]), w-1)); rc["x2"] = max(1, min(int(rc["x2"]), w))
    rc["y1"] = max(0, min(int(rc["y1"]), h-1)); rc["y2"] = max(1, min(int(rc["y2"]), h))
    if rc["x1"] >= rc["x2"]: rc["x2"] = min(w, rc["x1"]+1)
    if rc["y1"] >= rc["y2"]: rc["y2"] = min(h, rc["y1"]+1)

def clamp_zones(width:int, height:int):
    s = load()
    _clamp_rect(s["zones"]["stage_roi"], width, height)
    _clamp_rect(s["zones"]["track_roi"], width, height)
