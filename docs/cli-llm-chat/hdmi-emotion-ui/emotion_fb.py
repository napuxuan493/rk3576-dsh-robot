#!/usr/bin/env python3
"""HDMI emotion UI — all rk3576-robot-eyes v1.1.0 fb-raw clips, scaled up.

Pack: /userdata/animation-assets/rk3576-robot-eyes/fb-raw/<anim>/
Centers the *symmetry line between the two eyes* (pair midline) on the *active*
HDMI CRTC size (e.g. 1024x600, 1440x900, 1920x1080) — not fb xres (often 800
while a secondary panel is 800x1280) and not the preferred-modes[0] alone
(preferred may be 1024x600 while CRTC is still 1920x1080 after Weston).

Hot path: bake scale+glow once per frame into an RGBA patch, then memcpy to fb.
"""
from __future__ import annotations

import array
import fcntl
import glob
import json
import math
import mmap
import os
import random
import re
import struct
import time
import urllib.request

FB_DEV = os.environ.get("FRAMEBUFFER", "/dev/fb0")
API = os.environ.get("EMOTION_API", "http://127.0.0.1:8765/api/emotion")
STATE_FILE = os.environ.get("EMOTION_STATE_FILE", "/tmp/dafeiyu-emotion.json")
PACK_ROOT = os.environ.get(
    "ROBOT_EYES_PACK",
    "/userdata/animation-assets/rk3576-robot-eyes/fb-raw",
)
# Uniform zoom of the 480 plate (1.0 = native). Tuned at EYE_REF_*; mapped to
# active CRTC so 1920x1080 keeps the same apparent size as on 1024x600.
EYE_SCALE = float(os.environ.get("EYE_SCALE", "1.25"))
# Design scanout the EYE_* knobs were tuned against (panel preferred mode).
EYE_REF_W = int(os.environ.get("EYE_REF_W", "1024"))
EYE_REF_H = int(os.environ.get("EYE_REF_H", "600"))
# Mild plate aspect (>1 → eyeballs slightly elliptical, wider than tall).
EYE_GAP_X = float(os.environ.get("EYE_GAP_X", "1.28"))
# Center-to-center IPD multiplier vs packed plate (1.0 = packed; ~1.4 mild widen).
EYE_SEP = float(os.environ.get("EYE_SEP", "1.4"))
# Keep a small margin inside the scanout so both eyes stay on-screen.
EYE_FIT = float(os.environ.get("EYE_FIT", "0.96"))
# Soft glow (baked once at quarter-res). Keep modest — live glow/clear caused flicker.
EYE_GLOW_R = int(os.environ.get("EYE_GLOW_R", "4"))
EYE_GLOW = float(os.environ.get("EYE_GLOW", "0.55"))
# Optional extra nudge after pair-midline centering (pixels on screen).
EYE_OFF_X = int(os.environ.get("EYE_OFF_X", "0"))
EYE_OFF_Y = int(os.environ.get("EYE_OFF_Y", "0"))
# Cap ~12–15 Hz: smoother than ~10, avoids fast strobe/flicker on live fb.
EMOTION_FPS = float(os.environ.get("EMOTION_FPS", "12"))
# Optional floor for clip playback fps (0 = use meta.json as-is). Cap to render fps.
EMOTION_ANIM_FPS = float(os.environ.get("EMOTION_ANIM_FPS", "12"))
# Max dt per tick — keep near 2 frames so bake hitch does not skip/flash many frames.
EMOTION_DT_CAP = float(os.environ.get("EMOTION_DT_CAP", "0.18"))
# Poll emotion API every N frames (localhost is cheap; still avoid per-frame urllib).
EMOTION_POLL_EVERY = max(1, int(os.environ.get("EMOTION_POLL_EVERY", "3")))
# Livelier idle (blink / pupil drift / breath). Only when API state=idle & no variant.
IDLE_LIVELY = os.environ.get("IDLE_LIVELY", "1") != "0"
IDLE_BLINK_MIN_S = float(os.environ.get("IDLE_BLINK_MIN_S", "2.8"))
IDLE_BLINK_MAX_S = float(os.environ.get("IDLE_BLINK_MAX_S", "6.5"))
IDLE_DRIFT_PX = float(os.environ.get("IDLE_DRIFT_PX", "5"))
IDLE_DRIFT_PERIOD_S = float(os.environ.get("IDLE_DRIFT_PERIOD_S", "8.0"))
IDLE_BREATH_AMP = float(os.environ.get("IDLE_BREATH_AMP", "0.016"))
IDLE_BREATH_PERIOD_S = float(os.environ.get("IDLE_BREATH_PERIOD_S", "3.6"))
# Occasional look-around while idle (look_around pack = look-left/right).
IDLE_LOOK_MIN_S = float(os.environ.get("IDLE_LOOK_MIN_S", "9.0"))
IDLE_LOOK_MAX_S = float(os.environ.get("IDLE_LOOK_MAX_S", "18.0"))
# Cap looping look_around so it returns to idle (pack meta often loop=true).
IDLE_LOOK_HOLD_S = float(os.environ.get("IDLE_LOOK_HOLD_S", "2.8"))
# Keep bake RAM bounded after EYE_SCALE remap (1080p patches are huge).
# Resident packs only (look_around is lazy + dropped after glance — 150 frames @ remap OOMs).
BAKE_KEEP = frozenset(
    x.strip()
    for x in os.environ.get("EMOTION_BAKE_KEEP", "idle,blink").split(",")
    if x.strip()
)

ALIASES = {
    "look-left": "look_around",
    "look_left": "look_around",
    "look-right": "look_around",
    "look_right": "look_around",
    "look-up": "look_around",
    "lookaround": "look_around",
}

FBIOGET_VSCREENINFO = 0x4600


def fb_buffer_geometry(dev: str) -> tuple[int, int, int, int, int, int]:
    """Return (xres, yres, buf_w, buf_h, xoff, yoff) from fb ioctl."""
    fd = os.open(dev, os.O_RDWR)
    try:
        buf = array.array("B", [0] * 256)
        fcntl.ioctl(fd, FBIOGET_VSCREENINFO, buf, True)
        xres, yres, xres_v, yres_v, xoff, yoff = struct.unpack_from("<6I", buf, 0)
    finally:
        os.close(fd)

    if xres_v <= 0 or yres_v <= 0:
        vs = open("/sys/class/graphics/fb0/virtual_size").read().strip()
        xres_v, yres_v = [int(x) for x in vs.split(",")]
    if xres <= 0 or yres <= 0:
        xres, yres = xres_v, yres_v
    return xres, yres, xres_v, yres_v, xoff, yoff


def _parse_mode(s: str) -> tuple[int, int] | None:
    s = (s or "").strip().split()[0] if s else ""
    if "x" not in s:
        return None
    a, b = s.split("x", 1)
    try:
        return int(a), int(b.split("@")[0].rstrip("ip"))
    except ValueError:
        return None


def _active_hdmi_from_drm_state(buf_w: int, buf_h: int) -> tuple[int, int] | None:
    """Read live HDMI CRTC mode from debugfs (preferred modes[0] is often stale)."""
    crtc_of_hdmi: str | None = None
    mode_by_crtc: dict[str, tuple[int, int]] = {}
    plane_src_by_crtc: dict[str, tuple[int, int]] = {}
    for path in sorted(glob.glob("/sys/kernel/debug/dri/*/state")):
        try:
            text = open(path).read()
        except OSError:
            continue
        for m in re.finditer(
            r"connector\[\d+\]:\s*(HDMI[^\n]*)\n(?:\t.*\n)*?\tcrtc=([^\n]+)",
            text,
        ):
            crtc = (m.group(2) or "").strip()
            if crtc and crtc != "(null)":
                crtc_of_hdmi = crtc
        for m in re.finditer(
            r"crtc\[\d+\]:\s*([^\n]+)\n(?:\t.*\n)*?\tmode:\s*\"(\d+x\d+)\"",
            text,
        ):
            name = (m.group(1) or "").strip()
            parsed = _parse_mode(m.group(2))
            if name and parsed:
                mode_by_crtc[name] = parsed
        # Plane src-pos = region of fb actually scanned for that CRTC.
        for m in re.finditer(
            r"plane\[\d+\]:[^\n]*\n\tcrtc=([^\n]+)\n(?:\t.*\n)*?\tsrc-pos="
            r"(\d+(?:\.\d+)?)x(\d+(?:\.\d+)?)",
            text,
        ):
            cname = (m.group(1) or "").strip()
            if not cname or cname == "(null)":
                continue
            try:
                sw, sh = int(float(m.group(2))), int(float(m.group(3)))
            except ValueError:
                continue
            if sw > 0 and sh > 0:
                plane_src_by_crtc[cname] = (sw, sh)
    if not crtc_of_hdmi:
        return None
    for src in (plane_src_by_crtc.get(crtc_of_hdmi), mode_by_crtc.get(crtc_of_hdmi)):
        if src:
            w, h = src
            return min(w, buf_w), min(h, buf_h)
    return None


def hdmi_scanout_size(buf_w: int, buf_h: int) -> tuple[int, int]:
    """Active HDMI CRTC / plane src, else env, else preferred mode, else buf."""
    env_w = os.environ.get("FB_VIEW_W") or os.environ.get("HDMI_VIEW_W")
    env_h = os.environ.get("FB_VIEW_H") or os.environ.get("HDMI_VIEW_H")
    if env_w and env_h:
        return max(1, int(env_w)), max(1, int(env_h))

    active = _active_hdmi_from_drm_state(buf_w, buf_h)
    if active:
        return active

    drm = "/sys/class/drm"
    if os.path.isdir(drm):
        for name in sorted(os.listdir(drm)):
            if "HDMI" not in name.upper():
                continue
            base = os.path.join(drm, name)
            try:
                if open(os.path.join(base, "status")).read().strip() != "connected":
                    continue
            except OSError:
                continue
            try:
                modes = open(os.path.join(base, "modes")).read().splitlines()
            except OSError:
                continue
            if modes:
                parsed = _parse_mode(modes[0])
                if parsed:
                    w, h = parsed
                    return min(w, buf_w), min(h, buf_h)
    return buf_w, min(buf_h, 720)


def clear_fb_black(view, buf_w: int, buf_h: int, vw: int, vh: int, np) -> None:
    """Paint opaque black over the visible scanout (and pad to buf width rows)."""
    black4 = np.array([0, 0, 0, 255], dtype=np.uint8)
    # Full stride rows for active height — avoids snow in the unused right strip
    # when CRTC is wider than a stale preferred mode (e.g. 1920 vs 1024).
    hh = max(1, min(vh, buf_h))
    ww = max(1, min(max(vw, buf_w), buf_w))
    view[:hh, :ww] = black4


def ref_mapped_scale(
    vw: int,
    vh: int,
    req_scale: float,
    ref_w: int = EYE_REF_W,
    ref_h: int = EYE_REF_H,
) -> float:
    """Map EYE_SCALE tuned at ref WxH onto the active scanout (uniform zoom).

    Keeps apparent eye size vs screen the same when CRTC is 1920x1080 (or
    1440x900) instead of the design 1024x600 the knobs were tuned for.
    """
    if vw <= 0 or vh <= 0 or ref_w <= 0 or ref_h <= 0:
        return req_scale
    return req_scale * min(vw / float(ref_w), vh / float(ref_h))


def fit_scale(
    vw: int,
    vh: int,
    plate: int,
    scale: float,
    gap_x: float,
    fit: float,
    ipd_plate: float = 0.0,
    sep: float = 1.0,
) -> float:
    """Clamp scale so scaled plate + IPD sep gap fits inside the scanout."""
    if vw <= 0 or vh <= 0 or plate <= 0:
        return scale
    max_w = max(1.0, vw * fit)
    max_h = max(1.0, vh * fit)
    # Extra width from moving eyes apart: (sep-1)*ipd in plate-x after gap_x.
    extra = max(0.0, (max(sep, 1.0) - 1.0) * max(ipd_plate, 0.0))
    plate_w = plate * max(gap_x, 0.01) + extra * max(gap_x, 0.01)
    sx = max_w / max(plate_w, 1.0)
    sy = max_h / plate
    return max(0.05, min(scale, sx, sy))


def measure_pair_eyes(frame, np) -> tuple[float, float, float, float, float]:
    """Return (mid_x, mid_y, lcx, rcx, ipd) in plate px."""
    w, h, data = frame
    rgba = np.frombuffer(data, dtype=np.uint8).reshape(h, w, 4)
    lum = rgba[..., :3].max(axis=2)
    m = (rgba[..., 3] >= 32) & (lum >= 40)
    ys, xs = np.where(m)
    if len(xs) < 16:
        return w / 2.0, h / 2.0, w * 0.35, w * 0.65, w * 0.3
    x0, x1 = int(xs.min()), int(xs.max())
    split = (x0 + x1) // 2
    left = xs <= split
    right = xs > split
    if not np.any(left) or not np.any(right):
        cx, cy = float(xs.mean()), float(ys.mean())
        return cx, cy, cx - 40.0, cx + 40.0, 80.0
    lcx, lcy = float(xs[left].mean()), float(ys[left].mean())
    rcx, rcy = float(xs[right].mean()), float(ys[right].mean())
    return (lcx + rcx) / 2.0, (lcy + rcy) / 2.0, lcx, rcx, max(1.0, rcx - lcx)


def measure_pair_mid(frame, np) -> tuple[float, float]:
    """Return (cx, cy) of the symmetry point between left/right eye in plate px."""
    mx, my, _, _, _ = measure_pair_eyes(frame, np)
    return mx, my


def measure_pair_mid_avg(frames, np, samples: int = 12) -> tuple[float, float, float]:
    """Average pair midline + IPD over several frames."""
    if not frames:
        return 240.0, 240.0, 120.0
    n = min(samples, len(frames))
    step = max(1, len(frames) // n)
    xs, ys, ipds = [], [], []
    for i in range(0, len(frames), step):
        cx, cy, _, _, ipd = measure_pair_eyes(frames[i], np)
        xs.append(cx)
        ys.append(cy)
        ipds.append(ipd)
        if len(xs) >= n:
            break
    return (
        float(sum(xs) / len(xs)),
        float(sum(ys) / len(ys)),
        float(sum(ipds) / len(ipds)),
    )


def get_emotion():
    state, variant = "idle", ""
    try:
        with urllib.request.urlopen(API, timeout=0.05) as r:
            j = json.loads(r.read().decode())
            return (j.get("state") or state), (j.get("variant") or variant)
    except Exception:
        pass
    if os.path.isfile(STATE_FILE):
        try:
            j = json.loads(open(STATE_FILE).read())
            return j.get("state", state), j.get("variant", variant)
        except Exception:
            pass
    return state, variant


def resolve_anim(state: str, variant: str) -> str:
    s = (state or "idle").strip().lower().replace("-", "_")
    s = ALIASES.get(s, s)
    v = (variant or "").strip().lower().replace("-", "_")
    if s == "idle" and v:
        v = ALIASES.get(v, v)
        if os.path.isdir(os.path.join(PACK_ROOT, v)):
            return v
    if os.path.isdir(os.path.join(PACK_ROOT, s)):
        return s
    return "idle"


class AnimPack:
    def __init__(self, root: str, name: str):
        meta = json.loads(open(os.path.join(root, name, "meta.json")).read())
        self.name = name
        self.fps = float(meta.get("fps") or 30)
        # Cap clip fps to EMOTION_ANIM_FPS when set (smooth 12–15, not pack's 30).
        if EMOTION_ANIM_FPS > 0:
            self.fps = min(self.fps, EMOTION_ANIM_FPS)
        self.loop = bool(meta.get("loop", True))
        self.frames: list[tuple[int, int, bytes]] = []
        for e in meta["frames"]:
            path = os.path.join(root, name, e["file"])
            self.frames.append((int(e["w"]), int(e["h"]), open(path, "rb").read()))
        if not self.frames:
            raise RuntimeError(f"empty anim {name}")

    def __len__(self):
        return len(self.frames)


class Player:
    def __init__(self, root: str):
        self.root = root
        self.cache: dict[str, AnimPack] = {}
        self.cur: AnimPack | None = None
        self.idx = 0
        self.accum = 0.0
        self.done_once = False

    def load(self, name: str) -> AnimPack:
        if name not in self.cache:
            self.cache[name] = AnimPack(self.root, name)
            print(f"loaded {name} frames={len(self.cache[name])}", flush=True)
        return self.cache[name]

    def play(self, name: str, restart: bool = True):
        pack = self.load(name)
        if self.cur is pack and not restart:
            return
        self.cur = pack
        self.idx = 0
        self.accum = 0.0
        self.done_once = False
        print(
            f"play {name} frames={len(pack)} fps={pack.fps} loop={pack.loop}",
            flush=True,
        )

    def tick(self, dt: float):
        if not self.cur:
            return None
        self.accum += dt
        step = 1.0 / max(1.0, self.cur.fps)
        while self.accum >= step:
            self.accum -= step
            self.idx += 1
            if self.idx >= len(self.cur):
                if self.cur.loop:
                    self.idx = 0
                else:
                    self.idx = len(self.cur) - 1
                    self.done_once = True
        return self.idx


def _box_blur(ch, radius: int, np):
    """Fast separable box blur via cumulative sums (same HxW out)."""
    if radius <= 0:
        return ch
    k = 2 * radius + 1
    inv = 1.0 / float(k)
    pad = np.pad(ch, ((0, 0), (radius, radius)), mode="edge")
    c = np.cumsum(pad, axis=1, dtype=np.float32)
    z = np.zeros((ch.shape[0], 1), dtype=np.float32)
    c = np.concatenate([z, c], axis=1)
    h = (c[:, k:] - c[:, :-k]) * inv
    pad = np.pad(h, ((radius, radius), (0, 0)), mode="edge")
    c = np.cumsum(pad, axis=0, dtype=np.float32)
    z = np.zeros((1, h.shape[1]), dtype=np.float32)
    c = np.concatenate([z, c], axis=0)
    return (c[k:, :] - c[:-k, :]) * inv


# Nearest-neighbor index cache: (src_w, src_h, tw, th) → (ys, xs)
_SCALE_IDX: dict[tuple[int, int, int, int], tuple] = {}


def bake_frame(
    frame,
    np,
    scale: float,
    gap_x: float,
    glow_r: int,
    glow: float,
    pair_mx: float,
    ipd_plate: float,
    sep: float,
):
    """Scale + IPD sep (split halves) + glow → opaque-on-black RGBA patch.

    Eyes keep their glyph size; sep>1 inserts black between left/right halves so
    center-to-center distance grows (pair midline stays mid-canvas).
    """
    w, h, data = frame
    tw = max(1, int(round(w * scale * gap_x)))
    th = max(1, int(round(h * scale)))
    src = np.frombuffer(data, dtype=np.uint8).reshape(h, w, 4)

    key = (w, h, tw, th)
    cached = _SCALE_IDX.get(key)
    if cached is None:
        ys = np.clip((np.arange(th) * h / th).astype(np.int32), 0, h - 1)
        xs = np.clip((np.arange(tw) * w / tw).astype(np.int32), 0, w - 1)
        _SCALE_IDX[key] = (ys, xs)
        cached = (ys, xs)
    ys, xs = cached
    scaled = src[ys][:, xs]

    # Insert horizontal gap between left/right eye halves (true IPD, no eye stretch).
    sep = max(1.0, float(sep))
    extra = int(round(max(0.0, (sep - 1.0) * ipd_plate * scale * gap_x)))
    split = int(round(pair_mx * scale * gap_x))
    split = max(1, min(tw - 1, split))
    if extra > 0:
        wide = np.zeros((th, tw + extra, 4), dtype=np.uint8)
        wide[:, :split] = scaled[:, :split]
        wide[:, split + extra :] = scaled[:, split:]
        scaled = wide
        tw = tw + extra

    pad = max(0, int(glow_r)) if glow > 0 else 0
    if pad:
        canvas = np.zeros((th + 2 * pad, tw + 2 * pad, 4), dtype=np.uint8)
        canvas[pad : pad + th, pad : pad + tw] = scaled
        rgba = canvas
    else:
        rgba = scaled

    out = np.zeros_like(rgba)
    # Soft glow at quarter-res (full-res blur was the ~1–2fps bottleneck).
    if glow > 0 and glow_r > 0:
        a_f = rgba[..., 3].astype(np.float32) * (1.0 / 255.0)
        prem = rgba[..., :3].astype(np.float32) * a_f[..., None]
        step = 4
        sh, sw = prem.shape[0], prem.shape[1]
        small = prem[::step, ::step]
        sa = a_f[::step, ::step]
        r = max(1, (glow_r + step - 1) // step)
        g_rgb = np.empty_like(small)
        for c in range(3):
            g_rgb[..., c] = _box_blur(small[..., c], r, np)
        ga = _box_blur(sa, r, np)
        up = np.repeat(np.repeat(g_rgb, step, axis=0), step, axis=1)[:sh, :sw]
        ua = np.repeat(np.repeat(ga, step, axis=0), step, axis=1)[:sh, :sw]
        glow_rgb = np.clip(up * glow, 0, 255).astype(np.uint8)
        gm = ua * glow > 0.02
        out[..., 0][gm] = glow_rgb[..., 0][gm]
        out[..., 1][gm] = glow_rgb[..., 1][gm]
        out[..., 2][gm] = glow_rgb[..., 2][gm]
        out[..., 3][gm] = 255

    a = rgba[..., 3:4].astype(np.uint16)
    rgb = (rgba[..., :3].astype(np.uint16) * a // 255).astype(np.uint8)
    m = rgba[..., 3] >= 8
    out[..., 0][m] = rgb[..., 0][m]
    out[..., 1][m] = rgb[..., 1][m]
    out[..., 2][m] = rgb[..., 2][m]
    out[..., 3][m] = 255
    return out


class BakeCache:
    """Lazy baked patches keyed by anim name (keep idle+blink+look resident)."""

    def __init__(self, np, scale, gap_x, glow_r, glow, pair_mx, ipd_plate, sep):
        self.np = np
        self.scale = scale
        self.gap_x = gap_x
        self.glow_r = glow_r
        self.glow = glow
        self.pair_mx = pair_mx
        self.ipd_plate = ipd_plate
        self.sep = sep
        # name -> (patches list, ready flags)
        self._by_name: dict[str, tuple[list, list]] = {}

    def ensure(self, pack: AnimPack):
        if pack.name in self._by_name:
            return
        n = len(pack)
        self._by_name[pack.name] = ([None] * n, [False] * n)
        print(f"bake_cache alloc {pack.name} frames={n}", flush=True)

    def release_except(self, keep: set[str]):
        """Drop non-kept packs so remapped 1080p patches do not OOM the board."""
        drop = [n for n in self._by_name if n not in keep]
        for n in drop:
            del self._by_name[n]
            print(f"bake_cache drop {n}", flush=True)

    def get(self, pack: AnimPack, idx: int):
        self.ensure(pack)
        patches, ready = self._by_name[pack.name]
        if not ready[idx]:
            patches[idx] = bake_frame(
                pack.frames[idx],
                self.np,
                self.scale,
                self.gap_x,
                self.glow_r,
                self.glow,
                self.pair_mx,
                self.ipd_plate,
                self.sep,
            )
            ready[idx] = True
        return patches[idx]


def blit_baked(
    view,
    buf_w,
    buf_h,
    vw,
    vh,
    xoff,
    yoff,
    patch,
    pair_mx: float,
    pair_my: float,
    scale: float,
    gap_x: float,
    off_x: int,
    off_y: int,
    glow_r: int,
    glow: float,
    sep_extra_px: float,
    np,
):
    """Copy baked patch so pair midline lands on scanout center."""
    th_d, tw_d = patch.shape[0], patch.shape[1]
    pad = max(0, int(glow_r)) if glow > 0 else 0
    # Midline shifts by half the inserted sep gap (symmetric left/right move).
    pair_sx = pair_mx * scale * gap_x + sep_extra_px * 0.5 + pad
    pair_sy = pair_my * scale + pad
    x0 = int(round(xoff + vw / 2.0 - pair_sx + off_x))
    y0 = int(round(yoff + vh / 2.0 - pair_sy + off_y))

    vis_x1 = xoff + vw
    vis_y1 = yoff + vh
    sx0 = max(0, -x0)
    sy0 = max(0, -y0)
    dx0 = max(xoff, x0)
    dy0 = max(yoff, y0)
    ww = min(tw_d - sx0, vis_x1 - dx0, buf_w - dx0)
    hh = min(th_d - sy0, vis_y1 - dy0, buf_h - dy0)
    if ww <= 0 or hh <= 0:
        return dx0, dy0, 0, 0
    view[dy0 : dy0 + hh, dx0 : dx0 + ww] = patch[sy0 : sy0 + hh, sx0 : sx0 + ww]
    return dx0, dy0, ww, hh


def breath_rescale(patch, factor: float, np):
    """Gentle breath: NN-scale about center, always return same HxW (pad or crop)."""
    if abs(factor - 1.0) < 0.003:
        return patch
    th, tw = patch.shape[0], patch.shape[1]
    nth = max(1, int(round(th * factor)))
    ntw = max(1, int(round(tw * factor)))
    ys = np.clip((np.arange(nth) * th / nth).astype(np.int32), 0, th - 1)
    xs = np.clip((np.arange(ntw) * tw / ntw).astype(np.int32), 0, tw - 1)
    scaled = patch[ys][:, xs]
    if nth == th and ntw == tw:
        return scaled
    out = np.zeros_like(patch)
    # Center-paste (shrink) or center-crop (expand) into fixed canvas.
    src_y0 = max(0, (nth - th) // 2)
    src_x0 = max(0, (ntw - tw) // 2)
    dst_y0 = max(0, (th - nth) // 2)
    dst_x0 = max(0, (tw - ntw) // 2)
    copy_h = min(th - dst_y0, nth - src_y0)
    copy_w = min(tw - dst_x0, ntw - src_x0)
    if copy_h > 0 and copy_w > 0:
        out[dst_y0 : dst_y0 + copy_h, dst_x0 : dst_x0 + copy_w] = scaled[
            src_y0 : src_y0 + copy_h, src_x0 : src_x0 + copy_w
        ]
    return out


class IdleLively:
    """Blink + look-around + subtle gaze drift + breath while API idle."""

    def __init__(self):
        self.enabled = IDLE_LIVELY
        self.blinking = False
        self.looking = False
        self.look_until = 0.0
        self.t0 = time.perf_counter()
        self.next_blink_at = self.t0 + random.uniform(IDLE_BLINK_MIN_S, IDLE_BLINK_MAX_S)
        self.next_look_at = self.t0 + random.uniform(IDLE_LOOK_MIN_S, IDLE_LOOK_MAX_S)
        # Slow phase offsets so X/Y drift are not locked
        self.ph_x = random.uniform(0, 2 * math.pi)
        self.ph_y = random.uniform(0, 2 * math.pi)
        self.ph_b = random.uniform(0, 2 * math.pi)

    def schedule_blink(self, now: float):
        lo = min(IDLE_BLINK_MIN_S, IDLE_BLINK_MAX_S)
        hi = max(IDLE_BLINK_MIN_S, IDLE_BLINK_MAX_S)
        self.next_blink_at = now + random.uniform(lo, hi)

    def schedule_look(self, now: float):
        lo = min(IDLE_LOOK_MIN_S, IDLE_LOOK_MAX_S)
        hi = max(IDLE_LOOK_MIN_S, IDLE_LOOK_MAX_S)
        self.next_look_at = now + random.uniform(lo, hi)

    def reset_local(self):
        self.blinking = False
        self.looking = False
        self.look_until = 0.0

    def motion(self, now: float) -> tuple[float, float, float]:
        """Return (drift_x, drift_y, breath_factor)."""
        if not self.enabled:
            return 0.0, 0.0, 1.0
        # Drift/breath only on base idle (not during blink/look clips).
        if self.blinking or self.looking:
            return 0.0, 0.0, 1.0
        t = now - self.t0
        twopi = 2 * math.pi
        per = max(0.5, IDLE_DRIFT_PERIOD_S)
        dx = IDLE_DRIFT_PX * math.sin(t * twopi / per + self.ph_x)
        dy = IDLE_DRIFT_PX * 0.65 * math.sin(t * twopi / (per * 1.37) + self.ph_y)
        bper = max(0.5, IDLE_BREATH_PERIOD_S)
        breath = 1.0 + IDLE_BREATH_AMP * math.sin(t * twopi / bper + self.ph_b)
        return dx, dy, breath

    def tick(self, now: float, state: str, variant: str, player: Player) -> bool:
        """Drive local blink / look-around. True if lively owns clip selection."""
        if not self.enabled:
            return False
        if (state or "idle").lower() != "idle" or (variant or "").strip():
            self.reset_local()
            return False
        if self.looking:
            done = False
            if player.cur and player.cur.name == "look_around":
                if (not player.cur.loop) and player.done_once:
                    done = True
                elif player.cur.loop and now >= self.look_until:
                    done = True
            else:
                done = True
            if done:
                player.play("idle", restart=False)
                self.looking = False
                self.schedule_look(now)
                self.schedule_blink(now)
            return True
        if self.blinking:
            if player.cur and player.cur.name == "blink" and player.done_once:
                player.play("idle", restart=False)
                self.blinking = False
                self.schedule_blink(now)
            return True
        # Prefer look over blink when both due (look is rarer).
        if now >= self.next_look_at:
            try:
                player.play("look_around", restart=True)
                self.looking = True
                self.look_until = now + max(0.6, IDLE_LOOK_HOLD_S)
                return True
            except Exception as e:
                print(f"emotion_fb look skip: {e}", flush=True)
                self.schedule_look(now)
        if now >= self.next_blink_at:
            try:
                player.play("blink", restart=True)
                self.blinking = True
                return True
            except Exception as e:
                print(f"emotion_fb blink skip: {e}", flush=True)
                self.schedule_blink(now)
        return False


def main():
    import numpy as np

    if not os.path.isdir(PACK_ROOT):
        raise SystemExit(f"pack missing: {PACK_ROOT}")

    available = sorted(
        d
        for d in os.listdir(PACK_ROOT)
        if os.path.isdir(os.path.join(PACK_ROOT, d))
        and os.path.isfile(os.path.join(PACK_ROOT, d, "meta.json"))
    )
    print(f"emotion_fb pack clips ({len(available)}): {available}", flush=True)

    if os.environ.get("EMOTION_STOP_WESTON", "1") == "1":
        os.system("killall weston 2>/dev/null || true")
        time.sleep(0.5)

    settle_s = float(os.environ.get("EMOTION_DRM_SETTLE_S", "0.8"))
    bpp = int(open("/sys/class/graphics/fb0/bits_per_pixel").read().strip())
    if bpp != 32:
        raise SystemExit(f"need 32bpp fb, got {bpp}")

    xres, yres, buf_w, buf_h, xoff, yoff = fb_buffer_geometry(FB_DEV)
    vw, vh = hdmi_scanout_size(buf_w, buf_h)
    xoff, yoff = 0, 0

    fd = os.open(FB_DEV, os.O_RDWR)
    fb_bytes = buf_w * buf_h * 4
    try:
        fb_mm = mmap.mmap(fd, fb_bytes, mmap.MAP_SHARED, mmap.PROT_WRITE | mmap.PROT_READ)
        use_mmap = True
        screen_buf = fb_mm
    except OSError as e:
        print(f"emotion_fb mmap failed ({e}); using write path", flush=True)
        fb_mm = None
        screen_buf = bytearray(fb_bytes)
        use_mmap = False

    view0 = np.frombuffer(screen_buf, dtype=np.uint8).reshape(buf_h, buf_w, 4)
    black4 = np.array([0, 0, 0, 255], dtype=np.uint8)
    # Kill post-Weston snow immediately — before bake (can take tens of seconds).
    clear_fb_black(view0, buf_w, buf_h, vw, vh, np)
    if not use_mmap:
        os.lseek(fd, 0, os.SEEK_SET)
        os.write(fd, memoryview(screen_buf)[: buf_w * min(vh, buf_h) * 4])
    print(
        f"emotion_fb cleared black scanout~={vw}x{vh} virtual={buf_w}x{buf_h} "
        f"fb_xres={xres}x{yres}; settle {settle_s:.2f}s",
        flush=True,
    )
    if settle_s > 0:
        time.sleep(settle_s)
    # Re-probe after DRM/fbdev settle (mode may flip after Weston exit).
    xres, yres, buf_w2, buf_h2, _, _ = fb_buffer_geometry(FB_DEV)
    if (buf_w2, buf_h2) != (buf_w, buf_h):
        print(
            f"emotion_fb warn: virtual size changed {buf_w}x{buf_h} -> "
            f"{buf_w2}x{buf_h2}; keeping initial mmap",
            flush=True,
        )
    vw, vh = hdmi_scanout_size(buf_w, buf_h)
    clear_fb_black(view0, buf_w, buf_h, vw, vh, np)
    if not use_mmap:
        os.lseek(fd, 0, os.SEEK_SET)
        os.write(fd, memoryview(screen_buf)[: buf_w * min(vh, buf_h) * 4])

    plate = 480
    player = Player(PACK_ROOT)
    idle = player.load("idle")
    pair_mx, pair_my, ipd_plate = measure_pair_mid_avg(idle.frames, np)
    # EYE_SCALE tuned at EYE_REF_* (1024x600); remap so active CRTC keeps
    # the same apparent size (1080p must not look ~half as tall as 600p).
    req_scale = ref_mapped_scale(vw, vh, EYE_SCALE, EYE_REF_W, EYE_REF_H)
    scale = fit_scale(
        vw, vh, plate, req_scale, EYE_GAP_X, EYE_FIT, ipd_plate=ipd_plate, sep=EYE_SEP
    )
    sep_extra = max(0.0, (max(EYE_SEP, 1.0) - 1.0) * ipd_plate * scale * EYE_GAP_X)
    tw = int(round(plate * scale * EYE_GAP_X + sep_extra))
    th = int(round(plate * scale))
    pad = max(0, EYE_GLOW_R) if EYE_GLOW > 0 else 0
    x0 = int(
        round(
            xoff
            + vw / 2.0
            - pair_mx * scale * EYE_GAP_X
            - sep_extra * 0.5
            - pad
            + EYE_OFF_X
        )
    )
    y0 = int(round(yoff + vh / 2.0 - pair_my * scale - pad + EYE_OFF_Y))
    pair_sx = x0 + pair_mx * scale * EYE_GAP_X + sep_extra * 0.5 + pad
    pair_sy = y0 + pair_my * scale + pad

    vis_bytes = buf_w * min(vh, buf_h) * 4
    # Offscreen scanout: compose fully, then one copy to live fb (no clear→draw flicker).
    off = np.empty((vh, vw, 4), dtype=np.uint8)
    off[:] = black4

    baker = BakeCache(
        np, scale, EYE_GAP_X, EYE_GLOW_R, EYE_GLOW, pair_mx, ipd_plate, EYE_SEP
    )
    lively = IdleLively()
    player.play("idle")

    def present_patch(patch) -> None:
        off[:] = black4
        blit_baked(
            off,
            vw,
            vh,
            vw,
            vh,
            0,
            0,
            patch,
            pair_mx,
            pair_my,
            scale,
            EYE_GAP_X,
            EYE_OFF_X,
            EYE_OFF_Y,
            EYE_GLOW_R,
            EYE_GLOW,
            sep_extra,
            np,
        )
        # Full-width black rows already cleared; copy composed scanout.
        view0[:vh, :vw] = off
        if not use_mmap:
            os.lseek(fd, 0, os.SEEK_SET)
            os.write(fd, memoryview(screen_buf)[:vis_bytes])

    # Present idle frame 0 ASAP so eyes appear without waiting for full warm / chat.
    baker.ensure(idle)
    t_warm = time.perf_counter()
    patch0 = baker.get(idle, 0)
    present_patch(patch0)
    print(
        f"emotion_fb first present idle[0] scanout={vw}x{vh} "
        f"pair_screen=({pair_sx:.1f},{pair_sy:.1f}) want=({vw/2:.1f},{vh/2:.1f})",
        flush=True,
    )

    warm_n = len(idle)
    for i in range(1, warm_n):
        baker.get(idle, i)
    blink_n = 0
    look_n = 0
    if IDLE_LIVELY:
        try:
            blink = player.load("blink")
            for i in range(len(blink)):
                baker.get(blink, i)
            blink_n = len(blink)
        except Exception as e:
            print(f"emotion_fb blink warm skip: {e}", flush=True)
        # Do not pre-bake all look_around frames (often 100+ @ remapped size → OOM).
        # Alloc cache + bake frame 0 so first glance starts without hitch.
        try:
            look = player.load("look_around")
            baker.ensure(look)
            baker.get(look, 0)
            look_n = len(look)
        except Exception as e:
            print(f"emotion_fb look warm skip: {e}", flush=True)
    print(
        f"emotion_fb warmed idle={warm_n} blink={blink_n} look_around={look_n} "
        f"in {time.perf_counter() - t_warm:.2f}s",
        flush=True,
    )

    print(
        f"emotion_fb v1.1.0-all scanout={vw}x{vh}+{xoff}+{yoff} "
        f"fb_xres={xres}x{yres} virtual={buf_w}x{buf_h} "
        f"scale={scale:.3f} (knob {EYE_SCALE} ref={EYE_REF_W}x{EYE_REF_H} "
        f"mapped {req_scale:.3f}) gap_x={EYE_GAP_X} "
        f"sep={EYE_SEP} ipd_plate={ipd_plate:.1f} sep_extra={sep_extra:.0f}px "
        f"glow_r={EYE_GLOW_R} glow={EYE_GLOW} "
        f"lively={int(IDLE_LIVELY)} drift={IDLE_DRIFT_PX}px breath={IDLE_BREATH_AMP} "
        f"pair_plate=({pair_mx:.1f},{pair_my:.1f}) "
        f"pair_screen=({pair_sx:.1f},{pair_sy:.1f}) want=({vw/2:.1f},{vh/2:.1f}) "
        f"draw={tw}x{th}@{x0},{y0} off={EYE_OFF_X},{EYE_OFF_Y} "
        f"mmap={int(use_mmap)} bake=1 pack={PACK_ROOT} api={API}",
        flush=True,
    )
    if scale + 1e-6 < req_scale:
        print(
            f"emotion_fb scale clamped {req_scale:.3f} -> {scale:.3f} to fit scanout",
            flush=True,
        )

    last_key = None
    state, variant = "idle", ""
    last = time.perf_counter()
    fps_target = max(1.0, EMOTION_FPS)
    target_dt = 1.0 / fps_target
    dt_cap = max(target_dt * 2.0, EMOTION_DT_CAP)
    print(
        f"emotion_fb fps_target={fps_target:.1f} dt_cap={dt_cap:.3f}s "
        f"anim_fps_cap={EMOTION_ANIM_FPS or 'meta'} poll_every={EMOTION_POLL_EVERY}",
        flush=True,
    )
    fps_win_t = time.perf_counter()
    fps_win_n = 0
    frame_i = 0
    try:
        while True:
            now = time.perf_counter()
            dt = min(dt_cap, now - last)
            last = now
            fps_win_n += 1
            if now - fps_win_t >= 2.0:
                print(f"emotion_fb measured_fps={fps_win_n / (now - fps_win_t):.1f}", flush=True)
                fps_win_t = now
                fps_win_n = 0

            if frame_i % EMOTION_POLL_EVERY == 0:
                state, variant = get_emotion()
            frame_i += 1
            key = (state, variant or "")
            if key != last_key:
                last_key = key
                anim = resolve_anim(state, variant or "")
                # Evict specials' remapped patches; keep idle/blink/look (+ current).
                keep = set(BAKE_KEEP)
                keep.add(anim)
                baker.release_except(keep)
                player.play(anim, restart=True)
                lively.reset_local()
                if anim == "idle":
                    lively.schedule_blink(now)
                    lively.schedule_look(now)

            local_lively = lively.tick(now, state, variant or "", player)

            if (
                not local_lively
                and player.cur
                and (not player.cur.loop)
                and player.done_once
                and resolve_anim(state, variant or "") == player.cur.name
                and player.cur.name not in ("idle", "blink", "look_around")
            ):
                # force: special lock would otherwise ignore idle and freeze last frame
                try:
                    urllib.request.urlopen(
                        urllib.request.Request(
                            API,
                            data=b'{"state":"idle","hold":0.2,"force":true}',
                            headers={"Content-Type": "application/json"},
                            method="POST",
                        ),
                        timeout=0.3,
                    )
                    last_key = ("idle", "")
                    state, variant = "idle", ""
                    baker.release_except(set(BAKE_KEEP) | {"idle"})
                    player.play("idle", restart=True)
                    lively.reset_local()
                    lively.schedule_blink(now)
                    lively.schedule_look(now)
                except Exception:
                    player.play("idle", restart=True)
                    last_key = ("idle", "")
                    state, variant = "idle", ""

            idx = player.tick(dt)
            drift_x, drift_y, breath = 0.0, 0.0, 1.0
            if (state or "idle").lower() == "idle" and not (variant or "").strip():
                drift_x, drift_y, breath = lively.motion(now)
            # Compose offscreen (black + eyes), then single present — never clear live fb.
            off[:] = black4
            if idx is not None and player.cur is not None:
                patch = baker.get(player.cur, idx)
                if abs(breath - 1.0) >= 0.003:
                    patch = breath_rescale(patch, breath, np)
                blit_baked(
                    off,
                    vw,
                    vh,
                    vw,
                    vh,
                    0,
                    0,
                    patch,
                    pair_mx,
                    pair_my,
                    scale,
                    EYE_GAP_X,
                    int(round(EYE_OFF_X + drift_x)),
                    int(round(EYE_OFF_Y + drift_y)),
                    EYE_GLOW_R,
                    EYE_GLOW,
                    sep_extra,
                    np,
                )
            view0[:vh, :vw] = off
            if not use_mmap:
                os.lseek(fd, 0, os.SEEK_SET)
                os.write(fd, memoryview(screen_buf)[:vis_bytes])

            sleep = target_dt - (time.perf_counter() - now)
            if sleep > 0:
                time.sleep(sleep)
    finally:
        try:
            del view0
        except Exception:
            pass
        if fb_mm is not None:
            try:
                fb_mm.close()
            except BufferError:
                pass
        try:
            os.close(fd)
        except OSError:
            pass


if __name__ == "__main__":
    main()
