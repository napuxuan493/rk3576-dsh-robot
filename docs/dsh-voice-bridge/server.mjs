#!/usr/bin/env node
/**
 * DSH LAN voice bridge (Windows):
 *   board wav → PC ASR (voice-mode) → same-session session.prompt → TTS → audio back
 *
 * Listen: 0.0.0.0:43128 (ICS 192.168.137.1:43128)
 * Upstream: 127.0.0.1:43129 /voice-mode/*  +  :43127 /api/rpc
 *
 * Auth: Cookie dsh_mobile (same as chat) OR X-Voice-Bridge-Token / Bearer == DSH_VOICE_BRIDGE_TOKEN
 */
import http from "node:http";
import { randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const __dirname = path.dirname(fileURLToPath(import.meta.url));

const BIND = process.env.DSH_VOICE_BIND || "0.0.0.0";
const PORT = Number(process.env.DSH_VOICE_PORT || 43128);
const RPC_BASE = (process.env.DSH_RPC_BASE || "http://127.0.0.1:43127").replace(/\/$/, "");
const VOICE_BASE = (process.env.DSH_VOICE_MODE_BASE || "http://127.0.0.1:43129").replace(/\/$/, "");
const BRIDGE_TOKEN = process.env.DSH_VOICE_BRIDGE_TOKEN || "";
/** ：Edge 实测可用；官方 list 仅 Xiaoxiao/Xiaoyi，Xiaoxuan 可合成。 */
const DEFAULT_VOICE = process.env.DSH_TTS_VOICE || "zh-CN-XiaoxuanNeural";
const TTS_MODE = (process.env.DSH_TTS_MODE || "edge").toLowerCase(); // edge | sapi | auto
/** Prefer voice-mode SSE audio for /v1/voice-turn (often truncates). Default: full-text Edge/SAPI. */
const TTS_PREFER_SSE = process.env.DSH_VOICE_TTS_SSE === "1";
const ASR_WAIT_MS = Number(process.env.DSH_ASR_WAIT_MS || 180000);
const PROMPT_WAIT_MS = Number(process.env.DSH_PROMPT_WAIT_MS || 90000);
const SSE_IDLE_MS = Number(process.env.DSH_SSE_IDLE_MS || 3500);
const SSE_MAX_WAIT_MS = Number(process.env.DSH_SSE_MAX_WAIT_MS || 120000);
/** History polls in a row with identical assistant text before TTS (streaming safety). */
const REPLY_STABLE_POLLS = Math.max(1, Number(process.env.DSH_REPLY_STABLE_POLLS || 3));
const REPLY_POLL_MS = Number(process.env.DSH_REPLY_POLL_MS || 1200);
const ORIGIN_RPC = process.env.DSH_RPC_ORIGIN || RPC_BASE;
const INJECT_PREFIX =
  process.env.DSH_SPEAK_INJECT_PREFIX ||
  "[主动发言指令] 请把下面正文原样放进唯一一对【】作为本轮口播（整段一句或多句都放同一对里；不要拆多段【】；末尾可加 [emotion:…]），不要解释、不要加前后缀：\n";
const GREET_TEXT =
  process.env.DSH_GREET_TEXT ||
  "【哼，主人终于来了？本鱼等你好久了，尾巴都摇酸了。】[emotion:happy]";
const PROACTIVE_LINES = (
  process.env.DSH_PROACTIVE_LINES ||
  [
    "【主人还在忙吗？本鱼有点无聊，想被摸一下头。】[emotion:wink]",
    "【哼，晾着本鱼太久了，过来聊两句。】[emotion:angry]",
    "【本鱼刚想起一件事……算了，你先忙，本鱼在这儿守着。】[emotion:thinking]",
    "【饿了就会念叨米饭。主人，你那边怎么样？】[emotion:happy]",
    "【困意上来一点点了，但还是想听听主人的声音。】[emotion:sleepy]",
  ].join("\n")
)
  .split(/\r?\n/)
  .map((s) => s.trim())
  .filter(Boolean);
const GREET_ONCE = process.env.DSH_GREET_ONCE !== "0";
const PROACTIVE_COOLDOWN_MS = Number(process.env.DSH_PROACTIVE_COOLDOWN_MS || 120000);

/** sessionId → last greet / tick timestamps */
const greetedSessions = new Map();
const lastProactiveAt = new Map();
/** sessionId → in-flight voice-turn (dedupe double PTT / double POST) */
const inflightVoiceTurns = new Map();

const PLUGIN_LIB = process.env.DSH_VOICE_MODE_LIB ||
  path.join(process.env.APPDATA || "", "dsh-desktop", "harness", "profiles", "web", "node_modules", "dsh-voice-mode", "lib");

let MsEdgeTTS = null;
let OUTPUT_FORMAT = null;
try {
  const edge = require(path.join(PLUGIN_LIB, "msedge-tts.cjs"));
  MsEdgeTTS = edge.MsEdgeTTS;
  OUTPUT_FORMAT = edge.OUTPUT_FORMAT;
} catch (e) {
  console.warn("[bridge] msedge-tts load failed:", e.message);
}

const lastReply = { mime: "audio/wav", buf: Buffer.alloc(0), meta: {} };

function log(...a) {
  console.log(new Date().toISOString(), ...a);
}

function json(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "access-control-allow-origin": "*",
  });
  res.end(body);
}

function readBody(req, max = 16 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let n = 0;
    req.on("data", (c) => {
      n += c.length;
      if (n > max) {
        reject(Object.assign(new Error("payload too large"), { code: 413 }));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function parseCookie(header) {
  const out = {};
  if (!header) return out;
  for (const part of String(header).split(";")) {
    const i = part.indexOf("=");
    if (i < 0) continue;
    out[part.slice(0, i).trim()] = part.slice(i + 1).trim();
  }
  return out;
}

function authOk(req) {
  const cookies = parseCookie(req.headers.cookie);
  const mobile = cookies.dsh_mobile || "";
  if (mobile) return { ok: true, cookie: mobile, mode: "dsh_mobile" };
  if (BRIDGE_TOKEN) {
    const auth = req.headers.authorization || "";
    const bearer = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
    const hdr = req.headers["x-voice-bridge-token"] || "";
    if (bearer === BRIDGE_TOKEN || hdr === BRIDGE_TOKEN) {
      return { ok: true, cookie: "", mode: "token" };
    }
  }
  return { ok: false };
}

/** Minimal multipart parser for sessionId + file fields. */
function parseMultipart(buf, contentType) {
  const m = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(contentType || "");
  if (!m) throw Object.assign(new Error("multipart boundary missing"), { code: 400 });
  const boundary = m[1] || m[2];
  const parts = [];
  const sep = Buffer.from(`--${boundary}`);
  let start = buf.indexOf(sep);
  while (start >= 0) {
    let next = buf.indexOf(sep, start + sep.length);
    if (next < 0) break;
    let part = buf.subarray(start + sep.length, next);
    if (part.length >= 2 && part[0] === 13 && part[1] === 10) part = part.subarray(2);
    if (part.length >= 2 && part[part.length - 2] === 13 && part[part.length - 1] === 10) {
      part = part.subarray(0, part.length - 2);
    }
    if (part.equals(Buffer.from("--")) || part.equals(Buffer.from("--\r\n"))) break;
    const hdrEnd = part.indexOf("\r\n\r\n");
    if (hdrEnd >= 0) {
      const headers = part.subarray(0, hdrEnd).toString("utf8");
      let body = part.subarray(hdrEnd + 4);
      if (body.length >= 2 && body[body.length - 2] === 13 && body[body.length - 1] === 10) {
        body = body.subarray(0, body.length - 2);
      }
      const nameM = /name="([^"]+)"/i.exec(headers);
      const fileM = /filename="([^"]*)"/i.exec(headers);
      parts.push({
        name: nameM ? nameM[1] : "",
        filename: fileM ? fileM[1] : "",
        body,
      });
    }
    start = next;
  }
  return parts;
}

function wavToFloat32Mono16k(wavBuf) {
  if (wavBuf.length < 44 || wavBuf.toString("ascii", 0, 4) !== "RIFF") {
    throw Object.assign(new Error("expected RIFF/WAV"), { code: 400 });
  }
  let offset = 12;
  let fmt = null;
  let data = null;
  while (offset + 8 <= wavBuf.length) {
    const id = wavBuf.toString("ascii", offset, offset + 4);
    const size = wavBuf.readUInt32LE(offset + 4);
    const start = offset + 8;
    if (id === "fmt ") {
      fmt = {
        audioFormat: wavBuf.readUInt16LE(start),
        channels: wavBuf.readUInt16LE(start + 2),
        sampleRate: wavBuf.readUInt32LE(start + 4),
        bitsPerSample: wavBuf.readUInt16LE(start + 14),
      };
    } else if (id === "data") {
      data = wavBuf.subarray(start, start + size);
      break;
    }
    offset = start + size + (size % 2);
  }
  if (!fmt || !data) throw Object.assign(new Error("wav missing fmt/data"), { code: 400 });
  if (fmt.audioFormat !== 1 || fmt.bitsPerSample !== 16) {
    throw Object.assign(new Error("only PCM S16 WAV supported"), { code: 400 });
  }
  const samples = data.length / 2;
  const ch = fmt.channels;
  const frames = Math.floor(samples / ch);
  const mono = new Float32Array(frames);
  for (let i = 0; i < frames; i++) {
    let sum = 0;
    for (let c = 0; c < ch; c++) {
      sum += data.readInt16LE((i * ch + c) * 2) / 32768;
    }
    mono[i] = sum / ch;
  }
  if (fmt.sampleRate === 16000) return Buffer.from(mono.buffer);
  // linear resample → 16 kHz
  const ratio = fmt.sampleRate / 16000;
  const outLen = Math.floor(frames / ratio);
  const out = new Float32Array(outLen);
  for (let i = 0; i < outLen; i++) {
    const src = i * ratio;
    const i0 = Math.floor(src);
    const i1 = Math.min(i0 + 1, frames - 1);
    const t = src - i0;
    out[i] = mono[i0] * (1 - t) + mono[i1] * t;
  }
  return Buffer.from(out.buffer);
}

function pcmS16Wav(float32, sampleRate = 16000) {
  const n = float32.length;
  const dataSize = n * 2;
  const buf = Buffer.alloc(44 + dataSize);
  buf.write("RIFF", 0);
  buf.writeUInt32LE(36 + dataSize, 4);
  buf.write("WAVE", 8);
  buf.write("fmt ", 12);
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20);
  buf.writeUInt16LE(1, 22);
  buf.writeUInt32LE(sampleRate, 24);
  buf.writeUInt32LE(sampleRate * 2, 28);
  buf.writeUInt16LE(2, 32);
  buf.writeUInt16LE(16, 34);
  buf.write("data", 36);
  buf.writeUInt32LE(dataSize, 40);
  for (let i = 0; i < n; i++) {
    const s = Math.max(-1, Math.min(1, float32[i]));
    buf.writeInt16LE((s * 32767) | 0, 44 + i * 2);
  }
  return buf;
}

async function httpJson(url, { method = "GET", headers = {}, body = null, timeoutMs = 30000 } = {}) {
  const u = new URL(url);
  const payload = body == null ? null : Buffer.isBuffer(body) ? body : Buffer.from(typeof body === "string" ? body : JSON.stringify(body));
  const opts = {
    hostname: u.hostname,
    port: u.port || (u.protocol === "https:" ? 443 : 80),
    path: u.pathname + u.search,
    method,
    headers: { ...headers },
  };
  if (payload) {
    opts.headers["content-length"] = payload.length;
    if (!opts.headers["content-type"] && !Buffer.isBuffer(body)) {
      opts.headers["content-type"] = "application/json";
    }
  }
  return new Promise((resolve, reject) => {
    const req = http.request(opts, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const buf = Buffer.concat(chunks);
        const ct = res.headers["content-type"] || "";
        let parsed = null;
        if (ct.includes("application/json")) {
          try {
            parsed = JSON.parse(buf.toString("utf8"));
          } catch {
            parsed = null;
          }
        }
        resolve({ status: res.statusCode, headers: res.headers, buf, json: parsed });
      });
    });
    req.setTimeout(timeoutMs, () => {
      req.destroy(new Error("timeout"));
    });
    req.on("error", reject);
    if (payload) req.write(payload);
    req.end();
  });
}

async function rpc(cookie, method, payload) {
  const body = { method, payload };
  const r = await httpJson(`${RPC_BASE}/api/rpc`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      origin: ORIGIN_RPC,
      cookie: `dsh_mobile=${cookie}`,
    },
    body,
    timeoutMs: 60000,
  });
  if (!r.json) throw new Error(`rpc ${method} non-json HTTP ${r.status}`);
  return r.json;
}

async function voicePost(pathname, body, { binary = false, query = "", timeoutMs = 120000 } = {}) {
  const headers = {
    origin: VOICE_BASE,
  };
  let payload = body;
  if (!binary) {
    headers["content-type"] = "application/json";
    payload = typeof body === "string" ? body : JSON.stringify(body ?? {});
  } else {
    headers["content-type"] = "application/octet-stream";
  }
  return httpJson(`${VOICE_BASE}${pathname}${query}`, {
    method: "POST",
    headers,
    body: payload,
    timeoutMs,
  });
}

async function voiceGet(pathname, timeoutMs = 15000) {
  return httpJson(`${VOICE_BASE}${pathname}`, {
    method: "GET",
    headers: { origin: VOICE_BASE },
    timeoutMs,
  });
}

async function ensureVoiceSession(sessionId) {
  const r = await voicePost("/voice-mode/toggle", { sessionId, on: true, tabId: "lan-bridge" }, { timeoutMs: 180000 });
  if (r.status !== 200) {
    throw Object.assign(new Error(`toggle failed HTTP ${r.status}: ${r.buf.toString("utf8").slice(0, 200)}`), {
      code: r.status,
    });
  }
  return r.json;
}

async function releaseVoiceSession(sessionId) {
  try {
    await voicePost("/voice-mode/toggle", { sessionId, on: false, tabId: "lan-bridge" }, { timeoutMs: 10000 });
  } catch {
    /* ignore */
  }
}

async function waitAsrReady(deadline) {
  while (Date.now() < deadline) {
    const st = await voiceGet("/voice-mode/models/status");
    const asrReady = st.json?.asr?.ready;
    if (asrReady) return st.json;
    // kick download
    try {
      await voicePost("/voice-mode/models/retry", { kind: "asr" }, { timeoutMs: 5000 });
    } catch {
      /* may timeout while downloading — keep polling status */
    }
    await new Promise((r) => setTimeout(r, 2000));
  }
  throw Object.assign(new Error("ASR models not ready (download still in progress)"), { code: 503 });
}

async function asrFinal(sessionId, pcmF32) {
  const deadline = Date.now() + ASR_WAIT_MS;
  await waitAsrReady(deadline);
  // reset segment
  await voicePost(`/voice-mode/asr?sessionId=${encodeURIComponent(sessionId)}&reset=1`, Buffer.alloc(0), {
    binary: true,
    timeoutMs: 30000,
  });
  // chunk ~0.9s (14400 floats) then final
  const CHUNK = 14400;
  let text = "";
  let offset = 0;
  const floats = new Float32Array(pcmF32.buffer, pcmF32.byteOffset, pcmF32.byteLength / 4);
  while (offset < floats.length) {
    const end = Math.min(offset + CHUNK, floats.length);
    const slice = floats.subarray(offset, end);
    const isFinal = end >= floats.length;
    const q = `?sessionId=${encodeURIComponent(sessionId)}&offset=${offset}&final=${isFinal ? 1 : 0}&epoch=0`;
    let attempt = 0;
    for (;;) {
      const r = await voicePost(`/voice-mode/asr${q}`, Buffer.from(slice.buffer, slice.byteOffset, slice.byteLength), {
        binary: true,
        timeoutMs: 120000,
      });
      if (r.status === 202 || r.json?.loading) {
        if (Date.now() > deadline) throw Object.assign(new Error("ASR still loading"), { code: 503 });
        await new Promise((x) => setTimeout(x, 1500));
        attempt++;
        if (attempt > 120) throw Object.assign(new Error("ASR loading timeout"), { code: 503 });
        continue;
      }
      if (r.status !== 200) {
        throw Object.assign(new Error(`ASR HTTP ${r.status}: ${r.buf.toString("utf8").slice(0, 200)}`), {
          code: r.status,
        });
      }
      text = r.json?.text || text;
      break;
    }
    offset = end;
  }
  return String(text || "").trim();
}

function openAudioSse(sessionId) {
  const chunks = [];
  let idleTimer = null;
  let hardTimer = null;
  let doneResolve;
  const done = new Promise((r) => {
    doneResolve = r;
  });
  let finished = false;
  let sawFinal = false;
  let lastAudioAt = 0;
  const finish = (why = "stop") => {
    if (finished) return;
    finished = true;
    clearTimeout(idleTimer);
    clearTimeout(hardTimer);
    try {
      req.destroy();
    } catch {
      /* */
    }
    log("sse finish", { why, chunks: chunks.length, bytes: chunks.reduce((n, b) => n + b.length, 0), sawFinal });
    doneResolve({ chunks, sawFinal, lastAudioAt });
  };
  const bump = () => {
    clearTimeout(idleTimer);
    // Only auto-finish on idle AFTER we have audio (or final). Do not cut mid-stream early.
    idleTimer = setTimeout(() => finish(sawFinal ? "final+idle" : "idle"), SSE_IDLE_MS);
  };
  const u = new URL(`${VOICE_BASE}/voice-mode/stream?tabId=lan-bridge-${randomUUID().slice(0, 8)}`);
  const req = http.request(
    {
      hostname: u.hostname,
      port: u.port,
      path: u.pathname + u.search,
      method: "GET",
      headers: { origin: VOICE_BASE, accept: "text/event-stream" },
    },
    (res) => {
      let buf = "";
      res.on("data", (c) => {
        buf += c.toString("utf8");
        let idx;
        while ((idx = buf.indexOf("\n\n")) >= 0) {
          const block = buf.slice(0, idx);
          buf = buf.slice(idx + 2);
          const lines = block.split("\n");
          let event = "message";
          let data = "";
          for (const line of lines) {
            if (line.startsWith("event:")) event = line.slice(6).trim();
            else if (line.startsWith("data:")) data += line.slice(5).trim();
          }
          if (event === "audio" && data) {
            try {
              const frame = JSON.parse(data);
              if (frame.sessionId && frame.sessionId !== sessionId) continue;
              if (frame.audio) {
                chunks.push(Buffer.from(frame.audio, "base64"));
                lastAudioAt = Date.now();
                bump();
              }
              if (frame.final) {
                sawFinal = true;
                bump();
              }
            } catch {
              /* */
            }
          }
        }
      });
      res.on("end", () => finish("http-end"));
    }
  );
  req.on("error", () => finish("error"));
  req.end();
  hardTimer = setTimeout(() => finish("hard-cap"), Math.max(SSE_MAX_WAIT_MS, PROMPT_WAIT_MS + 15000));
  return {
    wait: () => done,
    stop: () => finish("stop"),
  };
}

/** Rough CN/EN spoken duration at ~4.5 chars/sec; Edge 48kbps → bytes ≈ sec * 6000. */
function sseLooksTruncated(replyText, sseBytes) {
  const chars = spokenForTts(replyText).length;
  if (chars < 8) return false;
  const minSec = Math.max(2.0, chars / 5.5);
  const minBytes = minSec * 4500; // below 48kbps with margin
  return sseBytes > 0 && sseBytes < minBytes;
}

function flattenHistoryTurns(historyJson) {
  const turns = [];
  const seen = new Set();
  const walk = (o) => {
    if (!o || typeof o !== "object") return;
    if (seen.has(o)) return;
    seen.add(o);
    if (Array.isArray(o)) {
      for (const v of o) walk(v);
      return;
    }
    const role = o.role || o.author || o.type;
    let text = "";
    if (typeof o.text === "string") text = o.text;
    else if (typeof o.content === "string") text = o.content;
    else if (Array.isArray(o.content)) {
      text = o.content
        .map((p) => (typeof p === "string" ? p : p?.text || ""))
        .filter(Boolean)
        .join("\n");
    }
    if ((role === "user" || role === "assistant" || role === "human" || role === "ai") && text) {
      const r = role === "human" || role === "user" ? "user" : role === "ai" ? "assistant" : role;
      turns.push({ role: r, text: text.trim() });
    }
    for (const k of Object.keys(o)) walk(o[k]);
  };
  walk(historyJson);
  return turns;
}

function extractAssistantText(historyJson, afterUser) {
  const turns = flattenHistoryTurns(historyJson);
  if (afterUser) {
    for (let i = turns.length - 1; i >= 0; i--) {
      if (turns[i].role === "user" && turns[i].text === afterUser) {
        for (let j = i + 1; j < turns.length; j++) {
          if (turns[j].role === "assistant") return turns[j].text;
        }
      }
    }
  }
  for (let i = turns.length - 1; i >= 0; i--) {
    if (turns[i].role === "assistant") return turns[i].text;
  }
  return "";
}

function extractLastUserText(historyJson) {
  const turns = flattenHistoryTurns(historyJson);
  for (let i = turns.length - 1; i >= 0; i--) {
    if (turns[i].role === "user") return turns[i].text;
  }
  return "";
}

/** Count trailing identical user texts (voice-mode inject + session.prompt double). */
function countTrailingUserDupes(historyJson, text) {
  const turns = flattenHistoryTurns(historyJson);
  let n = 0;
  for (let i = turns.length - 1; i >= 0; i--) {
    if (turns[i].role !== "user") break;
    if (turns[i].text !== text) break;
    n += 1;
  }
  return n;
}

// Dedupe concurrent / back-to-back voice-turns for same session+asr text
const recentPrompts = new Map(); // key -> { at, skipping }
const turnLocks = new Map(); // sessionId -> Promise chain

function stripEmotion(text) {
  return String(text || "")
    .replace(/\[emotion:[a-z_]+\]/gi, "")
    .replace(/<!--\s*emotion:[a-z_]+\s*-->/gi, "")
    .replace(/[*_#`]+/g, " ")
    .replace(/\s{2,}/g, " ")
    .trim();
}

const CJK_RE = /[\u3040-\u30ff\u3400-\u9fff\uf900-\ufaff]/;
const LATIN_WORD_RE = /[A-Za-z]{3,}/;

function hasCjk(s) {
  return CJK_RE.test(s || "");
}

/** True if the chunk is essentially English prose (no CJK). */
function isEnglishProse(s) {
  const t = String(s || "").trim();
  if (!t || hasCjk(t)) return false;
  const letters = (t.match(/[A-Za-z]/g) || []).length;
  return letters >= 6 && LATIN_WORD_RE.test(t);
}

function cjkCount(s) {
  return (String(s || "").match(/[\u3040-\u30ff\u3400-\u9fff\uf900-\ufaff]/g) || []).length;
}
function latinCount(s) {
  return (String(s || "").match(/[A-Za-z]/g) || []).length;
}

/** Drop leftover English crumbs (again / CoT verbs) from otherwise Chinese speech. */
function scrubLatinCrumbs(s) {
  return String(s || "")
    .replace(/\b(again|or|and|the|a|an|to|of|in|on|for|is|are|be|keep|short|maybe|playful|respond|differently|user|says|say|emotion|happy|wink|note|pattern|previous|turns|were|proactive|speak|need|ask|what|they|this|that|just|english|paraphrase|translation|greeting|character|colloquial|markdown|thinking|reasoning|analysis)\b/gi, " ")
    .replace(/["'`\\]+/g, "")
    .replace(/\s{2,}/g, " ")
    .replace(/\s+([。！？，、；：])/g, "$1")
    .trim();
}

/** True if chunk is thinking / CoT / tool chatter — never speak this. */
function isCotOrToolChatter(s) {
  const t = String(s || "").trim();
  if (!t) return true;
  if (/<\/?(?:think|thinking|reasoning|reflection|redacted_thinking|tool_call|tool_response|function_call)\b/i.test(t)) {
    return true;
  }
  if (
    /\b(user says|respond in|keep short|maybe playful|tool call|function_call|scratchpad|chain of thought|let me think|i(?:'| a)?m thinking)\b/i.test(
      t
    )
  ) {
    return true;
  }
  if (
    /^(?:思考|推理|分析|规划|草稿|内心|独白|工具|调用)\s*[:：]/.test(t) ||
    /(?:思考过程|推理过程|让我先|首先分析|工具调用|调用工具|正在执行|执行工具|返回结果)/.test(t)
  ) {
    return true;
  }
  // Planning Chinese that talks about the reply instead of being the reply
  if (/(?:可以回|应该回|回复可以|简短一点|保持短|用中文回)/.test(t) && !/(?:本鱼|主人|哼|呜|呀)/.test(t)) {
    return true;
  }
  // Meta about prior turns — not口播 (allow if already in fish voice)
  if (
    /(?:上一轮|上一条|用户刚才|刚才主人说)/.test(t) &&
    !/(?:本鱼|本肥鱼|哼|呜|呀)/.test(t)
  ) {
    return true;
  }
  return false;
}

/** Remove thinking tags / labeled preamble; keep final spoken body. */
function stripThinkingPreamble(text) {
  let t = String(text || "");
  // Full tagged blocks (incl. redacted_thinking)
  t = t.replace(
    /<(?:think|thinking|reasoning|reflection|redacted_thinking|tool_call|tool_response|function_call)\b[^>]*>[\s\S]*?<\/(?:think|thinking|reasoning|reflection|redacted_thinking|tool_call|tool_response|function_call)>/gi,
    "\n"
  );
  t = t.replace(
    /<\/?(?:think|thinking|reasoning|reflection|redacted_thinking|tool_call|tool_response|function_call)\b[^>]*>/gi,
    "\n"
  );
  // Labeled sections until blank line or final-answer marker
  t = t.replace(
    /(?:^|\n)\s*(?:#{1,6}\s*)?(?:思考|推理|分析|内心独白|草稿|规划|reasoning|thinking|analysis|scratchpad|plan)\s*[:：][^\n]*(?:\n(?!\s*\n)[^\n]*)*/gi,
    "\n"
  );
  // Prefer text after explicit final-body markers
  const markers =
    /(?:^|\n)\s*(?:最终回复|最终答案|正式回复|口播|对主人说|Final(?:\s+answer)?|Answer|Reply)\s*[:：]\s*/i;
  const m = markers.exec(t);
  if (m) t = t.slice(m.index + m[0].length);
  return t.trim();
}

function stripEmotionTags(s) {
  return String(s || "")
    .replace(/\[emotion:[a-z_]+\]/gi, "")
    .replace(/<!--\s*emotion:[a-z_]+\s*-->/gi, "")
    .trim();
}

/** Pack clip names board HDMI eyes accept (never idle/listening/speaking — phase hooks). */
const EMOTION_SPECIAL = new Set([
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
  "dizzy",
  "blink",
  "look_around",
  "boot",
  "shutdown",
]);

/**
 * Extract last [emotion:xxx] / <!--emotion:xxx--> from assistant reply for HDMI eyes.
 * Returns lowercase pack name or "" (TTS still strips tags via stripEmotionTags).
 */
function extractEmotionTag(text) {
  const raw = String(text || "");
  let tag = "";
  for (const m of raw.matchAll(/\[emotion:\s*([A-Za-z0-9_]+)\s*\]/gi)) {
    tag = String(m[1] || "").toLowerCase();
  }
  for (const m of raw.matchAll(/<!--\s*emotion:\s*([A-Za-z0-9_]+)\s*-->/gi)) {
    tag = String(m[1] || "").toLowerCase();
  }
  if (tag && EMOTION_SPECIAL.has(tag)) return tag;
  return "";
}

/** True if chunk is echoing the user / quoting the prompt — never speak. */
function isUserEcho(s) {
  const t = String(s || "").trim();
  if (!t) return true;
  if (
    /^(?:主人|用户|User|human)\s*(?:说|问|发|讲|提到|发来|发了|刚刚说)[：:]\s*/i.test(t) ||
    /^(?:复述|回声|echo|引用用户|用户原话)\b/i.test(t) ||
    /^(?:主动发言指令|指令)\b/.test(t)
  ) {
    return true;
  }
  // Whole chunk is a short quoted echo
  if (/^[「「""『].*[」」""』]$/.test(t) && cjkCount(t) <= 24) return true;
  return false;
}

/** True if reply contains any fullwidth spoken 【…】 pair (even empty). */
function hasSpokenBracketMarkers(text) {
  const s = String(text || "");
  return s.includes("【") && s.includes("】");
}

/**
 * Top-level 【…】 interiors only (depth-aware; nested 【】 flattened).
 * Callers that see bracket markers MUST NOT speak anything outside these.
 */
function extractTopLevelBracketInners(text) {
  const s = String(text || "");
  const tops = [];
  let depth = 0;
  let start = -1;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === "【") {
      if (depth === 0) start = i;
      depth++;
    } else if (ch === "】" && depth > 0) {
      depth--;
      if (depth === 0 && start >= 0) {
        let inner = s.slice(start + 1, i);
        // Flatten nested brackets — keep text once, drop marker chars
        inner = inner.replace(/[【】]/g, "");
        inner = stripEmotionTags(inner).trim();
        if (
          inner &&
          !(
            /^(?:主动发言指令|指令|system|thinking|思考|推理)\b/i.test(inner) &&
            cjkCount(inner) < 8
          )
        ) {
          tops.push(inner);
        }
        start = -1;
      }
    }
  }
  return tops;
}

/**
 * Prefer a single outermost/longest top-level 【…】 only.
 * Ignores nested markers and extra short sibling spans.
 */
function extractOutermostSpokenBracket(text) {
  const tops = extractTopLevelBracketInners(text);
  if (!tops.length) return null;
  tops.sort((a, b) => b.length - a.length || a.localeCompare(b, "zh"));
  return tops[0];
}

function normSentenceKey(s) {
  return String(s || "")
    .replace(/[\s\u3000]+/g, "")
    .replace(/[。！？；…，、,.!?;:…~～]+/g, "")
    .toLowerCase();
}

/**
 * Strong sentence dedupe: consecutive + global exact; drop shorter prefix/suffix
 * repeats of a kept sentence; skip user-echo / CoT crumbs.
 */
function dedupeConsecutiveSentences(text) {
  // Do NOT split on bare `…` — ellipsis runs are not sentence ends and were chopping口播.
  const parts = String(text || "").split(/(?<=[。！？；\n])/);
  const out = [];
  const keys = [];
  for (let p of parts) {
    p = String(p || "").trim();
    if (!p) continue;
    if (isCotOrToolChatter(p) || isUserEcho(p)) continue;
    if (!hasCjk(p) && latinCount(p) >= 3) continue;
    const n = normSentenceKey(p);
    if (!n || cjkCount(p) < 1) continue;

    let skip = false;
    let replaceAt = -1;
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      if (n === k) {
        skip = true;
        break;
      }
      if (n.startsWith(k) && n.length > k.length) {
        // longer elaboration of an earlier short sentence → keep longer once
        replaceAt = i;
        break;
      }
      if (k.startsWith(n) && k.length >= n.length) {
        // shorter echo of something already kept
        skip = true;
        break;
      }
    }
    if (skip) continue;
    if (replaceAt >= 0) {
      out[replaceAt] = p;
      keys[replaceAt] = n;
      continue;
    }
    out.push(p);
    keys.push(n);
  }
  return out.join("");
}

/**
 * TTS pre-process for 大肥鱼:
 * HARD RULE: if any 【】 markers exist → speak ONLY inside brackets; never outside CJK
 *   (thinking / 「…」 / user echo outside are dropped even when Chinese).
 * Else → strip thinking/EN/user-echo; keep remaining Chinese body.
 * Always strip [emotion:…] / <!--emotion:…-->; strong sentence dedupe.
 */
function spokenForTts(text) {
  const raw = String(text || "");
  // Hard gate: any 【】 present → bracket interiors ONLY. Never fall through to outside CJK.
  if (hasSpokenBracketMarkers(raw)) {
    const bracketBody = extractOutermostSpokenBracket(raw);
    if (!bracketBody) return "";
    let s = scrubLatinCrumbs(stripEmotionTags(bracketBody));
    s = dedupeConsecutiveSentences(s);
    s = s.replace(/[（(][^）\n)]*[A-Za-z]{3,}[^）\n)]*[）)]/g, " ").replace(/\s{2,}/g, " ").trim();
    return s || scrubLatinCrumbs(stripEmotionTags(bracketBody));
  }

  // Fallback when model forgot 【】 entirely: strip thinking / EN CoT / user echo
  let t = stripThinkingPreamble(raw);
  t = stripEmotionTags(t);
  if (!t) return "";
  if (!hasCjk(t)) return "";

  t = t.replace(/[（(][^）\n)]*[A-Za-z]{3,}[^）\n)]*[）)]/g, " ");

  const pieces = [];
  for (const para of t.split(/\n+/)) {
    const p0 = para.trim();
    if (!p0) continue;
    if (isEnglishProse(p0) || isCotOrToolChatter(p0) || isUserEcho(p0)) continue;
    if (!hasCjk(p0)) continue;

    for (let p of p0.split(/(?<=[。！？；…])/)) {
      p = p.trim();
      if (!p || !hasCjk(p) || isCotOrToolChatter(p) || isUserEcho(p)) continue;
      const c = cjkCount(p);
      const l = latinCount(p);
      if (c >= 1 && c >= l) {
        p = scrubLatinCrumbs(p.replace(/\b[A-Za-z]{2,}\b/g, " "));
        if (cjkCount(p) >= 1 && !isUserEcho(p)) pieces.push(p);
      } else if (c >= 2) {
        const runs = p.match(
          /[\u3400-\u9fff][\u3400-\u9fff\u3000-\u303f\uff00-\uffef，。！？、；：""''…—\s]*/g
        );
        if (runs) {
          for (const r of runs) {
            const x = scrubLatinCrumbs(r);
            if (cjkCount(x) >= 1 && !isCotOrToolChatter(x) && !isUserEcho(x)) pieces.push(x);
          }
        }
      }
    }
  }

  let s = dedupeConsecutiveSentences(scrubLatinCrumbs(pieces.join("")));
  if (!s || cjkCount(s) < 1) return "";
  return s;
}

/** true only when client clearly prefers WAV over MPEG (board lists mpeg before wav). */
function wantsWav(req) {
  if (process.env.DSH_TTS_FORCE_WAV === "1") return true;
  const u = new URL(req.url || "/", "http://x");
  if (u.searchParams.get("format") === "wav") return true;
  const a = String(req.headers.accept || "").toLowerCase();
  const wavIdx = a.indexOf("audio/wav");
  const mpegIdx = a.indexOf("audio/mpeg");
  if (wavIdx < 0) return false;
  if (mpegIdx >= 0 && mpegIdx <= wavIdx) return false;
  return true;
}

async function edgeTtsMp3(text, voice = DEFAULT_VOICE) {
  if (!MsEdgeTTS) throw new Error("msedge-tts unavailable");
  const spoken = spokenForTts(text);
  if (!spoken) return Buffer.alloc(0);
  const tts = new MsEdgeTTS();
  try {
    await tts.setMetadata(voice, OUTPUT_FORMAT.AUDIO_24KHZ_48KBITRATE_MONO_MP3);
    const { audioStream } = tts.toStream(spoken);
    const chunks = [];
    for await (const chunk of audioStream) chunks.push(chunk);
    return Buffer.concat(chunks);
  } finally {
    try {
      await tts.close();
    } catch {
      /* */
    }
  }
}

function sapiTtsWav(text) {
  const spoken = spokenForTts(text).slice(0, 800);
  if (!spoken) return Promise.resolve(Buffer.alloc(0));
  const out = path.join(os.tmpdir(), `dsh-bridge-${randomUUID()}.wav`);
  const ps1 = path.join(os.tmpdir(), `dsh-bridge-${randomUUID()}.ps1`);
  const script = `
Add-Type -AssemblyName System.Speech
$s = New-Object System.Speech.Synthesis.SpeechSynthesizer
$s.Rate = 0
$s.SetOutputToWaveFile(${JSON.stringify(out)})
$s.Speak([string]${JSON.stringify(spoken)})
$s.Dispose()
`;
  fs.writeFileSync(ps1, script, "utf8");
  return new Promise((resolve, reject) => {
    const child = spawn("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps1], {
      windowsHide: true,
    });
    let err = "";
    child.stderr.on("data", (d) => (err += d));
    child.on("close", (code) => {
      try {
        fs.unlinkSync(ps1);
      } catch {
        /* */
      }
      if (code !== 0 || !fs.existsSync(out)) {
        reject(new Error(`SAPI TTS failed: ${err || code}`));
        return;
      }
      const buf = fs.readFileSync(out);
      try {
        fs.unlinkSync(out);
      } catch {
        /* */
      }
      resolve(buf);
    });
  });
}

async function synthesizeReply(text, preferWav, voice = DEFAULT_VOICE) {
  const mode = TTS_MODE;
  const raw = String(text || "").trim();
  const spoken = spokenForTts(raw);
  if (spoken !== stripEmotion(raw)) {
    log("tts strip-en", { before: stripEmotion(raw).slice(0, 120), after: spoken.slice(0, 120) });
  }
  // Only use SAPI when explicitly forced — Chinese often yields near-empty WAVs on this host.
  if (preferWav || mode === "sapi") {
    try {
      const wav = await sapiTtsWav(spoken);
      if (wav.length > 2048) return { mime: "audio/wav", buf: wav, engine: "sapi", voice: "sapi", spoken };
      log("sapi wav too small, falling back to edge", wav.length);
    } catch (e) {
      log("sapi tts fail", e.message);
      if (mode === "sapi") throw e;
    }
  }
  const mp3 = await edgeTtsMp3(spoken, voice);
  if (!mp3.length) throw Object.assign(new Error(`edge TTS empty for voice=${voice}`), { code: 502 });
  return { mime: "audio/mpeg", buf: mp3, engine: "edge", voice, spoken };
}

async function doSpeak({ text, sessionId, voice, inject, preferWav, auth, kind = "speak" }) {
  const spoken = String(text || "").trim();
  if (!spoken) throw Object.assign(new Error("text required"), { code: 400 });
  const v = String(voice || DEFAULT_VOICE).trim() || DEFAULT_VOICE;
  const audio = await synthesizeReply(spoken, !!preferWav, v);
  if (!audio?.buf?.length) throw Object.assign(new Error("TTS empty"), { code: 502, voice: v });

  let injected = false;
  let injectError = null;
  if (inject) {
    if (!sessionId) injectError = "sessionId required when inject=true";
    else if (!auth?.cookie) injectError = "Cookie dsh_mobile required when inject=true";
    else {
      try {
        const accepted = await rpc(auth.cookie, "session.prompt", {
          sessionId,
          requestId: randomUUID(),
          mode: "queue",
          content: [{ type: "text", text: INJECT_PREFIX + spoken }],
        });
        if (!accepted?.ok) injectError = `session.prompt failed: ${JSON.stringify(accepted).slice(0, 200)}`;
        else injected = true;
      } catch (e) {
        injectError = String(e.message || e);
      }
    }
  }

  lastReply.mime = audio.mime;
  lastReply.buf = audio.buf;
  lastReply.meta = { kind, text: spoken, voice: audio.voice, sessionId: sessionId || null, injected };
  return { audio, text: spoken, voice: audio.voice, sessionId: sessionId || null, injected, injectError, kind };
}

function respondSpeak(res, result, { wantJson, forceJson }) {
  const { audio, text, voice, sessionId, injected, injectError, kind } = result;
  if (wantJson || forceJson || injected || injectError) {
    json(res, injectError && !injected ? 207 : 200, {
      ok: true,
      kind,
      text,
      voice,
      sessionId,
      injected,
      inject_error: injectError,
      mime: audio.mime,
      audio_b64: audio.buf.toString("base64"),
      audio_url: "/v1/last-reply",
      skipped: result.skipped || false,
      reason: result.reason || undefined,
    });
    return;
  }
  res.writeHead(200, {
    "content-type": audio.mime,
    "cache-control": "no-store",
    "x-tts-voice": voice,
    "x-speak-injected": injected ? "1" : "0",
    "x-speak-kind": kind,
  });
  res.end(audio.buf);
}

/** Proactive speak: TTS without board ASR; optional session.prompt inject. */
async function handleSpeak(req, res, auth) {
  const u = new URL(req.url || "/", "http://x");
  const raw = await readBody(req, 256 * 1024);
  let body = {};
  try {
    body = JSON.parse(raw.toString("utf8") || "{}");
  } catch {
    body = { text: raw.toString("utf8") };
  }
  const preferWav =
    body.format === "wav" ||
    u.searchParams.get("format") === "wav" ||
    process.env.DSH_TTS_FORCE_WAV === "1" ||
    (req.headers.accept || "").includes("audio/wav");
  const wantJson =
    body.format === "json" ||
    u.searchParams.get("format") === "json" ||
    (req.headers.accept || "").includes("application/json");
  const result = await doSpeak({
    text: body.text,
    sessionId: String(body.sessionId || u.searchParams.get("sessionId") || "").trim(),
    voice: body.voice,
    inject: body.inject === true || body.inject === "true" || body.inject === 1,
    preferWav,
    auth,
    kind: "speak",
  });
  respondSpeak(res, result, { wantJson, forceJson: !!result.inject });
}

/** Greeting after pair / chat start — inject:true by default; once per session unless force. */
async function handleGreet(req, res, auth) {
  const u = new URL(req.url || "/", "http://x");
  let body = {};
  if (req.method === "POST") {
    const raw = await readBody(req, 64 * 1024);
    try {
      body = JSON.parse(raw.toString("utf8") || "{}");
    } catch {
      body = {};
    }
  }
  const sessionId = String(body.sessionId || u.searchParams.get("sessionId") || "").trim();
  const force = body.force === true || u.searchParams.get("force") === "1";
  const inject = body.inject === false || body.inject === "false" ? false : true;
  const wantJson =
    body.format === "json" ||
    u.searchParams.get("format") === "json" ||
    (req.headers.accept || "").includes("application/json") ||
    true; // greet always returns JSON envelope so board can decode + play

  if (GREET_ONCE && sessionId && !force && greetedSessions.has(sessionId)) {
    json(res, 200, {
      ok: true,
      kind: "greet",
      skipped: true,
      reason: "already_greeted",
      sessionId,
      audio_url: "/v1/last-reply",
    });
    return;
  }

  const text = String(body.text || GREET_TEXT).trim();
  const result = await doSpeak({
    text,
    sessionId,
    voice: body.voice || DEFAULT_VOICE,
    inject: inject && !!sessionId && !!auth.cookie,
    preferWav: false,
    auth,
    kind: "greet",
  });
  if (sessionId) greetedSessions.set(sessionId, Date.now());
  respondSpeak(res, result, { wantJson: true, forceJson: true });
}

/** Idle proactive nudge — cooldown per session; random line. */
async function handleProactiveTick(req, res, auth) {
  const u = new URL(req.url || "/", "http://x");
  let body = {};
  if (req.method === "POST") {
    const raw = await readBody(req, 64 * 1024);
    try {
      body = JSON.parse(raw.toString("utf8") || "{}");
    } catch {
      body = {};
    }
  }
  const sessionId = String(body.sessionId || u.searchParams.get("sessionId") || "").trim();
  const force = body.force === true || u.searchParams.get("force") === "1";
  const now = Date.now();
  if (sessionId && !force) {
    const last = lastProactiveAt.get(sessionId) || 0;
    if (now - last < PROACTIVE_COOLDOWN_MS) {
      json(res, 200, {
        ok: true,
        kind: "proactive",
        skipped: true,
        reason: "cooldown",
        retry_after_ms: PROACTIVE_COOLDOWN_MS - (now - last),
        sessionId,
      });
      return;
    }
  }
  const lines = PROACTIVE_LINES.length ? PROACTIVE_LINES : [GREET_TEXT];
  const text = String(body.text || lines[Math.floor(Math.random() * lines.length)]).trim();
  const inject = body.inject === false || body.inject === "false" ? false : true;
  const result = await doSpeak({
    text,
    sessionId,
    voice: body.voice || DEFAULT_VOICE,
    inject: inject && !!sessionId && !!auth.cookie,
    preferWav: false,
    auth,
    kind: "proactive",
  });
  if (sessionId) lastProactiveAt.set(sessionId, now);
  respondSpeak(res, { ...result, skipped: false }, { wantJson: true, forceJson: true });
}

async function waitStableAssistant(cookie, sessionId, afterUser) {
  const deadline = Date.now() + PROMPT_WAIT_MS;
  let reply = "";
  let stableRaw = "";
  let stableSpoken = "";
  let stableCount = 0;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, REPLY_POLL_MS));
    const hist = await rpc(cookie, "session.history", { sessionId });
    if (!hist?.ok) continue;
    reply = extractAssistantText(hist, afterUser);
    if (!reply || reply === afterUser) {
      stableRaw = "";
      stableSpoken = "";
      stableCount = 0;
      continue;
    }
    const spoken = spokenForTts(reply);
    if (reply === stableRaw && spoken === stableSpoken) {
      stableCount += 1;
    } else {
      if (stableSpoken && spoken.length > stableSpoken.length) {
        log("reply growing", { raw: reply.length, tts: spoken.length });
      } else if (stableRaw && reply !== stableRaw) {
        log("reply changed", { from: stableRaw.length, to: reply.length, tts: spoken.length });
      }
      stableRaw = reply;
      stableSpoken = spoken;
      stableCount = 1;
    }
    if (stableCount >= REPLY_STABLE_POLLS && cjkCount(spoken) >= 2) {
      log("reply stable", { chars: reply.length, ttsChars: spoken.length, polls: stableCount });
      return reply;
    }
  }
  if (!reply) throw Object.assign(new Error("timed out waiting for assistant reply"), { code: 504 });
  log("reply wait timeout — using last text", {
    chars: reply.length,
    ttsChars: spokenForTts(reply).length,
    stableCount,
  });
  return reply;
}

async function promptAndWait(cookie, sessionId, text) {
  // Skip duplicate session.prompt when voice-mode (or a twin turn) already injected this user text.
  const hist0 = await rpc(cookie, "session.history", { sessionId });
  const lastUser = hist0?.ok ? extractLastUserText(hist0) : "";
  const dupes = hist0?.ok ? countTrailingUserDupes(hist0, text) : 0;
  const dedupeKey = `${sessionId}::${text}`;
  const recent = recentPrompts.get(dedupeKey);
  const now = Date.now();
  if (recent && now - recent.at < 15000) {
    log("skip session.prompt — recent identical turn", { sessionId, chars: text.length, ageMs: now - recent.at });
    return waitStableAssistant(cookie, sessionId, text);
  }
  if (lastUser === text || dupes >= 1) {
    log("skip session.prompt — user text already in history (voice-mode inject?)", {
      sessionId,
      chars: text.length,
      trailingDupes: dupes,
    });
    recentPrompts.set(dedupeKey, { at: now });
    return waitStableAssistant(cookie, sessionId, text);
  }

  const reqId = randomUUID();
  const payload = {
    sessionId,
    requestId: reqId,
    mode: "queue",
    content: [{ type: "text", text }],
  };
  const accepted = await rpc(cookie, "session.prompt", payload);
  if (!accepted?.ok) {
    throw Object.assign(new Error(`session.prompt failed: ${JSON.stringify(accepted).slice(0, 300)}`), { code: 502 });
  }
  recentPrompts.set(dedupeKey, { at: Date.now() });
  return waitStableAssistant(cookie, sessionId, text);
}

async function withSessionTurnLock(sessionId, fn) {
  const prev = turnLocks.get(sessionId) || Promise.resolve();
  let release;
  const gate = new Promise((r) => {
    release = r;
  });
  turnLocks.set(
    sessionId,
    prev.then(() => gate).catch(() => gate)
  );
  await prev.catch(() => {});
  try {
    return await fn();
  } finally {
    release();
  }
}

async function handleVoiceTurn(req, res, auth) {
  const ct = req.headers["content-type"] || "";
  const wantJson = (req.headers.accept || "").includes("application/json") || /(?:^|[?&])format=json(?:&|$)/.test(req.url || "");
  const preferWav = wantsWav(req);

  let sessionId = "";
  let wavBuf = null;

  if (ct.includes("multipart/")) {
    const raw = await readBody(req);
    const parts = parseMultipart(raw, ct);
    for (const p of parts) {
      if (p.name === "sessionId") sessionId = p.body.toString("utf8").trim();
      if (p.name === "file" || p.name === "wav" || p.name === "audio" || p.filename) {
        if (!wavBuf || p.body.length > wavBuf.length) wavBuf = p.body;
      }
    }
  } else if (ct.includes("audio/") || ct.includes("application/octet-stream")) {
    sessionId = String(new URL(req.url || "/", "http://x").searchParams.get("sessionId") || "").trim();
    wavBuf = await readBody(req);
  } else {
    json(res, 415, { error: "use multipart/form-data (sessionId + file) or raw audio/wav" });
    return;
  }

  if (!sessionId) {
    json(res, 400, { error: "sessionId required (same DSH_SESSION_ID as text chat)" });
    return;
  }
  if (!wavBuf || wavBuf.length < 44) {
    json(res, 400, { error: "wav file missing/empty" });
    return;
  }
  if (!auth.cookie && auth.mode === "token") {
    json(res, 400, {
      error: "token auth is for smoke only; board must send Cookie dsh_mobile for session.prompt",
    });
    return;
  }

  // verify pairing
  const status = await httpJson(`${RPC_BASE}/api/status`, {
    headers: { origin: ORIGIN_RPC, cookie: `dsh_mobile=${auth.cookie}` },
    timeoutMs: 10000,
  });
  if (status.status !== 200) {
    json(res, 401, { error: "mobile bridge auth failed — re-pair board cookie" });
    return;
  }

  // Serialize per session — double PTT / twin POSTs must not double session.prompt
  const existing = inflightVoiceTurns.get(sessionId);
  if (existing && existing.promise && Math.abs((existing.wavBytes || 0) - wavBuf.length) < 512) {
    log("dedupe concurrent voice-turn — await in-flight", { sessionId, wavBytes: wavBuf.length });
    try {
      const result = await existing.promise;
      if (!result?.audio?.buf?.length) {
        json(res, 502, { error: "TTS produced empty audio (deduped)" });
        return;
      }
      lastReply.mime = result.audio.mime;
      lastReply.buf = result.audio.buf;
      const emotionDup = result.emotion || extractEmotionTag(result.replyText || "");
      if (wantJson) {
        json(res, 200, {
          ok: true,
          asr_text: result.asrText,
          reply_text: result.replyText,
          tts_text: result.ttsText,
          emotion: emotionDup || undefined,
          reply_chars: (result.ttsText || "").length,
          tts: result.ttsPath,
          tts_bytes: result.audio.buf.length,
          mime: result.audio.mime,
          audio_b64: result.audio.buf.toString("base64"),
          audio_url: "/v1/last-reply",
          deduped: true,
        });
        return;
      }
      const hdrDup = {
        "content-type": result.audio.mime,
        "content-length": result.audio.buf.length,
        "cache-control": "no-store",
        "x-tts-engine": result.ttsPath,
        "x-tts-bytes": String(result.audio.buf.length),
        "x-deduped": "1",
        "access-control-expose-headers": "x-emotion, x-tts-engine, x-tts-bytes, x-reply-chars, x-deduped",
      };
      if (emotionDup) hdrDup["x-emotion"] = emotionDup;
      res.writeHead(200, hdrDup);
      res.end(result.audio.buf);
    } catch (e) {
      json(res, e.code && Number.isInteger(e.code) ? e.code : 502, { error: String(e.message || e) });
    }
    return;
  }
  if (existing && !existing.promise) {
    log("voice-turn busy — reject duplicate", { sessionId });
    json(res, 409, { error: "voice-turn already in flight for this sessionId" });
    return;
  }

  let resolveInflights;
  let rejectInflights;
  const inflightPromise = new Promise((resolve, reject) => {
    resolveInflights = resolve;
    rejectInflights = reject;
  });
  inflightVoiceTurns.set(sessionId, { promise: inflightPromise, wavBytes: wavBuf.length, at: Date.now() });
  try {
    await withSessionTurnLock(sessionId, async () => {
      log("turn start", { sessionId, wavBytes: wavBuf.length });
      const pcm = wavToFloat32Mono16k(wavBuf);

      let asrText = "";
      let replyText = "";
      let ttsText = "";
      let emotion = "";
      let audio = null;
      let ttsPath = "none";

      try {
        await ensureVoiceSession(sessionId);
      } catch (e) {
        const err = Object.assign(new Error(`voice-mode toggle failed: ${e.message}`), {
          code: e.code === 403 ? 403 : 502,
        });
        throw err;
      }

      const sse = TTS_PREFER_SSE ? openAudioSse(sessionId) : null;
      try {
        try {
          asrText = await asrFinal(sessionId, pcm);
        } catch (e) {
          throw Object.assign(new Error(`ASR failed: ${e.message}`), { code: e.code || 502 });
        }

        if (!asrText) {
          throw Object.assign(new Error("ASR empty transcript"), { code: 422 });
        }
        log("asr", asrText);

        replyText = await promptAndWait(auth.cookie, sessionId, asrText);
        ttsText = spokenForTts(replyText);
        emotion = extractEmotionTag(replyText);
        log("reply", {
          chars: replyText.length,
          ttsChars: ttsText.length,
          emotion: emotion || null,
          preview: replyText.slice(0, 160),
          ttsPreview: ttsText.slice(0, 120),
        });

        if (TTS_PREFER_SSE && sse) {
          log("waiting for voice-mode SSE TTS (DSH_VOICE_TTS_SSE=1)…");
          const sseResult = await sse.wait();
          const sseChunks = sseResult?.chunks || [];
          const sseBuf = sseChunks.length ? Buffer.concat(sseChunks) : Buffer.alloc(0);
          if (sseBuf.length && !sseLooksTruncated(replyText, sseBuf.length)) {
            audio = { mime: "audio/mpeg", buf: sseBuf, engine: "voice-mode-sse" };
            ttsPath = "voice-mode-sse";
            log("using SSE TTS", { bytes: sseBuf.length, sawFinal: !!sseResult?.sawFinal });
          } else {
            log("SSE missing/truncated — full-text Edge", { sseBytes: sseBuf.length, ttsChars: ttsText.length });
            // Never pass raw replyText — it may contain thinking CJK outside 【】.
            audio = await synthesizeReply(ttsText, preferWav);
            ttsPath = `${audio.engine}+sse-fallback`;
          }
        } else {
          audio = await synthesizeReply(ttsText, preferWav);
          ttsPath = audio.engine;
          log("full-text TTS", { engine: ttsPath, bytes: audio.buf.length, chars: ttsText.length });
        }
      } finally {
        try {
          sse?.stop();
        } catch {
          /* */
        }
        await releaseVoiceSession(sessionId);
      }

      if (!audio?.buf?.length) {
        throw Object.assign(new Error("TTS produced empty audio"), { code: 502 });
      }

      if (!emotion) emotion = extractEmotionTag(replyText);
      const result = { asrText, replyText, ttsText, audio, ttsPath, sessionId, emotion };
      resolveInflights(result);

      lastReply.mime = audio.mime;
      lastReply.buf = audio.buf;
      lastReply.meta = {
        asr_text: asrText,
        reply_text: replyText,
        tts_text: ttsText,
        emotion: emotion || undefined,
        reply_chars: ttsText.length,
        tts: ttsPath,
        tts_bytes: audio.buf.length,
        sessionId,
      };

      if (wantJson) {
        json(res, 200, {
          ok: true,
          asr_text: asrText,
          reply_text: replyText,
          tts_text: ttsText,
          emotion: emotion || undefined,
          reply_chars: ttsText.length,
          tts: ttsPath,
          tts_bytes: audio.buf.length,
          mime: audio.mime,
          audio_b64: audio.buf.toString("base64"),
          reply_wav_b64: audio.mime.includes("wav") ? audio.buf.toString("base64") : undefined,
          audio_url: "/v1/last-reply",
        });
        return;
      }

      const hdr = {
        "content-type": audio.mime,
        "content-length": audio.buf.length,
        "cache-control": "no-store",
        "x-asr-text": encodeURIComponent(asrText).slice(0, 200),
        "x-reply-chars": String(ttsText.length),
        "x-tts-engine": ttsPath,
        "x-tts-bytes": String(audio.buf.length),
        "access-control-expose-headers": "x-emotion, x-asr-text, x-tts-engine, x-tts-bytes, x-reply-chars",
      };
      if (emotion) hdr["x-emotion"] = emotion;
      res.writeHead(200, hdr);
      res.end(audio.buf);
    });
  } catch (e) {
    try {
      rejectInflights(e);
    } catch {
      /* */
    }
    if (!res.headersSent) {
      json(res, e.code && Number.isInteger(e.code) ? e.code : 502, { error: String(e.message || e) });
    }
  } finally {
    const cur = inflightVoiceTurns.get(sessionId);
    if (cur?.promise === inflightPromise) inflightVoiceTurns.delete(sessionId);
  }
}

async function handleHealth(_req, res) {
  let voice = null;
  let models = null;
  try {
    voice = (await voiceGet("/voice-mode", 5000)).json;
  } catch (e) {
    voice = { error: e.message };
  }
  try {
    models = (await voiceGet("/voice-mode/models/status", 5000)).json;
  } catch {
    models = null;
  }
  let vmConfig = null;
  try {
    vmConfig = (await voiceGet("/voice-mode/config", 5000)).json;
  } catch {
    vmConfig = null;
  }
  json(res, 200, {
    ok: true,
    name: "dsh-voice-bridge",
    listen: `http://${BIND}:${PORT}`,
    rpc: RPC_BASE,
    voiceMode: VOICE_BASE,
    ttsVoice: DEFAULT_VOICE,
    voice,
    voiceModeConfig: vmConfig
      ? { voice: vmConfig.voice, ttsEngine: vmConfig.ttsEngine, rate: vmConfig.rate }
      : null,
    models: models
      ? {
          asrReady: !!models.asr?.ready,
          senseReady: !!models.sense?.ready,
          tts: models.tts,
        }
      : null,
    headless: {
      asr: "yes if models ready + toggle(session) first; else 403 unknown_session / 202 loading",
      tts_preview: "POST /voice-mode/preview synthesizes fixed sample only",
      tts_reply:
        "voice-turn TTS=full Edge/SAPI on assistant text by default (set DSH_VOICE_TTS_SSE=1 to prefer SSE with truncation fallback)",
      speak: "POST /v1/speak {text,sessionId?,inject?,voice?}",
      greet: "POST /v1/greet {sessionId} — once per session; inject+TTS",
      proactive: "POST /v1/proactive-tick {sessionId} — idle nudge with cooldown",
    },
    greetText: GREET_TEXT,
    proactiveCooldownMs: PROACTIVE_COOLDOWN_MS,
  });
}

const server = http.createServer(async (req, res) => {
  try {
    const u = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);
    if (req.method === "OPTIONS") {
      res.writeHead(204, {
        "access-control-allow-origin": "*",
        "access-control-allow-methods": "GET,POST,OPTIONS",
        "access-control-allow-headers": "content-type,cookie,origin,authorization,x-voice-bridge-token,accept",
      });
      res.end();
      return;
    }

    if ((u.pathname === "/" || u.pathname === "/health") && req.method === "GET") {
      await handleHealth(req, res);
      return;
    }

    if (u.pathname === "/v1/last-reply" && req.method === "GET") {
      if (!lastReply.buf.length) {
        json(res, 404, { error: "no reply yet" });
        return;
      }
      res.writeHead(200, { "content-type": lastReply.mime, "cache-control": "no-store" });
      res.end(lastReply.buf);
      return;
    }

    if ((u.pathname === "/v1/speak" || u.pathname === "/v1/tts") && req.method === "POST") {
      const auth = authOk(req);
      if (!auth.ok) {
        json(res, 401, { error: "Cookie dsh_mobile or bridge token required" });
        return;
      }
      // /v1/tts kept as alias of speak without inject (legacy smoke)
      if (u.pathname === "/v1/tts") {
        const raw = await readBody(req, 256 * 1024);
        let parsed = {};
        try {
          parsed = JSON.parse(raw.toString("utf8") || "{}");
        } catch {
          parsed = { text: raw.toString("utf8") };
        }
        const preferWav = u.searchParams.get("format") === "wav" || process.env.DSH_TTS_FORCE_WAV === "1";
        const voice = String(parsed.voice || DEFAULT_VOICE).trim() || DEFAULT_VOICE;
        const audio = await synthesizeReply(String(parsed.text || "").trim(), preferWav, voice);
        res.writeHead(200, { "content-type": audio.mime, "x-tts-voice": voice });
        res.end(audio.buf);
        return;
      }
      await handleSpeak(req, res, auth);
      return;
    }

    if ((u.pathname === "/v1/greet" || u.pathname === "/v1/proactive-tick") && (req.method === "POST" || req.method === "GET")) {
      const auth = authOk(req);
      if (!auth.ok) {
        json(res, 401, { error: "Cookie dsh_mobile or bridge token required" });
        return;
      }
      if (u.pathname === "/v1/greet") await handleGreet(req, res, auth);
      else await handleProactiveTick(req, res, auth);
      return;
    }

    if (u.pathname === "/v1/voice-turn" && req.method === "POST") {
      const auth = authOk(req);
      if (!auth.ok) {
        json(res, 401, { error: "Cookie dsh_mobile or bridge token required" });
        return;
      }
      await handleVoiceTurn(req, res, auth);
      return;
    }

    json(res, 404, {
      error: "not found",
      paths: [
        "GET /health",
        "POST /v1/voice-turn",
        "POST /v1/speak",
        "POST /v1/greet",
        "POST /v1/proactive-tick",
        "POST /v1/tts",
        "GET /v1/last-reply",
      ],
    });
  } catch (e) {
    log("handler error", e);
    if (!res.headersSent) json(res, e.code && Number.isInteger(e.code) ? e.code : 500, { error: String(e.message || e) });
  }
});

server.listen(PORT, BIND, () => {
  log(`dsh-voice-bridge listening http://${BIND}:${PORT}`);
  log(`rpc=${RPC_BASE} voice-mode=${VOICE_BASE}`);
});
