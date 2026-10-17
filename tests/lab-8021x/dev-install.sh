#!/bin/bash
# Inside the thin client of the lab (d1x-dev), after lab.sh sync copied the rootfs in: what install.sh of an update does
# that matters here, the CAs of the lab as the CAs of the site, and the parts not under test as no-ops.
chown -R root:root /opt/openthinrdp /etc/systemd/system /etc/sudoers.d /etc/udev/rules.d 2>/dev/null
chmod 755 /opt/openthinrdp/*.sh
mkdir -p /etc/openthinrdp/ca /var/lib/openthinrdp /var/log/openthinrdp; touch /var/log/openthinrdp/events.log
id kiosk >/dev/null 2>&1 || useradd -m kiosk
cp /lab/pki/ca.crt /etc/openthinrdp/ca/lab-ca.crt; cp /lab/pki/rogue-ca.crt /etc/openthinrdp/ca/rogue-ca.crt
for s in browser-policy.sh schedule.sh; do printf '#!/bin/bash\nexit 0\n' > /opt/openthinrdp/$s; done
systemctl daemon-reload
echo installed
