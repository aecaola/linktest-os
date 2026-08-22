#!/bin/bash
# Builds the linktest-os ISO using Alpine's mkimage.sh with a custom profile.
# Intended to run inside an alpine:3.20 container (see .github/workflows/build-iso.yml)
# or a local Alpine VM/container for dev iteration — see docs in README "Local dev loop".
set -euo pipefail

ALPINE_VERSION="3.20"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/out"

mkdir -p "${OUT_DIR}"

# Fetch Alpine's mkimage tooling if not already vendored.
if [ ! -d "${REPO_ROOT}/build/aports" ]; then
  git clone --depth 1 -b "${ALPINE_VERSION}-stable" \
    https://gitlab.alpinelinux.org/alpine/aports.git \
    "${REPO_ROOT}/build/aports"
fi

# Profile: package list + overlay wiring. See build/mkimg.linktest.sh
export OVERLAY_DIR="${REPO_ROOT}/overlay"

sh "${REPO_ROOT}/build/aports/scripts/mkimage.sh" \
  --tag "linktest-os" \
  --outdir "${OUT_DIR}" \
  --arch x86_64 \
  --repository "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main" \
  --repository "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community" \
  --profile linktest

mv "${OUT_DIR}"/alpine-linktest-*.iso "${OUT_DIR}/linktest-os.iso" 2>/dev/null || true

echo "Build complete: ${OUT_DIR}/linktest-os.iso"
