_CFG = None

def set_cfg(cfg):
    """Set the in-memory config once at startup."""
    global _CFG
    _CFG = cfg

def get_cfg():
    """Access the in-memory config anywhere without touching disk."""
    if _CFG is None:
        raise RuntimeError("Runtime config not set. Call set_cfg(cfg) in main.py at startup.")
    return _CFG
