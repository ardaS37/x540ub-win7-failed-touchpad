#!/usr/bin/env bash
# =============================================================================
#  collect-touchpad-info.sh
#  Collects I2C-HID touchpad diagnostic info on Linux (ASUS X540UB and
#  similar laptops; works from a Live USB too). Written for Fedora (uses
#  dnf), but the actual collection logic is distro-agnostic.
#
#  Usage:
#     sudo bash collect-touchpad-info.sh              # normal
#     sudo bash collect-touchpad-info.sh --no-install  # don't install packages
#
#  Output: ~/touchpad-report-<timestamp>.tar.gz
#  (If you're on a Live USB, copy this file to a real USB stick before
#  rebooting — it gets wiped otherwise.)
#
#  This script only READS from the system; it does not write to hardware or
#  change system configuration, other than optionally installing a few
#  read-only diagnostic packages (acpica-tools, i2c-tools, pciutils,
#  dmidecode) if they're missing.
# =============================================================================

set -u

NO_INSTALL=0
for a in "$@"; do
    case "$a" in
        --no-install) NO_INSTALL=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "This script needs to run as root. Re-running: sudo $0 $*"
    exec sudo bash "$0" "$@"
fi

# Write output into the invoking (sudo) user's home directory, not root's.
REAL_USER="${SUDO_USER:-root}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
[ -z "$REAL_HOME" ] && REAL_HOME="/root"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$REAL_HOME/touchpad-report-$STAMP"
mkdir -p "$OUT"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }

# run <file> <command...>: runs the command, appends its output to <file>
run() {
    local f="$OUT/$1"; shift
    {
        echo "### \$ $*"
        "$@" 2>&1
        echo "### exit=$?"
        echo
    } >>"$f"
}

# -----------------------------------------------------------------------------
say "1/9 Checking required packages"
# -----------------------------------------------------------------------------
NEED=()
command -v acpidump  >/dev/null || NEED+=(acpica-tools)
command -v i2cdetect >/dev/null || NEED+=(i2c-tools)
command -v lspci     >/dev/null || NEED+=(pciutils)
command -v dmidecode >/dev/null || NEED+=(dmidecode)
command -v python3   >/dev/null || NEED+=(python3)

if [ "${#NEED[@]}" -gt 0 ]; then
    if [ "$NO_INSTALL" -eq 0 ] && command -v dnf >/dev/null; then
        echo "Installing: ${NEED[*]}"
        dnf -y install "${NEED[@]}" >"$OUT/00-dnf.txt" 2>&1 \
            || warn "dnf install failed (no internet?). Continuing anyway."
    else
        warn "Missing packages: ${NEED[*]} (skipping)"
    fi
fi

# -----------------------------------------------------------------------------
say "2/9 System information"
# -----------------------------------------------------------------------------
run 01-system.txt uname -a
run 01-system.txt cat /etc/os-release
for k in sys_vendor product_name product_version board_name bios_version bios_date; do
    [ -r "/sys/class/dmi/id/$k" ] && echo "$k: $(cat /sys/class/dmi/id/$k)" >>"$OUT/01-system.txt"
done
command -v dmidecode >/dev/null && run 01-system.txt dmidecode -t bios -t system -t baseboard
run 01-system.txt grep -m1 "model name" /proc/cpuinfo

# -----------------------------------------------------------------------------
say "3/9 PCI devices (Intel Serial IO I2C controllers)"
# -----------------------------------------------------------------------------
if command -v lspci >/dev/null; then
    run 02-pci.txt lspci -nn
    # Serial IO I2C controller details (BAR addresses etc.)
    for dev in $(lspci -Dnn | grep -iE "serial io i2c|i2c controller|8086:9d6[0-5]|8086:a36[89]" | awk '{print $1}'); do
        run 02-pci-i2c-detail.txt lspci -vvvnn -s "$dev"
        run 02-pci-i2c-detail.txt lspci -xxxx -s "$dev"
    done
fi

# -----------------------------------------------------------------------------
say "4/9 Kernel logs"
# -----------------------------------------------------------------------------
dmesg >"$OUT/03-dmesg-full.txt" 2>&1
dmesg | grep -iE "i2c|hid|elan|focal|fte|synap|touchpad|lpss|designware|gpio|input:" \
    >"$OUT/03-dmesg-filtered.txt" 2>&1
run 03-modules.txt lsmod

# -----------------------------------------------------------------------------
say "5/9 I2C bus and touchpad device"
# -----------------------------------------------------------------------------
F="$OUT/04-i2c.txt"
command -v i2cdetect >/dev/null && run 04-i2c.txt i2cdetect -l

{
    echo "### /sys/bus/i2c/devices"
    ls -l /sys/bus/i2c/devices/ 2>&1
    echo
} >>"$F"

TP_CLIENTS=()
for d in /sys/bus/i2c/devices/*; do
    [ -e "$d/name" ] || continue
    name="$(cat "$d/name" 2>/dev/null)"
    {
        echo "----- $(basename "$d") -----"
        echo "name       : $name"
        echo "real path  : $(readlink -f "$d")"
        [ -e "$d/modalias" ]      && echo "modalias   : $(cat "$d/modalias")"
        [ -e "$d/driver" ]        && echo "driver     : $(basename "$(readlink -f "$d/driver")")"
        [ -e "$d/firmware_node/path" ] && echo "ACPI path  : $(cat "$d/firmware_node/path")"
        [ -e "$d/firmware_node/hid" ]  && echo "ACPI _HID  : $(cat "$d/firmware_node/hid")"
        echo
    } >>"$F"
    case "$name" in
        *ELAN*|*FTE*|*SYN*|*ASUE*|*MSFT0001*|*ATML*|*CYAP*|*ALPS*|*DLL*|*SYNA*)
            TP_CLIENTS+=("$d") ;;
    esac
done

# Anything bound to the i2c-hid driver is also a touchpad candidate.
for d in /sys/bus/i2c/drivers/i2c_hid*/*; do
    [ -e "$d/name" ] && TP_CLIENTS+=("$(readlink -f "$d")")
done

# Deduplicate.
mapfile -t TP_CLIENTS < <(printf '%s\n' "${TP_CLIENTS[@]:-}" | grep -v '^$' | xargs -r -n1 readlink -f | sort -u)

if [ "${#TP_CLIENTS[@]}" -eq 0 ]; then
    warn "No touchpad I2C device found! (will check the ACPI tables instead)"
    echo "NO TOUCHPAD FOUND" >>"$F"
else
    for c in "${TP_CLIENTS[@]}"; do
        echo "Touchpad candidate: $(basename "$c") ($(cat "$c/name" 2>/dev/null))"
        echo "### TOUCHPAD CANDIDATE: $c" >>"$F"
    done
fi

run 04-interrupts.txt cat /proc/interrupts

# GPIO info (in case the touchpad uses a GPIO interrupt pin, see the ACPI
# dump below for whether it actually does on your hardware)
if [ -d /sys/kernel/debug ] && ! mountpoint -q /sys/kernel/debug; then
    mount -t debugfs none /sys/kernel/debug 2>/dev/null
fi
[ -r /sys/kernel/debug/gpio ] && run 05-gpio.txt cat /sys/kernel/debug/gpio
for p in /sys/kernel/debug/pinctrl/*/pins; do
    [ -r "$p" ] && run 05-gpio.txt cat "$p"
done
for p in /sys/kernel/debug/pinctrl/*/pinmux-pins; do
    [ -r "$p" ] && run 05-gpio.txt cat "$p"
done

# -----------------------------------------------------------------------------
say "6/9 HID report descriptors"
# -----------------------------------------------------------------------------
HD="$OUT/06-hid"
mkdir -p "$HD"
for h in /sys/bus/hid/devices/*; do
    [ -e "$h" ] || continue
    b="$(basename "$h")"
    {
        echo "device     : $b"
        echo "real path  : $(readlink -f "$h")"
        [ -e "$h/uevent" ] && cat "$h/uevent"
        [ -e "$h/driver" ] && echo "driver     : $(basename "$(readlink -f "$h/driver")")"
    } >"$HD/$b.info.txt" 2>&1
    if [ -r "$h/report_descriptor" ]; then
        cp "$h/report_descriptor" "$HD/$b.rdesc.bin" 2>/dev/null
        od -An -tx1 -v "$h/report_descriptor" >"$HD/$b.rdesc.hex.txt" 2>/dev/null
    fi
done
# The fully decoded descriptor from debugfs, if available.
for r in /sys/kernel/debug/hid/*/rdesc; do
    [ -r "$r" ] || continue
    b="$(basename "$(dirname "$r")")"
    timeout 3 cat "$r" >"$HD/$b.rdesc.decoded.txt" 2>&1
done

# -----------------------------------------------------------------------------
say "7/9 ACPI tables (DSDT/SSDT) — I2C address, speed, interrupt/GPIO pin"
# -----------------------------------------------------------------------------
AD="$OUT/07-acpi"
mkdir -p "$AD"
if command -v acpidump >/dev/null; then
    (
        cd "$AD" || exit
        acpidump >acpi.dat 2>acpidump.err
        acpixtract -a acpi.dat >/dev/null 2>&1
        if command -v iasl >/dev/null; then
            for t in dsdt.dat ssdt*.dat; do
                [ -e "$t" ] && iasl -d "$t" >/dev/null 2>&1
            done
        fi
    )
    # Pull out the ASL blocks relevant to the touchpad.
    if ls "$AD"/*.dsl >/dev/null 2>&1; then
        grep -n -B3 -A25 -E 'ELAN|FTE1|SYNA|ASUE|PNP0C50|ACPI0C50|I2cSerialBus' \
            "$AD"/*.dsl >"$AD/touchpad-summary.txt" 2>/dev/null
        grep -n -E 'I2cSerialBusV2|GpioInt|GpioIo|_HID|_CID|_DSM|_STA|_CRS' \
            "$AD"/*.dsl >"$AD/resource-lines.txt" 2>/dev/null
    fi
else
    warn "acpidump not available, could not get ACPI tables"
    # At least try to copy the raw table.
    [ -r /sys/firmware/acpi/tables/DSDT ] && cp /sys/firmware/acpi/tables/DSDT "$AD/DSDT.bin"
fi

# -----------------------------------------------------------------------------
say "8/9 I2C HID descriptor (reading directly from the touchpad, READ-ONLY)"
# -----------------------------------------------------------------------------
# HID-over-I2C: the HID descriptor usually lives at register 0x0001 (ELAN),
# sometimes 0x0020. We try to find the right address from the ACPI dump.
ID="$OUT/08-i2c-hid-desc.txt"
if command -v i2ctransfer >/dev/null && [ "${#TP_CLIENTS[@]}" -gt 0 ]; then
    modprobe i2c-dev 2>/dev/null
    for c in "${TP_CLIENTS[@]}"; do
        busdir="$(dirname "$c")"                 # .../i2c-N
        bus="$(basename "$busdir" | sed -n 's/^i2c-\([0-9]\+\)$/\1/p')"
        [ -z "$bus" ] && continue
        # Guess the address from the ACPI summary; fall back to common ones.
        addrs="0x15 0x38 0x2c"
        if [ -r "$AD/touchpad-summary.txt" ]; then
            a="$(grep -oE 'I2cSerialBusV2 \(0x[0-9A-Fa-f]+' "$AD/touchpad-summary.txt" \
                 | grep -oE '0x[0-9A-Fa-f]+' | sort -u | tr '\n' ' ')"
            [ -n "$a" ] && addrs="$a"
        fi
        for addr in $addrs; do
            for reg in "0x01 0x00" "0x20 0x00"; do
                {
                    echo "### bus=$bus addr=$addr reg=[$reg]  (30-byte HID descriptor)"
                    # shellcheck disable=SC2086
                    i2ctransfer -f -y "$bus" w2@"$addr" $reg r30 2>&1
                    echo
                } >>"$ID"
            done
        done
    done
else
    echo "i2ctransfer not available or no touchpad found, skipped." >"$ID"
fi

# -----------------------------------------------------------------------------
say "9/9 Live report capture (touch the touchpad when prompted)"
# -----------------------------------------------------------------------------
RAW="$OUT/09-live-reports"
mkdir -p "$RAW"
HIDRAWS=()
for r in /sys/class/hidraw/hidraw*; do
    [ -e "$r" ] || continue
    p="$(readlink -f "$r/device")"
    case "$p" in
        *i2c*) HIDRAWS+=("$(basename "$r")") ;;
    esac
done

if [ "${#HIDRAWS[@]}" -eq 0 ]; then
    warn "No I2C-attached hidraw device found, skipping live capture."
else
    echo "Found I2C hidraw devices: ${HIDRAWS[*]}"
    for hr in "${HIDRAWS[@]}"; do
        echo
        echo ">>> About to record 12 seconds from /dev/$hr. In order:"
        echo "      1) move one finger around"
        echo "      2) tap once and press the left/right button"
        echo "      3) scroll up/down with two fingers"
        if [ -t 0 ]; then
            read -r -p "    Press Enter when ready..." _
        fi
        if command -v python3 >/dev/null; then
            python3 -I - "/dev/$hr" 12 >"$RAW/$hr.txt" 2>&1 <<'PY'
import os, sys, time, select
dev, duration = sys.argv[1], float(sys.argv[2])
fd = os.open(dev, os.O_RDONLY | os.O_NONBLOCK)
t0 = time.time(); n = 0
print("# time(s)  length  bytes(hex)")
while time.time() - t0 < duration:
    r, _, _ = select.select([fd], [], [], 0.2)
    if not r:
        continue
    try:
        d = os.read(fd, 4096)
    except BlockingIOError:
        continue
    n += 1
    print("%8.3f  %3d  %s" % (time.time() - t0, len(d), d.hex(" ")))
print("# total reports: %d" % n)
PY
        else
            timeout 12 cat "/dev/$hr" | od -An -tx1 -v >"$RAW/$hr.txt" 2>&1
        fi
        echo "    saved: $(grep -c . "$RAW/$hr.txt") lines"
    done
fi

# What libinput thinks about the touchpad.
command -v libinput >/dev/null && run 10-libinput.txt libinput list-devices

# -----------------------------------------------------------------------------
say "Packaging"
# -----------------------------------------------------------------------------
TAR="$REAL_HOME/touchpad-report-$STAMP.tar.gz"
tar -C "$REAL_HOME" -czf "$TAR" "touchpad-report-$STAMP"
chown -R "$REAL_USER": "$OUT" "$TAR" 2>/dev/null

echo
echo "=========================================================="
echo " Done! Report: $TAR"
echo "=========================================================="
echo " If you're on a Live USB, copy this file to a USB stick now"
echo " — it gets wiped on reboot."
echo
echo " Quick summary:"
for c in "${TP_CLIENTS[@]:-}"; do
    [ -n "$c" ] && echo "   touchpad : $(basename "$c")  ->  $(dirname "$c" | xargs basename)"
done
if [ -r "$AD/touchpad-summary.txt" ]; then
    grep -oE 'I2cSerialBusV2 \(0x[0-9A-Fa-f]+, [A-Za-z]+, 0x[0-9A-Fa-f]+' \
        "$AD/touchpad-summary.txt" | sort -u | sed 's/^/   ACPI       : /'
    grep -A3 -E 'GpioInt' "$AD/touchpad-summary.txt" | grep -oE '0x[0-9A-Fa-f]{4}' \
        | sort -u | head -5 | sed 's/^/   GPIO pin   : /'
fi
echo
