#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$ROOT"
source configs/course.env; source configs/lab-06.env
cat <<'WARNING'
DANGER: this removes Lab 06 scaling policies, alarms, and the scalable target.
DANGER: confirm Lab 10 and the CloudWatch lab no longer need these resources.
DANGER: do not run this during normal verification or while the service is live.
DANGER: review every target before uncommenting deletion commands.
WARNING
echo 'Dry run only. No cleanup action was executed.'
