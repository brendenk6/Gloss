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

### Layers

Draw commands can include `layerID`. If omitted, Gloss draws on the active layer. Explicit missing layer IDs are rejected with `404 layer_not_found`, except `claude-layer`, `codex-layer`, and `brenden-layer`, which auto-create on first draw.

Layer order is bottom to top. Index `0` is the bottom layer.

### Grid

The grid is an exact cell data layer over the canvas, not a screenshot heuristic. Use `/grid/state` to verify fills by stable `(cx, cy)` cell IDs. `/grid/mask.png` is derived from that same ledger, one PNG pixel per cell. Strokes and raw pixel writes may snap to cell boundaries when `grid.snap=true`, but only `/grid/fill` changes the grid ledger.

### Brushes

`/stroke` and `/path` support:

```text
brush: round | calligraphy | marker | pencil | airbrush | chalk | ink | ribbon | glaze
brushAngle: radians, used by calligraphy
pressures: 0...1 values for variable width
taper: in | out | both | none
```

For `/stroke`, `pressures` must match `points.count`. For `/path`, pressures are mapped over the flattened path by arclength.

Brush intent:

```text
ink: solid pressure-responsive wet line with a soft shoulder
ribbon: flat flexible nib for broad-to-hairline calligraphic curves
glaze: translucent marker wash with feathered edges and buildable color
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

### Route Index

| Method | Route | Purpose |
| --- | --- | --- |
| GET | `/state` | Canvas state, recent commands, cursors, layer state |
| GET | `/layers`, `/layer/list` | Layer stack only |
| GET | `/canvas/presets` | Named canvas size presets |
| GET | `/grid/state` | Exact filled-cell data for one layer |
| GET | `/grid/cells` | Grid cell geometry touching a canvas region |
| GET | `/grid/mask.png`, `/grid/mask` | One-pixel-per-cell mask from exact grid data |
| GET | `/canvas.png`, `/canvas` | Composite PNG, optional `max_dim` |
| GET | `/export` | Downloadable composite PNG |
| GET | `/region.png`, `/canvas/region.png`, `/region` | Cropped composite PNG |
| GET | `/sample`, `/eyedropper` | One composite pixel |
| GET | `/sample/grid` | Region sampled into a 2D RGBA array |
| GET | `/sample/path` | Ordered point samples |
| GET | `/canvas.ascii` | Text-grid canvas perception |
| GET | `/diff` | Reserved; returns `501 not_implemented` |
| POST | `/stroke` | Smoothed stroke with brushes, pressure, taper |
| POST | `/path` | SVG-like path with brushes, pressure, taper |
| POST | `/pixel`, `/pixels` | Exact pixel art writes |
| POST | `/shape`, `/text`, `/image`, `/image_paste` | Basic drawing primitives |
| POST | `/clear`, `/undo`, `/redo` | History and canvas clearing |
| POST | `/resize`, `/canvas/new` | Canvas size and reset operations |
| POST | `/grid/config` | Configure grid cell size, origin, visibility, opacity, snap |
| POST | `/grid/fill` | Fill exact cells and record them in the grid ledger |
| POST | `/layer/create` | Create a layer; response includes `layer` |
| POST | `/layer/delete` | Delete a layer |
| POST | `/layer/reorder` | Move a layer; `toIndex=0` means bottom |
| POST | `/layer/visibility`, `/layer/show`, `/layer/hide` | Toggle visibility |
| POST | `/layer/opacity` | Set layer opacity |
| POST | `/layer/blend` | Set layer blend mode |
| POST | `/layer/lock` | Lock or unlock drawing on a layer |
| POST | `/layer/activate`, `/layer/active` | Set active draw target |

### GET /state

Returns canvas size, revision, recent commands, author cursors, and layer stack state.

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
  "grid": {"cell_w": 16, "cell_h": 16, "origin_x": 0, "origin_y": 0, "visible": false, "opacity": 0.35, "snap": false},
  "lastCommands": [],
  "authorCursors": {},
  "layerState": {
    "layers": [
      {"id": "base", "name": "Base", "visible": true, "opacity": 1, "blend": "normal", "locked": false}
    ],
    "activeLayerID": "base",
    "memoryUsageBytes": 4194304,
    "memoryCapBytes": 67108864,
    "maxLayers": 16
  }
}
```

### GET /layers

Returns only the layer stack state plus the current revision.

```bash
curl -s http://127.0.0.1:7778/layers | python3 -m json.tool
```

Alias:

```bash
curl -s http://127.0.0.1:7778/layer/list | python3 -m json.tool
```

### GET /canvas/presets

Lists named canvas size presets. Each preset includes a default `grid` sized to keep the long axis near agent-manageable training resolution.

```bash
curl -s http://127.0.0.1:7778/canvas/presets | python3 -m json.tool
```

Families:

```text
Animation: tv_hd, tv_fhd, tv_uhd, tv_dci, tv_ntsc
iPhone: iphone_se, iphone_16, iphone_16_plus, iphone_16_pro, iphone_16_pro_max
iPad: ipad_mini, ipad_pro_11, ipad_air_13, ipad_pro_13
Studio/social: square_1k, square_2k, study_default
```

All non-square landscape presets also have a `_portrait` variant, for example `iphone_16_portrait`.

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

### GET /grid/state

Returns the canonical grid data for one layer. This is the verification source for grid training. It does not inspect rendered pixels.

```bash
curl -s 'http://127.0.0.1:7778/grid/state?layerID=codex-layer' | python3 -m json.tool
```

Response:

```json
{
  "ok": true,
  "revision": 12,
  "layerID": "codex-layer",
  "grid": {"cell_w": 16, "cell_h": 16, "origin_x": 0, "origin_y": 0, "visible": true, "opacity": 0.5, "snap": true},
  "cols": 64,
  "rows": 64,
  "filled_cells": [[1, 1, "#FF0000"], [2, 1, "#FF0000"]]
}
```

### GET /grid/cells

Returns stable cell IDs and canvas rectangles for every cell touching a region.

```bash
curl -s 'http://127.0.0.1:7778/grid/cells?x=0&y=0&w=33&h=17' | python3 -m json.tool
```

Each cell is:

```json
{"cx": 0, "cy": 0, "x": 0, "y": 0, "w": 16, "h": 16}
```

Queries are capped at 100,000 cells.

### GET /grid/mask.png

Returns a PNG with dimensions `cols x rows`, where each image pixel represents one grid cell. Filled cells are black; empty cells are white. The mask is derived from `/grid/state` data, not from canvas pixels.

```bash
curl -s 'http://127.0.0.1:7778/grid/mask.png?layerID=codex-layer' -o codex-grid-mask.png
```

Alias:

```bash
curl -s 'http://127.0.0.1:7778/grid/mask?layerID=codex-layer' -o codex-grid-mask.png
```

### GET /diff

Reserved for revision-aware sparse diffs. Gloss currently returns `501 not_implemented` because `CanvasStore` does not retain per-revision dirty-cell history yet.

## Mutation Endpoints

All mutation endpoints accept a JSON object. The route infers `type`, so `POST /stroke` can omit `"type":"stroke"`. You can still include `type` explicitly when using a generic command payload.

All drawing endpoints accept optional `layerID`. Missing means active layer.

### POST /stroke

Draws a smoothed stroke through points.

Payload:

```json
{
  "author": "codex",
  "idempotencyKey": "codex-stroke-001",
  "layerID": "codex-layer",
  "points": [{"x": 120, "y": 140}, {"x": 220, "y": 210}, {"x": 340, "y": 150}],
  "width": 18,
  "color": "#14E6D4",
  "opacity": 1,
  "blend": "normal",
  "simplify": 0.5,
  "brush": "marker",
  "brushAngle": 0,
  "pressures": [0.25, 1, 0.35],
  "taper": "both"
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

Defaults: `opacity=1`, `blend=normal`, `brush=round`, `taper=none`.

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

Draws an SVG-like path with explicit line cap/join, optional fill, dash, brush, pressure, and cubic/quadratic segments.

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
brush: round | calligraphy | marker | pencil | airbrush | chalk | ink | ribbon | glaze
brushAngle: radians, used by calligraphy
pressures: optional pressure values mapped over flattened arclength
taper: in | out | both | none
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

### POST /canvas/new

Starts a fresh canvas. Unlike `/resize`, this can either reset to one base layer or preserve the layer stack while resizing every layer bitmap. Use either explicit `width` and `height`, or a named `preset` from `/canvas/presets`.

```bash
curl -s -X POST http://127.0.0.1:7778/canvas/new \
  -H 'Content-Type: application/json' \
  -d '{"author":"codex","width":2048,"height":2048,"background":"#FFFFFF","preserveLayers":false}' \
  | python3 -m json.tool
```

Preset-only:

```bash
curl -s -X POST http://127.0.0.1:7778/canvas/new \
  -H 'Content-Type: application/json' \
  -d '{"author":"codex","preset":"tv_fhd","background":"#FFFFFF","preserveLayers":false}' \
  | python3 -m json.tool
```

Payload:

```json
{
  "author": "codex",
  "idempotencyKey": "codex-new-001",
  "preset": "tv_fhd",
  "width": 2048,
  "height": 2048,
  "background": "#FFFFFF",
  "grid": {"cell_w": 16, "cell_h": 16, "origin_x": 0, "origin_y": 0, "visible": false, "opacity": 0.35, "snap": false},
  "preserveLayers": false
}
```

If `preset` is present, omitted `width`, `height`, and `grid` are filled from that preset. Explicit values override the preset.

### POST /grid/config

Configures the grid. Cell sizes are clamped to a minimum of `4 x 4`.

```bash
curl -s -X POST http://127.0.0.1:7778/grid/config \
  -H 'Content-Type: application/json' \
  -d '{"author":"codex","cell_w":16,"cell_h":16,"origin_x":0,"origin_y":0,"visible":true,"opacity":0.5,"snap":true}' \
  | python3 -m json.tool
```

Payload fields:

```text
cell_w, cell_h: grid cell size in canvas pixels
origin_x, origin_y: grid origin in canvas pixels
visible: whether the app overlays grid lines
opacity: overlay opacity, 0...1
snap: whether stroke and pixel commands snap coordinates to cell boundaries
```

Changing cell size or origin clears recorded grid cells because old cell IDs no longer describe the same geometry. Visibility, opacity, and snap changes preserve the grid ledger.

### POST /grid/fill

Fills exact cells on a layer and records those cells in `/grid/state`.

```bash
curl -s -X POST http://127.0.0.1:7778/grid/fill \
  -H 'Content-Type: application/json' \
  -d '{"author":"codex","layerID":"codex-layer","cells":[[1,1],[2,1]],"color":"#FF0000"}' \
  | python3 -m json.tool
```

Payload:

```json
{
  "author": "codex",
  "idempotencyKey": "codex-grid-fill-001",
  "layerID": "codex-layer",
  "cells": [[1, 1], [2, 1], {"cx": 3, "cy": 1}],
  "color": "#FF0000",
  "opacity": 1,
  "blend": "normal"
}
```

Use `blend:"clear"` or a zero-alpha color to clear cells from the ledger. `/grid/state` reports only cells written through `/grid/fill`; this is deliberate so training verification reads exact data instead of rendered pixels.

### Layer Mutations

Create a layer:

```bash
curl -s -X POST http://127.0.0.1:7778/layer/create \
  -H 'Content-Type: application/json' \
  -d '{"author":"codex","id":"codex-layer","name":"Codex","setActive":true}' \
  | python3 -m json.tool
```

`/layer/create` accepts:

```text
id: optional explicit layer ID
name: optional display name
afterID: optional layer ID to insert above
visible: optional bool, default true
opacity: optional 0...1, default 1
blend: optional blend mode, default normal
locked: optional bool, default false
setActive: optional bool
```

The response includes both the created `layer` and `layerState`.

Other layer endpoints:

```bash
curl -s -X POST http://127.0.0.1:7778/layer/activate   -H 'Content-Type: application/json' -d '{"author":"codex","id":"codex-layer"}'
curl -s -X POST http://127.0.0.1:7778/layer/visibility -H 'Content-Type: application/json' -d '{"author":"codex","id":"codex-layer","visible":false}'
curl -s -X POST http://127.0.0.1:7778/layer/show       -H 'Content-Type: application/json' -d '{"author":"codex","id":"codex-layer"}'
curl -s -X POST http://127.0.0.1:7778/layer/hide       -H 'Content-Type: application/json' -d '{"author":"codex","id":"codex-layer"}'
curl -s -X POST http://127.0.0.1:7778/layer/opacity    -H 'Content-Type: application/json' -d '{"author":"codex","id":"codex-layer","opacity":0.75}'
curl -s -X POST http://127.0.0.1:7778/layer/blend      -H 'Content-Type: application/json' -d '{"author":"codex","id":"codex-layer","blend":"multiply"}'
curl -s -X POST http://127.0.0.1:7778/layer/lock       -H 'Content-Type: application/json' -d '{"author":"codex","id":"codex-layer","locked":true}'
curl -s -X POST http://127.0.0.1:7778/layer/reorder    -H 'Content-Type: application/json' -d '{"author":"codex","id":"codex-layer","toIndex":0}'
curl -s -X POST http://127.0.0.1:7778/layer/delete     -H 'Content-Type: application/json' -d '{"author":"codex","id":"codex-layer"}'
```

Layer draw failures map to useful HTTP errors:

```text
layer_locked -> 400
layer_cap -> 400
layer_not_found -> 404
```

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
