#!/usr/bin/env bash
# =============================================================================
#  fetch-kb-update.sh
#  Scrapes Microsoft Update Catalog to find and download a .msu/.cab/.exe
#  update package directly, without needing a browser/JavaScript.
#  See ../docs/windows7-compat-updates.md for context on why this was
#  needed and which specific KBs matter for Windows 7 SP1 x64 in 2026.
#
#  Usage:
#     ./fetch-kb-update.sh KB3118401
#
#  This will:
#    1. search the catalog for that KB number
#    2. print every matching title with its internal GUID, so you can see
#       which one is for your OS/architecture
#    3. ask you to re-run with that GUID to actually resolve+download it:
#     ./fetch-kb-update.sh --guid <GUID> [output-file]
# =============================================================================
set -euo pipefail

UA="Mozilla/5.0 (Windows NT 6.1; Win64; x64)"

search() {
    local kb="$1"
    local html; html="$(mktemp)"
    curl -s "https://www.catalog.update.microsoft.com/Search.aspx?q=$kb" -A "$UA" -o "$html"

    python3 - "$html" <<'PY'
import re, sys
html = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
ids = sorted(set(re.findall(r'goToDetails\("([a-f0-9\-]+)"\)', html)))
if not ids:
    print("No results found.")
    sys.exit(0)
for uid in ids:
    anchor = f'goToDetails("{uid}")'
    idx = html.find(anchor)
    snippet = html[max(0, idx - 2500):idx]
    m = re.search(r'NoBreakLink">\s*([^<\n]+)', snippet)
    title = m.group(1).strip() if m else "?"
    print(f"{uid}  {title}")
PY
    rm -f "$html"
}

resolve_download() {
    local guid="$1"
    local out="${2:-dl.html}"
    curl -s "https://www.catalog.update.microsoft.com/DownloadDialog.aspx" -A "$UA" \
        --data-urlencode "updateIDs=[{\"size\":0,\"languages\":\"\",\"uidInfo\":\"$guid\",\"updateID\":\"$guid\"}]" \
        --data-urlencode 'updateIDsBlockedForImport=' \
        --data-urlencode 'wsusApiPresent=' \
        --data-urlencode 'contentImport=' \
        --data-urlencode 'sku=' \
        --data-urlencode 'serverName=' \
        --data-urlencode 'ssl=' \
        --data-urlencode 'portNumber=' \
        --data-urlencode 'version=' \
        -o "$out"
    grep -oE "https?://[^'\" ]+\.(msu|cab|exe)" "$out" | sort -u
}

case "${1:-}" in
    --guid)
        [ -n "${2:-}" ] || { echo "Usage: $0 --guid <GUID>"; exit 1; }
        resolve_download "$2"
        ;;
    "" )
        echo "Usage:"
        echo "  $0 <KBNUMBER>              # search, list titles+GUIDs"
        echo "  $0 --guid <GUID>           # resolve one GUID to a direct URL"
        exit 1
        ;;
    * )
        search "$1"
        echo
        echo "Pick the GUID matching your OS/architecture above, then run:"
        echo "  $0 --guid <GUID>"
        ;;
esac
