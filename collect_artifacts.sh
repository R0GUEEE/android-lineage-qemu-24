#!/bin/bash
#
# Collect + report the arm64only artifacts produced by build.sh.
#
# Usage:
#   ./collect_artifacts.sh verify   # print a detailed report of what exists where
#                                   # (non-fatal, used by CI before publishing)
#   ./collect_artifacts.sh list     # print only the release-asset files that exist,
#                                   # one per line (consumed by the release step)
#
# Everything is resolved relative to $ARTIFACTS_DIR (default: artifacts/) and
# $OUT_DIR (default: android/lineage/out/target/product/virtio_arm64only).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT" || exit 1

ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts}"
OUT_DIR="${OUT_DIR:-android/lineage/out/target/product/virtio_arm64only}"
MODE="${1:-verify}"

# Expected release assets (literal names; build.sh always emits the exact names).
REQUIRED=(
  "lineage_virtio_arm64only-ota.zip"
  "boot_arm64only.img"
  "EFI.img"
)
EXPECTED=(
  "lineage_virtio_arm64only-ota.zip"
  "boot_arm64only.img"
  "vendor_boot_arm64only.img"
  "recovery_arm64only-userdebug.img"
  "recovery_arm64only.img"
  "EFI.img"
)

# Extra, non-release files we also copy out for inspection/debugging.
EXTRA=(
  "dynamic_partitions_op_list"
  "system.transfer.list"
  "vendor.transfer.list"
  "product.transfer.list"
  "dynamic_partitions_info.txt"
)

have() { [ -f "$ARTIFACTS_DIR/$1" ]; }

case "$MODE" in
  list)
    {
      for f in "${EXPECTED[@]}" "${REQUIRED[@]}"; do
        [ -f "$ARTIFACTS_DIR/$f" ] && printf '%s\n' "$f"
      done
      for u in "$ARTIFACTS_DIR"/UTM-VM-lineage-24*.zip; do
        [ -f "$u" ] && basename "$u"
      done
    } | sort -u
    exit 0
    ;;
  verify) ;;
  *)
    echo "usage: $0 [verify|list]" >&2
    exit 2
    ;;
esac

echo "== Artifact report (arm64only, LineageOS 24.0) =="
echo "workspace:      $ROOT"
echo "artifacts dir:  $ARTIFACTS_DIR"
echo "out dir:        $OUT_DIR"
echo

echo "-- release assets (from $ARTIFACTS_DIR) --"
missing=0
total_bytes=0
report() { # $1=name
  if have "$1"; then
    bytes=$(stat -c '%s' "$ARTIFACTS_DIR/$1" 2>/dev/null || echo 0)
    total_bytes=$((total_bytes + bytes))
    printf '  OK   %-42s %12s bytes\n' "$1" "$bytes"
  else
    printf '  MISS %-42s <-- EXPECTED\n' "$1"
    missing=$((missing + 1))
  fi
}
report lineage_virtio_arm64only-ota.zip
report boot_arm64only.img
report EFI.img
# UTM bundle: name embeds $(LINEAGE_VERSION) (patched with -jqssun), so glob it.
utm_found=0
for u in "$ARTIFACTS_DIR"/UTM-VM-lineage-24*.zip; do
  if [ -f "$u" ]; then
    u=$(basename "$u")
    report "$u"
    utm_found=1
  fi
done
[ "$utm_found" = 1 ] || { printf '  MISS %-42s <-- EXPECTED\n' "UTM-VM-lineage-24*.zip"; missing=$((missing + 1)); }
# Optional (configuration dependent) files.
for o in vendor_boot_arm64only.img recovery_arm64only-userdebug.img recovery_arm64only.img; do
  if have "$o"; then
    bytes=$(stat -c '%s' "$ARTIFACTS_DIR/$o" 2>/dev/null || echo 0)
    total_bytes=$((total_bytes + bytes))
    printf '  OK   %-42s %12s bytes\n' "$o" "$bytes"
  else
    printf '  --   %-42s (not produced by this configuration)\n' "$o"
  fi
done
echo

echo "-- extra out-dir copies --"
for f in "${EXTRA[@]}"; do
  if have "$f"; then
    printf '  OK   %-42s %12s bytes\n' "$f" "$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
  else
    printf '  --   %-42s (not present)\n' "$f"
  fi
done
echo

echo "-- raw out dir (informational) --"
if [ -d "$OUT_DIR" ]; then
  for pattern in boot.img vendor_boot.img recovery.img EFI.img '*.transfer.list' \
                 dynamic_partitions_op_list '*.zip' 'VirtualMachine/UTM/*.zip'; do
    # shellcheck disable=SC2086
    find "$OUT_DIR" -maxdepth 2 -name "$pattern" -type f -printf '  %-60p %12s\n' 2>/dev/null
  done | sort -u
  echo "  (out dir size: $(du -sh "$OUT_DIR" 2>/dev/null | cut -f1))"
else
  echo "  <out dir does not exist>"
fi
echo

printf 'Total release payload: %s MB\n' "$((total_bytes / 1024 / 1024))"
if [ "$missing" -gt 0 ]; then
  echo "WARNING: $missing expected release asset(s) missing." >&2
  exit 1
fi
echo "All expected release assets present."
