#!/bin/sh
# Force CON24 HP playback + best-known mic capture path on rockchip-es8388 (hw:0,0).
# No flash. Safe to call before arecord/aplay/ASR/TTS.
# See docs/board-headset-audio.md (CON24 force play + mic route A).
set -eu

CARD="${ALSA_CARD:-0}"
DEV="${ALSA_DEV:-hw:${CARD},0}"

amixer_c() {
	amixer -c "$CARD" "$@" >/dev/null 2>&1 || return 0
}

# --- Playback (HP / OUT1) — max loud defaults ---
amixer_c sset "hp switch" on
amixer_c sset Headphone on
amixer_c sset Speaker off
amixer_c sset OUT1 on
amixer_c sset OUT2 off
amixer_c sset "spk switch" off
# Absolute max (ES8388): Output 1 = 33, PCM = 192
amixer_c sset "Output 1" 33
amixer_c sset PCM 192
amixer_c sset "Output 1" 100%
amixer_c sset PCM 100%
amixer_c cset name="Left Mixer Left Playback Switch" on
amixer_c cset name="Right Mixer Right Playback Switch" on
# Soft-vol bump if present (ignore if missing)
amixer_c sset SoftMaster 100%
amixer_c sset Master 100%
amixer_c sset DAC 100%

# --- Capture (route A: Differential + Line 2) ---
amixer_c sset "Headset Mic" on
amixer_c sset "Main Mic" on
amixer_c sset "Capture Mute" off
amixer_c sset "Capture Digital" 100%
amixer_c sset "Left Channel" 100%
amixer_c sset "Right Channel" 100%
amixer_c sset "Left PGA Mux" DifferentialL
amixer_c sset "Right PGA Mux" DifferentialR
amixer_c sset "Differential Mux" "Line 2"
amixer_c sset "Left Line Mux" MicL
amixer_c sset "Right Line Mux" MicR

if [ "${AUDIO_UP_QUIET:-0}" = "1" ]; then
	exit 0
fi

echo "board-audio-up: card=$CARD dev=$DEV"
amixer -c "$CARD" sget "hp switch" 2>/dev/null | sed -n '/Mono:/p' || true
amixer -c "$CARD" sget Headphone 2>/dev/null | sed -n '/Mono:/p' || true
amixer -c "$CARD" sget OUT1 2>/dev/null | sed -n '/Mono:/p' || true
amixer -c "$CARD" sget "Headset Mic" 2>/dev/null | sed -n '/Mono:/p' || true
amixer -c "$CARD" sget "Capture Mute" 2>/dev/null | sed -n '/Mono:/p' || true
amixer -c "$CARD" sget "Differential Mux" 2>/dev/null | sed -n '/Item0:/p' || true
amixer -c "$CARD" cget iface=CARD,name="Headphone Jack" 2>/dev/null | sed -n '/values=/p' || true
grep -E "138|490" /sys/kernel/debug/gpio 2>/dev/null || true
