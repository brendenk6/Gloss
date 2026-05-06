# Gloss

Gloss is a local macOS drawing app built for human plus LLM collaboration. The app shows a live SwiftUI canvas, while a localhost HTTP API lets agents draw, inspect pixels, export PNGs, and coordinate by author metadata.

The default canvas is `1024 x 1024` sRGB RGBA. Coordinates use a top-left origin with `y` increasing downward.

## Quickstart

```bash
cd ~/Projects/Gloss
xcodegen
xcodebuild -project Gloss.xcodeproj -scheme Gloss -configuration Debug -destination 'platform=macOS' build
open /tmp/XcodeDerivedData/Gloss-*/Build/Products/Debug/Gloss.app
```

The app starts a localhost-only server on:

```text
http://127.0.0.1:7778
```

Run the integration smoke test while Gloss is open:

```bash
./scripts/smoke.sh
```

Override the server URL if needed:

```bash
BASE_URL=http://127.0.0.1:7778 ./scripts/smoke.sh
```

## Collaboration Convention

Every mutation payload can include:

```json
{
  "author": "codex",
  "idempotencyKey": "codex-unique-command-001"
}
```

Use these author names unless the session needs something else:

```text
brenden
claude
codex
```

`author` drives last-touch cursors and command history. `idempotencyKey` prevents duplicate mutations when a client retries a request. The server keeps a small recent-result cache, and `CanvasStore` also deduplicates internally.

## Common Types

### Color

Colors can be hex strings:

```json
"#14E6D4"
```

or RGBA objects with components in `0...1`:

```json
{"r": 0.08, "g": 0.9, "b": 0.83, "a": 1}
```

### Point

```json
{"x": 120, "y": 140}
```

### Blend

Valid blend modes:

```text
normal, multiply, screen, overlay, darken, lighten, plusLighter, plusDarker, clear
```

### Command Result

Mutation endpoints return:

```json
{
  "ok": true,
  "revision": 3,
  "dirtyRect": {"x": 100, "y": 100, "w": 80, "h": 80},
  "deduped": false,
  "dedupedByServer": false
}
```

Errors return:

```json
{
  "ok": false,
  "error": {
    "code": "bad_json",
    "message": "Invalid JSON body"
  }
}
```

## API Reference

### GET /state

Returns canvas size, revision, recent commands, and author cursors.

```bash
curl -s http://127.0.0.1:7778/state | python3 -m json.tool
```

Response:

```json
{
  "ok": true,
  "width": 1024,
  "height": 1024,
  "revision": 0,
  "lastCommands": [],
  "authorCursors": {}
}
```

### GET /canvas.png

Returns the full canvas as PNG.

```bash
curl -s http://127.0.0.1:7778/canvas.png -o canvas.png
```

Optional downscale:

```bash
curl -s 'http://127.0.0.1:7778/canvas.png?max_dim=512' -o canvas-512.png
```

Alias:

```bash
curl -s 'http://127.0.0.1:7778/canvas?maxDim=512' -o canvas-512.png
```

PNG responses include:

```text
X-Gloss-Revision
X-Gloss-Width
X-Gloss-Height
```

### GET /export

Returns the canvas as a downloadable PNG with `Content-Disposition: attachment`.

```bash
curl -sOJ 'http://127.0.0.1:7778/export?format=png&max_dim=1024'
```

`format` defaults to `png`; other formats currently return `400 unsupported_format`.

### GET /region.png

Returns a cropped PNG region. `x`, `y`, `w`, and `h` are in canvas coordinates. `scale` is optional.

```bash
curl -s 'http://127.0.0.1:7778/region.png?x=80&y=80&w=240&h=160&scale=1' -o region.png
```

Aliases:

```bash
curl -s 'http://127.0.0.1:7778/canvas/region.png?x=80&y=80&w=240&h=160' -o region.png
curl -s 'http://127.0.0.1:7778/region?x=80&y=80&width=240&height=160' -o region.png
```

### GET /sample

Samples one pixel at top-left canvas coordinates.

```bash
curl -s 'http://127.0.0.1:7778/sample?x=140&y=140' | python3 -m json.tool
```

Alias:

```bash
curl -s 'http://127.0.0.1:7778/eyedropper?x=140&y=140' | python3 -m json.tool
```

Response:

```json
{
  "ok": true,
  "x": 140,
  "y": 140,
  "rgba": {"r": 255, "g": 77, "b": 156, "a": 255},
  "revision": 4
}
```

### GET /canvas.ascii

Returns a deterministic text-grid view of the canvas for cheap agent perception.

```bash
curl -s 'http://127.0.0.1:7778/canvas.ascii?mode=color&cols=64&rows=48' | python3 -m json.tool
```

Modes:

```text
color       palette letter per cell: A=aqua, G=glow, L=lavender, P=hotpink, .=white, #=black
brightness  luminance characters from light to dark
braille     2x4 Unicode braille density per cell
```

Optional parameters:

```text
cols, rows: output grid; defaults to 64 x 48 and caps at 8192 cells
grid: alternate cols x rows syntax, for example grid=64x48
fullmap: 1 to include per-cell col,row,x,y,char tags
x,y,w,h: optional canvas region
```

Response:

```json
{
  "mode": "color",
  "grid": {"w": 64, "h": 48},
  "region": {"x": 0, "y": 0, "w": 1024, "h": 1024},
  "cellSize": [16, 21.3333333333],
  "legend": {"A": "aqua #7FFFD4", ".": "white #FFFFFF"},
  "rows": ["................................................................"],
  "cells": null,
  "revision": 4
}
```

### GET /sample/grid

Samples a region into a 2D RGBA array. `step` defaults to `8`; the server raises it when needed so output stays at or below `64 x 64`.

```bash
curl -s 'http://127.0.0.1:7778/sample/grid?x=0&y=0&w=128&h=128&step=16' | python3 -m json.tool
```

Response includes `x` and `y` coordinate arrays plus `samples[row][col]`. Out-of-bounds points encode as `null`.

### GET /sample/path

Samples exact points in one request.

```bash
curl -s 'http://127.0.0.1:7778/sample/path?points=10,10;140,140;512,512' | python3 -m json.tool
```

Response:

```json
{
  "ok": true,
  "revision": 4,
  "samples": [
    {"index": 0, "x": 10, "y": 10, "rgba": {"r": 255, "g": 255, "b": 255, "a": 255}}
  ]
}
```

### GET /diff

Reserved for revision-aware sparse diffs. v1.1 returns `501 not_implemented` because `CanvasStore` does not retain per-revision snapshots yet.

## Mutation Endpoints

All mutation endpoints accept a JSON object. The route infers `type`, so `POST /stroke` can omit `"type":"stroke"`. You can still include `type` explicitly when using a generic command payload.

### POST /stroke

Draws a smoothed stroke through points.

Payload:

```json
{
  "author": "codex",
  "idempotencyKey": "codex-stroke-001",
  "points": [{"x": 120, "y": 140}, {"x": 220, "y": 210}, {"x": 340, "y": 150}],
  "width": 18,
  "color": "#14E6D4",
  "opacity": 1,
  "blend": "normal",
  "simplify": 0.5
}
```

Example:

```bash
curl -s -X POST http://127.0.0.1:7778/stroke \
  -H 'Content-Type: application/json' \
  -d '{"author":"codex","idempotencyKey":"codex-stroke-001","points":[{"x":120,"y":140},{"x":220,"y":210},{"x":340,"y":150}],"width":18,"color":"#14E6D4"}' \
  | python3 -m json.tool
```

Required: `points`, `width`, `color`.

Defaults: `opacity=1`, `blend=normal`.

### POST /shape

Draws a rectangle, ellipse, rounded rectangle, or line.

Payload:

```json
{
  "author": "claude",
  "idempotencyKey": "claude-shape-001",
  "kind": "ellipse",
  "x": 520,
  "y": 150,
  "w": 220,
  "h": 160,
  "stroke": "#7F8CFF",
  "strokeWidth": 8,
  "fill": "#EAFBFF",
  "opacity": 0.92,
  "blend": "normal"
}
```

Example:

```bash
curl -s -X POST http://127.0.0.1:7778/shape \
  -H 'Content-Type: application/json' \
  -d '{"author":"claude","kind":"ellipse","x":520,"y":150,"w":220,"h":160,"stroke":"#7F8CFF","strokeWidth":8,"fill":"#EAFBFF"}' \
  | python3 -m json.tool
```

Shape fields:

```text
kind: rect | ellipse | roundedRect | line
x, y: start or origin
w, h: size for rect, ellipse, roundedRect
x2, y2: end point for line
radius: corner radius for roundedRect
stroke, strokeWidth: optional outline
fill: optional fill
```

### POST /text

Draws text.

Payload:

```json
{
  "author": "brenden",
  "idempotencyKey": "brenden-text-001",
  "string": "Gloss API alive",
  "x": 150,
  "y": 360,
  "fontSize": 44,
  "fontName": "Helvetica",
  "weight": "bold",
  "color": "#3C65FF",
  "opacity": 1,
  "blend": "normal"
}
```

Example:

```bash
curl -s -X POST http://127.0.0.1:7778/text \
  -H 'Content-Type: application/json' \
  -d '{"author":"brenden","string":"Gloss API alive","x":150,"y":360,"fontSize":44,"weight":"bold","color":"#3C65FF"}' \
  | python3 -m json.tool
```

Required: `string`, `x`, `y`.

Defaults: `fontSize=24`, `color=#000000`, `opacity=1`, `blend=normal`.

### POST /image

Stamps a base64 PNG.

Payload:

```json
{
  "author": "codex",
  "idempotencyKey": "codex-image-001",
  "pngBase64": "iVBORw0KGgo...",
  "x": 320,
  "y": 100,
  "w": 24,
  "h": 24,
  "opacity": 1,
  "blend": "normal"
}
```

Example:

```bash
TINY_PNG='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMB/axLQD0AAAAASUVORK5CYII='
curl -s -X POST http://127.0.0.1:7778/image \
  -H 'Content-Type: application/json' \
  -d '{"author":"codex","pngBase64":"'"$TINY_PNG"'","x":320,"y":100,"w":24,"h":24}' \
  | python3 -m json.tool
```

Alias:

```bash
curl -s -X POST http://127.0.0.1:7778/image_paste ...
```

Required: `pngBase64`, `x`, `y`.

Defaults: native image size if `w` and `h` are omitted; `opacity=1`, `blend=normal`.

### POST /path

Draws an SVG-like path with explicit line cap/join, optional fill, dash, and cubic/quadratic segments.

```bash
curl -s -X POST http://127.0.0.1:7778/path \
  -H 'Content-Type: application/json' \
  -d '{"author":"codex","ops":[{"op":"M","x":120,"y":120},{"op":"L","x":220,"y":120},{"op":"Q","cx":260,"cy":180,"x":220,"y":240},{"op":"C","c1x":180,"c1y":280,"c2x":120,"c2y":260,"x":120,"y":180},{"op":"Z"}],"color":"#FF9EE0","strokeWidth":1,"lineCap":"round","lineJoin":"round","dash":[8,4]}' \
  | python3 -m json.tool
```

Path ops:

```text
{"op":"M","x":0,"y":0}
{"op":"L","x":10,"y":10}
{"op":"Q","cx":10,"cy":0,"x":20,"y":10}
{"op":"C","c1x":10,"c1y":0,"c2x":20,"c2y":20,"x":30,"y":10}
{"op":"Z"}
```

Fields:

```text
color: optional stroke color
strokeWidth: stroke width in pixels
fill: optional fill color
lineCap: round | square | butt
lineJoin: round | miter | bevel
miterLimit: optional numeric miter limit
dash: optional dash lengths array
closed: true to close before drawing
```

### POST /pixel

Sets one exact pixel without antialiasing.

```bash
curl -s -X POST http://127.0.0.1:7778/pixel \
  -H 'Content-Type: application/json' \
  -d '{"author":"codex","x":64,"y":64,"color":"#FF9EE0"}' \
  | python3 -m json.tool
```

### POST /pixels

Sets many exact pixels in one request. Individual pixels can carry `color`; otherwise `defaultColor` is used.

```bash
curl -s -X POST http://127.0.0.1:7778/pixels \
  -H 'Content-Type: application/json' \
  -d '{"author":"codex","defaultColor":"#7FFFD4","pixels":[{"x":70,"y":64},{"x":71,"y":64},{"x":72,"y":64,"color":"#FF6B9D"}]}' \
  | python3 -m json.tool
```

### POST /clear

Clears the canvas to white or a supplied color.

```bash
curl -s -X POST http://127.0.0.1:7778/clear \
  -H 'Content-Type: application/json' \
  -d '{"author":"codex","color":"#FFFFFF"}' \
  | python3 -m json.tool
```

### POST /undo

Restores the previous canvas snapshot.

```bash
curl -s -X POST http://127.0.0.1:7778/undo \
  -H 'Content-Type: application/json' \
  -d '{"author":"codex"}' \
  | python3 -m json.tool
```

### POST /redo

Reapplies the last undone snapshot.

```bash
curl -s -X POST http://127.0.0.1:7778/redo \
  -H 'Content-Type: application/json' \
  -d '{"author":"codex"}' \
  | python3 -m json.tool
```

### POST /resize

Resizes the canvas. Width and height are clamped to `16...8192`.

```bash
curl -s -X POST http://127.0.0.1:7778/resize \
  -H 'Content-Type: application/json' \
  -d '{"author":"codex","width":1024,"height":1024,"preserveContents":true}' \
  | python3 -m json.tool
```

Payload:

```json
{
  "author": "codex",
  "idempotencyKey": "codex-resize-001",
  "width": 1024,
  "height": 1024,
  "preserveContents": true
}
```

`preserveContents=false` clears to white after resizing.

## Dogfood Draw Pattern

One agent draws a base, the other samples or pulls a region, then adds a response. A simple exchange:

```bash
curl -s -X POST "$BASE_URL/clear" -H 'Content-Type: application/json' -d '{"author":"brenden","color":"#FFFFFF"}'
curl -s -X POST "$BASE_URL/shape" -H 'Content-Type: application/json' -d '{"author":"claude","kind":"ellipse","x":300,"y":300,"w":240,"h":180,"fill":"#EAFBFF","stroke":"#7F8CFF","strokeWidth":8}'
curl -s -X POST "$BASE_URL/stroke" -H 'Content-Type: application/json' -d '{"author":"codex","points":[{"x":260,"y":260},{"x":420,"y":220},{"x":580,"y":260}],"width":14,"color":"#14E6D4"}'
curl -s "$BASE_URL/canvas.png" -o gloss-dogfood.png
```

For pixel-level iteration, use:

```bash
curl -s "$BASE_URL/canvas.png?max_dim=512" -o preview.png
curl -s "$BASE_URL/region.png?x=240&y=220&w=420&h=320" -o region.png
curl -s "$BASE_URL/sample?x=420&y=300" | python3 -m json.tool
```
