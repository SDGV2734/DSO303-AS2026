#!/usr/bin/env bash
# Upload one student transcript using the instance profile credential provider.
set -euo pipefail

if [ "$#" -ne 2 ] || [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
  echo "Usage: $0 <student-id> <file-path>" >&2
  exit 2
fi

student_id=$1
file_path=$2

if [ ! -f "$file_path" ]; then
  echo "Error: file does not exist: $file_path" >&2
  exit 3
fi

case "$student_id" in
  *[!A-Za-z0-9._-]*|'')
    echo "Error: student ID may contain only letters, numbers, dot, underscore, and hyphen" >&2
    exit 4
    ;;
esac

bucket_name=${USMS_BUCKET_NAME:-usms-student-data}
filename=$(basename "$file_path")

aws s3 cp "$file_path" \
  "s3://${bucket_name}/transcripts/${student_id}/${filename}"
