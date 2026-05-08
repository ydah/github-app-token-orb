#!/usr/bin/env bash
set -euo pipefail

major_version="$(node -p 'process.versions.node.split(".")[0]')"
if [ "${major_version}" -lt 20 ]; then
  echo "Node.js 20 or newer is required." >&2
  exit 1
fi
