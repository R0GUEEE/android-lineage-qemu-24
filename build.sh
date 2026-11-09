#!/bin/bash
#
# Build a LineageOS 24.0 (Android 17) arm64-only QEMU/UTM virtual-machine image.
#
# Fork of jqssun/android-lineage-qemu, retargeted at:
#   * repo manifest branch : lineage-24.0
#   * lunch target          : lineage_virtio_arm64only (a.k.a. `virtio_arm64only`)
#   * build types           : user, userdebug  (x86_64 targets dropped on purpose)
#
# Everything the CI needs is published into $ARTIFACTS_DIR (default ./artifacts)
# by a single explicit `cp` list, and the presence of every expected file is
# asserted at the end, so a silently changed out-dir layout fails the run instead
# of producing a release with missing assets.
#
# GRUB: we intentionally do NOT pin or downgrade GRUB. LineageOS 24.0 ships
# external/grub on branch lineage-24.0, which contains grub-core/fs/android_bootimg_fs.c
# and registers the `android_bootimg_fs` module in grub-core/Makefile.core.def.
# Nothing in this script touches external/grub.

set -euo pipefail

# ---------------------------------------------------------------------------
# Tunables (env-overridable)
# ---------------------------------------------------------------------------
LINEAGE_BRANCH="${LINEAGE_BRANCH:-lineage-24.0}"
DEVICE="${DEVICE:-virtio_arm64only}"
BUILD_TYPES="${BUILD_TYPES:-user userdebug}"
SYNC_JOBS="${SYNC_JOBS:-8}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
WORKDIR="${WORKDIR:-$PWD}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$PWD/artifacts}"

LINEAGE_SRC="$WORKDIR/android/lineage"
OUT_DIR="$LINEAGE_SRC/out/target/product/$DEVICE"

export DEBIAN_FRONTEND=noninteractive

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[fatal] %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Sanity: disk, CPU and RAM. AOSP + ccache needs a lot of all three.
# ---------------------------------------------------------------------------
log "Runner resources"
nproc
free -h || true
df -h "$WORKDIR" || true

AVAIL_KB=$(df -Pk "$WORKDIR" | awk 'NR==2 {print $4}')
AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
log "Free space on $WORKDIR: ${AVAIL_GB} GB"
if [ "$AVAIL_GB" -lt 120 ]; then
  warn "Only ${AVAIL_GB} GB free. A full arm64-only AOSP build needs roughly 150-250 GB"
  warn "including the repo checkout and ccache. A stock ubuntu-latest runner (14 GB free)"
  warn "CANNOT complete this build. Use a larger runner or a self-hosted one."
fi

# ---------------------------------------------------------------------------
# 1. Host dependencies
# ---------------------------------------------------------------------------
if command -v apt-get >/dev/null 2>&1; then
  log "Installing build dependencies"
  SUDO=""
  [ "$(id -u)" -ne 0 ] && SUDO="sudo"
  $SUDO apt-get update -y
  DEPS="sudo git android-sdk-platform-tools python-is-python3 python3-yaml qemu-utils \
bc bison build-essential ccache curl flex g++-multilib gcc-multilib git git-lfs gnupg gperf \
imagemagick protobuf-compiler python3-protobuf lib32readline-dev lib32z1-dev libdw-dev libelf-dev \
lz4 libsdl1.2-dev libssl-dev libxml2 libxml2-utils lzop pngcrush rsync schedtool squashfs-tools \
xsltproc zip zlib1g-dev meson glslang-tools python3-mako"
  # `meson-1.5` only exists on some Ubuntu images; fall back to plain meson.
  $SUDO apt-get install -y $DEPS || {
    warn "retrying dependency install without meson-1.5 pin"
    $SUDO apt-get install -y $(echo "$DEPS" | sed 's/ meson / /') || die "dependency install failed"
  }
else
  warn "apt-get not found: assuming dependencies are already installed (self-hosted runner)"
fi

git config --global user.name "github-actions[bot]"
git config --global user.email "github-actions[bot]@users.noreply.github.com"
git config --global trailer.changeid.key "Change-Id"
git config --global color.ui true
git lfs install

# ---------------------------------------------------------------------------
# 2. repo init / sync
# ---------------------------------------------------------------------------
log "Installing repo"
unset REPO_URL || true
mkdir -p "$WORKDIR/bin" "$LINEAGE_SRC"
curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo > "$WORKDIR/bin/repo"
chmod a+x "$WORKDIR/bin/repo"
export PATH="$WORKDIR/bin:$PATH"

cd "$LINEAGE_SRC"
export PATH="$LINEAGE_SRC/prebuilts/sdk/tools/linux/bin/:$PATH"

log "repo init -b $LINEAGE_BRANCH"
repo init --no-repo-verify \
  -u https://github.com/LineageOS/android.git \
  -b "$LINEAGE_BRANCH" \
  --git-lfs --no-clone-bundle --depth 1

log "repo sync -j $SYNC_JOBS"
repo sync -c --prune --force-sync --fail-fast --retry-fetches=8 -j "$SYNC_JOBS"

# Verify the manifest really resolved to lineage-24.0 (guards against a typo or a
# manifest that silently fell back to another branch).
MANIFEST_BRANCH=$(git -C .repo/manifests rev-parse --abbrev-ref HEAD 2>/dev/null || true)
log "Manifest branch: ${MANIFEST_BRANCH:-unknown}"
if [ -n "$MANIFEST_BRANCH" ] && [ "$MANIFEST_BRANCH" != "$LINEAGE_BRANCH" ]; then
  die "manifest branch is '$MANIFEST_BRANCH', expected '$LINEAGE_BRANCH'"
fi

# GRUB is taken as LineageOS 24.0 ships it (branch lineage-24.0 of external/grub,
# which includes grub-core/fs/android_bootimg_fs.c). Do not pin/downgrade it;
# just report what we got.
if [ -f external/grub/grub-core/Makefile.core.def ]; then
  GRUB_REV=$(git -C external/grub rev-parse --short HEAD 2>/dev/null || echo unknown)
  GRUB_BRANCH=$(git -C external/grub rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
  if grep -q 'android_bootimg_fs' external/grub/grub-core/Makefile.core.def; then
    log "GRUB: $GRUB_BRANCH @ $GRUB_REV (android_bootimg_fs present)"
  else
    warn "GRUB: $GRUB_BRANCH @ $GRUB_REV -- android_bootimg_fs NOT found;"
    warn "GRUB boot menu will not be able to read Android boot images."
  fi
else
  warn "external/grub not checked out; cannot verify android_bootimg_fs"
fi

# LineageOS version suffix: keep the upstream behaviour.
sed -i 's/-$(LINEAGE_BUILDTYPE)/-jqssun/g' vendor/lineage/config/version.mk

# ---------------------------------------------------------------------------
# 3. Build helpers
# ---------------------------------------------------------------------------
source build/envsetup.sh

# Non-A/B updater (recovery-based OTA + Magisk-patchable boot.img), matching the
# shipped LineageOS 23.2 "v12" images.
export AB_OTA_UPDATER=false
export ROOMSERVICE_BRANCHES="lineage-24.0 lineage-23.2 lineage-23.1"

# ccache keeps the second build type (user after userdebug) cheap.
export USE_CCACHE=1
export CCACHE_DIR="${CCACHE_DIR:-$WORKDIR/.ccache}"
export CCACHE_EXEC="${CCACHE_EXEC:-/usr/bin/ccache}"
mkdir -p "$CCACHE_DIR"
ccache -M 50G >/dev/null 2>&1 || true

mkdir -p "$ARTIFACTS_DIR"
ARTIFACTS_DIR="$(cd "$ARTIFACTS_DIR" && pwd)"
export ARTIFACTS_DIR
: > "$ARTIFACTS_DIR/.collected"

# copy_if_present <src> <dst-name>
copy_if_present() {
  local src="$1" name="$2"
  if [ -f "$src" ]; then
    cp -f "$src" "$ARTIFACTS_DIR/$name"
    printf '%s\n' "$name" >> "$ARTIFACTS_DIR/.collected"
    log "collected $name ($(stat -c '%s' "$src") bytes)"
  else
    warn "missing $src (skipping $name)"
  fi
}

# collect_glob <pattern>   (glob relative to $OUT_DIR; may contain '/' for nested paths)
collect_glob() {
  local pattern="$1" hit name
  # shellcheck disable=SC2086
  for hit in "$OUT_DIR"/$pattern; do
    [ -f "$hit" ] || continue
    name=$(basename "$hit")
    cp -f "$hit" "$ARTIFACTS_DIR/$name"
    printf '%s\n' "$name" >> "$ARTIFACTS_DIR/.collected"
    log "collected $name ($(stat -c '%s' "$hit") bytes)"
    return 0
  done
  warn "no $pattern in $OUT_DIR"
  return 1
}

# Publish everything produced by one lunch target into $ARTIFACTS_DIR.
collect_all() {
  local bt="$1"

  # --- always-present release assets -------------------------------------
  copy_if_present "$OUT_DIR/boot.img"  "boot_arm64only.img"
  collect_glob 'lineage-*-ota.zip'                     # -> lineage_virtio_arm64only-ota.zip

  # --- UTM bundle --------------------------------------------------------
  collect_glob 'VirtualMachine/UTM/UTM-VM-*.zip' \
    || collect_glob 'VirtualMachine/UTM/*.zip' \
    || collect_glob 'UTM-VM-*.zip'

  # --- EFI / vendor_boot -------------------------------------------------
  # EFI.img = $PRODUCT_OUT/EFI.img (GRUB ESP built by device/virt/virt-common),
  # produced by the GRUB/espimage path that the disk image and otapackage need.
  copy_if_present "$OUT_DIR/EFI.img"  "EFI.img"
  copy_if_present "$OUT_DIR/vendor_boot.img" "vendor_boot_arm64only.img"

  # --- recovery ----------------------------------------------------------
  # The user build is done last, so the plain (signed-if-keys-exist) recovery.img
  # ending up in $ARTIFACTS_DIR under the generic name is the user one.
  if [ "$bt" = "userdebug" ]; then
    copy_if_present "$OUT_DIR/recovery.img" "recovery_arm64only-userdebug.img"
  else
    copy_if_present "$OUT_DIR/recovery.img" "recovery_arm64only.img"
  fi

  # --- cheap extras for inspection (not released) ------------------------
  copy_if_present "$OUT_DIR/dynamic_partitions_op_list" "dynamic_partitions_op_list"
  copy_if_present "$OUT_DIR/system.transfer.list"  "system.transfer.list"
  copy_if_present "$OUT_DIR/vendor.transfer.list"  "vendor.transfer.list"
  copy_if_present "$OUT_DIR/product.transfer.list" "product.transfer.list"
  copy_if_present "$OUT_DIR/dynamic_partitions_info.txt" "dynamic_partitions_info.txt"

  # Useful for debugging kernel/GRUB bootstrap inside the VM.
  [ -f "$OUT_DIR/obj/KERNEL_OBJ/.config" ] && \
    cp -f "$OUT_DIR/obj/KERNEL_OBJ/.config" "$ARTIFACTS_DIR/kernel_arm64only.config" || true
}

# ---------------------------------------------------------------------------
# 4. Build: userdebug (recovery + full images), then user
# ---------------------------------------------------------------------------
build_one() {
  local device="$1" bt="$2"
  log "Building $device-$bt"
  # `breakfast` == `lunch lineage_<device>-<bt>`
  breakfast "$device" "$bt"

  # recoveryimage first so recovery_arm64only*.img is a real image.
  m recoveryimage

  m vm-utm-zip otapackage

  collect_all "$bt"
}

for bt in $BUILD_TYPES; do
  case "$bt" in
    user|userdebug) build_one "$DEVICE" "$bt" ;;
    *) die "unsupported build type '$bt' (only user/userdebug are built by this fork)" ;;
  esac
done

# ---------------------------------------------------------------------------
# 5. Verify + report
# ---------------------------------------------------------------------------
chmod +x ./collect_artifacts.sh 2>/dev/null || true
log "Artifact report"
if ! ARTIFACTS_DIR="$ARTIFACTS_DIR" OUT_DIR="$OUT_DIR" ./collect_artifacts.sh verify; then
  die "expected release artifacts are missing (see report above)"
fi

# Machine-readable summary for the workflow.
{
  echo "## LineageOS ${LINEAGE_BRANCH} / ${DEVICE} build summary"
  echo
  echo '| file | size |'
  echo '| --- | --- |'
  for f in "$ARTIFACTS_DIR"/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in .*) continue ;; esac
    printf '| `%s` | %s |\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
  done
  echo
  echo "Out dir: \`$OUT_DIR\` ($(du -sh "$OUT_DIR" 2>/dev/null | cut -f1))"
} > "$ARTIFACTS_DIR/BUILD-SUMMARY.md"

log "Done. Artifacts in $ARTIFACTS_DIR"
ls -la "$ARTIFACTS_DIR"
