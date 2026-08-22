#!/usr/bin/env bash
# Rebuild the initramfs with the patched CMP 50HX modules (Ubuntu/Debian).
# Run this AFTER install.sh and AFTER you confirmed the card works:
# the module must be verified good before it is made boot-persistent.
#
#   sudo install-initramfs.sh             backup + rebuild + verify
#   sudo install-initramfs.sh --rollback  restore the newest backup
set -Eeuo pipefail

krel="$(uname -r)"
image=''
for candidate in "/boot/initrd.img-${krel}" "/boot/initramfs.img-${krel}"; do
    [[ -e "${candidate}" ]] && image="${candidate}"
done

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'die "failed at line ${LINENO}"' ERR
[[ ${EUID} -eq 0 ]] || die "run as root (sudo)"

if [[ "${1:-}" == "--rollback" ]]; then
    [[ -n "${image}" ]] || die "no initramfs image found for kernel ${krel}"
    backup="$(ls -1t "${image}".cmp50-bak-* 2>/dev/null | head -n 1 || true)"
    [[ -n "${backup}" ]] || die "no backup found for ${image}"
    cp -a "${backup}" "${image}"
    log "restored ${image} from ${backup}"
    log "reboot to use the restored initramfs"
    exit 0
fi
[[ -z "${1:-}" ]] || die "unknown option: ${1} (only --rollback is supported)"

[[ -n "${image}" ]] || die "no initramfs image found for kernel ${krel}"
command -v update-initramfs >/dev/null || die "update-initramfs not found; only Ubuntu/Debian are supported"
ours="/lib/modules/${krel}/updates/nvidia.ko"
[[ -f "${ours}" ]] || die "patched module ${ours} not found; run install.sh first"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
backup="${image}.cmp50-bak-${ts}"
cp -a "${image}" "${backup}"
log "backup: ${backup}"
ls -1t "${image}".cmp50-bak-* 2>/dev/null | tail -n +4 | xargs -r rm -f --

log "rebuilding initramfs for ${krel}"
update-initramfs -u -k "${krel}"

# --- verify what actually went into the image -------------------------------

module_hash() {
    case "$1" in
        *.zst) unzstd -c "$1" 2>/dev/null | sha256sum ;;
        *.xz)  xz -dc "$1" 2>/dev/null | sha256sum ;;
        *)     sha256sum "$1" ;;
    esac
}

status="no nvidia module is inside the initramfs; the patched module loads from disk at boot"
if command -v unmkinitramfs >/dev/null 2>&1; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp}"' EXIT
    unmkinitramfs "${image}" "${tmp}"

    declare -A installed_hashes=()
    for ko in /lib/modules/"${krel}"/updates/nvidia*.ko; do
        [[ -e "${ko}" ]] || continue
        installed_hashes["$(basename "${ko}")"]="$(sha256sum "${ko}" | awk '{print $1}')"
    done

    found=0
    bad=0
    while IFS= read -r -d '' mod; do
        found=1
        name="$(basename "${mod}")"
        name="${name%.zst}"; name="${name%.xz}"
        img_hash="$(module_hash "${mod}" | awk '{print $1}')"
        if [[ "${installed_hashes[${name}]:-}" == "${img_hash}" ]]; then
            log "verified: ${name} in the initramfs matches the patched module"
        else
            log "MISMATCH: ${name} in the initramfs is NOT the patched module"
            bad=1
        fi
    done < <(find "${tmp}" -name 'nvidia.ko*' -print0)
    if [[ ${found} -eq 0 ]]; then
        log "INFO: ${status}"
    elif [[ ${bad} -ne 0 ]]; then
        die "initramfs contains a wrong nvidia module; restore with: $0 --rollback"
    fi

    if find "${tmp}" -name 'nouveau.ko*' | grep -q . \
            && ! grep -rq 'nouveau' "${tmp}"/*/etc/modprobe.d 2>/dev/null; then
        log "WARNING: nouveau is in the initramfs without a blacklist; it may grab the card at early boot"
    fi
else
    log "WARNING: unmkinitramfs not found; could not verify the image content"
fi

cat <<EOF

PASS_CMP50HX_INITRAMFS
Reboot now. After reboot, verify with:
  /opt/cmp50hx-unlock/artifacts/610.43.03-${krel}/rm-issue-rate 0
Rollback:
  sudo $0 --rollback
EOF
