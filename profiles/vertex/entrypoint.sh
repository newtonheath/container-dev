#!/usr/bin/env bash
# Copy the mounted public key into place with correct ownership for sshd.
if [[ -f /tmp/pubkey/authorized_keys ]]; then
  cp /tmp/pubkey/authorized_keys /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi

exec /usr/sbin/sshd -D
