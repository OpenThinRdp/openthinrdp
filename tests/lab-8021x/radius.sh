#!/bin/bash
# FreeRADIUS in the lab "switch" container: the RADIUS server hostapd (as a plain authenticator, like a switch) asks.
# PEAP-MSCHAPv2 with the user thinuser, EAP-TLS for the clients of the lab CA, the server certificate of the lab.
R=/etc/freeradius/3.0
pkill -x freeradius; sleep 0.5
grep -q '^thinuser' $R/mods-config/files/authorize || sed -i '1i thinuser Cleartext-Password := "Secret-Pw1"' $R/mods-config/files/authorize
install -m 640 -g freerad /lab/pki/server.key $R/certs/lab-server.key
install -m 644 /lab/pki/server.crt $R/certs/lab-server.crt; install -m 644 /lab/pki/ca.crt $R/certs/lab-ca.crt
sed -i -E "s#^(\s*private_key_file\s*=).*#\1 $R/certs/lab-server.key#; s#^(\s*certificate_file\s*=).*#\1 $R/certs/lab-server.crt#; s#^(\s*ca_file\s*=).*#\1 $R/certs/lab-ca.crt#; s#^(\s*private_key_password\s*=).*#\1#" $R/mods-available/eap
freeradius -X > /lab/out/freeradius.log 2>&1 &
sleep 3; grep -q "Ready to process requests" /lab/out/freeradius.log && echo "freeradius ready" || { tail -20 /lab/out/freeradius.log; exit 1; }
