# COM automation - the transport that works

Verified 2026-10-05 against DraftSight 2026 SP3 (`26.3.0.4078`) with the HTTP broker dead. 26 entities created, live mouse selection read back with geometry, **zero failures**. Every signature below was read off the live process, not from the docs.

Re-verified 2026-10-06 on 26.4.0.5067: a 43 x 7 BOM table written cell by cell from a CSV, per-column widths, geometry read back, Korean cell text intact. Runnable: `scripts/com-table.ps1`.

## Why COM instead of HTTP

| | COM | HTTP/JSON |
|---|---|---|
| Endpoint | the running `DraftSight.exe`, via the ROT | `dsHttpApiService` on `127.0.0.1:7776` |
| Status on this machine | **works** | **broken** - broker dies on the first request, see `protocol.md` |
| File paths | unrestricted; exports went straight to the vault | sandboxed to `C:\ProgramData\Dassault Systemes\DraftSight\` |
| Session state | plain object references | `{id, macroId, type}` handles and a `macroId` epoch that churns |
| Extra processes | none | a Windows service plus three ports |
| Host | Windows PowerShell 5.1 | any language that can POST |

## Attach - the ROT trap

DraftSight registers its COM objects in the Running Object Table **only when it was activated through COM**. The ProgID is marked `Programmable` and `LocalServer32` is `"...\DraftSight.exe" -activex`.

```
[Runtime.InteropServices.Marshal]::GetActiveObject('DraftSight.Application')
  -> works only if DraftSight was COM-activated
  -> otherwise MK_E_UNAVAILABLE (0x800401E3)
```

Fix, and the way to start a COM-attachable instance:

```powershell
$app = New-Object -ComObject DraftSight.Application   # launches DraftSight with -activex
$app.Visible = $true
```

**This can replace the user's running instance.** Observed: PID 10516 holding the user's drawing was gone afterwards, replaced by a fresh instance on `NONAME_0.dwg`. Never run it against a session holding unsaved work.

`Marshal.GetActiveObject` **does not exist in PowerShell 7** - it was removed from .NET Core. Use `powershell.exe` (5.1). `New-Object -ComObject` works in both.

Registered ProgIDs:

```
DraftSight.Application          CLSID {F549458B-32F0-49FE-A11B-3904E12446F5}   native
DraftSight_AC_X.AcadApplication CLSID {2234B07A-2D9E-458E-9783-D2B0D1649EAA}   AutoCAD-compatible
```

## The walk

```powershell
$app  = [Runtime.InteropServices.Marshal]::GetActiveObject('DraftSight.Application')
$doc  = $app.GetActiveDocument()
$model = $doc.GetModel()
$sk   = $model.GetSketchManager()
$selm = $doc.GetSelectionManager()
$ex   = $doc.GetDocumentExporter()
```

`IDraftSightDocument` has **no `GetSketchManager`** - same as the HTTP API, it lives on `IModel`. Calling it on the document throws `MethodNotFound`.

## Verified signatures (COM)

Read live via `Get-Member` on the running objects:

```
IModel            GetActiveDocument() -> GetModel()
ISketchManager    InsertLine(double x1, double y1, double z1, double x2, double y2, double z2)
ISketchManager    InsertCircle(double cx, double cy, double cz, double radius)
ISketchManager    InsertPolyline2D(Variant flatXY, bool closed)
ISketchManager    InsertArc(double, double, double, double, double, double)
ISketchManager    InsertSpline(Variant, bool, double x6, ...)
ISketchManager    GetEntities(ISelectionFilter, Variant, Variant, Variant)   # declared void - see below
ISketchManager    SetObjectErased(IDispatch, bool) / IsObjectErased(IDispatch)
IApplication      Zoom(dsZoomRange_e, Variant, Variant)      # 0 = fit; see protocol.md
IDocument         SaveAs(string, dsDocumentSaveAsOption_e, dsDocumentSaveError_e)
IDocument         Save() -> dsDocumentSaveError_e
IDocumentExporter ExportToPng(string, bool) / ExportToSvg / ExportToJpg / ExportToBmp
IDocumentExporter ExportToTiff / ExportToStl / ExportToSld / ExportToEmf
IDocumentExporter ExportToPdf(string, Variant, double, double, bool)
IDocument         GetPathName()                       # there is no GetName() over COM
IDocument         ScaleUnit                           # dsScaleUnit_e as int; 8 = Millimeters
ISketchManager    GetBoundingBox(6 [ref] doubles)     # 1e20 -> -1e20 means an empty drawing
IApplication      AbortRunningCommand()               # on the app, not on ISketchManager
IDocumentExporter ExportToPdf(string, Variant, double, double, bool)
```

`ExportToPng(path, $true)` writes straight to any path - **no sandbox**. That is a second, independent reason to prefer COM: the whole staging dance in `protocol.md` does not apply.

Over COM it returns **nothing**, not `{"Success":true}`. The HTTP trust table does not port. Confirm the write by checking the file's mtime.

## SAFEARRAYs and out parameters

```powershell
# Variant coordinate arrays: pass a typed double array, flat x,y pairs
$sk.InsertPolyline2D([double[]]@(-38,8, 38,8, 26,95, -26,95), $true)

# out parameters need [ref]
$x1=0.0;$y1=0.0;$z1=0.0;$x2=0.0;$y2=0.0;$z2=0.0
$e.GetBoundingBox([ref]$x1,[ref]$y1,[ref]$z1,[ref]$x2,[ref]$y2,[ref]$z2)
```

`GetSelectedObjects` takes **two** arguments in COM - `(set, Variant)` - where the JS form took one. Calling it with one argument raises `Cannot find an overload`.

`ISketchManager.GetEntities` is declared **`void`** in the type library, so the HTTP enumeration pattern does not port: every call shape PowerShell can build fails with `Exception setting "GetEntities": Cannot convert ... to type "Object"`. Enumerate a region with the selection manager instead:

```
ISelectionManager   SelectByPolygon(CoordinateDblArray, Crossing) -> bool   # flat x,y,z triples
                    GetSelectedObjectCount(set) -> int
                    GetSelectedObject(set, index, dsObjectType_e) -> entity
                    ClearSelections(set)
```

**`SelectByWindow` is declared but unusable over COM.** It takes `IMathPoint`, and no `CreateMathPoint` exists on `IDocument`, `IModel`, or `ISketchManager`. `SelectByPolygon` is the only working region select, and it needs **flat x,y,z triples**: `@(0,0,0, 80,0,0, 80,-25,0, 0,-25,0)`. Hand it flat x,y pairs and it returns `False` and selects nothing - a silent no-op, not an error.

## Tables over COM

`InsertTable(Left, Top, Rows, Columns, RowHeight, ColumnWidth, FirstRowStyle, SecondRowStyle, OtherRowStyle)`. The style arguments are `dsTableCellType_e` and **plain ints work over COM**: `2` header, `3` data. Verified with a 43 x 7 table filled from a CSV.

Members read live off the created table:

```
SetText(Row, Col, Text)   GetText(Row, Col)   GetSimplifiedText(Row, Col)
TotalRowCount()           TotalColumnCount()
SetColumnWidthAt(Col, Width)     GetColumnWidth(Col)      # per column
SetRowHeightAt(Row, Height)      GetRowHeight(Row)        # per row
SetColumnWidth(Width)            SetRowHeight(Height)     # every column / every row
SetTextHeight(CellType, Height)  GetCellTextHeight(Row, Col)
SetCellType  SetCellAlignment  SetCellTextColor  SetCellBackgroundColor
SetCellHorizontalMargin  SetCellVerticalMargin  MergeCells  UnmergeCells
InsertRow(Row, Height)  InsertColumn(Col, Width)  DeleteRow(Row)  DeleteColumn(Col)
GetBoundingBox(6 out doubles)
```

The `*At` setters are the ones that matter and they are easy to miss - `SetColumnWidth` alone makes every column the same width. `GetColumnWidthAt` genuinely does not exist on either transport; the getter is `GetColumnWidth(Col)`.

Sizing behaviour, measured:

- Rows grow to fit text. Requesting `RowHeight = 7` with header text height 3.5 read back as **11**.
- Cells **wrap, they never clip**. A column too narrow for its text grows the row instead of truncating, so a table can silently double in height.
- At text height 3.0 the default font needs about **2.5 mm per ASCII character**, plus ~10 mm of cell margin. `KL61-POLYMER-LINE-ASSEMBLY-1-0` (30 chars) needed 85 mm; 70.5 mm wrapped it to two lines. CJK glyphs are ~1.7x an ASCII glyph.
- A table is **one entity**, so `GetBoundingBox` returns the whole grid: 43 x 7 at those widths read back `(0, 0) -> (452, -430.4)`.

Non-ASCII cell text is fine. `Import-Csv -Encoding UTF8`, strip the BOM from header names (`-replace '\uFEFF',''`), and the strings survive the BSTR marshalling; Korean rendered correctly in `ExportToPng`.

## Selection sets - the trap

A normal mouse pick does **not** land in set 0:

```
GetSelectedObjectCount(0)  -> 0     Current
GetSelectedObjectCount(1)  -> 1     <- where the live pick actually is
GetSelectedObjectCount(2)  -> 0
GetSelectedObjectCount(3)  -> 0

$e = $selm.GetSelectedObject(1, 0, 0)   # set, index, dsObjectType_e (0 resolves anything)
```

`GetSelectedObjectCount` returns a plain `int`, so it is a reliable liveness probe - the COM equivalent of `GetVersion` on HTTP.

**Programmatic selection does not use set 1.** `SelectByPolygon` put its hits in sets **0 and 2** and left set 1 empty - the opposite of a mouse pick. Probe every set before reading, and `ClearSelections(set)` afterwards.

## Entity protocol

Members present on a selected entity (a circle, read live):

```
properties  Handle  Layer  Color  LineStyle  LineWeight  LineScale  PrintStyle
            Transparency  Visible  Erased  Thickness  Radius
methods     GetArea  GetLength  GetBoundingBox(6 out doubles)  GetCenter  SetCenter
            GetNormal  SetNormal  GetEndParams  EvaluateAtDistance  EvaluateAtParameter
            EvaluateAtPoint  GetClosestPointOn  Select
            GetCustomData  SetCustomData  DeleteCustomData
            GetHyperLink  SetHyperLink  DeleteHyperLink
            GetExtensionDictionary  CreateExtensionDictionary  ReleaseExtensionDictionary
```

There is **no `Delete()`** on any entity. `$entity.Delete()` raises `MethodNotFound`. Remove one with `ISketchManager.SetObjectErased($entity, $true)`.

Worked read-back of a selected circle - every number self-consistent:

```
handle=cd  layer=0  radius=10  visible=True  erased=False  lineWeight=-1 (ByLayer)
GetArea()   = 314.159265358979   = pi * 10^2
GetLength() =  62.8318530717959  = 2 * pi * 10
bbox (42,150,0) -> (62,170,0)    -> centre (52,160), 20 x 20
```

## Introspect instead of guessing

`Get-Member` on a `__ComObject` returns the real signatures, which beats the CHM docs whenever they disagree:

```powershell
foreach ($m in ($sk | Get-Member)) { $d = [string]$m.Definition; if ($d -match 'InsertLine|InsertPolyline') { Write-Output $d } }
```

Two PowerShell gotchas that cost time:

- Cast `[string]$m.Definition` before matching. Concatenating `$m.MemberType` into a string throws `Cannot convert value "::" to type PSMemberTypes`.
- **Filter properties on `$m.MemberType -eq 'Property'`, not on `(`.** A COM property definition contains parentheses - `string Handle () {get}`, `double Radius () {get} {set}` - so an `(` filter silently drops every property and the loop prints nothing.
- **Never anchor a name filter while discovering an API.** Filtering on `^(Set|Get)(ColumnWidth|RowHeight|TextHeight|Text)$` reported no `SetColumnWidthAt`, and "per-column widths are unreachable over COM" was written down as fact. It is reachable: `SetColumnWidthAt(int, double)` is right there; the `$` anchor dropped it. Filter on a bare substring (`Column|Row|Cell`) or dump the whole list. **Absence from a filtered list is unknown, not absent.**

## Worked example

`scripts/com-inspect.ps1` reads the current selection. `scripts/com-draw-example.ps1` draws, fits the view, and exports a PNG. `scripts/com-table.ps1` turns a CSV into a sized table. All run under `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...`.

The COM route drew the package's wizard figure end to end - 22 entities, then 4 more for the eyes, `Zoom(0)` to fit, `ExportToPng` - see `assets/wizard-ava-com.png`.

## Driving PowerShell from a POSIX shell

pi's `pi.bash` on Windows is git-bash, and two things bite:

- `powershell.exe -Command "... $var ..."` - git-bash expands `$var` before PowerShell sees it, and the script arrives with every variable stripped. **Write a `.ps1` and run it with `-File`.**
- `powershell.exe -File x.ps1 | Out-String` - `Out-String` is a cmdlet, not a shell command; git-bash answers `Out-String: command not found`. Redirect with `2>&1` and let the harness capture stdout.

Keep the `.ps1` itself ASCII-only and read non-ASCII data inside PowerShell with an explicit `-Encoding UTF8`. That sidesteps whether the script file was saved with a BOM.

## Probe entities: clean up in the same script

Introspecting an interface sometimes means creating an object of that type first - there is no other way to reach `ITable`'s members. If the script then dies, the object is left in the user's drawing. That happened: a 2x2 probe table sat under the real table, and because `SelectByPolygon` was being called with the wrong (x,y) argument shape, the check that should have found it returned `False` and reported an empty region. Two independent failures covering for each other.

Erase the probe in the same script that creates it, and verify the erase by re-selecting and reading the survivors' properties - not by counting, which cannot tell a probe from a real entity. `GetColumnWidth(0)` on the two tables (40 vs 82) is what finally distinguished them.
