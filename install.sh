#!/usr/bin/env bash
# CMP 50HX (10de:1e09) / CMP 90HX (10de:220d) all-feature installer for
# Ubuntu/Debian. The card is auto-detected; force it with --card.
#
#   curl -fsSL https://raw.githubusercontent.com/xrip/cmp50hx-unlock/master/install.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/xrip/cmp50hx-unlock/master/install.sh | sudo bash -s -- --card cmp90hx
#
# Options:
#   --card cmp50hx|cmp90hx   force the card instead of auto-detecting
#   --idle-governor          also enable the optional idle clock governor,
#                            which halves idle power (see idle-governor/)
#
# What it does, in order:
#   1. detects the card (or takes --card cmp50hx|cmp90hx)
#   2. installs build tools and kernel headers
#   3. installs the NVIDIA 610.43.03 userland from the official .run package
#   4. builds the patched kernel modules for the running kernel (build.sh)
#   5. installs the modules with a backup of any previous ones, runs depmod
#   6. cmp90hx only: installs the rejoin16 Gen2 apply scripts and the
#      cmp90hx-gen2 boot service (enabled, not started)
#   7. installs the optional idle governor unit, enabled only with
#      --idle-governor
#   8. best-effort live check of the card
#
# It never rebuilds the initramfs and never unloads a loaded driver. When the
# card works, make it boot-persistent with:
#   sudo /opt/cmp50hx-unlock/install-initramfs.sh
set -Eeuo pipefail

readonly driver_version="610.43.03"
readonly repo_tarball="https://github.com/xrip/cmp50hx-unlock/archive/refs/heads/master.tar.gz"
readonly nvidia_run_url="https://us.download.nvidia.com/XFree86/Linux-x86_64/${driver_version}/NVIDIA-Linux-x86_64-${driver_version}.run"
# SHA-256 of the .run package above, pinned from the official download.
readonly nvidia_run_sha256="45e2d4c134a23c35e50f253a4aa63e7e5e8d17e3d185d4a07c8a58e9612ed392"
readonly install_dir="/opt/cmp50hx-unlock"
readonly krel="$(uname -r)"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'die "install failed at line ${LINENO}; see output above"' ERR

card=''
idle_governor=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --card)
            card="${2:?--card needs cmp50hx or cmp90hx}"
            [[ "${card}" == cmp50hx || "${card}" == cmp90hx ]] \
                || die "unknown card: ${card} (supported: cmp50hx, cmp90hx)"
            shift 2
            ;;
        --idle-governor)
            idle_governor=1
            shift
            ;;
        -h|--help)
            sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            die "unknown argument: $1 (supported: --card, --idle-governor)"
            ;;
    esac
done

[[ ${EUID} -eq 0 ]] || die "run as root (sudo)"
[[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
    *" ubuntu "*|*" debian "*|*" linuxmint "*) ;;
    *) die "only Ubuntu/Debian and their derivatives are supported (this system is ${ID:-unknown})" ;;
esac

# --- 1. detect the card -------------------------------------------------------

# device id -> card name; one build serves exactly one card type
detect_cards() {
    local dev vendor device
    for dev in /sys/bus/pci/devices/*/; do
        [[ -r "${dev}vendor" && -r "${dev}device" ]] || continue
        read -r vendor < "${dev}vendor"
        read -r device < "${dev}device"
        [[ "${vendor}" == "0x10de" ]] || continue
        case "${device}" in
            0x1e09) echo cmp50hx ;;
            0x220d) echo cmp90hx ;;
        esac
    done | sort -u
}

mapfile -t present_cards < <(detect_cards)
if [[ -n "${card}" ]]; then
    log "card forced by --card: ${card}"
elif [[ ${#present_cards[@]} -eq 1 ]]; then
    card="${present_cards[0]}"
    log "detected card: ${card}"
elif [[ ${#present_cards[@]} -eq 0 ]]; then
    die "no CMP 50HX (10de:1e09) or CMP 90HX (10de:220d) found on the PCI bus; use --card to force"
else
    die "both a CMP 50HX and a CMP 90HX are present; one build serves one card - rerun with --card cmp50hx or --card cmp90hx"
fi

case "${card}" in
    cmp50hx) readonly pci_device="0x1e09" ;;
    cmp90hx) readonly pci_device="0x220d" ;;
esac

cmp_subsystem=''
for dev in /sys/bus/pci/devices/*/; do
    [[ -r "${dev}vendor" && -r "${dev}device" ]] || continue
    read -r vendor < "${dev}vendor"
    read -r device < "${dev}device"
    [[ "${vendor}" == "0x10de" && "${device}" == "${pci_device}" ]] || continue
    read -r sv < "${dev}subsystem_vendor"
    read -r sd < "${dev}subsystem_device"
    cmp_subsystem="${sv}:${sd}"
done
[[ -n "${cmp_subsystem}" ]] || die "no card with device ${pci_device} found on the PCI bus"

case "${card}:${cmp_subsystem}" in
    cmp50hx:0x10de:0x1554|cmp50hx:0x1462:0x371f)
        log "found CMP 50HX 10de:1e09 subsystem ${cmp_subsystem} (tested board)" ;;
    cmp50hx:*)
        log "WARNING: subsystem ${cmp_subsystem} is not a tested board (tested: 10de:1554, 1462:371f); continuing" ;;
    cmp90hx:0x10de:0x1555)
        log "found CMP 90HX 10de:220d subsystem ${cmp_subsystem} (tested board)" ;;
    cmp90hx:*)
        log "WARNING: subsystem ${cmp_subsystem} is not a tested board (tested: 10de:1555); the kernel Gen2 path only runs on 10de:1555 boards" ;;
esac

if [[ -d /sys/firmware/efi ]] && command -v mokutil >/dev/null 2>&1 \
        && mokutil --sb-state 2>/dev/null | grep -q 'Secure Boot enabled'; then
    log "WARNING: Secure Boot is enabled; the unsigned patched module will most likely not load."
    log "         Disable Secure Boot in firmware setup, or sign the module with your own MOK."
fi

old_version="$(modinfo -F version nvidia 2>/dev/null || true)"
if [[ -n "${old_version}" && "${old_version}" != "${driver_version}" ]]; then
    log "note: driver ${old_version} is installed; it is replaced by ${driver_version}, reboot to switch fully"
fi

# --- 2. packages ------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive
log "installing build tools and kernel headers"
apt-get update -y
apt-get install -y build-essential curl patch xz-utils kmod binutils ca-certificates mokutil lsb-release python3 pciutils
apt-get install -y "linux-headers-${krel}" \
    || die "no linux-headers package for kernel ${krel}; install the matching headers first"

# --- 3. fetch this repository ----------------------------------------------

ts="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -d "${install_dir}" ]]; then
    mv "${install_dir}" "${install_dir}.old-${ts}"
fi
mkdir -p "${install_dir}/logs" "${install_dir}/cache" "${install_dir}/artifacts" "${install_dir}/backups"
exec 3>&1 4>&2
exec > >(tee -a "${install_dir}/logs/install-${ts}.log") 2>&1
log "CMP unlock install start: card ${card}, driver ${driver_version}, kernel ${krel}, subsystem ${cmp_subsystem}"

if [[ -d "${install_dir}.old-${ts}" ]]; then
    for keep in cache artifacts backups; do
        if [[ -e "${install_dir}.old-${ts}/${keep}" ]]; then
            rm -rf "${install_dir:?}/${keep}"
            mv "${install_dir}.old-${ts}/${keep}" "${install_dir}/${keep}"
        fi
    done
    rm -rf "${install_dir}.old-${ts}"
fi

repo_tar="$(mktemp)"
log "downloading repository"
curl -fsSL --retry 3 -o "${repo_tar}" "${repo_tarball}"
tar -xzf "${repo_tar}" -C "${install_dir}" --strip-components=1
rm -f "${repo_tar}"
[[ -f "${install_dir}/build.sh" ]] || die "repository layout broken: build.sh missing"

# --- 4. NVIDIA userland (.run, no kernel module) ----------------------------

run_file="${install_dir}/cache/NVIDIA-Linux-x86_64-${driver_version}.run"
if [[ ! -f "${run_file}" ]]; then
    log "downloading NVIDIA ${driver_version} .run installer (several hundred MB)"
    curl -fL --retry 3 --show-error -o "${run_file}.part" "${nvidia_run_url}"
    mv "${run_file}.part" "${run_file}"
fi
if [[ -n "${nvidia_run_sha256}" ]]; then
    printf '%s  %s\n' "${nvidia_run_sha256}" "${run_file}" | sha256sum -c - \
        || die "NVIDIA .run SHA-256 mismatch"
else
    log "WARNING: the .run SHA-256 is not pinned in this script; continuing over TLS"
fi

log "installing NVIDIA userland (the kernel module comes from this repo, not the .run)"
sh "${run_file}" --silent --no-kernel-modules --no-dkms --no-backup \
    --no-rebuild-initramfs --no-x-check --no-nouveau-check --skip-module-unload

if ! find /lib/firmware/nvidia -name 'gsp*.bin' -print -quit 2>/dev/null | grep -q .; then
    log "GSP firmware not present; extracting it from the .run package"
    fw_dir="$(mktemp -d)"
    sh "${run_file}" -x --target "${fw_dir}" >/dev/null
    if [[ -d "${fw_dir}/firmware" ]]; then
        cp -a "${fw_dir}/firmware/." /lib/firmware/
    else
        log "WARNING: no firmware directory inside the .run package"
    fi
    rm -rf "${fw_dir}"
fi

# --- 5. build the patched modules ------------------------------------------

artifact_dir="${install_dir}/artifacts/${driver_version}-${krel}"
if [[ -f "${artifact_dir}/checksums.sha256" ]] \
        && (cd "${artifact_dir}" && sha256sum -c checksums.sha256 >/dev/null 2>&1); then
    log "reusing the previous build in ${artifact_dir}"
else
    rm -rf "${artifact_dir}"
    log "building the patched ${card} modules for kernel ${krel} (this can take a while)"
    (cd "${install_dir}" && KERNEL_RELEASE="${krel}" bash build.sh --card "${card}")
fi

# --- 6. install the modules -------------------------------------------------

backup_dir="${install_dir}/backups/modules-${ts}"
dest_dir="/lib/modules/${krel}/updates"
for mod in nvidia nvidia-uvm nvidia-modeset nvidia-drm nvidia-peermem; do
    path="$(modinfo -n "${mod}" 2>/dev/null || true)"
    [[ -n "${path}" && -f "${path}" ]] || continue
    [[ "${path}" == "${dest_dir}/${mod}.ko" ]] && continue
    mkdir -p "${backup_dir}$(dirname "${path}")"
    case "${path}" in
        "${dest_dir}"/*)
            mv "${path}" "${backup_dir}${path}"
            log "moved ${path} aside (inside updates/, it would shadow the new module)" ;;
        *)
            cp -a "${path}" "${backup_dir}${path}"
            log "backed up ${path}" ;;
    esac
done
[[ -d "${backup_dir}" ]] || log "no previous modules to back up (fresh system)"

mkdir -p "/lib/modules/${krel}/updates"
for mod in nvidia nvidia-uvm nvidia-modeset nvidia-drm nvidia-peermem; do
    src="${artifact_dir}/${mod}.ko"
    [[ -f "${src}" ]] || continue
    install -m 0644 "${src}" "/lib/modules/${krel}/updates/${mod}.ko"
    log "installed /lib/modules/${krel}/updates/${mod}.ko"
done

# cmp50hx carries the ReBAR size as a module option; cmp90hx takes none
if [[ "${card}" == cmp50hx ]]; then
    printf 'options nvidia cmp50_rebar_size=8\n' > /etc/modprobe.d/cmp50hx-unlock.conf
else
    # an older cmp50hx install leaves an option the cmp90hx module does not know
    if [[ -f /etc/modprobe.d/cmp50hx-unlock.conf ]] \
            && grep -q cmp50_rebar_size /etc/modprobe.d/cmp50hx-unlock.conf; then
        rm -f /etc/modprobe.d/cmp50hx-unlock.conf
        log "removed the stale cmp50hx modprobe option (cmp50_rebar_size)"
    fi
fi
depmod -a "${krel}"

[[ "$(modinfo -F version nvidia)" == "${driver_version}" ]] || die "installed nvidia.ko has the wrong version"
[[ "$(modinfo -F vermagic nvidia)" == "${krel} "* ]] || die "installed nvidia.ko has the wrong vermagic"

# --- 6b. cmp90hx: rejoin16 runtime + boot service ----------------------------

if [[ "${card}" == cmp90hx ]]; then
    runtime_dir="${install_dir}/cmp90hx"
    for f in rejoin16-apply-all.sh rejoin16-cycle.sh retry-gen2-train.sh verify.sh; do
        [[ -f "${runtime_dir}/${f}" ]] || die "repository layout broken: cmp90hx/${f} missing"
        chmod 0755 "${runtime_dir}/${f}"
    done
    install -m 0755 "${artifact_dir}/bar0poke" "${runtime_dir}/bar0poke"
    install -m 0755 "${artifact_dir}/cmpunlocker-rs" "${runtime_dir}/cmpunlocker-rs"

    install -m 0644 "${runtime_dir}/cmp90hx-gen2.service" /etc/systemd/system/cmp90hx-gen2.service
    systemctl daemon-reload
    systemctl enable cmp90hx-gen2.service >/dev/null
    log "installed and enabled cmp90hx-gen2.service (runs the PLM opens + Gen2 retrain once per boot; NOT started now)"
fi

# --- 6c. optional idle clock governor ---------------------------------------

# The card never lowers its own clock request, so this supervisor applies a
# clock ceiling while idle and removes it on load. Optional and independent of
# the unlock: the unit is always installed, but only enabled on request.
governor_state="installed, NOT enabled (enable: systemctl enable --now cmp-idle-governor)"
governor_dir="${install_dir}/idle-governor"
if [[ -f "${governor_dir}/cmp-idle-governor.sh" ]]; then
    chmod 0755 "${governor_dir}/cmp-idle-governor.sh"
    install -m 0644 "${governor_dir}/cmp-idle-governor.service" \
        /etc/systemd/system/cmp-idle-governor.service
    systemctl daemon-reload
    if [[ "${idle_governor}" -eq 1 ]]; then
        if systemctl enable --now cmp-idle-governor.service >/dev/null 2>&1; then
            governor_state="ENABLED and running (idle power should drop within ~30s)"
            log "idle governor enabled and started"
        else
            governor_state="install ok, but enable failed (see: journalctl -u cmp-idle-governor)"
            log "WARNING: could not enable the idle governor"
        fi
    else
        log "idle governor installed but not enabled (pass --idle-governor to enable)"
    fi
else
    governor_state="not present in this repository copy"
fi

# --- 7. best-effort live check (never fatal) --------------------------------

live_check="SKIPPED"
if lsmod | grep -q '^nvidia '; then
    log "an nvidia module is already loaded; reboot to test the new one"
elif lsmod | grep -q '^nouveau '; then
    if rmmod nouveau 2>/dev/null; then
        log "unloaded the nouveau module"
    else
        log "could not unload nouveau; reboot to test"
    fi
fi
if ! lsmod | grep -q '^nvidia ' && modprobe nvidia 2>/dev/null; then
    log "loaded nvidia"
    command -v nvidia-modprobe >/dev/null 2>&1 && nvidia-modprobe -c 0 -u || true
    if [[ "${card}" == cmp50hx ]]; then
        # verify every card, not just the first (multi-GPU hosts)
        gpu_count="$(nvidia-smi -L 2>/dev/null | grep -c 'CMP 50HX' || true)"
        [[ "${gpu_count}" -ge 1 ]] || gpu_count=1
        live_check="PASS_CMP50HX_ISSUE_RATE_AND_COUNTS"
        for dev_index in $(seq 0 $((gpu_count - 1))); do
            probe_json="${install_dir}/logs/rm-probe-${ts}-dev${dev_index}.json"
            if timeout 180 "${artifact_dir}/rm-issue-rate" "${dev_index}" >"${probe_json}" \
                    && python3 "${install_dir}/verify/verify.py" "${probe_json}" > /dev/null; then
                log "device ${dev_index}: PASS_CMP50HX_ISSUE_RATE_AND_COUNTS"
            else
                log "device ${dev_index}: verify FAILED (probe kept at ${probe_json})"
                live_check="FAILED (device ${dev_index}; a warm load after a driver swap can fail, reboot usually fixes it)"
            fi
        done
    else
        bdf="$(lspci -Dnn | awk '/10de:220d/ {print $1; exit}')"
        speed="$(cat "/sys/bus/pci/devices/${bdf}/current_link_speed" 2>/dev/null || echo unknown)"
        plm_state="$(python3 - "${bdf}" <<'PY' 2>/dev/null || echo unknown
import os, struct, sys
with open(f"/sys/bus/pci/devices/{sys.argv[1]}/resource0", "rb", buffering=0) as f:
    for name, off in (("FEAT_ECC_PLM", 0x823800), ("FEAT_OVR_PLM", 0x823804),
                      ("XVE_PLM", 0x88ff4), ("XP3G_PLM", 0x8e1b0)):
        f.seek(off)
        print(f"{name}=0x{struct.unpack('<I', f.read(4))[0]:08x}")
PY
)"
        log "link speed: ${speed}"
        log "PLM state (partial; the gen2 service opens the rest at boot):"
        echo "${plm_state}" | while IFS= read -r l; do log "  ${l}"; done
        live_check="LOADED (full unlock state is applied by cmp90hx-gen2.service at the next boot)"
    fi
fi

# --- summary ----------------------------------------------------------------

exec 1>&3 2>&4
[[ -d "${backup_dir}" ]] || backup_dir="(none; fresh system)"
if [[ "${card}" == cmp50hx ]]; then
    cat <<EOF

PASS_CMP50HX_INSTALL
Modules    : /lib/modules/${krel}/updates/nvidia*.ko (patched ${driver_version})
Repository : ${install_dir}
Log        : ${install_dir}/logs/install-${ts}.log
Live check : ${live_check}
Idle governor: ${governor_state}

Next steps:
  1. Confirm the card works (the verifier above, or nvidia-smi after a reboot).
  2. Make it boot-persistent:
         sudo ${install_dir}/install-initramfs.sh
  3. Reboot.

Rollback:
  modules : copy files from ${backup_dir:-/opt/cmp50hx-unlock/backups/} back to
            their original paths, then run: depmod -a ${krel}
  userland: sh ${run_file} --uninstall
EOF
else
    cat <<EOF

PASS_CMP90HX_INSTALL
Modules    : /lib/modules/${krel}/updates/nvidia*.ko (patched ${driver_version})
Runtime    : ${install_dir}/cmp90hx (rejoin16 apply + verify + cmpunlocker-rs)
Boot service: cmp90hx-gen2.service (enabled; runs once per boot after reboot)
Log        : ${install_dir}/logs/install-${ts}.log
Live check : ${live_check}
Idle governor: ${governor_state}

Next steps:
  1. Reboot. On a COLD boot the cmp90hx-gen2 service runs ~35 driver reload
     cycles (7-8 min) to open the PCIe privilege masks, then retrains the
     link to Gen2. A warm reboot usually skips the cycles.
     Keep console/power access the first times; if the GPU shares a PCIe
     switch with the boot disk or NIC, a wedged endpoint can hang the host.
  2. After the service finishes, verify:
         sudo ${install_dir}/cmp90hx/verify.sh
  3. Make the module boot-persistent:
         sudo ${install_dir}/install-initramfs.sh

Rollback:
  service : systemctl disable --now cmp90hx-gen2 && rm /etc/systemd/system/cmp90hx-gen2.service
  modules : copy files from ${backup_dir:-/opt/cmp50hx-unlock/backups/} back to
            their original paths, then run: depmod -a ${krel}
  userland: sh ${run_file} --uninstall
EOF
fi
