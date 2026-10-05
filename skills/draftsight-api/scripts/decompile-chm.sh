#!/usr/bin/env bash
# Decompile DraftSight CHM help files into greppable HTML under docs/<name>/.
# Windows' built-in hh.exe does the extraction; no third-party tool is needed.
#   usage: decompile-chm.sh                 -> the default set
#   usage: decompile-chm.sh DraftSight.chm  -> one file
set -euo pipefail

HELP_WIN='C:\Program Files\Dassault Systemes\DraftSight\Help\english'
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_ROOT="$SKILL_DIR/docs"

DEFAULT=(
  draftsightapi.chm            # API reference (classes, methods, enums, examples)
  DraftSight.chm               # application + command reference (valid RunCommand names)
  DraftSight_Lisp_Reference.chm
  DSAPIHelp.chm
  DraftSightMech.chm
  DraftSightSW.chm
  NestingManager.chm
  DraftSightConnected.chm
)

if [ "$#" -eq 0 ]; then names=("${DEFAULT[@]}"); else names=("$@"); fi

for chm in "${names[@]}"; do
  if [ ! -f "$(cygpath -u "$HELP_WIN")/$chm" ]; then
    echo "skip: $chm not found in $HELP_WIN" >&2
    continue
  fi
  base="${chm%.chm}"
  mkdir -p "$OUT_ROOT/$base"
  outwin="$(cygpath -w "$OUT_ROOT/$base")"
  powershell -NoProfile -Command "Start-Process -FilePath 'C:\\Windows\\hh.exe' -ArgumentList '-decompile','$outwin','$HELP_WIN\\$chm' -Wait"
  n=$(find "$OUT_ROOT/$base" -name '*.htm*' | wc -l)
  echo "$chm -> docs/$base  ($n pages, $(du -sh "$OUT_ROOT/$base" | cut -f1))"
done
