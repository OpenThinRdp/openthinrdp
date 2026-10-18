#!/bin/bash
# The 802.1X lab (as root, on a Linux host with docker; Wi-Fi also needs the mac80211_hwsim kernel module): two
# containers of the lab image joined by a veth pair, as by a patch cable.
#   d1x-auth  the "switch": hostapd (wired driver, its own EAP server or FreeRADIUS behind it), dnsmasq for DHCP,
#             nftables keeping DHCP closed until the port is authorized (auth.sh)
#   d1x-dev   the thin client: systemd as PID 1 and the OpenThinRDP rootfs of this repository, its eth0 the other end
# lab.sh image | up | sync | wifi-up | down       run.sh runs every scenario with its checks.
# Names used on the host: the image dot1x-lab:test, the containers d1x-auth and d1x-dev, the veth pair d1xa/d1xd.
set -u
LAB=$(dirname "$(readlink -f "$0")"); REPO=$(readlink -f "$LAB/../..")
pid(){ docker inspect -f '{{.State.Pid}}' "$1"; }
# iw from the lab image, in the network and process namespaces of the host (the host may not have it)
iw(){ docker run --rm --privileged --network host --pid host dot1x-lab:test iw "$@"; }
case "${1:-}" in
  image)
    docker build -q -t dot1x-lab:test "$LAB" ;;
  up)
    docker rm -f d1x-auth d1x-dev >/dev/null 2>&1
    rm -rf "$LAB/out"; mkdir -p "$LAB/out"
    [ -f "$LAB/pki/client.p12" ] || docker run --rm -v "$LAB:/lab" dot1x-lab:test bash /lab/pki.sh /lab/pki >/dev/null
    docker run -d --name d1x-auth --hostname d1x-auth --privileged --network none -v "$LAB:/lab" dot1x-lab:test sleep infinity >/dev/null
    docker run -d --name d1x-dev --hostname thin1 --privileged --network none --cgroupns=private \
      -v "$LAB:/lab" --tmpfs /run --tmpfs /run/lock dot1x-lab:test /lib/systemd/systemd >/dev/null
    sleep 2
    ip link add d1xa type veth peer name d1xd
    ip link set d1xa netns "$(pid d1x-auth)"; ip link set d1xd netns "$(pid d1x-dev)"
    nsenter -t "$(pid d1x-auth)" -n ip link set d1xa name eth0
    nsenter -t "$(pid d1x-dev)" -n ip link set d1xd name eth0
    "$0" sync
    docker exec d1x-auth /lab/auth.sh setup >/dev/null
    echo up ;;
  sync)
    # the rootfs of the repository into the thin client, as an update installs it (docker cp: a bind mount of the
    # host's disk would be unmounted by apply.sh, which takes every mounted /dev/sd* for a USB stick when the USB
    # rules change)
    docker cp "$REPO/rootfs/." d1x-dev:/ && docker exec d1x-dev /lab/dev-install.sh ;;
  wifi-up)
    # two virtual radios, one in each container: the access point and the thin client
    lsmod | grep -q '^mac80211_hwsim' || modprobe mac80211_hwsim radios=2
    n=0
    for p in $(ls /sys/class/ieee80211/); do
      [ -n "$(ls /sys/class/ieee80211/$p/device/net/ 2>/dev/null)" ] || continue
      t=d1x-auth; [ $n = 1 ] && t=d1x-dev
      iw phy "$p" set netns "$(pid $t)" && n=$((n + 1))
      [ $n = 2 ] && break
    done
    for t in d1x-auth d1x-dev; do
      docker exec $t bash -c 'w=$(ls /sys/class/net | grep -E "^wlan" | head -1); [ -n "$w" ] && [ "$w" != wlan0 ] && ip link set $w name wlan0; true'
    done
    echo "wifi-up ($n radios)" ;;
  down)
    docker rm -f d1x-auth d1x-dev >/dev/null 2>&1; sleep 1
    lsmod | grep -q '^mac80211_hwsim' && rmmod mac80211_hwsim
    echo down ;;
  *) echo "usage: $0 image | up | sync | wifi-up | down"; exit 2 ;;
esac
