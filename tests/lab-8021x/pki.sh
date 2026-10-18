#!/bin/bash
# Test PKI of the 802.1X lab: a CA, the RADIUS server, a client; a rogue CA with a server of the same name; a server
# with another name. Runs inside the lab image (openssl), writes into $1.
set -e
D=$1; mkdir -p "$D"; cd "$D"
sub(){ # name CN ca extfile-lines
  local n=$1 cn=$2 ca=$3 ext=$4
  openssl req -new -newkey rsa:2048 -nodes -keyout $n.key -subj "/O=Lab/CN=${cn//\//\\/}" -out $n.csr 2>/dev/null
  printf '%b\n' "$ext" > $n.ext
  openssl x509 -req -in $n.csr -CA $ca.crt -CAkey $ca.key -CAcreateserial -days 30 -sha256 -extfile $n.ext -out $n.crt 2>/dev/null
}
for c in ca rogue-ca; do
  openssl req -x509 -newkey rsa:2048 -nodes -keyout $c.key -subj "/O=Lab/CN=Lab $c" -days 30 -sha256 \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign -out $c.crt 2>/dev/null
done
SRV='basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth'
sub server radius.lab.example ca "$SRV\nsubjectAltName=DNS:radius.lab.example"
sub rogue-server radius.lab.example rogue-ca "$SRV\nsubjectAltName=DNS:radius.lab.example"
sub other-server evil.other.example ca "$SRV\nsubjectAltName=DNS:evil.other.example"
CLI='basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth'
sub client "host/thin1.lab.example" ca "$CLI"
sub client2 "host/thin2.lab.example" ca "$CLI"
# the client as the manager sends it: PEM with an encrypted key, PKCS#12 (current and legacy algorithms)
openssl pkey -in client.key -aes256 -passout pass:Key-Pw1 -out client-enc.key
openssl pkcs12 -export -inkey client.key -in client.crt -certfile ca.crt -passout pass:Pfx-Pw1 -out client.p12
openssl pkcs12 -export -legacy -inkey client.key -in client.crt -passout pass:Pfx-Pw1 -out client-legacy.p12 2>/dev/null || true
chmod 644 *
ls
