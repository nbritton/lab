#!/bin/bash
#
# AMD Vega II BAR Resize Script v3 for Mac Pro 7,1
#
# WHAT THIS DOES:
#   The kernel's hot-resize path (resource0_resize sysfs) can't cascade bridge
#   window growth through 5+ bridge levels. So instead we:
#
#   1. Unbind drivers from all GPUs
#   2. Write the rebar CONTROL register directly on each GPU via setpci,
#      changing the hardware BAR size at the PCIe config-space level
#   3. Remove the top-level PCI bridge for each GPU group, which cascade-
#      removes the entire PLX switch + AMD bridge + GPU subtree
#   4. Rescan the PCI bus — the kernel re-enumerates everything from scratch,
#      reads the now-32GB BARs from config space, and allocates correctly-
#      sized bridge windows all the way up the chain
#
# REQUIREMENTS:
#   - Root access
#   - Kernel booted with: pci=realloc
#   - No active GPU workloads
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# GPU BDF addresses
GPU_BDFS=("0000:0b:00.0" "0000:0e:00.0" "0000:1b:00.0" "0000:1e:00.0")
AUDIO_BDFS=("0000:0b:00.1" "0000:0e:00.1" "0000:1b:00.1" "0000:1e:00.1")

# Top-level bridges to remove (each controls one GPU pair via PLX switch)
# Removing these cascade-removes the entire subtree including PLX + AMD bridges + GPUs
TOP_BRIDGES=("0000:06:00.0" "0000:16:00.0")

# Bridge chains for diagnostic display
BRIDGE_CHAIN_BDFS=(
    "0000:06:00.0" "0000:07:00.0" "0000:08:08.0" "0000:09:00.0" "0000:0a:00.0"
    "0000:08:10.0" "0000:0c:00.0" "0000:0d:00.0"
    "0000:16:00.0" "0000:17:00.0" "0000:18:08.0" "0000:19:00.0" "0000:1a:00.0"
    "0000:18:10.0" "0000:1c:00.0" "0000:1d:00.0"
)

# Rebar extended capability offset (pre-determined from diagnostics)
REBAR_CAP_OFFSET=0x200
# Rebar control register = cap_offset + 8
REBAR_CTRL_OFFSET=0x208
# Target BAR size index: 15 = 32 GB  (2^(15+20) = 2^35 = 32 GiB)
TARGET_SIZE_INDEX=15

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

size_index_to_human() {
    local idx=$1
    local bytes=$((1 << (idx + 20)))
    if   (( bytes >= 1073741824 )); then echo "$((bytes / 1073741824)) GB"
    elif (( bytes >= 1048576 ));    then echo "$((bytes / 1048576)) MB"
    else echo "$((bytes / 1024)) KB"
    fi
}

read_rebar_size_index() {
    local bdf=$1
    local ctrl_val
    ctrl_val=$(setpci -s "$bdf" "${REBAR_CTRL_OFFSET}.l" 2>/dev/null) || { echo "-1"; return; }
    echo $(( (16#${ctrl_val} >> 8) & 0x3F ))
}

write_rebar_size_index() {
    local bdf=$1
    local new_index=$2

    # Read current control register
    local ctrl_val
    ctrl_val=$(setpci -s "$bdf" "${REBAR_CTRL_OFFSET}.l" 2>/dev/null) || return 1

    # Clear bits 13:8 (BAR Size field), set to new index
    local current_int=$((16#${ctrl_val}))
    local cleared=$(( current_int & ~0x3F00 ))
    local new_val=$(( cleared | (new_index << 8) ))
    local new_hex
    new_hex=$(printf "%08x" "$new_val")

    setpci -s "$bdf" "${REBAR_CTRL_OFFSET}.l=${new_hex}" 2>/dev/null || return 1

    # Verify
    local readback
    readback=$(read_rebar_size_index "$bdf")
    if (( readback == new_index )); then
        return 0
    else
        return 1
    fi
}

# ---- Phase 1: Diagnostics ----

phase1_diagnose() {
    echo "" >&2
    echo "============================================================" >&2
    echo "  Phase 1: Resizable BAR Diagnostics" >&2
    echo "============================================================" >&2
    echo "" >&2

    if [[ $EUID -ne 0 ]]; then
        log_err "This script must be run as root."
        exit 1
    fi

    if grep -q "pci=realloc" /proc/cmdline; then
        log_ok "Kernel booted with pci=realloc"
    else
        log_err "Kernel NOT booted with pci=realloc — required for bridge window sizing."
        exit 1
    fi

    if ! command -v setpci &>/dev/null; then
        log_err "setpci not found. Install: apt install pciutils"
        exit 1
    fi

    for bdf in "${GPU_BDFS[@]}"; do
        echo "" >&2
        log_info "--- GPU $bdf ---"

        # Current BAR0 size
        if [[ -f "/sys/bus/pci/devices/$bdf/resource" ]]; then
            local resource0
            resource0=$(head -1 "/sys/bus/pci/devices/$bdf/resource")
            local bar_start bar_end bar_size
            bar_start=$(echo "$resource0" | awk '{print $1}')
            bar_end=$(echo "$resource0" | awk '{print $2}')
            bar_size=$(( 16#${bar_end#0x} - 16#${bar_start#0x} + 1 ))
            log_info "BAR0 current size: $(numfmt --to=iec-i --suffix=B "$bar_size" 2>/dev/null || echo "$bar_size bytes")"
        fi

        # Visible VRAM
        local vis_vram
        vis_vram=$(cat "/sys/bus/pci/devices/$bdf/mem_info_vis_vram_total" 2>/dev/null || echo "N/A")
        if [[ "$vis_vram" != "N/A" ]]; then
            log_info "Visible VRAM: $(numfmt --to=iec-i --suffix=B "$vis_vram" 2>/dev/null || echo "$vis_vram bytes")"
        fi

        # Total VRAM
        local total_vram
        total_vram=$(cat "/sys/bus/pci/devices/$bdf/mem_info_vram_total" 2>/dev/null || echo "N/A")
        if [[ "$total_vram" != "N/A" ]]; then
            log_info "Total VRAM:   $(numfmt --to=iec-i --suffix=B "$total_vram" 2>/dev/null || echo "$total_vram bytes")"
        fi

        # Current rebar setting
        local cur_idx
        cur_idx=$(read_rebar_size_index "$bdf")
        if (( cur_idx >= 0 )); then
            log_info "Rebar control register: size index $cur_idx ($(size_index_to_human "$cur_idx"))"
        else
            log_warn "Could not read rebar control register"
        fi
    done

    # Bridge windows
    echo "" >&2
    log_info "Bridge chain prefetchable windows:"
    echo "" >&2
    for bdf in "${BRIDGE_CHAIN_BDFS[@]}"; do
        if [[ -e "/sys/bus/pci/devices/$bdf" ]]; then
            local pref
            pref=$(lspci -vvs "$bdf" 2>/dev/null | grep -i "Prefetchable memory behind" || true)
            if [[ -n "$pref" ]]; then
                echo "    $bdf: $(echo "$pref" | sed 's/.*://' | xargs)" >&2
            fi
        fi
    done
    echo "" >&2
}

# ---- Phase 2: Resize via setpci + remove/rescan ----

phase2_resize() {
    echo "" >&2
    echo "============================================================" >&2
    echo "  Phase 2: Direct Hardware BAR Resize + PCI Subtree Reset" >&2
    echo "============================================================" >&2
    echo "" >&2

    # Step 1: Unbind audio drivers
    log_info "Step 1: Unbinding audio drivers..."
    for bdf in "${AUDIO_BDFS[@]}"; do
        if [[ -e "/sys/bus/pci/devices/$bdf/driver" ]]; then
            local drv
            drv=$(basename "$(readlink "/sys/bus/pci/devices/$bdf/driver")")
            echo "$bdf" > "/sys/bus/pci/drivers/$drv/unbind" 2>/dev/null && \
                log_ok "  Unbound $drv from $bdf" || \
                log_warn "  Could not unbind $drv from $bdf"
        fi
    done

    # Step 2: Unbind amdgpu
    log_info "Step 2: Unbinding amdgpu driver..."
    for bdf in "${GPU_BDFS[@]}"; do
        if [[ -e "/sys/bus/pci/devices/$bdf/driver" ]]; then
            local drv
            drv=$(basename "$(readlink "/sys/bus/pci/devices/$bdf/driver")")
            echo "$bdf" > "/sys/bus/pci/drivers/$drv/unbind" 2>/dev/null && \
                log_ok "  Unbound $drv from $bdf" || \
                log_err "  FAILED to unbind $drv from $bdf"
        fi
    done

    sleep 2

    # Step 3: Write rebar control registers directly via setpci
    log_info "Step 3: Writing rebar control registers (setpci)..."
    echo "" >&2
    local rebar_ok=true
    for bdf in "${GPU_BDFS[@]}"; do
        local before
        before=$(read_rebar_size_index "$bdf")
        log_info "  $bdf: current size index = $before ($(size_index_to_human "$before"))"

        if write_rebar_size_index "$bdf" "$TARGET_SIZE_INDEX"; then
            local after
            after=$(read_rebar_size_index "$bdf")
            log_ok "  $bdf: rebar control written → size index $after ($(size_index_to_human "$after"))"
        else
            log_err "  $bdf: FAILED to write rebar control register!"
            rebar_ok=false
        fi
    done
    echo "" >&2

    if ! $rebar_ok; then
        log_err "Some rebar writes failed. Aborting."
        log_info "GPUs may need a cold reboot to recover."
        return 1
    fi

    # Step 4: Remove top-level bridges (cascades to entire GPU subtree)
    log_info "Step 4: Removing PCI bridge subtrees..."
    log_info "  This removes PLX switches, AMD bridges, and all GPU devices."
    echo "" >&2
    for bridge in "${TOP_BRIDGES[@]}"; do
        if [[ -e "/sys/bus/pci/devices/$bridge" ]]; then
            log_info "  Removing $bridge and all downstream devices..."
            echo 1 > "/sys/bus/pci/devices/$bridge/remove" 2>/dev/null && \
                log_ok "  Removed $bridge subtree" || \
                log_err "  FAILED to remove $bridge"
        else
            log_warn "  $bridge not present (already removed?)"
        fi
    done

    sleep 3

    # Step 5: Rescan PCI bus
    log_info "Step 5: Rescanning PCI bus..."
    log_info "  Kernel will re-enumerate devices, read 32GB BARs from config space,"
    log_info "  and allocate fresh bridge windows to fit."
    echo "" >&2
    echo 1 > /sys/bus/pci/rescan

    # Wait for full enumeration and driver probe
    log_info "  Waiting for enumeration and driver binding (15 seconds)..."
    sleep 15

    log_ok "PCI rescan complete."
    return 0
}

# ---- Phase 3: Verify ----

phase3_verify() {
    echo "" >&2
    echo "============================================================" >&2
    echo "  Phase 3: Verification" >&2
    echo "============================================================" >&2
    echo "" >&2

    local all_success=true

    for bdf in "${GPU_BDFS[@]}"; do
        echo "" >&2
        log_info "--- GPU $bdf ---"

        if [[ ! -e "/sys/bus/pci/devices/$bdf" ]]; then
            log_err "  Device not present after rescan!"
            all_success=false
            continue
        fi

        # BAR0 size from lspci
        local bar_line
        bar_line=$(lspci -vvs "${bdf#0000:}" 2>/dev/null | grep "Region 0:" || true)
        if [[ -n "$bar_line" ]]; then
            log_info "  $bar_line"
            if echo "$bar_line" | grep -qP 'size=(16G|32G)'; then
                log_ok "  BAR0 is now large!"
            elif echo "$bar_line" | grep -qP 'size=256M'; then
                log_warn "  BAR0 still 256M — resize did not persist through rescan"
                all_success=false
            fi
        fi

        # Visible VRAM
        local vis_vram
        vis_vram=$(cat "/sys/bus/pci/devices/$bdf/mem_info_vis_vram_total" 2>/dev/null || echo "0")
        local vis_mb=$((vis_vram / 1048576))
        if (( vis_mb > 256 )); then
            log_ok "  Visible VRAM: ${vis_mb} MiB ← SUCCESS!"
        elif (( vis_mb > 0 )); then
            log_warn "  Visible VRAM: ${vis_mb} MiB (unchanged)"
        fi

        # Rebar control register
        local cur_idx
        cur_idx=$(read_rebar_size_index "$bdf")
        log_info "  Rebar control: size index $cur_idx ($(size_index_to_human "$cur_idx"))"
    done

    # Bridge windows
    echo "" >&2
    log_info "Bridge windows after resize:"
    for bdf in "${BRIDGE_CHAIN_BDFS[@]}"; do
        if [[ -e "/sys/bus/pci/devices/$bdf" ]]; then
            local pref
            pref=$(lspci -vvs "$bdf" 2>/dev/null | grep -i "Prefetchable memory behind" || true)
            if [[ -n "$pref" ]]; then
                echo "    $bdf: $(echo "$pref" | sed 's/.*://' | xargs)" >&2
            fi
        fi
    done

    # Check peer mapping
    echo "" >&2
    local new_peer_errors
    new_peer_errors=$(dmesg | tail -200 | grep -c "Failed to map peer" || true)
    if (( new_peer_errors == 0 )); then
        log_ok "No recent peer mapping errors!"
    else
        log_warn "Peer mapping errors found in recent dmesg ($new_peer_errors)"
    fi

    echo "" >&2
    if $all_success; then
        log_ok "═══════════════════════════════════════════════════════"
        log_ok "  BAR resize successful! All GPUs have large BARs."
        log_ok "═══════════════════════════════════════════════════════"
    else
        log_warn "BAR resize did not fully succeed."
        echo "" >&2
        log_info "If BARs reverted to 256MB, the device may reset rebar on re-enumeration."
        log_info "In that case, you'll need a kernel patch to make amdgpu call"
        log_info "pci_resize_resource() AFTER bridge windows are already large, or"
        log_info "a custom ACPI SSDT to provide larger initial bridge windows."
    fi
}

# ---- Main ----

main() {
    local mode="${1:---resize}"

    echo "" >&2
    echo "╔════════════════════════════════════════════════════════════╗" >&2
    echo "║    AMD Vega II BAR Resize v3 — Mac Pro 7,1                 ║" >&2
    echo "║    Direct setpci rebar + PCI subtree reset approach        ║" >&2
    echo "╚════════════════════════════════════════════════════════════╝" >&2

    phase1_diagnose

    if [[ "$mode" == "--diagnose-only" ]]; then
        echo "" >&2
        log_info "Diagnostics complete. Run without --diagnose-only to resize."
        exit 0
    fi

    local target_human
    target_human=$(size_index_to_human "$TARGET_SIZE_INDEX")

    echo "------------------------------------------------------------" >&2
    echo "" >&2
    log_info "Plan:"
    log_info "  1. Unbind drivers"
    log_info "  2. Write rebar control register → $target_human on all 4 GPUs"
    log_info "  3. Remove top-level PCI bridges (cascade-remove entire GPU subtree)"
    log_info "  4. Rescan PCI bus (kernel re-enumerates with fresh bridge windows)"
    echo "" >&2
    log_warn "This will temporarily kill all GPU display output."
    log_warn "If running over SSH, the session should survive."
    echo "" >&2

    if [[ "$mode" == "--force" ]]; then
        log_info "Non-interactive mode (--force). Proceeding..."
    else
        read -rp "Proceed? (y/N): " confirm
        if [[ "${confirm,,}" != "y" ]]; then
            log_info "Aborted."
            exit 0
        fi
    fi

    phase2_resize || { log_err "Resize failed."; exit 1; }
    phase3_verify

    echo "" >&2
    echo "============================================================" >&2
    echo "  To make persistent: install as a systemd service that" >&2
    echo "  runs this script at boot before GPU workloads start." >&2
    echo "============================================================" >&2
    echo "" >&2
}

main "$@"
