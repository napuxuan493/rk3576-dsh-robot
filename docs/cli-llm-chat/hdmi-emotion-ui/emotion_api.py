#!/usr/bin/env python3
"""Emotion API — one emotion at a time; special clips outrank normal.

Normal set (priority 0): idle | listening | speaking
Special set (priority 1): all other v1.1.0 pack clips (happy, confused, …)

While a higher-priority (or same-priority locked) clip holds the lock,
lower-priority requests are ignored (return current state + ignored:true).
"""
from __future__ import annotations

import json
import os
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ROOT = os.path.dirname(os.path.abspath(__file__))
HOST = os.environ.get("EMOTION_HOST", "127.0.0.1")
PORT = int(os.environ.get("EMOTION_PORT", "8765"))
PACK_INDEX = os.environ.get(
    "ROBOT_EYES_INDEX",
    "/userdata/animation-assets/rk3576-robot-eyes/fb-raw/index.json",
)

NORMAL_STATES = frozenset({"idle", "listening", "speaking"})
DEFAULT_SPECIAL_HOLD = float(os.environ.get("EMOTION_SPECIAL_HOLD", "2.5"))
DEFAULT_NORMAL_HOLD = float(os.environ.get("EMOTION_NORMAL_HOLD", "0.4"))

DEFAULT_STATES = [
    "idle",
    "blink",
    "look_around",
    "listening",
    "happy",
    "excited",
    "love",
    "surprised",
    "confused",
    "thinking",
    "sad",
    "angry",
    "sleepy",
    "sleep",
    "wink",
    "speaking",
    "dizzy",
    "boot",
    "shutdown",
]


def _load_states() -> list[str]:
    try:
        j = json.loads(open(PACK_INDEX).read())
        names = [a["name"] for a in j.get("animations", []) if a.get("name")]
        if names:
            return names
    except Exception:
        pass
    return list(DEFAULT_STATES)


STATES = set(_load_states())
STATE_LIST = _load_states()

_lock = threading.Lock()
_state = {
    "state": "idle",
    "variant": "",
    "ts": time.time(),
    "priority": 0,
    "lock_until": 0.0,
}


def priority_of(state: str) -> int:
    return 0 if state in NORMAL_STATES else 1


def _expire_special_unlocked(now: float | None = None) -> bool:
    """When a special's hold ends, release to idle so eyes can leave (confused etc.).

    Lock only blocks *preemption*; without this, state stays on the special forever
    and non-loop clips freeze on the last frame / looping clips never yield to idle.
    """
    now = time.time() if now is None else now
    lock_until = float(_state.get("lock_until") or 0)
    pri = int(_state.get("priority") or 0)
    st = (_state.get("state") or "idle").strip().lower()
    if pri < 1 or st in NORMAL_STATES:
        return False
    if now < lock_until:
        return False
    _state["state"] = "idle"
    _state["variant"] = ""
    _state["ts"] = now
    _state["priority"] = 0
    _state["lock_until"] = 0.0
    return True


def get_state():
    with _lock:
        _expire_special_unlocked()
        s = dict(_state)
    s["locked"] = time.time() < float(s.get("lock_until") or 0)
    s["normal"] = sorted(NORMAL_STATES)
    return s


def set_state(
    state: str,
    variant: str | None = None,
    hold: float | None = None,
    force: bool = False,
):
    state = (state or "idle").strip().lower().replace("-", "_")
    aliases = {
        "lookleft": "look_around",
        "look_left": "look_around",
        "lookright": "look_around",
        "look_right": "look_around",
        "look_up": "look_around",
        "lookaround": "look_around",
    }
    state = aliases.get(state, state)
    if state not in STATES:
        raise ValueError(f"unknown state: {state}; try: {', '.join(STATE_LIST)}")

    pri = priority_of(state)
    now = time.time()
    if hold is None:
        hold = DEFAULT_SPECIAL_HOLD if pri >= 1 else DEFAULT_NORMAL_HOLD

    with _lock:
        _expire_special_unlocked(now)
        cur_pri = int(_state.get("priority") or 0)
        lock_until = float(_state.get("lock_until") or 0)
        locked = now < lock_until

        # One-at-a-time: lower priority cannot preempt an active higher lock.
        # Same priority: allow replace (new speaking/listening) unless force=false
        # and we want special to finish — special→special allowed; normal→normal ok.
        if not force and locked and pri < cur_pri:
            out = dict(_state)
            out["ignored"] = True
            out["reason"] = "locked_by_special"
            out["locked"] = True
            return out

        _state["state"] = state
        _state["variant"] = (variant or "").strip().lower() if variant else ""
        _state["ts"] = now
        _state["priority"] = pri
        _state["lock_until"] = now + max(0.0, float(hold))
        out = dict(_state)
        out["ignored"] = False
        out["locked"] = True if hold > 0 else False
        return out


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def log_message(self, fmt, *args):
        if os.environ.get("EMOTION_VERBOSE"):
            super().log_message(fmt, *args)

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        try:
            return json.loads(raw.decode() or "{}")
        except Exception:
            return {}

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,PUT,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/api/emotion":
            self._json(200, get_state())
            return
        if u.path == "/api/emotion/list":
            special = [s for s in STATE_LIST if s not in NORMAL_STATES]
            self._json(
                200,
                {
                    "animations": STATE_LIST,
                    "count": len(STATE_LIST),
                    "normal": sorted(NORMAL_STATES),
                    "special": special,
                },
            )
            return
        if u.path == "/api/emotion/set":
            qs = parse_qs(u.query)
            try:
                st = (qs.get("state") or ["idle"])[0]
                var = (qs.get("variant") or [None])[0]
                hold = qs.get("hold")
                force = (qs.get("force") or [""])[0] in ("1", "true", "yes")
                h = float(hold[0]) if hold else None
                self._json(200, set_state(st, var, hold=h, force=force))
            except ValueError as e:
                self._json(400, {"error": str(e)})
            return
        if u.path.startswith("/api/emotion/"):
            name = u.path.rsplit("/", 1)[-1]
            if name and name not in ("set", "list"):
                try:
                    self._json(200, set_state(name))
                except ValueError as e:
                    self._json(400, {"error": str(e)})
                return
        return super().do_GET()

    def do_POST(self):
        u = urlparse(self.path)
        if u.path == "/api/emotion":
            body = self._read_json()
            if not body and self.headers.get("Content-Type", "").startswith(
                "application/x-www-form-urlencoded"
            ):
                n = int(self.headers.get("Content-Length") or 0)
                qs = parse_qs(self.rfile.read(n).decode())
                body = {k: (v[0] if v else "") for k, v in qs.items()}
            try:
                hold = body.get("hold")
                h = float(hold) if hold is not None and hold != "" else None
                force = bool(body.get("force"))
                self._json(
                    200,
                    set_state(
                        body.get("state", "idle"),
                        body.get("variant"),
                        hold=h,
                        force=force,
                    ),
                )
            except ValueError as e:
                self._json(400, {"error": str(e)})
            return
        self._json(404, {"error": "not found"})

    def do_PUT(self):
        u = urlparse(self.path)
        if u.path.startswith("/api/emotion/"):
            name = u.path.rsplit("/", 1)[-1]
            try:
                self._json(200, set_state(name))
            except ValueError as e:
                self._json(400, {"error": str(e)})
            return
        self._json(404, {"error": "not found"})


def main():
    global STATES, STATE_LIST
    STATE_LIST = _load_states()
    STATES = set(STATE_LIST)
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    print(
        f"emotion_api :{PORT} normal={sorted(NORMAL_STATES)} "
        f"special_hold={DEFAULT_SPECIAL_HOLD}s states={len(STATE_LIST)}",
        flush=True,
    )
    httpd.serve_forever()


if __name__ == "__main__":
    main()
