#!/usr/bin/env bash
# Strip tags from a decompiled help page so it can be read or grepped as text.
#   usage: html2txt.sh docs/api/Interop...ExportToPng.html
#   grep -ril "ZoomExtents" docs/DraftSight/*.htm* | head -5 | xargs -I{} html2txt.sh {}
set -euo pipefail
perl -0777 -pe '
  s{<(script|style)[^>]*>.*?</\1>}{}gs;
  s{<[^>]+>}{ }gs;
  s{&nbsp;}{ }g; s{&quot;}{"}g; s{&lt;}{<}g; s{&gt;}{>}g; s{&amp;}{&}g;
  s{[ \t]+}{ }g; s{\n\s*\n+}{\n}g;
' "$1"
