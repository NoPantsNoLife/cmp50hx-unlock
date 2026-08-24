#!/usr/bin/env bash
# Post-reboot verification for the CMP 90HX unlock (compute + PCIe Gen2).
# Safe to re-run at any time; it only reads state.
#
# Passes when: the patched module is live, the rejoin16 PLM set is open,
# the link is at 5.0 GT/s on both ends, and (when cmpunlocker-rs is present,
# installed from the pearlfortune bundle) the compute unlock verifies full.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ART="${CMP90_ARTIFACT:-${SCRIPT_DIR}/../artifacts/610.43.03-$(uname -r)}"
BIN="${SCRIPT_DIR}/cmpunlocker-rs"
LOG="${SCRIPT_DIR}/verify-90hx.log"
driver_version="610.43.03"

exec > >(tee "${LOG}") 2>&1

echo "=============================================="
echo " CMP 90HX unlock verification  $(date -Is)"
echo "=============================================="

fail=0
note() { echo "NOTE: $*"; }
bad()  { echo "FAIL: $*"; fail=1; }

echo
echo "--- 1. kernel / driver ---"
echo "kernel        : $(uname -r)"
echo "nvidia version: $(modinfo -F version nvidia 2>/dev/null)"
echo "nvidia path   : $(modinfo -n nvidia 2>/dev/null)"

[[ "$(modinfo -F version nvidia 2>/dev/null)" == "${driver_version}" ]] \
    || bad "installed nvidia module is not ${driver_version}"
if modinfo -n nvidia 2>/dev/null | grep -q "/updates/nvidia.ko"; then
    echo "RESOLUTION    : OK - using the patched updates/ module"
else
    bad "not on the patched updates/ module path"
fi

echo
echo "--- 2. GPU present ---"
nvidia-smi --query-gpu=name,vbios_version,memory.total,power.limit --format=csv 2>&1

BDF="${CMP90_BDF:-$(lspci -Dnn | awk '/10de:220d/ {print $1; exit}')}"
[[ -n "${BDF}" ]] || { echo "FATAL: no CMP 90HX (10de:220d) found; set CMP90_BDF"; exit 2; }

echo
echo "--- 3. unlock state (PLM set + GFX speed select, read-only) ---"
state="$(python3 - "${BDF}" <<'PY'
import os, struct, sys
out = {}
with open(f"/sys/bus/pci/devices/{sys.argv[1]}/resource0", "rb", buffering=0) as f:
    for name, off in (("FEAT_ECC_PLM", 0x823800), ("FEAT_OVR_PLM", 0x823804),
                      ("XVE_PLM", 0x88ff4), ("XP3G_PLM", 0x8e1b0),
                      ("GFX_SPEED_SELECT", 0x823830)):
        f.seek(off)
        out[name] = struct.unpack("<I", f.read(4))[0]
for k, v in out.items():
    print(f"{k} = 0x{v:08x}")
PY
)"
echo "${state}"
echo "${state}" | grep -q 'FEAT_ECC_PLM = 0xffffffff' \
    || bad "FEAT_ECC_PLM not open (Gen2 kernel path stays inactive)"
echo "${state}" | grep -q 'FEAT_OVR_PLM = 0xffffffff' \
    || note "FEAT_OVR_PLM not open; the gen2 service should open it at boot"
echo "${state}" | grep -q 'XVE_PLM = 0xffffffff' \
    || bad "XVE_PLM not open"
echo "${state}" | grep -q 'XP3G_PLM = 0xffffffff' \
    || bad "XP3G_PLM not open"
echo "${state}" | grep -q 'GFX_SPEED_SELECT = 0x00000004' \
    || note "GFX_SPEED_SELECT is not 0x4 (full gfx bin); headless use is unaffected"

echo
echo "--- 4. PCIe link ---"
UPSTREAM="$(basename "$(readlink -f "/sys/bus/pci/devices/${BDF}/..")")"
echo "endpoint  ${BDF}: $(cat "/sys/bus/pci/devices/${BDF}/current_link_speed" 2>/dev/null)"
echo "upstream  ${UPSTREAM}: $(cat "/sys/bus/pci/devices/${UPSTREAM}/current_link_speed" 2>/dev/null)"
[[ "$(cat "/sys/bus/pci/devices/${BDF}/current_link_speed" 2>/dev/null)" == "5.0 GT/s PCIe" ]] \
    || bad "endpoint link is not 5.0 GT/s (Gen2 not active)"
if [[ -r "/sys/bus/pci/devices/${UPSTREAM}/current_link_speed" ]]; then
    [[ "$(cat "/sys/bus/pci/devices/${UPSTREAM}/current_link_speed")" == "5.0 GT/s PCIe" ]] \
        || bad "upstream link is not 5.0 GT/s"
else
    note "no current_link_speed on ${UPSTREAM} (no upstream bridge port); skipping"
fi

echo
echo "--- 5. compute unlock (authoritative, via cmpunlocker-rs) ---"
if [[ -x "${BIN}" ]]; then
    out="$(sudo "${BIN}" compute90hx-v67 verify --all-cmp90hx --expect full 2>&1 || true)"
    echo "${out}" | grep -E '^(PASS|FAIL|error|TARGET)' || echo "(no result lines)"
    echo "${out}" | grep -q '^PASS' || bad "cmpunlocker-rs verify did not report PASS"
else
    bad "cmpunlocker-rs not found at ${BIN} (installed from the pearlfortune bundle)"
fi

echo
if [[ ${fail} -eq 0 ]]; then
    echo "PASS_CMP90HX_ALL_LIVE"
else
    echo "FAILED_CMP90HX_VERIFY (log kept at ${LOG})"
    exit 1
fi
