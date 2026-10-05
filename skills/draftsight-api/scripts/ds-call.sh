#!/usr/bin/env bash
# Minimal DraftSight HTTP/JSON API client. Always echoes the full owner object.
#   ds-call.sh boot                                  -> app / doc / model / sketchManager, one JSON per line
#   ds-call.sh version                               -> liveness probe (must be on dsApplication)
#   ds-call.sh call '<ownerJson>' <Fn> '<argsJson>'  -> one call
set -euo pipefail
URL="${DSAPI_URL:-http://127.0.0.1:7776}"

post() { curl -s -m 15 -X POST "$URL" -H 'Content-Type: text/json;charset=UTF-8' -d "$1"; }
fld()  { sed -n "s/.*\"$1\":\([0-9][0-9]*\).*/\1/p"; }
owner() { echo "{\"id\":$1,\"macroId\":$2,\"type\":$3}"; }

app_raw=$(post '{"language":"dsJavaScript","owner":{"type":"jsScriptManager"},"functionName":"getApplication","args":[]}')
if ! printf '%s' "$app_raw" | grep -q '"dsApplication"'; then
  echo "getApplication failed: $app_raw" >&2
  echo "DraftSight is not running, or the broker has no live jsServer link." >&2
  exit 1
fi

invoke() { # invoke <ownerJson> <Fn> <argsJson>
  post "{\"language\":\"dsJavaScript\",\"owner\":$1,\"functionName\":\"$2\",\"args\":$3}"
}

ai=$(printf '%s' "$app_raw" | fld id);      am=$(printf '%s' "$app_raw" | fld macroId)
app=$(owner "$ai" "$am" '"dsApplication"')

case "${1:-boot}" in
  version) invoke "$app" GetVersion '[]' ;;
  boot)
    echo "app $app_raw"
    doc=$(invoke "$app" GetActiveDocument '[]')
    echo "doc $doc"
    di=$(printf '%s' "$doc" | fld id); dm=$(printf '%s' "$doc" | fld macroId)
    if [ -n "${di:-}" ]; then
      downer=$(owner "$di" "$dm" '"dsDocument"')
      model=$(invoke "$downer" GetModel '[]')
      echo "model $model"
      mi=$(printf '%s' "$model" | fld id); mm=$(printf '%s' "$model" | fld macroId)
      if [ -n "${mi:-}" ]; then
        echo "sketchManager $(invoke "$(owner "$mi" "$mm" '"dsModel"')" GetSketchManager '[]')"
      fi
    fi
    ;;
  call) invoke "$2" "$3" "${4:-[]}"
    ;;
  *) echo "usage: ds-call.sh [boot|version|call <ownerJson> <Fn> <argsJson>]" >&2; exit 2 ;;
esac
