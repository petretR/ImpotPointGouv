#!/usr/bin/env bash
# Every .lua file listed in the toc must exist (a missing file silently breaks the addon in game).
set -euo pipefail
missing=0
while IFS= read -r line; do
  line="${line%$'\r'}"
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ "$line" == *.lua ]] || continue
  f="${line//\\//}"
  if [[ ! -f "$f" ]]; then echo "missing: $f"; missing=1; fi
done < ImpotPointGouv.toc
exit $missing
