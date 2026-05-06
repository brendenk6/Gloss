#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7778}"
RUN_ID="${RUN_ID:-$(date +%s)-$$}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gloss-smoke.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

log() {
  printf '==> %s\n' "$*"
}

fail() {
  printf 'smoke failed: %s\n' "$*" >&2
  exit 1
}

request() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local expected="${4:-200}"
  local out="$TMP_DIR/body.json"
  local status

  if [[ -n "$body" ]]; then
    status="$(curl -sS -m 5 -X "$method" -H 'Content-Type: application/json' -d "$body" -o "$out" -w '%{http_code}' "$url")"
  else
    status="$(curl -sS -m 5 -X "$method" -o "$out" -w '%{http_code}' "$url")"
  fi

  [[ "$status" == "$expected" ]] || {
    cat "$out" >&2 || true
    fail "$method $url returned HTTP $status, expected $expected"
  }
  cat "$out"
}

assert_json() {
  local expr="$1"
  local payload
  payload="$(cat)"
  PAYLOAD="$payload" python3 - "$expr" <<'PY'
import json
import os
import sys

expr = sys.argv[1]
payload = json.loads(os.environ["PAYLOAD"])
if not eval(expr, {"__builtins__": {}}, {"j": payload}):
    raise SystemExit(f"assertion failed: {expr}\npayload={json.dumps(payload, indent=2, sort_keys=True)}")
PY
}

assert_png() {
  local path="$1"
  python3 - "$path" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = path.read_bytes()
if not data.startswith(b"\x89PNG\r\n\x1a\n"):
    raise SystemExit(f"{path} is not a PNG")
if len(data) < 64:
    raise SystemExit(f"{path} is unexpectedly small")
PY
}

download() {
  local url="$1"
  local path="$2"
  local expected="${3:-200}"
  local header_path="$path.headers"
  local status
  status="$(curl -sS -m 5 -D "$header_path" -o "$path" -w '%{http_code}' "$url")"
  [[ "$status" == "$expected" ]] || {
    cat "$header_path" >&2 || true
    fail "GET $url returned HTTP $status, expected $expected"
  }
}

log "checking server at $BASE_URL"
request GET "$BASE_URL/state" | assert_json 'j["ok"] is True and j["width"] > 0 and j["height"] > 0 and j["layerState"]["activeLayerID"]'

log "canvas presets and new canvas reset"
request GET "$BASE_URL/canvas/presets" | assert_json 'j["ok"] is True and j["presets"][0]["name"] == "1024_square"'
request POST "$BASE_URL/canvas/new" "{\"author\":\"codex\",\"idempotencyKey\":\"smoke-$RUN_ID-new\",\"width\":1024,\"height\":1024,\"background\":\"#FFFFFF\",\"preserveLayers\":false}" | assert_json 'j["ok"] is True'
request GET "$BASE_URL/layers" | assert_json 'j["ok"] is True and j["layerState"]["activeLayerID"] == "base" and j["layerState"]["layers"][0]["id"] == "base"'

log "layers"
LAYER_ID="smoke-$RUN_ID-layer"
request POST "$BASE_URL/layer/create" '{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-layer-create","id":"'"$LAYER_ID"'","name":"Smoke Layer","setActive":true}' | assert_json 'j["ok"] is True and j["layer"]["id"] and j["layerState"]["activeLayerID"] == j["layer"]["id"]'
request POST "$BASE_URL/pixel" '{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-layer-pixel","layerID":"'"$LAYER_ID"'","x":48,"y":48,"color":"#FF9EE0"}' | assert_json 'j["ok"] is True'
request GET "$BASE_URL/sample?x=48&y=48" | assert_json 'j["ok"] is True and j["rgba"]["r"] == 255 and j["rgba"]["g"] == 158 and j["rgba"]["b"] == 224'
request POST "$BASE_URL/layer/visibility" '{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-layer-hide","id":"'"$LAYER_ID"'","visible":false}' | assert_json 'j["ok"] is True'
request GET "$BASE_URL/sample?x=48&y=48" | assert_json 'j["ok"] is True and j["rgba"]["r"] == 255 and j["rgba"]["g"] == 255 and j["rgba"]["b"] == 255'
request POST "$BASE_URL/undo" '{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-layer-undo"}' | assert_json 'j["ok"] is True'
request GET "$BASE_URL/sample?x=48&y=48" | assert_json 'j["ok"] is True and j["rgba"]["r"] == 255 and j["rgba"]["g"] == 158 and j["rgba"]["b"] == 224'
request POST "$BASE_URL/layer/opacity" '{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-layer-opacity","id":"'"$LAYER_ID"'","opacity":0.75}' | assert_json 'j["ok"] is True'
request POST "$BASE_URL/layer/blend" '{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-layer-blend","id":"'"$LAYER_ID"'","blend":"normal"}' | assert_json 'j["ok"] is True'
request POST "$BASE_URL/layer/reorder" '{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-layer-reorder","id":"'"$LAYER_ID"'","toIndex":0}' | assert_json 'j["ok"] is True'
request POST "$BASE_URL/layer/lock" '{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-layer-lock","id":"'"$LAYER_ID"'","locked":true}' | assert_json 'j["ok"] is True'
request POST "$BASE_URL/pixel" '{"author":"codex","layerID":"'"$LAYER_ID"'","x":49,"y":48,"color":"#7FFFD4"}' 400 | assert_json 'j["ok"] is False and j["error"]["code"] == "layer_locked"'
request POST "$BASE_URL/layer/lock" '{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-layer-unlock","id":"'"$LAYER_ID"'","locked":false}' | assert_json 'j["ok"] is True'
request POST "$BASE_URL/layer/activate" '{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-layer-activate","id":"base"}' | assert_json 'j["ok"] is True'
request POST "$BASE_URL/layer/delete" '{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-layer-delete","id":"'"$LAYER_ID"'"}' | assert_json 'j["ok"] is True'

log "clear"
request POST "$BASE_URL/clear" "{\"author\":\"codex\",\"idempotencyKey\":\"smoke-$RUN_ID-clear\",\"color\":\"#FFFFFF\"}" | assert_json 'j["ok"] is True'

log "ascii on empty canvas"
request GET "$BASE_URL/canvas.ascii?mode=color&cols=8&rows=4" | assert_json 'j["mode"] == "color" and j["grid"]["w"] == 8 and j["grid"]["h"] == 4 and j["rows"] == ["........", "........", "........", "........"]'
request GET "$BASE_URL/canvas.ascii?mode=brightness&cols=8&rows=4&fullmap=1" | assert_json 'j["mode"] == "brightness" and j["grid"]["w"] == 8 and j["grid"]["h"] == 4 and j["rows"][3] == "        " and j["cells"][31]["row"] == 3'
request GET "$BASE_URL/canvas.ascii?mode=braille&cols=4&rows=3" | assert_json 'j["mode"] == "braille" and j["grid"]["w"] == 4 and j["grid"]["h"] == 3 and j["rows"][2] == "⠀⠀⠀⠀"'

log "stroke and idempotency"
STROKE='{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-stroke","points":[{"x":24,"y":24},{"x":96,"y":72},{"x":168,"y":24}],"width":12,"color":"#14E6D4"}'
request POST "$BASE_URL/stroke" "$STROKE" | assert_json 'j["ok"] is True and j["deduped"] is False'
request POST "$BASE_URL/stroke" "$STROKE" | assert_json 'j["ok"] is True and j["deduped"] is True'

log "shape"
request POST "$BASE_URL/shape" '{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-shape","kind":"rect","x":100,"y":100,"w":80,"h":80,"fill":"#FF4D9C","stroke":"#7F8CFF","strokeWidth":2}' | assert_json 'j["ok"] is True'

log "text"
request POST "$BASE_URL/text" '{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-text","string":"smoke","x":220,"y":140,"fontSize":32,"color":"#3C65FF","weight":"bold"}' | assert_json 'j["ok"] is True'

log "image and image_paste"
TINY_PNG='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMB/axLQD0AAAAASUVORK5CYII='
request POST "$BASE_URL/image" '{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-image","pngBase64":"'"$TINY_PNG"'","x":320,"y":100,"w":24,"h":24}' | assert_json 'j["ok"] is True'
request POST "$BASE_URL/image_paste" '{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-image-paste","pngBase64":"'"$TINY_PNG"'","x":352,"y":100,"w":24,"h":24}' | assert_json 'j["ok"] is True'

log "path, pixel, and pixels"
request POST "$BASE_URL/path" '{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-path","ops":[{"op":"M","x":420,"y":80},{"op":"L","x":480,"y":80},{"op":"Q","cx":510,"cy":110,"x":480,"y":140},{"op":"C","c1x":455,"c1y":165,"c2x":420,"c2y":150,"x":420,"y":100},{"op":"Z"}],"color":"#FF9EE0","strokeWidth":1,"lineCap":"round","lineJoin":"round","dash":[8,4]}' | assert_json 'j["ok"] is True'
request POST "$BASE_URL/pixel" '{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-pixel","x":64,"y":64,"color":"#FF9EE0"}' | assert_json 'j["ok"] is True'
request POST "$BASE_URL/pixels" '{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-pixels","defaultColor":"#7FFFD4","pixels":[{"x":70,"y":64},{"x":71,"y":64},{"x":72,"y":64,"color":"#FF6B9D"}]}' | assert_json 'j["ok"] is True'

log "state, sample, eyedropper"
request GET "$BASE_URL/state" | assert_json 'j["ok"] is True and j["revision"] >= 5 and "codex" in j["authorCursors"]'
request GET "$BASE_URL/sample?x=140&y=140" | assert_json 'j["ok"] is True and j["rgba"]["r"] == 255 and j["rgba"]["g"] == 77 and j["rgba"]["b"] == 156'
request GET "$BASE_URL/sample?x=64&y=64" | assert_json 'j["ok"] is True and j["rgba"]["r"] == 255 and j["rgba"]["g"] == 158 and j["rgba"]["b"] == 224'
request GET "$BASE_URL/eyedropper?x=20&y=200" | assert_json 'j["ok"] is True and j["rgba"]["r"] == 255 and j["rgba"]["g"] == 255 and j["rgba"]["b"] == 255'
request GET "$BASE_URL/sample/grid?x=60&y=60&w=24&h=16&step=4" | assert_json 'j["ok"] is True and j["cols"] == 6 and j["rows"] == 4 and j["samples"][1][1]["r"] == 255'
request GET "$BASE_URL/sample/path?points=64,64;70,64;20,200" | assert_json 'j["ok"] is True and j["samples"][2]["index"] == 2 and j["samples"][0]["rgba"]["b"] == 224 and j["samples"][1]["rgba"]["g"] == 255'
request GET "$BASE_URL/canvas.ascii?mode=color&cols=16&rows=12&fullmap=1" | assert_json 'j["mode"] == "color" and j["grid"]["w"] == 16 and j["grid"]["h"] == 12 and j["rows"][11] and j["cells"][191]["row"] == 11'

log "canvas, export, and regions"
download "$BASE_URL/canvas.png" "$TMP_DIR/canvas.png"
assert_png "$TMP_DIR/canvas.png"
download "$BASE_URL/canvas?maxDim=256" "$TMP_DIR/canvas-256.png"
assert_png "$TMP_DIR/canvas-256.png"
download "$BASE_URL/export?format=png&max_dim=128" "$TMP_DIR/export.png"
assert_png "$TMP_DIR/export.png"
grep -qi 'Content-Disposition: attachment; filename="gloss-rev-' "$TMP_DIR/export.png.headers" || fail "/export missing attachment Content-Disposition"
download "$BASE_URL/region.png?x=80&y=80&w=160&h=140&scale=1" "$TMP_DIR/region-a.png"
assert_png "$TMP_DIR/region-a.png"
download "$BASE_URL/canvas/region.png?x=80&y=80&w=160&h=140" "$TMP_DIR/region-b.png"
assert_png "$TMP_DIR/region-b.png"
download "$BASE_URL/region?x=80&y=80&width=160&height=140" "$TMP_DIR/region-c.png"
assert_png "$TMP_DIR/region-c.png"

log "undo and redo"
request POST "$BASE_URL/undo" '{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-undo"}' | assert_json 'j["ok"] is True'
request POST "$BASE_URL/redo" '{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-redo"}' | assert_json 'j["ok"] is True'

log "resize and restore"
request POST "$BASE_URL/resize" '{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-resize-small","width":512,"height":512,"preserveContents":false}' | assert_json 'j["ok"] is True'
request GET "$BASE_URL/state" | assert_json 'j["ok"] is True and j["width"] == 512 and j["height"] == 512'
request POST "$BASE_URL/resize" '{"author":"codex","idempotencyKey":"smoke-'"$RUN_ID"'-resize-restore","width":1024,"height":1024,"preserveContents":false}' | assert_json 'j["ok"] is True'
request POST "$BASE_URL/clear" "{\"author\":\"codex\",\"idempotencyKey\":\"smoke-$RUN_ID-final-clear\",\"color\":\"#FFFFFF\"}" | assert_json 'j["ok"] is True'

log "bad JSON returns 400"
request POST "$BASE_URL/stroke" '{bad json' 400 | assert_json 'j["ok"] is False and j["error"]["code"] == "bad_json"'

log "unsupported export format returns 400"
request GET "$BASE_URL/export?format=jpeg" "" 400 | assert_json 'j["ok"] is False and j["error"]["code"] == "unsupported_format"'

log "diff is reserved"
request GET "$BASE_URL/diff?revision=1" "" 501 | assert_json 'j["ok"] is False and j["error"]["code"] == "not_implemented"'

log "ok"
