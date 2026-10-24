#!/usr/bin/env bash
# Context-safe lookup inside the decompiled DraftSight help tree.
#
# That tree is tens of megabytes across thousands of pages, so it is a search target and never a
# reading target: no agent should open pages until it knows which one it wants. This resolves the page
# by NAME first (decompiled CHM filenames embed Interface~Member, so this is cheap and precise), then
# prints the stripped text of at most -n pages, truncated to -l lines. Total output stays in the tens
# of lines even when the tree is huge.
#
#   scripts/docs-lookup.sh InsertHatchByBoundary      # prose for one API member
#   scripts/docs-lookup.sh -t ZoomFit                 # command reference only (valid RunCommand names)
#   scripts/docs-lookup.sh dsLnWt -n 3                # an enum family, up to 3 pages
#   scripts/docs-lookup.sh GetEntities -c             # search page CONTENT, list matches only
set -euo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS="$SKILL_DIR/docs"
PAGES=1; MAXL=70; RAW=0; CONTENT=0; ONLY=''

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

PAT=''
while [ $# -gt 0 ]; do
  case "$1" in
    -n) PAGES="$2"; shift 2 ;;
    -l) MAXL="$2"; shift 2 ;;
    -t) ONLY="$DOCS/DraftSight/cmdref"; shift ;;
    -c) CONTENT=1; shift ;;
    -r) RAW=1; shift ;;
    -h|--help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) PAT="$1"; shift ;;
  esac
done
[ -n "$PAT" ] || usage

if [ ! -d "$DOCS" ]; then
  echo "docs/ is not generated. It is deliberately not shipped (vendor-copyrighted, tens of MB):"
  echo "  bash skills/draftsight-api/scripts/decompile-chm.sh"
  echo "For signatures you probably do not need it - the type library is exact and 2 MB:"
  echo "  powershell -File skills/draftsight-api/scripts/com-signature-oracle.ps1 -Types ISketchManager -Method <Name>"
  exit 3
fi

SCOPE="$DOCS"
[ -n "$ONLY" ] && { [ -d "$ONLY" ] || { echo "no such scope: $ONLY" >&2; exit 4; }; SCOPE="$ONLY"; }

if [ "$CONTENT" = 1 ]; then
  hits=$(grep -ril --include='*.htm*' -- "$PAT" "$SCOPE" | head -n "$PAGES" || true)
else
  hits=$(find "$SCOPE" -iname "*.htm*" -iname "*${PAT}*" | head -n "$PAGES" || true)
  if [ -z "$hits" ]; then
    echo "no page name matched; searching content instead"
    hits=$(grep -ril --include='*.htm*' -- "$PAT" "$SCOPE" | head -n "$PAGES" || true)
  fi
fi

if [ -z "$hits" ]; then
  echo "no match for: $PAT  (scope: ${SCOPE#"$SKILL_DIR"/})"
  echo "for an API member, the type library answers whether it exists at all: com-signature-oracle.ps1 -Search $PAT"
  exit 1
fi

for f in $hits; do
  echo "=== ${f#"$SKILL_DIR"/}"
  if [ "$RAW" = 1 ]; then
    head -c 4000 "$f"
    echo
  else
    "$(dirname "${BASH_SOURCE[0]}")/html2txt.sh" "$f" | head -n "$MAXL"
  fi
done
