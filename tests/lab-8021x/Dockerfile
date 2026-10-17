# The image of the 802.1X lab (lab.sh image): both ends, the "switch" and the thin client, from Debian 13
FROM debian:trixie
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    systemd systemd-sysv dbus wpasupplicant hostapd dnsmasq-base ifupdown dhcpcd-base iproute2 iw openssl \
    procps ca-certificates e2fsprogs nftables python3 kmod freeradius >/dev/null && \
    systemctl mask systemd-udevd.service systemd-udevd-control.socket systemd-udevd-kernel.socket getty@tty1.service \
      systemd-networkd.service systemd-resolved.service freeradius.service networking.service console-getty.service; \
    rm -f /etc/network/interfaces.d/*; true
