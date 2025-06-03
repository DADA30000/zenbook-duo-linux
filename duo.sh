#!/usr/bin/env bash

# Default backlight (0-3)
DEFAULT_BACKLIGHT=1

# Default scale (1-2)
DEFAULT_SCALE=1
temp=$(mktemp -d)
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
WAYLAND_DISPLAY=wayland-1
DISPLAY=:0

# Capture Ctrl+C and close any subprocesses such as duo-watch-monitor
trap 'echo "Ctrl+C captured. Exiting..."; pkill -P $$; exit 1' INT
HYPRLAND_INSTANCE_SIGNATURE=$(ls -Art /run/user/1001/hypr | tail -n 1)
echo "test1 $(ls -Art /run/user/1001/hypr | tail -n 1)"
echo "test2 $(ls -Art /run/user/1001/hypr)"
echo "test3 $(ls /run/user)"
echo $temp

# SCALE=$(gdctl show |grep Scale: |sed 's/│//g' |awk '{print $2}' |head -n1)
# if [ -z "${SCALE}" ]; then
#     SCALE=1
# fi
SCALE=${DEFAULT_SCALE}

# Python embed
PYTHON3=$(which python3)
KEYBOARD_DEV=$(lsusb | grep 'Zenbook Duo Keyboard' |awk '{print $6}')
if [ -n "${KEYBOARD_DEV}" ] && [ ! -f "$temp/backlight.py" ]; then
    VENDOR_ID=${KEYBOARD_DEV%:*}
    PRODUCT_ID=${KEYBOARD_DEV#*:}
    echo "#!/usr/bin/env python3

# BSD 2-Clause License
#
# Copyright (c) 2024, Alesya Huzik
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this
#    list of conditions and the following disclaimer.

# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import sys
import usb.core
import usb.util

# USB Parameters
VENDOR_ID = 0x${VENDOR_ID}
PRODUCT_ID = 0x${PRODUCT_ID}
REPORT_ID = 0x5A
WVALUE = 0x035A
WINDEX = 4
WLENGTH = 16

if len(sys.argv) != 2:
    print(f\"Usage: {sys.argv[0]} <level>\")
    sys.exit(1)

try:
    level = int(sys.argv[1])
    if level < 0 or level > 3:
        raise ValueError
except ValueError:
    print(\"Invalid level. Must be an integer between 0 and 3.\")
    sys.exit(1)

# Prepare the data packet
data = [0] * WLENGTH
data[0] = REPORT_ID
data[1] = 0xBA
data[2] = 0xC5
data[3] = 0xC4
data[4] = level

# Find the device
dev = usb.core.find(idVendor=VENDOR_ID, idProduct=PRODUCT_ID)

if dev is None:
    print(f\"Device not found (Vendor ID: 0x{VENDOR_ID:04X}, Product ID: 0x{PRODUCT_ID:04X})\")
    sys.exit(1)

# Detach kernel driver if necessary
if dev.is_kernel_driver_active(WINDEX):
    try:
        dev.detach_kernel_driver(WINDEX)
    except usb.core.USBError as e:
        print(f\"Could not detach kernel driver: {str(e)}\")
        sys.exit(1)

# try:
#     dev.set_configuration()
#     usb.util.claim_interface(dev, WINDEX)
# except usb.core.USBError as e:
#     print(f\"Could not set configuration or claim interface: {str(e)}\")
#     sys.exit(1)

# Send the control transfer
try:
    bmRequestType = 0x21  # Host to Device | Class | Interface
    bRequest = 0x09       # SET_REPORT
    wValue = WVALUE       # 0x035A
    wIndex = WINDEX       # Interface number
    ret = dev.ctrl_transfer(bmRequestType, bRequest, wValue, wIndex, data, timeout=1000)
    if ret != WLENGTH:
        print(f\"Warning: Only {ret} bytes sent out of {WLENGTH}.\")
    else:
        print(\"Data packet sent successfully.\")
except usb.core.USBError as e:
    print(f\"Control transfer failed: {str(e)}\")
    usb.util.release_interface(dev, WINDEX)
    sys.exit(1)

# Release the interface
usb.util.release_interface(dev, WINDEX)
# Reattach the kernel driver if necessary
try:
    dev.attach_kernel_driver(WINDEX)
except usb.core.USBError:
    pass  # Ignore if we can't reattach the driver

sys.exit(0)
" > "$temp/backlight.py"
fi

WIFI_BEFORE=$(nmcli radio wifi)
BLUETOOTH_BEFORE=$(rfkill -n -o SOFT list bluetooth |head -n1)
KEYBOARD_ATTACHED=false
if [ -n "$(lsusb | grep 'Zenbook Duo Keyboard')" ]; then
    KEYBOARD_ATTACHED=true
fi
MONITOR_COUNT=$(gdctl show | grep 'Logical monitor #' | wc -l)
function duo-set-status() {
    echo "
        BLUETOOTH_BEFORE=${BLUETOOTH_BEFORE}
        WIFI_BEFORE=${WIFI_BEFORE}
        KEYBOARD_ATTACHED=${KEYBOARD_ATTACHED}
        MONITOR_COUNT=${MONITOR_COUNT}
    " > "$temp/status"
}
duo-set-status

function duo-set-kb-backlight() {
    ${PYTHON3} "$temp/backlight.py" ${1} >/dev/null
}

BRIGHTNESS=0
function duo-sync-display-backlight() {
    . "$temp/status"
    if [ "${KEYBOARD_ATTACHED}" = false ]; then
        CUR_BRIGHTNESS=$(cat /sys/class/backlight/intel_backlight/brightness)
        if [ "${CUR_BRIGHTNESS}" != "${BRIGHTNESS}" ]; then
            BRIGHTNESS=${CUR_BRIGHTNESS}
            echo "$(date) - DISPLAY - Setting brightness to $(echo ${BRIGHTNESS} | tee /sys/class/backlight/card1-eDP-2-backlight/brightness)"
        fi
    fi
}

function duo-watch-display-backlight() {
    while true; do
        inotifywait -e modify /sys/class/backlight/intel_backlight/brightness >/dev/null 2>&1
        duo-sync-display-backlight
    done
}

function duo-watch-wifi() {
    while read -r LINE; do
        sleep 1
        . "$temp/status"
        if [ "${KEYBOARD_ATTACHED}" = true ]; then
            if [[ "${LINE}" = *"<true>"* ]]; then
                WIFI_BEFORE=enabled
            else
                WIFI_BEFORE=disabled
            fi
            echo "$(date) - NETWORK - WIFI: ${WIFI_BEFORE}"
            duo-set-status
        fi
    done < <(gdbus monitor -y -d org.freedesktop.NetworkManager | grep --line-buffered WirelessEnabled)
}

function duo-watch-bluetooth() {
    while read -r LINE; do
        sleep 1
        . "$temp/status"
        if [ "${KEYBOARD_ATTACHED}" = true ]; then
            if [[ "${LINE}" = *"<true>"* ]]; then
                BLUETOOTH_BEFORE=unblocked
            else
                BLUETOOTH_BEFORE=blocked
            fi
            echo "$(date) - NETWORK - Bluetooth: ${BLUETOOTH_BEFORE}"
            duo-set-status
        fi
    done < <(gdbus monitor -y -d org.bluez | grep --line-buffered "'Powered':")
}

function duo-watch-lock() {
    while read -r LINE; do
        sleep 1
        echo "$(date) - DEBUG - ${LINE}"
        . "$temp/status"
        if [ "${KEYBOARD_ATTACHED}" = true ]; then
            if [[ "${LINE}" = *"<true>"* ]]; then
                BLUETOOTH_BEFORE=unblocked
            else
                BLUETOOTH_BEFORE=blocked
            fi
            echo "$(date) - NETWORK - Bluetooth: ${BLUETOOTH_BEFORE}"
            duo-set-status
            duo-check-monitor
        fi
    done < <(gdbus monitor -y -d org.freedesktop.login1 | grep --line-buffered "LockedHint")
}

function duo-check-monitor() {
    . "$temp/status"
    KEYBOARD_ATTACHED=false
    if [ -n "$(lsusb | grep 'Zenbook Duo Keyboard')" ]; then
        KEYBOARD_ATTACHED=true
    fi
    HYPRLAND_INSTANCE_SIGNATURE=$(ls -Art /run/user/1001/hypr | tail -n 1)
    MONITOR_COUNT=$(sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl monitors | grep Monitor --color=none | wc -l)
    echo "OUTPUT $(sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl monitors)"
    duo-set-status
    echo "$(date) - MONITOR - WIFI before: ${WIFI_BEFORE}, Bluetooth before: ${BLUETOOTH_BEFORE}"
    echo "$(date) - MONITOR - Keyboard attached: ${KEYBOARD_ATTACHED}, Monitor count: ${MONITOR_COUNT}"
    if [ ${KEYBOARD_ATTACHED} = true ]; then
        echo "$(date) - MONITOR - Keyboard attached"
        duo-set-kb-backlight ${DEFAULT_BACKLIGHT}
        if [ "${WIFI_BEFORE}" = enabled ]; then
            echo "$(date) - MONITOR - Turning on WIFI"
            nmcli radio wifi on
        fi
        if [ "${BLUETOOTH_BEFORE}" = unblocked ]; then
            echo "$(date) - MONITOR - Turning on Bluetooth"
            rfkill unblock bluetooth
        else
            echo "$(date) - MONITOR - Turning off Bluetooth"
            rfkill block bluetooth
        fi
        if ((${MONITOR_COUNT} > 1)); then
            echo "$(date) - MONITOR - Disabling bottom monitor"
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-2,disabled
            NEW_MONITOR_COUNT=$(sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl monitors | grep Monitor --color=none | wc -l)
            if ((${NEW_MONITOR_COUNT} == 1)); then
                MESSAGE="Disabled bottom display"
            else
                MESSAGE="ERROR: Bottom display still on"
            fi
            sudo -E -u nick notify-send -a "Zenbook Duo" -t 1000 --hint=int:transient:1 -i "preferences-desktop-display" "${MESSAGE}"
        fi
    else
        echo "$(date) - MONITOR - Keyboard detached"
        if [ "${WIFI_BEFORE}" = enabled ]; then
            echo "$(date) - MONITOR - Turning on WIFI"
            nmcli radio wifi on
        fi
        echo "$(date) - MONITOR - Turning on Bluetooth"
        rfkill unblock bluetooth
        if ((${MONITOR_COUNT} < 2)); then
            echo "$(date) - MONITOR - Enabling bottom monitor"
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-2,1920x1200@60,0x1200,1
            NEW_MONITOR_COUNT=$(sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl monitors | grep Monitor --color=none | wc -l)
            if ((${NEW_MONITOR_COUNT} == 2)); then
                MESSAGE="Enabled bottom display"
            else
                MESSAGE="ERROR: Bottom display still off"
            fi
            sudo -E -u nick notify-send -a "Zenbook Duo" -t 1000 --hint=int:transient:1 -i "preferences-desktop-display" "${MESSAGE}"
        fi
    fi
}

function duo-watch-monitor() {
    while true; do
        echo "$(date) - MONITOR - Waiting for USB event"
        inotifywait -e attrib /dev/bus/usb/*/ >/dev/null 2>&1
        duo-check-monitor
    done
}

function duo-cli() {
    . "$temp/status"
    HYPRLAND_INSTANCE_SIGNATURE=$(ls -Art /run/user/1001/hypr | tail -n 1)
    case "${1}" in
    pre|hibernate|shutdown)
        echo "$(date) - ACPI - $@"
        duo-set-kb-backlight 0
    ;;
    post|thaw|boot)
        echo "$(date) - ACPI - $@"
        duo-set-kb-backlight ${DEFAULT_BACKLIGHT}
        duo-check-monitor
    ;;
    kbb)
        echo "$(date) - KEYBOARD - Backlight = ${2}"
        duo-set-kb-backlight ${2}
    ;;
    left-up)
        echo "$(date) - ROTATE - Left-up"
        if [ ${KEYBOARD_ATTACHED} = true ]; then
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-1,1920x1200@60,0x0,1,transform,1
        else
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-1,1920x1200@60,1200x0,1,transform,1
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-2,1920x1200@60,0x0,1,transform,1
        fi

        ;;
    right-up)
        echo "$(date) - ROTATE - Right-up"
        if [ ${KEYBOARD_ATTACHED} = true ]; then
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-1,1920x1200@60,0x0,1,transform,3
        else
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-1,1920x1200@60,0x0,1,transform,3
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-2,1920x1200@60,1200x0,1,transform,3
        fi
        ;;
    bottom-up)
        echo "$(date) - ROTATE - Bottom-up"
        if [ ${KEYBOARD_ATTACHED} = true ]; then
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-1,1920x1200@60,0x0,1,transform,2
        else
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-1,1920x1200@60,0x1200,1,transform,3
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-2,1920x1200@60,0x0,1,transform,3
        fi
        ;;
    normal)
        echo "$(date) - ROTATE - Normal"
        if [ ${KEYBOARD_ATTACHED} = true ]; then
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-1,1920x1200@60,0x0,1
        else
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-1,1920x1200@60,0x0,1
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-2,1920x1200@60,0x1200,1
        fi
        ;;
    *)
        echo "$(date) - UNKNOWN - $@"
        ;;
    esac
}

function duo-watch-rotate() {
    echo "$(date) - ROTATE - Watching"
    monitor-sensor --accel |
        stdbuf -oL grep "Accelerometer orientation changed:" |
        stdbuf -oL awk '{print $4}' |
        xargs -I '{}' stdbuf -oL "$0" '{}' 2>/dev/null
}

function main() {
    duo-set-kb-backlight ${DEFAULT_BACKLIGHT}
    duo-check-monitor
    duo-watch-monitor &
    duo-watch-rotate &
    duo-watch-display-backlight &
    duo-watch-wifi &
    duo-watch-bluetooth
}

if [ -z "${1}" ]; then
    main | tee -a "$temp/duo.log"
else
    duo-cli $@ | tee -a "$temp/duo.log"
    if [ "${USER}" = root ]; then
        chmod a+w "$temp" "$temp/duo.log" "$temp/status"
    fi
fi
