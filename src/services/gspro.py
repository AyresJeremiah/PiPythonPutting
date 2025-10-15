import requests

def post_shot(mph, direction, cfg = None):
    post = cfg.get("post", {})
    if not post.get("enabled", True):
        return False, None
    url = f"http://{post.get('host', '10.10.10.23')}:{int(post.get('port', 8888))}{post.get('path', '/putting')}"
    payload = {
        "ballData": {
            "BallSpeed": f"{(mph or 0.0):.2f}",
            "TotalSpin": 0,
            "LaunchDirection": f"{(direction or 0.0):.2f}"
        }
    }
    try:
        r = requests.post(url, json=payload, timeout=float(post.get("timeout_sec", 2.5)))
        r.raise_for_status()
        try:
            data = r.json()
        except ValueError:
            data = None
        print(f"POST OK -> {url} | {payload}")
        return True, data
    except requests.exceptions.RequestException as e:
        print(f"POST error -> {e}")
        return False, None
