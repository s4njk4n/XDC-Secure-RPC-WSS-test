#!/usr/bin/env bash
# This script has been replaced by xdc-rpc, which does everything from one menu.
# Running it downloads the latest xdc-rpc release, checks it, and opens it.
# Guide: https://xdcoutpost.xyz/XDC-Secure-RPC-WSS-test/
set -euo pipefail
url=https://github.com/s4njk4n/XDC-Secure-RPC-WSS-test/releases/latest/download
tmp=$(mktemp -d)
echo "This script has been replaced by xdc-rpc. Downloading the latest version..."
curl -fsSL -o "$tmp/xdc-rpc.sh" "$url/xdc-rpc.sh"
curl -fsSL -o "$tmp/xdc-rpc.sh.sha256" "$url/xdc-rpc.sh.sha256"
if ! (cd "$tmp" && sha256sum -c --status xdc-rpc.sh.sha256); then
  echo "The download didn't match its published checksum. Please try again." >&2
  exit 1
fi
exec sudo bash "$tmp/xdc-rpc.sh"
