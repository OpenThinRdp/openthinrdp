#!/bin/bash
# At every start (openthinrdp-secrets.service, before the network and SSH), lib/secrets.sh:
# - the secrets kept in the TPM out into memory, their usual paths linked to that copy;
# - with a TPM and TPM_SECRETS on, the plain files of a device set up before into the TPM;
# - with TPM_SECRETS=off, the secrets in the TPM back to plain files (the way back).
. /opt/openthinrdp/lib/common.sh
. "$OTR/lib/secrets.sh"
mkdir -p "$OTR_LOG"; touch "$OTR_EVENTS"
install -d -m 700 "$OTR_SECRETS"
# The TPM driver may still be loading. The unit does not pull tpm2.target: on Debian it always waits for /dev/tpmrm0,
# up to 90 s at every boot of a device that has no TPM at all (most old thin clients). So only when the firmware
# declares a TPM 2.0 (ACPI table TPM2) its device is waited for here, at most 10 s.
[ -e /sys/firmware/acpi/tables/TPM2 ] && [ ! -e /dev/tpmrm0 ] && udevadm wait --timeout=10 /dev/tpmrm0 >/dev/null 2>&1
ON=0; secret_enabled && ON=1
OFF=0; [ "$(secret_setting)" = off ] && OFF=1
moved=""; back=""; lost=""; retry=""
for n in "${!OTR_SECRET_FILES[@]}"; do
  p=${OTR_SECRET_FILES[$n]}
  if secret_sealed "$n"; then
    # A TPM may answer late or fail once (a firmware TPM still busy at power on): three tries at this start, and a
    # secret is given up only after 3 starts in a row without it. Set aside at the first failure, the Wi-Fi key was
    # lost for good after one bad start, and every save refused it from then on (0.3.6, #201)
    if ! { secret_unseal "$n" || { sleep 2; secret_unseal "$n"; } || { sleep 5; secret_unseal "$n"; }; }; then
      f=$(( $(cat "$OTR_SEALED/$n.fails" 2>/dev/null || echo 0) + 1 ))
      if [ $f -ge 3 ]; then rm -f "$OTR_SEALED/$n.fails"; lost="$lost $n"
      else echo $f > "$OTR_SEALED/$n.fails"; retry="$retry $n"; fi
      continue
    fi
    rm -f "$OTR_SEALED/$n.fails"
    if [ $OFF = 1 ]; then
      t=$(mktemp); cp "$OTR_SECRETS/$n" "$t" && secret_plain "$n" "$t" && back="$back $n"; rm -f "$t"
    elif secret_linked "$n"; then
      secret_link "$n"
    elif [ -e "$p" ]; then
      # a plain copy next to the one in the TPM (e.g. host keys created again by an openssh-server upgrade) is never
      # used: removed, so no secret stays readable on the disk
      rm -f "$p"
    fi
  elif [ $ON = 1 ] && [ -f "$p" ] && [ ! -L "$p" ] && [ -s "$p" ]; then
    t=$(mktemp); cp -p "$p" "$t" && secret_store "$n" "$t" && secret_sealed "$n" && moved="$moved $n"; rm -f "$t"
  fi
done
[ -n "$moved" ] && ev "secrets moved into the TPM:$moved (plain files deleted; on flash memory old blocks may survive until overwritten)"
[ -n "$back" ] && ev "secrets back to root-only files (TPM_SECRETS=off):$back"
[ -n "$retry" ] && ev "secrets not readable from the TPM at this start:$retry (kept, tried again at the next start; given up after 3 starts in a row)"
# not readable any more (TPM cleared or replaced, disk moved to another device): set aside, never retried at every
# start. SSH host keys are created again by apply.sh; the folder password and the Wi-Fi key must be set again.
if [ -n "$lost" ]; then
  for n in $lost; do mv -f "$OTR_SEALED/$n.cred" "$OTR_SEALED/$n.cred.unreadable"; secret_linked "$n" && rm -f "${OTR_SECRET_FILES[$n]}"; done
  ev "secrets NOT readable from the TPM:$lost (TPM cleared or replaced, or the disk moved to another device): set them again"
fi
# sshd starts after this service: it must already know where the host keys are (in memory when in the TPM)
secret_sshd_hostkeys
exit 0
