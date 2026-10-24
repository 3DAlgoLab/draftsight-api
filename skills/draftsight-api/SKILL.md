---
name: draftsight-api
description: Drive DraftSight 2026 through COM automation (the transport that works) or its local HTTP/JSON API on 127.0.0.1:7776 - create and edit DWG drawings programmatically, read the live selection, export views, plot sheet frames to PDF, and verify results by reading geometry back. Use when generating or modifying DraftSight drawings, calling dsSketchManager / dsDocument / dsApplication, automating CAD, or consulting the DraftSight API reference.
---

# DraftSight automation - COM first

**Windows only.** The API broker, the file I/O sandbox, and the bundled help decompiler are all
Windows-specific, so this ships as an optional pi package rather than a permanent skill.

DraftSight 2026 (verified on 26.4.0.5067) exposes two transports onto the same object model.
**COM is the primary transport and the only one that currently works.** The HTTP/JSON transport is
documented here as a fallback and a failure catalogue: on this machine its broker dies on the first
JS-RPC request on every build tried, and nothing on the client side recovers it
(`references/protocol.md`). Everything below the `HTTP/JSON transport` heading is HTTP-specific
unless the heading says otherwise - none of it applies to COM work.

Two processes matter, both on the HTTP path:

| Process | Role |
|---|---|
| `DraftSight.exe` | the app; listens on `7775` (jsServer) |
| `dsHttpApiService` | the broker; listens on `127.0.0.1:7776` and **survives DraftSight restarts** |

DraftSight must be running either way. COM talks to the app itself; HTTP talks to the broker.

## COM transport - primary

**Use COM.** Same object model, no broker, no ports, no Windows service, no `macroId` epochs, and no file-path sandbox. It is also the only transport that currently works here - the HTTP broker has a reproducible crash-on-first-request defect (`references/protocol.md`).

| | COM | HTTP/JSON |
|---|---|---|
| Endpoint | running `DraftSight.exe`, via the ROT | `dsHttpApiService` on `127.0.0.1:7776` |
| Verified | 26 entities, then a 43x7 CSV-fed table with per-column widths; selection read back, zero failures | 3 h 07 m of correct service, then dead |
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

Signatures, the ROT activation trap, SAFEARRAY/`[ref]` marshalling, the selection-set table, the table API, and the out-parameter trick for creating layers, styles and hatches: `references/com-api.md`. Runnable: `scripts/com-inspect.ps1`, `scripts/com-draw-example.ps1`, `scripts/com-table.ps1`, `scripts/com-section-hatch.ps1`, `scripts/com-signature-oracle.ps1` (offline signatures), `scripts/com-entities-dump.ps1` (early-bound inventory).

**Parity rule: if the JS API has it, COM almost certainly has it.** The shipped JS layer (`install_dir\APISDK\djLibrary\ds<Interface>.js`) is a thin shim over the same object model and is **not a stable contract** - its arities drift and it hides out-parameters (`ExportToPdf`: 4 args in JS, 5 in the type library). Use the stubs to learn *what exists*, never the calling convention. The contract is the **type library**
(`APISDK\tlb\DraftSight.Interop.dsAutomation.dll`, read offline with `scripts/com-signature-oracle.ps1`).
`Get-Member` on a live `__ComObject` shows only what the server exposes through `IDispatch` at that
moment: it invented `GetEntities` on `IModel`, which the type library does not declare, and it types
every array parameter as `Object`, which is what makes the late-bound path have to guess. Names differ: JS/HTTP say `dsPrintManager`, the COM type library says `IPrintManager`.

## HTTP/JSON transport - fallback, broken on this machine

```
POST http://127.0.0.1:7776
Content-Type: text/json;charset=UTF-8

{"language":"dsJavaScript","owner":{...},"functionName":"InsertLine","args":[...]}
```

`language` is only a label - the wire format is plain JSON, so any language can drive it. Use `scripts/ds-call.sh` for the handshake.

## Three HTTP rules that cause every failure

COM has none of these: object references replace `{id, macroId, type}` handles, there is no epoch
to go stale, and there is no path sandbox.

1. **Echo the owner object verbatim.** Every returned object is `{"id":N,"macroId":E,"type":"dsX"}`. Dropping `macroId` produces `"jsServer connection Failed"`. Always pass the whole object back as `owner`.
2. **`macroId` is a session epoch.** It resets to 1 when DraftSight restarts. On restart every cached id is garbage - re-run `getApplication` and re-walk the chain.
3. **API file I/O is sandboxed to `C:\ProgramData\Dassault Systemes\DraftSight\`.** `OpenDocument2`, `SaveAs2`, and `ExportTo*` all fail for any other path - vault, `Documents`, `C:\temp`, user profile. Stage the file inside that root, operate, copy the result back. The check is on the **path argument**, not on the open document: a DWG already open outside the root can still be drawn into and `Save()`-ed in place without staging.

## Liveness check (HTTP)

Call `GetVersion` on the **dsApplication** object, never on `jsScriptManager` (that returns `null` and looks like a dead connection).

A version string means connected. `null` means the broker is up but has no live jsServer link - do not proceed, reconnect instead.

Over COM the probe is cheaper and needs no broker: `GetActiveObject('DraftSight.Application')`
succeeding, plus `GetSelectedObjectCount(set)` returning a plain `int`, confirms the app is live and
answering.

## Reconnect procedure (HTTP only)

```
1. POST getApplication on {"type":"jsScriptManager"}   -> new app object, new macroId
2. discard every cached id                             -> no reuse across epochs
3. re-walk app -> GetActiveDocument -> GetModel -> GetSketchManager
4. dsApplication.GetVersion                            -> null means not connected
```

## Trust table - which return values are evidence

Rows without a qualifier are HTTP returns. Rows marked `over COM` are the COM form of the same
call, and the two differ: `ExportToPng` returns `{"Success":true}` over HTTP and nothing at all
over COM.

| Call | Return | Trust |
|---|---|---|
| `ExportToPng/Jpg/Bmp/Svg` | `{"Success":true/false}` | **Yes** - matched reality every time |
| `SaveAs2` | `{"Errors":"dsDocumentSave_Succeeded"}` | **Yes** |
| `GetEntities`, `GetBoundingBox` | real data | **Yes** |
| `ExportToPng` over COM | nothing (void) | Neutral - confirm by file mtime |
| `SelectByPolygon` over COM | `True`/`False` | **Yes**, but `False` also means "wrong argument shape", not "nothing there" |
| `RunCommand` | `"dsRunCommand_Succeeded"` | **No** - returned success while DraftSight printed `Unrecognized command`. Verify by reading geometry or the command window. |
| `Zoom`, `StartUndoRecord`, `StopUndoRecord`, `CloseDocument` | `null` | Neutral - `null` means no return value, not failure |
| `OpenDocument2` | `null` | **Failure** - a real open returns a document object |
| `CreateLayer` / `CreateDimensionStyle` result code | `0` or `1` | **No** - both values seen on successful creations; trust the `GetLayer()` / `GetDimensionStyle()` read-back |
| `InsertHatchByEntities` / `InsertHatchByEntitiesEx` / `InsertHatchByInternalPoints` over COM | `null` | **Failure** - a silent no-op; only `InsertHatchByBoundary` with point arrays draws |
| `IModel.GetEntities()` over COM | sometimes answers, else `MethodNotFound` | **Not a contract** - `IModel` has no `GetEntities` in the type library; what answered was an undocumented `IDispatch` member. Never build on it |
| `ISketchManager.GetEntities(null, null, out ids, out ents)` early-bound | whole-model inventory | **Yes** - 56 entities / 56 type ids on a known 56-entity drawing, 2026-10-24; `scripts/com-entities-dump.ps1` |

## Do not call

Each entry names the transport it was observed on. Do not read an HTTP-path finding as proof that
the COM call is safe, or the other way round.

| Call | Why |
|---|---|
| `dsDocumentExporter.ExportToEmf` | returned empty, then `jsServer connection Failed`, then DraftSight restarted |
| `dsDocument.SaveAs` | **HTTP only**: obsolete, superseded by `SaveAs2`; returns `GenericError` for every option. Over COM it is the call that works - `SaveAs($path, 28, [ref]$err)` returned `0` and wrote a DWG that reopened with every layer intact |
| `dsApplication.GetDocuments` | HTTP only: the only chain that preceded an unexplained crash; prefer `GetActiveDocument`. Over COM it is fine - used across 4 open documents on 26.4.0.5067 with no fault |

## Drawing discipline

- Wrap every generated drawing in `StartUndoRecord` / `StopUndoRecord` so one Ctrl+Z reverts it.
- Call `dsApplication.AbortRunningCommand()` before starting - the shipped examples do, and it avoids nested-command errors.
- **Angles are radians.** Confirmed: `InsertArc(...,0,1.5707963)` read back `get_StartAngle = 1.5707963`.
- Enum parameters take the **symbolic name as a string**, not the number: `"dsDocumentSaveAs_R2018_DWG"`, `"dsDocumentOpen_Default"`, `"dsEncoding_Default"`. Passing `28` gives the misleading `arguments[1], Options, should be type String`.
- Never attach to a DraftSight instance holding unsaved production work. Check the autosave folder and open documents first.
- **`SelectByWindow` works over COM; the point factory is on `IApplication`.** `$app.GetMathUtility().CreatePoint(x,y,z)` returns the `IMathPoint`. No `CreateMathPoint` exists on `IDocument`, `IModel`, or `ISketchManager`, so grepping only those three produces a false "unusable". A full-extents window is the entity inventory; classify hits with `$app.GetObjectType($e)` (89 = table, 24 = text).
- **`SelectByPolygon` needs flat x,y,z triples.** x,y pairs return `False` and select nothing - a silent no-op that hides leftovers.
- **A filtered `Get-Member` list is not proof of absence.** Anchor the name regex and you will miss methods that exist. See `references/com-api.md`.
- Erase any probe entity in the same script that created it. Entities have no `Delete()`; use `ISketchManager.SetObjectErased($e, $true)`.
- **PowerShell written from bash: `param()` must be the first statement** - a leading comment line makes the whole block a silent no-op and `-Switch` arguments then do nothing. `$` inside a double-quoted bash string is eaten, and backtick escapes vanish through the two layers, so write the script to a file and run it with `-File` instead of `-Command`.
- **Grep the working tree for earlier `*.ps1` before probing the API from scratch.** A previous session's scratch script is verified prior art. Re-deriving its signatures is how confident wrong claims get written into this skill.
- **Out-object slots need a live IDispatch.** `CreateLayer` / `CreateDimensionStyle` fail on `[ref]$null` (`NullReferenceException`), on `Type.Missing` (`ArgumentException`) and on reflection (`DISP_E_TYPEMISMATCH`); pass an existing object of the same interface in the slot - `$lm.CreateLayer('X', $lm.GetLayer('0'), $res)`.
- **`[math]::Pi`, never `[math]::PI()`.** `Pi` is a property; the parens turn it into a method call and PowerShell reports `[System.Math] does not contain a method named 'PI'`.
- **Batch the unknowns into one probe script.** Label the blocks A/B/C, wrap each in `try/catch`, print `OK <label>` or `ERR <label> <ExceptionType>`. Five independent API questions cost five DraftSight round trips on 2026-10-24 for no reason; one 12-line probe with four labelled blocks covers the same ground in one.
- **Read the type library before probing the live app.** `scripts/com-signature-oracle.ps1` prints real
  in/out/ref signatures from the shipped interop assembly in about two seconds, DraftSight closed, no
  document touched. Both of 2026-10-24's costliest mistakes were readable off it: `InsertRotatedDimension`
  has a fourth parameter named `DimensionTextOverride` (a text override, not a style name), and `IModel`
  has no `GetEntities` at all.
- **`Object`-typed parameters are unreachable over late binding.** PowerShell's COM binder refuses `$null`
  for them (`NullReferenceException`) and refuses to box a scalar into them
  (`int "0" ... cannot be converted to "Object"`) - the real mechanism behind `Zoom(0, $null, $null)`
  failing, not a COM enum quirk. Early binding takes them in one line and needs no new software:
  `Add-Type -Path $interop` then inline C#, and PowerShell 5.1 is .NET Framework so `GetActiveObject`
  still exists there. See `scripts/com-entities-dump.ps1`.
- **Size annotation against the part, then prove legibility.** 12 mm text on a 283 mm part reads on screen, 2.5 mm does not; export a `Zoom(2, ll, ur)` window over the dimension stack rather than trusting a whole-part export where every number is unreadable.
- **Geometry you invented has to say so on the sheet.** A sketch that omits the outside diameter is not an invitation to pick one silently: draw it, dimension it as `(REF)`, and footnote `OUTSIDE DIA NOT DIMENSIONED IN SOURCE SKETCH - DRAWN %%c85 (REF)`.

## Plotting sheets to PDF

Plotting lives on `IApplication.GetPrintManager()` -> `IPrintManager` (36 members). `IDocument` has no
plot or print member at all - grepping its 85 members and finding nothing is a false negative, the
call is on the application. Full surface plus the `[ref]` arity of every out-param getter:
`references/com-api.md`.

Runnable: `scripts/com-plot-frames.ps1` (find sheet frames, plot one PDF per frame) and
`scripts/verify-plot.py` (page size, ink-to-edge distance, colored-pixel fraction).

- **Sheet frames are found geometrically, not by name.** Production DWGs keep every sheet inside
  *model space* as a drawn border; there is usually no `TITLE` / `BORDER` / `SHEET` layer or block to
  select, and `ISelectionManager` has no `SelectByLayer` at all. Match closed polylines
  (`dsPolyLineType` = 27) whose bounding box has an ISO A-series aspect ratio (~1.414). Borders come
  as nested triples (outer / middle / inner), so collapse coincident corners or every frame counts 3x.
- **Monochrome needs three settings, not one:** `StyleTable = 'monochrome.ctb'`,
  `UseAssignedPrintStyle = $true`, and `ViewDisplayStyle = 3` (wireframe with hidden lines). The
  default `ViewDisplayStyle = 0` is "as displayed", which *shades* the sheet: the PDF becomes
  `DeviceRGB` raster tiles and no plot style table can touch rasterised pixels, so colour survives
  `monochrome.ctb` completely. Measured 2026-10-19 on one sheet: `ViewStyle` 0 with the CTB applied
  -> 566 chromatic colour operators; `ViewStyle` 3 -> 2, the near-black title-block logo pair.
  `GetAvailablePrintStyleTables` raises `DISP_E_BADCALLEE`; the tables are plain files in
  `install_dir\Default Files\Print Styles\`.
- **Verify plotted PDFs with `scripts/verify-plot.py`, never by regexing the raw file.** Counting
  `rg` / `m` / `l` operators across the whole file also matches bytes *inside embedded image streams*:
  it reported a fully rasterised sheet as healthy vector art and coloured sheets got committed. Vector
  truth = decompress the `FlateDecode` content streams and count `m x y l` pairs (hundreds to
  thousands on a real sheet, ~1 plus many `/Subtype /Image` tiles on a shaded one). Producer metadata
  reads `ODA PDF Export v25.5.0.47139`, which is how you prove which PDFs a plot run produced.
- **A sheet border can be drawn with `LINE` entities instead of a closed polyline**, and then polyline
  matching silently loses the sheet (F3: 6 of 7 sheets found; 1,080 entities + 89 texts sat outside
  every frame; the missing border was 12 lines at 0,0 - 1266,897, same triple offset 1.5 / 3). Gate
  every run on entities and texts *outside* all frames. A cluster carrying `UNIT/mm`, `TITLE`,
  `REVISON`, `DWG. NO.`, `SIZE`, `DWG'D BY` is a real sheet; a lone `No. / PART NAME / Q'TY / MAT'L`
  table is a borderless fragment - report it, do not plot it.
- **Plot one document per run.** `IDocument` / `IModel` have no working `Activate()` over COM (it
  returns successfully and does nothing) and `IPrintManager` always prints the *active* document.
  Opening a document is what raises it, so close the others and `OpenDocument2` the target, then assert
  `$app.GetActiveDocument().GetPathName()` matches before each `PrintOut` and abort if it does not.
  Never `CloseDocument($false)` a document the user opened - it discards unsaved work without a prompt.
  `SelectByWindow` does read non-active documents, so dump every DWG's extents and texts first, plot after.
- **Pick paper from the title block, not from habit.** Sheet frames are integer multiples of one ISO
  size (KL-61: every frame 2x, 3x or 5x A3, and the block states `SIZE A3`), so one paper plus
  `ScaleToFit` gives uniform pages *and* honest relative scale between small and large frames.
- **Name sheets from the drawing, then expect renames.** Use `DWG. NO.` plus the nearest `KL61...` text
  to its right; one sheet spanning two frames repeats the number (`-015` twice -> `-015-a/-b` by x
  order). If files get renamed by hand afterwards, rebuild the manifest from what is on disk.
- **Margins are paper-dependent and non-zero by default** (A4: 20/20/7.5/7.5 mm). `SetPrintMargins(0,0,0,0)`
  with `PrintOnCenter = $false` puts ink flush to the paper edge.
- `PrintOut(Copies, FileName)` with `Printer = 'PDF'` needs a full path, overwrites silently, and
  returns nothing. The built-in file plotters are `PDF`, `JPG`, `PNG`, `SVG` - no printer has to exist.


## Verification loop

Prefer geometry read-back over pixels; it is deterministic and never touches the render pipeline.

```
ISketchManager.GetEntities(null, null, out ids, out ents)  -> whole-model entity array + type ids
sk.GetEntities(null, @('2-HATCH'), out ids, out ents)      -> per-layer count, same call
GetBoundingBox()     -> {X1,X2,Y1,Y2,Z1,Z2}
per-entity props     -> get_StartAngle, get_Radius, ...
```

The supported enumerator is **early-bound** (`scripts/com-entities-dump.ps1`): late binding cannot pass
the typed `null` its `SelectionFilter` parameter needs. The `IModel.GetEntities()` that earlier revisions
of this skill told you to call is not a type-library member - see the trust table.

For a visual check, `ExportToPng` gives clean chrome-free line art. It exports **the current view, not full extents**, so `dsModel.Zoom(0,...)` (Fit) first, and expect edge clipping - a margin-corrected `Zoom(2, ll, ur)` avoids it.

A save is proven from disk, not from the save call: `OpenDocument($path, 0)` -> read the layers back -> `CloseDocument($path, $false)`. That confirms the version code actually wrote a file DraftSight can re-read. Never close a document the user opened.
Screen capture is the fallback only: `PrintWindow` returns `False` on DraftSight's Qt5 GL surface; `CopyFromScreen` over `GetWindowRect` works but includes ribbon and palettes.

## Official reference (bundled, 76 MB)

Decompiled from the DraftSight Help folder by `scripts/decompile-chm.sh`. Look things up instead of guessing.

| Directory | Pages | Contents |
|---|---|---|
| `docs/draftsightapi/` | 4,353 | API reference - **pages are named by COM interface**: `Interop.dsAutomation~Interop.dsAutomation.IPrintManager~PrintOut.html`. Grep `IPrintManager`, not `dsPrintManager` |
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
