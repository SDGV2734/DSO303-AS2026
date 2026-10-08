#!/bin/bash
# USMS data-tier bootstrap. Cloud-init runs this as root on first boot.
set -euxo pipefail

MARKER=/var/log/usms-db-bootstrap.done
if [ -f "$MARKER" ]; then
  echo "USMS database bootstrap already completed; refusing to run twice"
  exit 0
fi

dnf -y update
dnf -y install postgresql15-server

postgresql-setup --initdb
systemctl enable --now postgresql

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='usms'" | grep -q 1; then
  sudo -u postgres createdb usms
fi

TOKEN=$(curl -fsS -X PUT \
  http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')
INSTANCE_ID=$(curl -fsS \
  -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

printf 'instance_id=%s completed_at=%s\n' \
  "$INSTANCE_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
