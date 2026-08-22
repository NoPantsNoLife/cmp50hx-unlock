#!/usr/bin/env bash
# CMP 50HX (10de:1e09) all-feature installer for Ubuntu/Debian.
#
#   curl -fsSL https://raw.githubusercontent.com/xrip/cmp50hx-unlock/master/install.sh | sudo bash
#
# What it does, in order:
#   1. installs build tools and kernel headers
#   2. installs the NVIDIA 610.43.03 userland from the official .run package
#   3. builds the patched kernel modules for the running kernel (build.sh)
#   4. installs the modules with a backup of any previous ones, runs depmod
#   5. best-effort live check of the card
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

[[ ${EUID} -eq 0 ]] || die "run as root (sudo)"
[[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
    *" ubuntu "*|*" debian "*|*" linuxmint "*) ;;
    *) die "only Ubuntu/Debian and their derivatives are supported (this system is ${ID:-unknown})" ;;
esac

# --- 1. system checks -------------------------------------------------------

cmp_subsystem=''
for dev in /sys/bus/pci/devices/*/; do
    [[ -r "${dev}vendor" && -r "${dev}device" ]] || continue
    read -r vendor < "${dev}vendor"
    read -r device < "${dev}device"
    [[ "${vendor}" == "0x10de" && "${device}" == "0x1e09" ]] || continue
    read -r sv < "${dev}subsystem_vendor"
    read -r sd < "${dev}subsystem_device"
    cmp_subsystem="${sv}:${sd}"
done
[[ -n "${cmp_subsystem}" ]] || die "no CMP 50HX (10de:1e09) found on the PCI bus"
case "${cmp_subsystem}" in
    0x10de:0x1554|0x1462:0x371f)
        log "found CMP 50HX 10de:1e09 subsystem ${cmp_subsystem} (tested board)" ;;
    *)
        log "WARNING: subsystem ${cmp_subsystem} is not a tested board (tested: 10de:1554, 1462:371f); continuing" ;;
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
apt-get install -y build-essential curl patch xz-utils kmod binutils ca-certificates mokutil lsb-release
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
log "CMP 50HX install start: driver ${driver_version}, kernel ${krel}, subsystem ${cmp_subsystem}"

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
    log "building the patched modules for kernel ${krel} (this can take a while)"
    (cd "${install_dir}" && KERNEL_RELEASE="${krel}" bash build.sh)
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

printf 'options nvidia cmp50_rebar_size=8\n' > /etc/modprobe.d/cmp50hx-unlock.conf
depmod -a "${krel}"

[[ "$(modinfo -F version nvidia)" == "${driver_version}" ]] || die "installed nvidia.ko has the wrong version"
[[ "$(modinfo -F vermagic nvidia)" == "${krel} "* ]] || die "installed nvidia.ko has the wrong vermagic"

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
    log "loaded nvidia; running the verifier"
    command -v nvidia-modprobe >/dev/null 2>&1 && nvidia-modprobe -c 0 -u || true
    if timeout 180 "${artifact_dir}/rm-issue-rate"; then
        live_check="PASS_CMP50HX_ISSUE_RATE_AND_COUNTS"
    else
        live_check="FAILED (see output above; a first warm load can fail, reboot usually fixes it)"
    fi
fi

# --- summary ----------------------------------------------------------------

exec 1>&3 2>&4
[[ -d "${backup_dir}" ]] || backup_dir="(none; fresh system)"
cat <<EOF

PASS_CMP50HX_INSTALL
Modules    : /lib/modules/${krel}/updates/nvidia*.ko (patched ${driver_version})
Repository : ${install_dir}
Log        : ${install_dir}/logs/install-${ts}.log
Live check : ${live_check}

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
