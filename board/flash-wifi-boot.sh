#!/usr/bin/env bash
# Flash patched WiFi-PCIe DT boot.img to eMMC boot only (Loader mode).
# TL3576-EVM-H: EMMC only — never SPINAND. Needs root USB access.
set -euo pipefail
UT="${UT:-/home/na/sdk/tools/linux/Linux_Upgrade_Tool/Linux_Upgrade_Tool/upgrade_tool}"
BOOT="${BOOT:-/home/na/sdk/kernel-6.1/boot.img}"
echo "USB:"; lsusb -d 2207: || true
"$UT" LD
"$UT" PL | head -40
echo "Writing eMMC boot <- $BOOT (not SPINAND)"
"$UT" DI -b "$BOOT"
"$UT" RD
echo "Done — board should reboot. Verify: vpcie3v3-supply; lspci 14e4:449d; wlan0"
