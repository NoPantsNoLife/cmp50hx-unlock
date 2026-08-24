#!/usr/bin/env bash
# Idle clock governor for unlocked CMP cards.
#
# Why this exists: the card does not lower its own clock request. Measured on
# CMP 50HX (2026-08-24) it sits at P0/1920 MHz/62-64 W at 0 % utilisation
# indefinitely, and even an explicit min,max range lock is resolved to the
# maximum. The one lever the firmware does honour from the host is a hard
# clock ceiling, which drops the card to P3/300 MHz/32.4 W.
#
# So this supervisor supplies that ceiling automatically: clamp after a
# debounce of idle polls, release the moment work appears.
#
# All state is runtime-only. Stopping the service releases every clamp, and a
# reboot clears clock locks regardless.
#
# Tunables (environment, or systemd drop-in):
#   CMP_IDLE_CLOCK   MHz ceiling while idle. Default: each GPU's lowest
#                    supported graphics clock, auto-detected.
#   CMP_POLL         seconds between samples (default 5). This is also the
#                    worst-case delay before a new job gets full clocks.
#   CMP_IDLE_AFTER   consecutive idle polls before clamping (default 6).
#   CMP_UTIL         utilisation percent still counted as idle (default 5).
#   CMP_LOAD_CLOCK   what to restore when work appears, as "MIN,MAX" or a
#                    single MHz value. Unset (default) means reset the lock
#                    entirely. Set this to the clock range your tuning profile
#                    uses, so the governor hands the card back in that state
#                    instead of clearing it -- see "interaction with
#                    cmp50-vfctl" in README.md.
#
# Usage: cmp-idle-governor.sh            run the governor
#        cmp-idle-governor.sh --release  release every GPU and exit
set -u

POLL="${CMP_POLL:-5}"
IDLE_AFTER="${CMP_IDLE_AFTER:-6}"
UTIL_THRESHOLD="${CMP_UTIL:-5}"
LOAD_CLOCK="${CMP_LOAD_CLOCK:-}"

log() { printf '%s cmp-idle-governor: %s\n' "$(date -Is)" "$*"; }

command -v nvidia-smi >/dev/null || { log "nvidia-smi not found"; exit 1; }

# Only CMP cards are managed. A box can hold a display card or another
# accelerator, and clamping those is not wanted. Override with CMP_GPUS as a
# comma-separated index list if you need to.
# nvidia-smi reports pci.device_id as 0xDDDDVVVV (device, then vendor).
SUPPORTED_PCI_IDS="0x1E0910DE 0x220D10DE"   # CMP 50HX, CMP 90HX

select_gpus() {
    if [[ -n "${CMP_GPUS:-}" ]]; then
        tr ',' ' ' <<< "${CMP_GPUS}"
        return
    fi
    while IFS=', ' read -r idx pciid; do
        [[ -n "${idx:-}" && -n "${pciid:-}" ]] || continue
        for want in ${SUPPORTED_PCI_IDS}; do
            if [[ "${pciid^^}" == "${want^^}" ]]; then
                printf '%s
' "$idx"
                break
            fi
        done
    done < <(nvidia-smi --query-gpu=index,pci.device_id                         --format=csv,noheader,nounits)
}

mapfile -t GPUS < <(select_gpus)
if [[ ${#GPUS[@]} -eq 0 ]]; then
    log "no supported CMP card found (CMP 50HX / CMP 90HX); nothing to manage"
    exit 0
fi

# Lowest supported graphics clock for this GPU, so the same unit works on a
# 50HX (300 MHz) and on any other card without hardcoding a model.
detect_idle_clock() {
    local idx="$1" v
    v="$(nvidia-smi -i "$idx" -q -d SUPPORTED_CLOCKS 2>/dev/null \
         | awk '/Graphics/ {print $3}' | sort -n | head -1)"
    if [[ "${v}" =~ ^[0-9]+$ && "${v}" -gt 0 ]]; then
        printf '%s' "${v}"
    else
        printf '300'
    fi
}

# Hand the card back to whatever should own its clocks: an explicit tuning
# range if one was configured, otherwise no lock at all. Never leave a GPU
# clamped at the idle ceiling.
release_gpu() {
    local idx="$1"
    if [[ -n "${LOAD_CLOCK}" ]]; then
        nvidia-smi -i "$idx" -lgc "${LOAD_CLOCK}" >/dev/null 2>&1
    else
        nvidia-smi -i "$idx" -rgc >/dev/null 2>&1
    fi
}

# --release: used by the unit's ExecStopPost as a safety net, so a killed
# governor never leaves the card stuck at its idle ceiling.
if [[ "${1:-}" == "--release" ]]; then
    for g in "${GPUS[@]}"; do
        release_gpu "$g" && log "GPU $g: released (--release)"
    done
    exit 0
fi

declare -A idle_count state clamp_mhz
for g in "${GPUS[@]}"; do
    idle_count["$g"]=0
    state["$g"]=free
    clamp_mhz["$g"]="${CMP_IDLE_CLOCK:-$(detect_idle_clock "$g")}"
    log "GPU $g: idle ceiling ${clamp_mhz[$g]} MHz"
done
log "managing CMP GPU indices: ${GPUS[*]} (clamp after $((POLL * IDLE_AFTER))s idle${LOAD_CLOCK:+, restoring ${LOAD_CLOCK} MHz on load})"

release_all() {
    for g in "${GPUS[@]}"; do
        [[ "${state[$g]:-free}" == clamped ]] || continue
        release_gpu "$g" && log "GPU $g: released on exit"
    done
    exit 0
}
trap release_all TERM INT EXIT

while true; do
    while IFS=', ' read -r idx util; do
        [[ -n "${idx:-}" && -n "${util:-}" ]] || continue
        [[ -n "${state[$idx]+x}" ]] || continue
        if [[ "$util" -le "$UTIL_THRESHOLD" ]]; then
            idle_count["$idx"]=$(( idle_count[$idx] + 1 ))
            if [[ "${state[$idx]}" == free
                  && "${idle_count[$idx]}" -ge "$IDLE_AFTER" ]]; then
                if nvidia-smi -i "$idx" -lgc "${clamp_mhz[$idx]}" \
                        >/dev/null 2>&1; then
                    state["$idx"]=clamped
                    log "GPU $idx: idle, clamped to ${clamp_mhz[$idx]} MHz"
                else
                    log "GPU $idx: clamp failed"
                fi
            fi
        else
            idle_count["$idx"]=0
            if [[ "${state[$idx]}" == clamped ]]; then
                if release_gpu "$idx"; then
                    state["$idx"]=free
                    log "GPU $idx: busy (${util}%), released to full clocks"
                else
                    log "GPU $idx: release failed"
                fi
            fi
        fi
    done < <(nvidia-smi --query-gpu=index,utilization.gpu \
                        --format=csv,noheader,nounits)
    sleep "$POLL"
done
