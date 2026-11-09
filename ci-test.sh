#!/bin/bash
# Fast CI self-test: validates the workflow + build script without running AOSP.
# Usage: ./ci-test.sh
set -euo pipefail
cd "$(dirname "$0")"

echo "== bash -n (shell scripts) =="
for f in build.sh common.sh collect_artifacts.sh; do
  chmod +x "$f"
  bash -n "$f"
  echo "  OK  $f"
done

echo "== YAML parse (.github/workflows/build.yml) =="
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY'
import sys, yaml
d = yaml.safe_load(open('.github/workflows/build.yml'))
print('  OK  top-level keys:', ', '.join(sorted(str(k) for k in d)))
PY
else
  echo "  (python3 not available; run: pip install pyyaml)"
fi

echo "== collect_artifacts.sh smoke test =="
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/artifacts"
for f in boot_arm64only.img EFI.img lineage_virtio_arm64only-ota.zip \
         UTM-VM-lineage-24.0-20260101-UNOFFICIAL-jqssun.zip vendor_boot_arm64only.img \
         recovery_arm64only-userdebug.img recovery_arm64only.img; do
  printf x > "$TMP/artifacts/$f"
done
cp collect_artifacts.sh "$TMP/"
( cd "$TMP" && chmod +x collect_artifacts.sh && ./collect_artifacts.sh verify >/dev/null && test "$(./collect_artifacts.sh list | wc -l)" -eq 7 )
echo "  OK  7/7 assets detected"
