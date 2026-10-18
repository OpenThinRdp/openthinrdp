#!/bin/bash
# The Raspberry Pi image (image/build-rpi.sh) booted in QEMU, without a board: the same SD card image, kernel,
# initramfs and command line (cmdline.txt of its firmware partition), on QEMU's "virt" arm64 machine with a virtio
# disk, network and screen (the Pi's own SD controller, HDMI and USB are not emulated: see docs/arm.md).
# Needs qemu-system-arm, mtools, python3, xz-utils. Emulated (TCG) on a PC: the first boot takes a few minutes.
#   tests/rpi-qemu.sh start <image.img.xz|image.img> <work folder> [extra GB for the SD card]
#   tests/rpi-qemu.sh shot <work folder> <file.png>       screenshot of the virtual screen
#   tests/rpi-qemu.sh ssh <work folder> <key> [command]   as otradmin (SSH=on and the key in the image)
#   tests/rpi-qemu.sh stop <work folder>
# The serial console goes to <work folder>/serial.log; SSH of the guest is on 127.0.0.1:<port in work folder/port>.
set -euo pipefail
cmd=${1:-}; W=${3:-}; [ "$cmd" = start ] || W=${2:-}
[ -n "$W" ] || { sed -n '2,10p' "$0"; exit 2; }
hmp(){ python3 - "$W/monitor.sock" "$1" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); time.sleep(0.3); s.recv(65536)
s.sendall((sys.argv[2] + "\n").encode()); time.sleep(1.5); print(s.recv(65536).decode(errors="replace"))
PY
}
case "$cmd" in
  start)
    IMG=$2; mkdir -p "$W"; D=$W/disk.img
    case "$IMG" in *.xz) xz -dc "$IMG" > "$D" ;; *) cp --sparse=always "$IMG" "$D" ;; esac
    # a larger "SD card": the first boot grows the root partition to it (openthinrdp-growroot)
    [ -n "${4:-}" ] && truncate -s +"$4"G "$D"
    # kernel, initramfs and command line from the FAT partition (it starts at 4 MB)
    F="$D@@4194304"
    K=$(mdir -b -i "$F" :: | sed -n 's|^::/||p' | grep '^vmlinuz-' | sort -V | tail -1)
    I=$(mdir -b -i "$F" :: | sed -n 's|^::/||p' | grep '^initrd.img-' | sort -V | tail -1)
    mcopy -o -i "$F" "::$K" "$W/vmlinuz"; mcopy -o -i "$F" "::$I" "$W/initrd.img"; mcopy -o -i "$F" ::cmdline.txt "$W/cmdline.txt"
    # the serial port of QEMU's machine is ttyAMA0, the Pi 4's is ttyS1
    CMD="$(sed -e 's/console=ttyS1,115200/console=ttyAMA0,115200/' "$W/cmdline.txt" | tr -d '\r\n')"
    echo "kernel $K, initramfs $I, command line: $CMD"
    PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'); echo "$PORT" > "$W/port"
    # SMP: emulated cores (each one keeps a host core busy), 2 by default like a gentle guest on a shared machine
    nice -n 10 qemu-system-aarch64 -M virt -cpu cortex-a72 -smp "${SMP:-2}" -m 2048 \
      -kernel "$W/vmlinuz" -initrd "$W/initrd.img" -append "$CMD" \
      -drive file="$D",format=raw,if=none,id=sd -device virtio-blk-pci,drive=sd \
      -netdev user,id=n,hostfwd=tcp:127.0.0.1:"$PORT"-:22 -device virtio-net-pci,netdev=n \
      -device virtio-gpu-pci,xres=1280,yres=800 -device qemu-xhci -device usb-kbd -device usb-tablet \
      -display none -serial file:"$W/serial.log" -monitor unix:"$W/monitor.sock",server,nowait \
      -pidfile "$W/qemu.pid" -daemonize
    echo "started: serial $W/serial.log, ssh port $PORT" ;;
  shot) hmp "screendump $3 -f png" >/dev/null; ls -l "$3" ;;
  ssh)  K=$3; shift 3; ssh -i "$K" -p "$(cat "$W/port")" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
          -o ConnectTimeout=10 otradmin@127.0.0.1 "$@" ;;
  stop) hmp quit >/dev/null 2>&1 || true; sleep 2
        # only this QEMU (its pid file), and only if that pid is still a QEMU
        p=$(cat "$W/qemu.pid" 2>/dev/null || true)
        [ -n "$p" ] && [ "$(cat /proc/$p/comm 2>/dev/null)" = qemu-system-aar ] && kill "$p"
        rm -f "$W/qemu.pid"; echo stopped ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
