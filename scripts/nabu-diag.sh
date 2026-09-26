#!/bin/bash
# nabu-diag.sh - hardware/driver diagnostic for Fedora on Xiaomi Pad 5 (nabu).
#
#   sudo /root/nabu-diag.sh                  # after booting into Fedora
#   sudo /root/nabu-diag.sh --save /mnt/shared/
#
# Best-effort: a missing tool is reported, never fatal.
# Full log: /root/nabu-diag-report.txt

REPORT=/root/nabu-diag-report.txt
PASS=0; FAIL=0; WARN=0
declare -a SUMMARY

have() { command -v "$1" >/dev/null 2>&1; }

# check <PASS|FAIL|WARN> <label> <detail>
check() {
    local lvl="$1" label="$2" detail="${3:-}"
    case "$lvl" in
        PASS) PASS=$((PASS+1)) ;;
        FAIL) FAIL=$((FAIL+1)) ;;
        *)    WARN=$((WARN+1)) ;;
    esac
    SUMMARY+=("$(printf '%-6s %-34s %s' "[$lvl]" "$label" "$detail")")
    printf '%-6s %-34s %s\n' "[$lvl]" "$label" "$detail" >> "$REPORT"
}

# section <title>  + a matching header in the log
section() {
    { echo; echo "======================================================================"
      echo "== $*"
      echo "======================================================================"; } >> "$REPORT"
    printf '\n>>> %s\n' "$*" >&2
}

# run <cmd...> - append stdout+stderr to the report
run() {
    { echo "\$ $*"; "$@" 2>&1 || echo "(exit $?)"; echo; } >> "$REPORT"
}

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root:  sudo $0" >&2
    exit 1
fi

: > "$REPORT"
{
    echo "nabu diagnostic report"
    echo "generated: $(date -Is)"
    echo "uptime:    $(uptime -p 2>/dev/null)"
} >> "$REPORT"

# --- system
section "System"
run uname -a
run cat /etc/os-release
echo "machine model: $(tr -d '\0' </proc/device-tree/model 2>/dev/null)" >> "$REPORT"
echo "compatible:    $(tr '\0' ' ' </proc/device-tree/compatible 2>/dev/null)" >> "$REPORT"
run ls -l /boot/dtb-linux-nabu
run cat /etc/fstab
run cat /proc/cmdline

# --- selinux
section "SELinux"
# linux-nabu has no CONFIG_SECURITY_SELINUX at all, so getenforce is always
# "disabled". Detect the missing kernel support rather than report it as a fault.
if grep -qw selinux /proc/cmdline 2>/dev/null; then
    check WARN "kernel cmdline" "selinux forced on/off via cmdline"
fi
if [ -d /sys/fs/selinux ]; then
    if have getenforce; then
        SE=$(getenforce 2>&1)
        check "$( [ "$SE" = enforcing ] && echo PASS || echo WARN )" "mode" "$SE"
        run sestatus
    fi
    if [ -e /.autorelabel ]; then
        check FAIL ".autorelabel" "present - relabel has not completed"
    else
        check PASS ".autorelabel" "consumed"
    fi
    run ls -l /etc/selinux/targeted/active
else
    check INFO "SELinux" "NOT SUPPORTED by linux-nabu (expected)"
    check INFO "  why" "active LSMs: $(cat /sys/kernel/security/lsm 2>/dev/null || echo unknown)"
    check INFO "  getenforce" "$(have getenforce && getenforce 2>&1 || echo 'getenforce not installed')"
    if [ -e /.autorelabel ]; then
        check WARN ".autorelabel" "present but inert - no SELinux to relabel with"
    fi
    run ls -l /etc/selinux/targeted/active 2>/dev/null
fi

# --- services
section "Services"
for u in NetworkManager bluetooth rmtfs tqftpserv qbootctl displaylink \
         systemd-udevd; do
    st=$(systemctl is-active "$u" 2>/dev/null)
    en=$(systemctl is-enabled "$u" 2>/dev/null)
    if [ "$st" = active ]; then check PASS "$u" "active / $en"
    elif [ "$st" = static ]; then check PASS "$u" "static (D-Bus activated)"
    else check FAIL "$u" "$st / $en"; fi
done
# pipewire/wireplumber are per-user, so a system-scope query always says
# "not-found". They are checked in the Audio section, inside the user session.
st=$(systemctl is-active rtkit-daemon 2>/dev/null)
[ "$st" = active ] && check PASS "rtkit-daemon" "active" || check FAIL "rtkit-daemon" "$st"
echo "--- failed units ---" >> "$REPORT"
systemctl --failed --no-pager >> "$REPORT" 2>&1
if systemctl --failed --no-legend --no-pager 2>/dev/null | grep -q .; then
    check FAIL "systemctl --failed" "$(systemctl --failed --no-legend --no-pager 2>/dev/null | wc -l) unit(s)"
else
    check PASS "systemctl --failed" "none"
fi

# --- dsp firmware
section "Remoteproc / DSP firmware  (the thing that took out wifi+bt+audio)"
DM=$(dmesg 2>/dev/null)
for r in slpi cdsp adsp modem; do
    if echo "$DM" | grep -q "remote processor $r is now up"; then
        check PASS "$r remoteproc" "up"
    elif echo "$DM" | grep -qE "failed to boot $r|request_firmware failed"; then
        check FAIL "$r remoteproc" "firmware load FAILED"
    else
        check WARN "$r remoteproc" "not mentioned"
    fi
done
echo "--- remoteproc log ---" >> "$REPORT"
echo "$DM" | grep -iE 'remoteproc|firmware load|request_firmware' | tail -40 >> "$REPORT" 2>&1
echo "$DM" | grep -iE 'Direct firmware load for .* failed' | sort -u >> "$REPORT" 2>&1
for f in slpi_nb cdsp adsp venus wlanmdsp a640_zap modem; do
    p="/usr/lib/firmware/qcom/sm8150/xiaomi/nabu/$f.mbn"
    [ -e "$p" ] && check PASS "fw $f.mbn" "present" || check FAIL "fw $f.mbn" "MISSING"
done
for f in socinfo/soc_id sensors/sns_reg.conf; do
    p="/usr/lib/firmware/hexagonfs/$f"
    [ -e "$p" ] && check PASS "hexagonfs/$f" "present" || check FAIL "hexagonfs/$f" "MISSING"
done
for l in sensors socinfo; do
    p="/usr/lib/firmware/qcom/sm8150/xiaomi/nabu/$l"
    [ -d "$p" ] && check PASS "hexagonfs link $l" "resolves" || check FAIL "hexagonfs link $l" "BROKEN/MISSING"
done

# --- audio
section "Audio"
# Trust aplay, not /proc/asound/cards. Never use [ -s ] on /proc/asound/*:
# procfs reports st_size 0, so -s is false even when there is content.
CARDS=0
if have aplay; then
    n=$(aplay -l 2>/dev/null | grep -c '^card ')
    [ "${n:-0}" -gt 0 ] && CARDS="$n"
fi
if [ "$CARDS" = "0" ]; then
    c="$(cat /proc/asound/cards 2>/dev/null)"
    if [ -n "$c" ]; then
        CARDS="$(printf '%s\n' "$c" | grep -c '^[[:space:]]*[0-9]')"
    else
        p="$(cat /proc/asound/pcm 2>/dev/null)"
        [ -n "$p" ] && CARDS=1
    fi
fi
if [ "${CARDS:-0}" -gt 0 ]; then
    check PASS "ALSA cards" "$CARDS card(s)"
    run aplay -l
    run cat /proc/asound/cards
    run cat /proc/asound/pcm
else
    check FAIL "ALSA cards" "none registered - no sound card in the kernel"
fi
echo "--- ASoC / snd log ---" >> "$REPORT"
echo "$DM" | grep -iE 'snd-sm8150|asoc|deferred probe|no backend DAI|corrected Nabu' | tail -30 >> "$REPORT" 2>&1

# pipewire runs as the desktop user; pactl as root hits a dead socket.
DU=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$0 ~ /x11|wayland/ {print $3; exit}')
[ -z "$DU" ] && DU=$(loginctl list-users --no-legend 2>/dev/null | awk 'NR==1{print $2}')
if [ -n "$DU" ]; then
    DUID=$(id -u "$DU" 2>/dev/null)
    asuser() { sudo -u "$DU" env XDG_RUNTIME_DIR="/run/user/$DUID" HOME="/home/$DU" "$@" 2>&1; }
    echo "--- pipewire, as user '$DU' ---" >> "$REPORT"
    for u in pipewire wireplumber; do
        st=$(asuser systemctl --user is-active $u)
        if [ "$st" = active ]; then check PASS "$u (user $DU)" "active"
        else check FAIL "$u (user $DU)" "${st:-unknown}"; fi
    done
    asuser systemctl --user --no-pager status pipewire wireplumber >> "$REPORT" 2>&1
    NS=$(asuser pactl list short sinks | grep -c . )
    if [ "${NS:-0}" -gt 0 ]; then
        check PASS "pipewire sinks" "$NS"
    else
        check FAIL "pipewire sinks" "none"
    fi
    { echo "\$ (as $DU) pactl list short sinks"; asuser pactl list short sinks; echo
      echo "\$ (as $DU) pactl list short sources"; asuser pactl list short sources; echo; } >> "$REPORT" 2>&1
    { echo "\$ (as $DU) pactl info"; asuser pactl info; echo; } >> "$REPORT" 2>&1
else
    check WARN "desktop user" "no graphical session found; skipping pipewire checks"
fi
if ! have aplay; then check WARN "aplay" "not installed (alsa-utils)"; fi

# --- wifi
section "WiFi"
# Don't hardcode the name: 10-wlan.link pins it to wlan0, but older images and
# rescue shells can still show the upstream wld0.
WIFI_IF=""
if have nmcli; then
    WIFI_IF=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
fi
if [ -z "$WIFI_IF" ] && have iw; then
    WIFI_IF=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
fi
if [ -n "$WIFI_IF" ]; then
    check PASS "wifi interface" "$WIFI_IF"
    GOT=$(cat "/sys/class/net/$WIFI_IF/address" 2>/dev/null)
    if [ -z "$GOT" ]; then
        check WARN "wifi mac" "could not read $WIFI_IF/address"
    elif systemctl is-enabled nabu-pmac.service >/dev/null 2>&1; then
        check PASS "wifi mac" "$GOT (nabu-pmac enabled)"
    else
        check WARN "wifi mac" "$GOT (nabu-pmac not enabled - may change per boot)"
    fi
else
    check FAIL "wifi interface" "no wifi netdev found"
fi
if have rfkill; then
    rfkill list >> "$REPORT" 2>&1
    # rfkill puts the device and its "blocked:" state on separate lines, so
    # filter by type rather than grepping for the state.
    RKW=$(rfkill list wifi 2>/dev/null)
    if [ -z "$RKW" ]; then
        check WARN "rfkill wlan" "no Wireless LAN entry"
    elif echo "$RKW" | grep -qi 'Soft blocked: no'; then
        check PASS "rfkill wlan" "unblocked ($(echo "$RKW" | head -1 | tr -s ' '))"
    else
        check FAIL "rfkill wlan" "$(echo "$RKW" | tr -s ' ' | tr '\n' ' ')"
    fi
else
    check WARN "rfkill" "not installed"
fi
if have iw; then
    run iw dev
    if [ -n "$WIFI_IF" ] && iw dev 2>/dev/null | grep -q "Interface $WIFI_IF"; then
        check PASS "iw $WIFI_IF" "$(iw dev 2>/dev/null | grep -A3 "Interface $WIFI_IF" | grep -o 'type [a-z-]*' | head -1)"
    else
        check FAIL "iw $WIFI_IF" "interface not present"
    fi
else
    check WARN "iw" "not installed (NetworkManager-wifi may be incomplete)"
fi
if have nmcli; then
    run nmcli device status
    run nmcli radio all
    if [ -n "$WIFI_IF" ]; then
        # nmcli -t escapes ':' in values as '\:'. Match on the prefix so a colon
        # inside the network name stays intact; unescape for display.
        ST=$(nmcli -t -f DEVICE,STATE device 2>/dev/null | awk -F: -v d="$WIFI_IF" '$1==d{print $2; exit}')
        CON=$(nmcli -t -f DEVICE,CONNECTION device 2>/dev/null | sed -n "s/^$WIFI_IF://p" | head -1 | sed 's/\\:/:/g')
        case "$ST" in
            connected*) check PASS "nmcli $WIFI_IF" "connected to '${CON:-?}'" ;;
            "")          check FAIL "nmcli $WIFI_IF" "not seen by NetworkManager" ;;
            *)           check PASS "nmcli $WIFI_IF" "$ST" ;;
        esac
    fi
else
    check FAIL "nmcli" "NetworkManager CLI missing"
fi
echo "--- ath10k log ---" >> "$REPORT"
echo "$DM" | grep -iE 'ath10k|wcn3990|qmi|htt-ver' | tail -30 >> "$REPORT" 2>&1
if echo "$DM" | grep -q 'ath10k_snoc.*firmware ver'; then
    check PASS "ath10k firmware" "$(echo "$DM" | grep -o 'firmware ver.*' | tail -1 | cut -c1-40)"
else
    check FAIL "ath10k firmware" "did not report a firmware version"
fi
for f in ath10k/WCN3990/hw1.0/wlanmdsp.mbn ath10k/WCN3990/hw1.0/board-2.bin ath10k/WCN3990/hw1.0/firmware-5.bin; do
    for x in "" .xz .zst; do [ -e "/usr/lib/firmware/$f$x" ] && break; done
    [ -e "/usr/lib/firmware/$f$x" ] && check PASS "fw $f" "present" || check FAIL "fw $f" "MISSING"
done

# --- bluetooth
section "Bluetooth"
echo "--- BT log ---" >> "$REPORT"
echo "$DM" | grep -iE 'bluetooth|hci0|btqca|qca' | tail -30 >> "$REPORT" 2>&1
if [ -e /sys/class/bluetooth/hci0 ]; then
    check PASS "hci0" "present"
else
    check FAIL "hci0" "no bluetooth controller"
fi
if have bluetoothctl; then
    run timeout 10 bluetoothctl list
    run timeout 10 bluetoothctl show
    if timeout 10 bluetoothctl list 2>/dev/null | grep -q '^Controller'; then
        check PASS "bluetoothctl" "controller enumerated"
    else
        check FAIL "bluetoothctl" "no controller"
    fi
else
    check WARN "bluetoothctl" "not installed"
fi
if have btmgmt; then
    run timeout 10 btmgmt info
fi
for f in qca/crbtfw32.tlv qca/crnv32.bin; do
    for x in "" .xz .zst; do [ -e "/usr/lib/firmware/$f$x" ] && break; done
    [ -e "/usr/lib/firmware/$f$x" ] && check PASS "fw $f" "present" || check FAIL "fw $f" "MISSING"
done

# --- camera
section "Camera"
ls -l /dev/video* /dev/media* /dev/v4l-subdev* >/dev/null 2>&1
run ls -l /dev/video* /dev/media* /dev/v4l-subdev*
NV=$(ls /dev/video* 2>/dev/null | wc -l)
if [ "$NV" -gt 0 ]; then
    check PASS "/dev/video*" "$NV node(s)"
else
    check WARN "/dev/video*" "none - no camera"
fi
echo "--- camera / camss log ---" >> "$REPORT"
echo "$DM" | grep -iE 'camss|csiphy|camera|cam_|msm_cam|v4l2' | tail -30 >> "$REPORT" 2>&1
if echo "$DM" | grep -qiE 'camss|csiphy'; then
    check PASS "camss probe" "found in dmesg"
else
    check WARN "camss probe" "nothing in dmesg"
fi
if have media-ctl; then run media-ctl -p; else check WARN "media-ctl" "not installed"; fi

# --- gpu
section "GPU / graphics acceleration"
run ls -l /dev/dri
if ls /dev/dri/renderD* >/dev/null 2>&1; then
    check PASS "/dev/dri/renderD*" "present"
else
    check FAIL "/dev/dri/renderD*" "no render node - no GPU accel"
fi
echo "--- GPU log ---" >> "$REPORT"
echo "$DM" | grep -iE 'msm/kgsl|kgsl|adreno|msm_drm|drm|gpu' | tail -30 >> "$REPORT" 2>&1
if have eglinfo; then
    run eglinfo -B
    if eglinfo -B 2>/dev/null | grep -qiE 'adreno|kgsl'; then
        check PASS "EGL" "adreno/kgsl renderer found"
    else
        check WARN "EGL" "no adreno/kgsl renderer"
    fi
else
    check WARN "eglinfo" "not installed (mesa-utils)"
fi
if have glxinfo; then run glxinfo -B; else check WARN "glxinfo" "not installed"; fi
run ls -l /sys/class/drm/ 2>/dev/null

# --- display
section "Display / panel"
echo "--- display log ---" >> "$REPORT"
echo "$DM" | grep -iE 'dsi|panel|novatek|hdmi|mdss|disp' | tail -30 >> "$REPORT" 2>&1
if echo "$DM" | grep -qiE 'novatek|nt36523'; then
    check PASS "panel driver" "novatek nt36523 in dmesg"
else
    check WARN "panel driver" "novatek nt36523 not mentioned"
fi
run cat /sys/class/drm/card*-DSI-1/status 2>/dev/null
run cat /sys/class/backlight/*/brightness 2>/dev/null

# --- sensors
section "Sensors (iio-sensor-proxy: rotation, accelerometer, light)"
run ls -l /dev/iio:device*
run ls /sys/bus/iio/devices/ 2>/dev/null
NA=$(ls /sys/bus/iio/devices/ 2>/dev/null | grep -ci accel)
if [ "${NA:-0}" -gt 0 ]; then
    check PASS "iio accel devices" "$NA"
else
    check WARN "iio accel devices" "none"
fi
SVC=$(systemctl is-active iio-sensor-proxy 2>/dev/null)
case "$SVC" in
    active|static) check PASS "iio-sensor-proxy" "$SVC" ;;
    *) check WARN "iio-sensor-proxy" "$SVC (a static unit shows inactive but is D-Bus activated)" ;;
esac

# --- input
section "Input / touch / power"
run ls -l /dev/input/
run cat /proc/bus/input/devices
if have libinput; then run libinput list-devices; else check WARN "libinput" "not installed"; fi

# --- power
section "Power / suspend"
if [ -e /sys/power/state ]; then
    check INFO "sleep states" "$(cut -d' ' -f1-3 /sys/power/state | cut -c1-45)"
fi
run systemctl is-enabled sleep.target suspend.target 2>/dev/null
echo "--- suspend log ---" >> "$REPORT"
echo "$DM" | grep -iE 'suspend|resume|sleep' | tail -20 >> "$REPORT" 2>&1

# --- journal
section "Journal: errors and warnings"
run journalctl -p err -b --no-pager
run journalctl -p warning -b --no-pager -n 200
NE=$(journalctl -p err -b --no-pager 2>/dev/null | grep -c .)
if [ "${NE:-0}" -gt 0 ]; then check WARN "journal errors" "$NE lines in report"; else check PASS "journal errors" "none"; fi

# --- summary
{
    echo
    echo "======================================================================"
    echo "== SUMMARY"
    echo "======================================================================"
} >> "$REPORT"
printf '%s\n' "${SUMMARY[@]}" >> "$REPORT"

echo
echo "======================================================================" >&2
printf 'PASS: %d   FAIL: %d   WARN/INFO: %d\n' "$PASS" "$FAIL" "$WARN" >&2
echo "full report: $REPORT" >&2
echo "======================================================================" >&2

# optional: --save <dir> copies the report to a shared volume
if [ "$1" = "--save" ] && [ -n "$2" ]; then
    dest="$2"
    mkdir -p "$dest" 2>/dev/null
    if cp "$REPORT" "$dest/nabu-diag-report.txt" 2>/dev/null; then
        echo "copied report to $dest/nabu-diag-report.txt" >&2
    else
        echo "WARNING: could not write to $dest (is it mounted and writable?)" >&2
    fi
fi

[ "$FAIL" -eq 0 ] || exit 1
exit 0
