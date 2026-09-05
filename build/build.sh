#!/bin/bash
# Builds the linktest-os ISO using Alpine's mkimage.sh with a custom profile.
# Intended to run inside an alpine:3.20 container (see .github/workflows/build-iso.yml)
# or a local Alpine VM/container for dev iteration — see docs in README "Local dev loop".
set -euo pipefail

ALPINE_VERSION="3.20"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/out"

mkdir -p "${OUT_DIR}"

# Fetch Alpine's mkimage tooling if not already vendored. Uses the GitHub
# mirror, not gitlab.alpinelinux.org directly -- Alpine's GitLab returns
# HTTP 418 to GitHub Actions' runner IP ranges (a known block against CI
# traffic), which broke this on the very first tag-triggered CI run.
if [ ! -d "${REPO_ROOT}/build/aports" ]; then
  git clone --depth 1 -b "${ALPINE_VERSION}-stable" \
    https://github.com/alpinelinux/aports.git \
    "${REPO_ROOT}/build/aports"
fi

# mkimage.sh's kernel build step (alpine-conf's /sbin/update-kernel) signs
# the kernel-modules squashfs (modloop) via its sign_modloop() function,
# which sources ~/.abuild/abuild.conf and reads $PACKAGER_PRIVKEY -- with
# no key configured it fails with "Could not open file or uri for loading
# private key". Found by actually running this build and reading
# update-kernel's source; not documented anywhere upstream we started from,
# and easy to get wrong: `abuild-keygen --kernel` looks like the obvious
# flag for a *kernel* signing key, but it sets $KERNEL_SIGNING_KEY, a
# different variable that sign_modloop() never reads. Plain `-a` (append)
# is what actually sets $PACKAGER_PRIVKEY. `-i` (install the pubkey into
# /etc/apk/keys) is deliberately omitted -- it shells out to doas/sudo to
# do the copy even when already running as root, and isn't installed in
# this container; we don't need the pubkey installed anywhere for signing
# to work, only the private key referenced from abuild.conf.
#
# `alpine-sdk` (already a required package for this script) provides
# abuild-keygen. Skip regenerating if a key is already configured, so
# re-running this in a persistent local dev VM is a no-op.
if ! grep -q '^PACKAGER_PRIVKEY=' /root/.abuild/abuild.conf 2>/dev/null; then
  abuild-keygen -a -n
fi

# Profile: package list + overlay wiring. See build/mkimg.linktest.sh and
# build/genapkovl-linktest.sh.
export OVERLAY_DIR="${REPO_ROOT}/overlay"
export SRC_DIR="${REPO_ROOT}/src"

# mkimage.sh resolves `--profile linktest` and the genapkovl script it
# references (apkovl="genapkovl-linktest.sh" in mkimg.linktest.sh) by
# looking inside its OWN scripts/ directory -- i.e. build/aports/scripts/,
# not this repo's build/. Neither file lives there on disk; they have to be
# copied in before every invocation, since build/aports/ is a throwaway
# clone that isn't part of this repo.
cp "${REPO_ROOT}/build/mkimg.linktest.sh" "${REPO_ROOT}/build/aports/scripts/mkimg.linktest.sh"
cp "${REPO_ROOT}/build/genapkovl-linktest.sh" "${REPO_ROOT}/build/aports/scripts/genapkovl-linktest.sh"
chmod +x "${REPO_ROOT}/build/aports/scripts/genapkovl-linktest.sh"

# mkimg.base.sh's section_apkovl() reads the apkovl script via a bare
# relative redirect (`checksum < "$apkovl"`, i.e. `< "genapkovl-linktest.sh"`
# with no directory) rather than the resolved path build_apkovl() itself
# uses -- it only opens correctly if the shell's cwd is already
# build/aports/scripts/ when mkimage.sh runs, which is Alpine's own assumed
# invocation convention (cd into scripts/, then ./mkimage.sh). Found by
# actually running this build: skipping this cd doesn't stop the build (the
# error is non-fatal, and build_apkovl()'s own path search still finds and
# runs our script fine), but it does leave section_apkovl's build-cache key
# empty/unstable, so cd there properly instead.
(
  cd "${REPO_ROOT}/build/aports/scripts"
  sh ./mkimage.sh \
    --tag "linktest-os" \
    --outdir "${OUT_DIR}" \
    --arch x86_64 \
    --repository "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main" \
    --repository "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community" \
    --profile linktest
)

mv "${OUT_DIR}"/alpine-linktest-*.iso "${OUT_DIR}/linktest-os.iso" 2>/dev/null || true

echo "Build complete: ${OUT_DIR}/linktest-os.iso"
