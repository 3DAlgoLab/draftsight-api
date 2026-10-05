---
name: draftsight-api
description: Drive DraftSight 2026 through COM automation (the transport that works) or its local HTTP/JSON API on 127.0.0.1:7776 - create and edit DWG drawings programmatically, read the live selection, export views, and verify results by reading geometry back. Use when generating or modifying DraftSight drawings, calling dsSketchManager / dsDocument / dsApplication, automating CAD, or consulting the DraftSight API reference.
---

# DraftSight HTTP/JSON API

**Windows only.** The API broker, the file I/O sandbox, and the bundled help decompiler are all
Windows-specific, so this ships as an optional pi package rather than a permanent skill.

DraftSight 2026 (verified on 26.4.0.5067) exposes a local JSON API. Two processes matter:

| Process | Role |
|---|---|
| `DraftSight.exe` | the app; listens on `7775` (jsServer) |
| `dsHttpApiService` | the broker; listens on `127.0.0.1:7776` and **survives DraftSight restarts** |

DraftSight must be running. COM talks to the app itself; HTTP talks to the broker.

## Transport: COM first

**Prefer COM.** Same object model, no broker, no ports, no Windows service, no `macroId` epochs, and no file-path sandbox. It is also the only transport that currently works here - the HTTP broker has a reproducible crash-on-first-request defect (`references/protocol.md`).

| | COM | HTTP/JSON |
|---|---|---|
| Endpoint | running `DraftSight.exe`, via the ROT | `dsHttpApiService` on `127.0.0.1:7776` |
| Verified | 26 entities created, live selection read back, zero failures | 3 h 07 m of correct service, then dead |
| Output paths | unrestricted - exports land straight in the vault | sandboxed to `C:\ProgramData\Dassault Systemes\DraftSight\` |
| Host | Windows PowerShell 5.1 (`GetActiveObject` was removed from .NET Core / PS 7) | any language that can POST |

```powershell
$app  = [Runtime.InteropServices.Marshal]::GetActiveObject('DraftSight.Application')
$doc  = $app.GetActiveDocument()
$sk   = $doc.GetModel().GetSketchManager()   # on IModel, never on the document
$selm = $doc.GetSelectionManager()
$e    = $selm.GetSelectedObject(1, 0, 0)     # set 1, not 0 - a live pick is not in set 0
$e.Handle; $e.Layer; $e.Radius; $e.GetArea(); $e.GetLength()
$app.Zoom(0, $null, $null)                   # fit before export; exports the current view
$doc.GetDocumentExporter().ExportToPng('D:\out.png', $true)
```

Signatures, the ROT activation trap, SAFEARRAY/`[ref]` marshalling, and the selection-set table: `references/com-api.md`. Runnable: `scripts/com-inspect.ps1`, `scripts/com-draw-example.ps1`.

## HTTP/JSON transport

```
POST http://127.0.0.1:7776
Content-Type: text/json;charset=UTF-8

{"language":"dsJavaScript","owner":{...},"functionName":"InsertLine","args":[...]}
```

`language` is only a label - the wire format is plain JSON, so any language can drive it. Use `scripts/ds-call.sh` for the handshake.

## Three rules that cause every failure

1. **Echo the owner object verbatim.** Every returned object is `{"id":N,"macroId":E,"type":"dsX"}`. Dropping `macroId` produces `"jsServer connection Failed"`. Always pass the whole object back as `owner`.
2. **`macroId` is a session epoch.** It resets to 1 when DraftSight restarts. On restart every cached id is garbage - re-run `getApplication` and re-walk the chain.
3. **API file I/O is sandboxed to `C:\ProgramData\Dassault Systemes\DraftSight\`.** `OpenDocument2`, `SaveAs2`, and `ExportTo*` all fail for any other path - vault, `Documents`, `C:\temp`, user profile. Stage the file inside that root, operate, copy the result back. The check is on the **path argument**, not on the open document: a DWG already open outside the root can still be drawn into and `Save()`-ed in place without staging.

## Liveness check

Call `GetVersion` on the **dsApplication** object, never on `jsScriptManager` (that returns `null` and looks like a dead connection).

A version string means connected. `null` means the broker is up but has no live jsServer link - do not proceed, reconnect instead.

## Reconnect procedure

```
1. POST getApplication on {"type":"jsScriptManager"}   -> new app object, new macroId
2. discard every cached id                             -> no reuse across epochs
3. re-walk app -> GetActiveDocument -> GetModel -> GetSketchManager
4. dsApplication.GetVersion                            -> null means not connected
```

## Trust table - which return values are evidence

| Call | Return | Trust |
|---|---|---|
| `ExportToPng/Jpg/Bmp/Svg` | `{"Success":true/false}` | **Yes** - matched reality every time |
| `SaveAs2` | `{"Errors":"dsDocumentSave_Succeeded"}` | **Yes** |
| `GetEntities`, `GetBoundingBox` | real data | **Yes** |
| `RunCommand` | `"dsRunCommand_Succeeded"` | **No** - returned success while DraftSight printed `Unrecognized command`. Verify by reading geometry or the command window. |
| `Zoom`, `StartUndoRecord`, `StopUndoRecord`, `CloseDocument` | `null` | Neutral - `null` means no return value, not failure |
| `OpenDocument2` | `null` | **Failure** - a real open returns a document object |

## Do not call

| Call | Why |
|---|---|
| `dsDocumentExporter.ExportToEmf` | returned empty, then `jsServer connection Failed`, then DraftSight restarted |
| `dsDocument.SaveAs` | obsolete, superseded by `SaveAs2`; returns `GenericError` for every option |
| `dsApplication.GetDocuments` | the only chain that preceded an unexplained crash; prefer `GetActiveDocument` |

## Drawing discipline

- Wrap every generated drawing in `StartUndoRecord` / `StopUndoRecord` so one Ctrl+Z reverts it.
- Call `dsApplication.AbortRunningCommand()` before starting - the shipped examples do, and it avoids nested-command errors.
- **Angles are radians.** Confirmed: `InsertArc(...,0,1.5707963)` read back `get_StartAngle = 1.5707963`.
- Enum parameters take the **symbolic name as a string**, not the number: `"dsDocumentSaveAs_R2018_DWG"`, `"dsDocumentOpen_Default"`, `"dsEncoding_Default"`. Passing `28` gives the misleading `arguments[1], Options, should be type String`.
- Never attach to a DraftSight instance holding unsaved production work. Check the autosave folder and open documents first.

## Verification loop

Prefer geometry read-back over pixels; it is deterministic and never touches the render pipeline.

```
GetEntities(0, [])   -> {EntitiesArray:[{id,macroId,type}], EntityTypeLongArray:[...]}
GetBoundingBox()     -> {X1,X2,Y1,Y2,Z1,Z2}
per-entity props     -> get_StartAngle, get_Radius, ...
```

For a visual check, `ExportToPng` gives clean chrome-free line art. It exports **the current view, not full extents**, so `dsModel.Zoom(0,...)` (Fit) first, and expect edge clipping - a margin-corrected `Zoom(2, ll, ur)` avoids it.

Screen capture is the fallback only: `PrintWindow` returns `False` on DraftSight's Qt5 GL surface; `CopyFromScreen` over `GetWindowRect` works but includes ribbon and palettes.

## Official reference (bundled, 76 MB)

Decompiled from the DraftSight Help folder by `scripts/decompile-chm.sh`. Look things up instead of guessing.

| Directory | Pages | Contents |
|---|---|---|
| `docs/draftsightapi/` | 4,353 | API reference - classes, methods, enums, per-language examples |
| `docs/DraftSight/` | 1,318 | application guide + **command reference**: `cmdref/command_reference_chart.htm`, `cmdvar/sv_cmdnames.htm` |
| `docs/DraftSight_Lisp_Reference/` | 257 | AutoLISP reference |
| `docs/DraftSightMech/` | 222 | mechanical |
| `docs/DraftSightSW/` | 256 | sheet metal |
| `docs/DraftSightConnected/` | 49 | Connected |
| `docs/DSAPIHelp/`, `docs/NestingManager/` | 1 each | stubs, low value |

```
grep -ril "ExportToPng" docs/draftsightapi/*.htm* | head
scripts/html2txt.sh docs/DraftSight/cmdref/command_reference_chart.htm | grep -i zoom
```

## Command names are not AutoCAD's

`ZoomExtents` **does not exist** in DraftSight - it is an AutoCAD-ism. The command reference lists `ZoomFit` ("Zooms to the drawing extents"), plus `Zoom`, `ZoomIn`, `ZoomOut`, `ZoomBack`, `ZoomDynamic`, `ZoomFactor`. That is exactly why `RunCommand("ZoomExtents")` printed `Unrecognized command` while still returning `dsRunCommand_Succeeded`. Check `docs/DraftSight/cmdref/` before passing any command string.

See `references/com-api.md` for the COM surface, `references/protocol.md` for the failure catalogue including the broker defect, and `references/signatures.md` for verified HTTP method signatures and enums.
