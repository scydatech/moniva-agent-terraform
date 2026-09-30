#!/usr/bin/env bash
# Packages the investigation agent for AgentCore Runtime direct code deployment:
# agent code + dependencies built for Linux arm64 / Python 3.13, zipped to <out_dir>/agent.zip.
# Called by Terraform (agent.tf); can also be run by hand.
set -euo pipefail

SRC_DIR="${1:?usage: build_agent.sh <agent_dir> <out_dir>}"
OUT_DIR="${2:?usage: build_agent.sh <agent_dir> <out_dir>}"
STAGE="$OUT_DIR/agent_package"

if ! python3 -m pip --version >/dev/null 2>&1; then
  echo "ERROR: pip is required to package the agent. Install it with: sudo apt install -y python3-pip" >&2
  exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE"

# Installs only into the package folder; the system Python is not touched.
PIP_BREAK_SYSTEM_PACKAGES=1 python3 -m pip install \
  --quiet --no-compile --upgrade \
  --target "$STAGE" \
  --platform manylinux2014_aarch64 --implementation cp --python-version 3.13 --only-binary=:all: \
  -r "$SRC_DIR/requirements.txt"

cp "$SRC_DIR"/*.py "$STAGE"/

python3 - "$STAGE" "$OUT_DIR/agent.zip" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d != "__pycache__"]
        for name in sorted(files):
            path = os.path.join(root, name)
            info = zipfile.ZipInfo(os.path.relpath(path, src))
            info.external_attr = 0o644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(path, "rb") as fh:
                z.writestr(info, fh.read())
print(f"Built {dst} ({os.path.getsize(dst) // 1024} KB)")
PY
