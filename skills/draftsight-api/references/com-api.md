# COM automation - the transport that works

Verified 2026-10-05 against DraftSight 2026 SP3 (`26.3.0.4078`) with the HTTP broker dead. 26 entities created, live mouse selection read back with geometry, **zero failures**. Every signature below was read off the live process, not from the docs.

Re-verified 2026-10-06 on 26.4.0.5067: a 43 x 7 BOM table written cell by cell from a CSV, per-column widths, geometry read back, Korean cell text intact. Runnable: `scripts/com-table.ps1`.

Print/plot surface read live 2026-10-07 on 26.4.0.5067 - see `Printing and plotting`.

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
IApplication      GetPrintManager() -> IPrintManager  # plotting lives here, never on IDocument
IDocument         GetPathName()                       # there is no GetName() over COM
ILayerManager     CreateLayer(string, ILayer out, dsCreateObjectResult_e)   # out slot must be a live IDispatch
IDimensionStyleManager CreateDimensionStyle(string, IDimensionStyle out, dsCreateObjectResult_e)
ISketchManager    InsertHatchByBoundary(int[] loopCounts, double[] xyzLoops, string pattern, double scale, double angle)
ISketchManager    GetEntities(SelectionFilter filter, string[] layerNames, out object typeIdArray, out object entityArray)   # 4 args; early-bound only
IModel            # has NO GetEntities - not declared anywhere in the type library
ISketchManager    InsertRotatedDimension(double[] ext1, double[] ext2, double[] dimLine, string textOverride, double rotationRad)
ISketchManager    InsertSimpleNote(double x, double y, double z, double height, double angle, string text)
IApplication      OpenDocument(string, dsDocumentOpenOption_e)   # 2 args; OpenDocument2 adds dsEncoding_e
IApplication      CloseDocument(string, bool)
IDimensionStyle   GetDimensionStyleTextOptions() / GetDimensionStyleArrowsOptions() / GetDimensionStyleLineOptions()
IDimensionStyle   GetDimensionStyleFitOptions().SetDimensionScale(dsDimensionScale_e, double)
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

`ISketchManager.GetEntities` is declared **`void`** in the type library, so the HTTP enumeration pattern does not port: every call shape PowerShell can build fails with `Exception setting "GetEntities": Cannot convert ... to type "Object"`. Enumerate with the selection manager instead:

```
IApplication        GetMathUtility() -> IMathUtility
IMathUtility        CreatePoint(x, y, z) -> IMathPoint
IApplication        GetObjectType(IDispatch) -> dsObjectType_e (int)
ISelectionManager   SelectByWindow(IMathPoint, IMathPoint, Crossing) -> bool
                    SelectByPolygon(CoordinateDblArray, Crossing) -> bool   # flat x,y,z triples
                    GetSelectedObjectCount(set) -> int
                    GetSelectedObject(set, index, dsObjectType_e) -> entity
                    ClearSelections(set)
```

Full entity inventory over COM - a window over the whole drawing:

```powershell
$mu = $app.GetMathUtility()
$selm.SelectByWindow($mu.CreatePoint(-1e6,-1e6,0), $mu.CreatePoint(1e6,1e6,0), $true)   # -> True
# hits land in sets 0, 2 and 3; classify each with $app.GetObjectType($e)
```

Observed `GetObjectType` codes: **89 = table**, **24 = text**.

**The `IMathPoint` factory is on `IApplication`, not on the document.** No `CreateMathPoint` exists on `IDocument`, `IModel`, or `ISketchManager` - grepping those three and concluding `SelectByWindow` is "unusable" is a wrong answer you can reach without ever asking the application object for `GetMathUtility`.

`SelectByPolygon` needs **flat x,y,z triples**: `@(0,0,0, 80,0,0, 80,-25,0, 0,-25,0)`. Hand it flat x,y pairs and it returns `False` and selects nothing - a silent no-op, not an error.

## Created objects: layers, styles, hatches, annotation

**The out slot needs a live IDispatch.** `CreateLayer` and `CreateDimensionStyle` hand the new object
back through an out slot typed as an interface, and PowerShell cannot fabricate that slot over
`IDispatch`. All four natural call shapes fail, three of them confusingly:

| Attempt | Failure |
|---|---|
| `CreateLayer('X', [ref]$null, [ref]$r)` | `NullReferenceException` |
| `CreateLayer('X', [System.Reflection.Missing]::Value, ...)` | `ArgumentException` on the parameter count |
| `[int]$o = 0; CreateLayer('X', [ref]$o, [ref]$o)` | cannot marshal `int` into a ref of interface type |
| `InvokeMember('CreateLayer', ..., @('X', $null, 0))` | `DISP_E_TYPEMISMATCH` |

Hand in an **existing object of the same interface** instead. It is an out parameter, so the value you
pass is overwritten - it only has to marshall:

```powershell
$lm    = $doc.GetLayerManager()
$proto = $lm.GetLayer('0')                  # any live ILayer
$res   = 0
$lm.CreateLayer('1-OUTLINE', $proto, $res)
$lay   = $lm.GetLayer('1-OUTLINE')          # read-back is the evidence, not $res
$lay.LineWeight = 35                        # 35 = 0.35 mm; per-entity .LineWeight works too
$dm.CreateDimensionStyle('X-DIM', $dm.GetDimensionStyle('ISO-25'), $res)
```

`$res` came back `1` on one creation and `0` on another, both successful - trust `GetLayer()` /
`GetDimensionStyle()`, never the result code. There is no way around `CreateLayer` either:
`SetObjectLayer($e,'NEWNAME')` on a name that does not exist does not create it.

### Hatch - exactly one overload works

```powershell
# a boundary is [count, then count flat x,y,z triples] - documented for exactly ONE loop per call.
# PatternScale is documented as 0.25..2.0 in 0.25 steps (default 1); PatternAngle is radians, 0..2*pi.
$sk.InsertHatchByBoundary([int[]]@(6), [double[]]@($x1,$y1,0, $x2,$y2,0, ...), 'ANSI31', 1.5, 0.0)
```

`InsertHatchByEntities`, `InsertHatchByEntitiesEx` and `InsertHatchByInternalPoints` all return
`null` over COM - no exception, nothing drawn - even though the JS API accepts them. Read the hatch
back through `PatternName` / `PatternScale` / `Area` instead of trusting the call to have drawn.

Three things the help settles that a first pass guessed at. `PatternScale` is bounded **0.25 to 2.0 in
0.25 steps**, default 1, and is ignored for `UserDefined` patterns - those respace through
`IHatchPattern::SetHatchOrSolidData`. `PatternAngle` is radians, 0 to 2*pi. And `BoundaryPointDblArray` is
documented as "array of x-y coordinates" while the call that actually draws passes **x, y, z triples** -
the help trails the implementation here, which is worth remembering about this reference in general.
Whether a single call can hatch more than one loop is **undocumented and still untested** by me; the counts
array is described in the singular, so treat `@(6, 4)` as an inference, not a recipe. A hatched region's
loops are read back through `IHatch.GetBoundaryLoopsCount` / `IHatch.GetHatchBoundaryLoop` /
`IHatchBoundaryLoop.GetPolyLineBoundaryLoopData`.

### Dimension annotation is style-level, not entity-level

Text height, arrow size and extension-line offsets come from the **style**, and option-group writes
do persist - but only for the next read from a *fresh* style object:

```powershell
$ds = $doc.GetDimensionStyleManager().GetDimensionStyle('ISO-25')
$ds.GetDimensionStyleFitOptions().SetDimensionScale(1, 1.0)   # normalise FIRST - see below
$to = $ds.GetDimensionStyleTextOptions(); $to.Height = 12.0
$doc.GetDimensionStyleManager().GetDimensionStyle('ISO-25').GetDimensionStyleTextOptions().Height
```

- Set the fit scale **before** the height or the millimetre value is multiplied by whatever factor the
  style already carries. `dsDimensionScale_e`: 1 = use scale factor, 2 = scale according to sheet.
  `GetDimensionScale(method, [ref]double)` reads it back.
- `InsertRotatedDimension(ext1[3], ext2[3], dimLine[3], string, rotationRad)` - the string is a
  **text override, not a style name**: passing `'AA-DIM'` left the dimension on the active style and
  printed `AA-DIM` as its text.
- `GeneralDimension.TextOverride = '%%c23'` renders `Ø23`. `.Measurement` still reports the true
  `23.0`, so assert on `Measurement` and let the override carry the presentation.
- A `DBText` is already on `Standard`: `SetObjectTextStyle` and `SetTextStyleName($e,'Standard')` raise
  `E_INVALIDARG`. Set `.Height`.
- A dash-dot centre line needs no linetype loaded - emit long-dash / short-dot segments (14 mm dash,
  1.4 mm dot, 3 mm gap at 283 mm part height).

### Save, reopen, and the entity-binding drift

`SaveAs($path, 28, [ref]$err)` over COM returned `0` and wrote a DWG that reopened with every layer
intact, so the "`SaveAs` is obsolete" rule is an **HTTP** finding that does not port.
`OpenDocument(path, option)` takes **two** arguments (`OpenDocument2` adds `dsEncoding_e`),
`CloseDocument($path, $false)` closes by path, and `GetPathName()` is the only document identity read
- `GetDocumentName`, `GetDocumentFilePath` and `GetDocumentCount` are not on `IDispatch`.

There is no binding drift story here. **`IModel.GetEntities()` is not in the type library at all** - all
723 interop types were enumerated on 2026-10-24 and the only declarers of `GetEntities` are
`IBlockDefinition` (out, out), `IGroup` (out, out), `IHighlightSet` (out, out) and `ISketchManager`
(in SelectionFilter, in Object LayerNamesStrArray, out Object EntityTypeLongArray, out Object
EntitiesArray). What answered as `IModel.GetEntities()` is a member the running server exposes through
`IDispatch` that the type library does not declare, so it appearing on one document and not on another
was never a question of binding strength - it was never supported, and `MethodNotFound` was the honest
answer.

Retacted the same day it was written: an earlier revision of this file, and the trust-table row that
came with it, called this "binding strength drifts after `SaveAs`". That reading came from runtime
`Get-Member` and it was wrong. The fix is to read the type library before the live app -
`scripts/com-signature-oracle.ps1` - and to enumerate entities through the supported early-bound call,
which returned 56 entities and 56 type ids from a known 56-entity drawing on its first attempt
(`scripts/com-entities-dump.ps1`).


## Early binding: the shipped interop assembly

DraftSight ships a tlbimp wrapper over its own type library: `install_dir\APISDK\tlb\DraftSight.Interop.dsAutomation.dll`
(26.4.0.43 on 26.4.0.5067, 723 types, every interface `IsImport`). It is the only complete and honest
signature source available, and it reads with DraftSight closed:

```powershell
scripts\com-signature-oracle.ps1                                                # the hot interfaces
scripts\com-signature-oracle.ps1 -Search ObjectName                             # who declares it
scripts\com-signature-oracle.ps1 -Types ISketchManager -Method GetEntities -Enums
```

Read the signature before the first live probe. The two costliest mistakes of 2026-10-24 were both
readable off the type library in one line each: `InsertRotatedDimension`'s fourth parameter is named
`DimensionTextOverride` - it is a text override, and passing a style name there prints the style name as
the dimension text - and `IModel` declares no `GetEntities` at all.

What late binding cannot express: every array parameter is typed `Object` in the typelib, and PowerShell's
COM binder **refuses `$null` for an `Object` parameter** (`NullReferenceException`) **and refuses to box a
scalar into it** (`int "0" ... cannot be converted to "Object"`). That is the real mechanism behind
`Zoom(0, $null, $null)` failing over late binding, not the COM enum marshalling quirk an earlier revision
of this file claimed.

The same call early-bound, from PowerShell 5.1, with no new software (PS 5.1 is .NET Framework 4.x, so
`Marshal.GetActiveObject` still exists there):

```powershell
$interop = 'C:\Program Files\Dassault Systemes\DraftSight\APISDK\tlb\DraftSight.Interop.dsAutomation.dll'
Add-Type -Path $interop        # LOAD it: a bare -ReferencedAssemblies compiles, then dies at run time
                               # with "cannot load file or assembly" and looks like a broken DLL
$src = @'
using System; using System.Runtime.InteropServices;
using DraftSight.Interop.dsAutomation;
public static class EB {
  public static void Run() {
    IApplication app = (IApplication)Marshal.GetActiveObject("DraftSight.Application");
    Document doc = app.GetActiveDocument();
    ISketchManager sk = doc.GetModel().GetSketchManager();
    object types, ents;
    sk.GetEntities(null, null, out types, out ents);   // the typed null a binder can never pass
    System.Array a = (System.Array)types; System.Array b = (System.Array)ents;
    System.Console.WriteLine("entities=" + b.Length + " typeIds=" + a.Length);
  }
}
'@
Add-Type -TypeDefinition $src -Language CSharp -ReferencedAssemblies @($interop,'mscorlib','System','System.Core')
[EB]::Run()
```

Measured 2026-10-24 against a known 56-entity section drawing: `entities=56`, `typeIds=56`, first six type
ids all `21` - the twelve lines drawn first. The same run read `GetLayer('1-OUTLINE').LineWeight` back as
the symbolic **`dsLnWt_035`**, where the late-bound path returns a bare `35`; typed enums retire the "is
`0` success?" guessing the trust table has to carry everywhere else. Runnable version with a per-layer
breakdown and a type histogram: `scripts/com-entities-dump.ps1`.

That run also needed its type ids decoded, and getting them decoded took two attempts: the first search
asked the type library for a `*EntityType` enum, found none, and recorded "no enum is published". The enum
is published - it is `dsObjectType_e`, 164 values - I had simply guessed the wrong name, which is what the
help is for. The help gives the name and the type library gives the numbers, which the help never prints:

```
powershell -File scripts/com-signature-oracle.ps1 -Search dsObjectType_e -Enums -Values
```

| id | `dsObjectType_e` member | in that drawing |
|---|---|---|
| 21 | `dsLineType` | 47 (12 outline + 29 centre + 6 leader and rule lines) |
| 24 | `dsSimpleNoteType` | 3 - `InsertNote` creates a *SimpleNote*, not a Text entity |
| 55 | `dsRotatedDimensionType` | 4 |
| 71 | `dsHatchType` | 2 |

56 entities total, and the per-layer split (12 / 2 / 29 / 4 / 9) matched the layers they were drawn onto:
numbers from the type library and contents from a known drawing, corroborating each other from two
independent sources. When a new id appears, do the same - known drawing first, id afterwards.

Five traps on this path, each one hit during the 2026-10-24 spike:

- `-Language "C#"` does not exist in PowerShell 5.1; the accepted names are **`CSharp`**, `CSharpVersion3`, `CSharpVersion2`, `VisualBasic`, `JScript`.
- The interop's interface names are the coclass-flavoured ones: `Application`, `Document`, `Layer`, `Line`, `Hatch`, `SimpleNote`. **`IEntity` is not one of them** - a `using`-clean compile still fails with `'IEntity' does not exist`; ask the oracle with `-Search ObjectName` for the declaring interface.
- Entity array elements arrive as `System.__ComObject`, so read a property either through a cast to the interface that declares it, or through `GetType().InvokeMember(name, BindingFlags.GetProperty, ...)`.
- There is **no `*EntityType` enum** among the 723 types, so `EntityTypeLongArray` values have no published names: calibrate the ids you depend on against one drawing whose contents you already know.
- The `SelectionFilter` parameter is an interface with **zero constructors**, so late binding cannot build one either. `null` is the only useful argument and only early binding can pass it - and the help says so outright: *"Selection filter indicating which entities to get or a null value to accept all types of entities"*, with `LayerNamesStrArray` described as an array of layer-name strings. So `GetEntities(null, @('1-OUTLINE'), [ref]$ids, [ref]$ents)` is the documented call rather than a workaround. A real filter object is obtainable from `ISelectionManager.GetSelectionFilter()`.

For creating objects the type library declares real out parameters -
`CreateLayer(in String Name, out Layer Layer, out dsCreateObjectResult_e Result)` and
`CreateDimensionStyle(in String Name, out DimensionStyle DimensionStyle, out dsCreateObjectResult_e Result)`
- so the "hand a live IDispatch to the out slot" workaround above is an artefact of *late* binding, not
of the API. It remains what the PowerShell-only scripts use, because it needs no compiled C#; the
early-bound form was deliberately left untested, since exercising it creates layers in a document the
user has open.

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

**Programmatic selection does not use set 1.** `SelectByPolygon` put its hits in sets **0 and 2**; `SelectByWindow` used **0, 2 and 3**. Both left set 1 empty - the opposite of a mouse pick. Probe every set before reading, and `ClearSelections(set)` afterwards.

**There is no `SelectByLayer`.** `ISelectionManager` is geometric only - `SelectByWindow`, `SelectByPolygon`, `SelectByCrossline`, `SelectByPoint`. To select "everything on layer X", select a window and filter on `$e.Layer` yourself.

`IDocument::GetObjectByHandle(string Handle, out dsObjectType_e ObjType)` takes **2 args**, the second an out-param: `$e = $doc.GetObjectByHandle('8fa9d', [ref]$ot)`. A 1-arg call raises an argument-count error.

`IEntityHelper::Select(object Obj, bool SelectFlag)` is declared 2-arg but is **unusable from PowerShell**: both the 0-arg and the 2-arg call raise an argument-conversion error, because the `object Obj` parameter will not marshal. Select geometrically instead.

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

## JS SDK stubs are an index, not a contract

`install_dir\APISDK\djLibrary\ds<Interface>.js` - one file per interface, every method name on a single screen (`dsPrintManager.js`, `dsDocument.js`, `dsApplication.js`). Read it to learn **what exists**. Do not read it as the calling convention.

**Parity rule: if the JS API has it, COM almost certainly has it.** Both layers sit on one object model; the JS layer is a thin `djProcessCommand` shim over the same interfaces. So "not in the JS stub" and "not in the JS docs" are **not** evidence of absence over COM - enumerate the `__ComObject` before concluding a feature is unreachable.

**The JS layer is not a stable contract.** It is a convenience shim shipped with the SDK; its names and arities drift, and it hides out-parameters behind JS return values. Measured against the COM type library:

| Member | JS stub | COM type library |
|---|---|---|
| `ExportToPdf` | 4 args | 5 args - trailing `out bool Success` |
| `GetPrintMargins` | 0 args, returns values | 4 x `[out] double` |
| `GetPrintRange` | 0 args | 7 x `[out]` |
| `GetSelectedObjects` | 1 arg | 2 args |

A JS signature is a hint about the **name**, never about the arity. `Get-Member` on the live object is the contract.

**Name mapping.** JS/HTTP use `dsXxx`; the COM type library (`bin\dsAutomation.dll`) uses `IXxx`:

```
dsPrintManager      -> IPrintManager        dsDocument       -> IDocument / IDraftSightDocument
dsApplication       -> IApplication         dsSketchManager  -> ISketchManager
dsDocumentExporter  -> IDocumentExporter    dsSheet          -> ISheet
```

The decompiled `docs/draftsightapi/` is organised by the **COM** names - 161 interfaces across ~4,000 pages, e.g. `Interop.dsAutomation~Interop.dsAutomation.IPrintManager~PrintOut.html`. Grepping `dsPrintManager` there returns nothing; grep `IPrintManager`. Enum pages keep the `ds` prefix (`dsPrintRange_e`), and those are the values COM methods take - **as ints**, not as the symbolic strings the HTTP transport wants.

## Printing and plotting - IPrintManager

Read live 2026-10-07 on 26.4.0.5067: `GetPrintManager()` returns an `IPrintManager` with **36 members**, all reachable over COM.

**Plotting is not on the document.** All 85 `IDocument` members contain no `Plot`, `Print`, or `PageSetup` - the only export hook there is `GetDocumentExporter()`. The print manager hangs off `IApplication`:

```powershell
$pm = $app.GetPrintManager()
```

Surface: `Printer` `PaperSize` `GetPaperSize` `SetClosestValidPaperSize` `AvailablePaperSizes` `AvailablePaperSizesInLocale` `PaperSizeInLocale` `ScaleToFit` `UserScale` `GetUserScaleValue` `SetUserScaleValue` `GetStandardScale` `SetStandardScale` `ScaleLineWeight` `GetPrintMargins` `SetPrintMargins` `GetPrintOffset` `SetPrintOffset` `StyleTable` `GetAvailablePrintStyleTables` `ViewDisplayStyle` `Quality` `Orientation` `PrintOnCenter` `PrintInverse` `PrintInBackground` `PrintSheetLast` `HideGeometryOnSheet` `UseAssignedLineWeight` `UseAssignedPrintStyle` `GetPrintRange` `SetPrintRange` `GetSheets` `SetSheets` `GetAvailablePrinters` `PrintOut(Copies, FileName)`.

Every `Get*` here is out-param style; calling one bare raises `MethodException ... "0" arguments`:

| Call | `[ref]` arguments |
|---|---|
| `GetPrintMargins` | 4 x double (top, bottom, left, right) |
| `GetPrintOffset` | 2 x double |
| `GetPaperSize` | 2 x double (length, width) |
| `GetUserScaleValue` | 2 x double (paper units, drawing units) |
| `GetStandardScale` | enum + double |
| `GetPrintRange` | enum, string, bool, 4 x double |
| `GetAvailablePrintStyleTables` | 1 x object array |

Zero-arg and working: `GetAvailablePrinters()` (9 devices here), `AvailablePaperSizes()` (46 names, `Letter_(8.50_x_11.00_Inches)` style), `AvailablePaperSizesInLocale()`, `GetSheets()`.

Verified reads on a live drawing: `Printer='None'`, `PaperSize=''`, `Orientation=1` (portrait), `Quality=2`, `PrintSheetLast=True`, `UseAssignedLineWeight`/`UseAssignedPrintStyle=True`, `GetPrintRange -> 2` (`dsPrintRange_DrawingBoundary`), margins `0 0 0 0`, `GetUserScaleValue -> 1/1`.

Enums as ints: `dsPrintRange_e` All=1, DrawingBoundary=2, CurrentView=3, NamedView=4, SpecifyWindow=5 - `dsPrintOrientation_e` Portrait=1, Landscape=2 - `dsStandardPrintScale_e` 1:1=16, 1:2=17, 1:10=20, 1:20=22, 1:50=25, 1:100=26.

**Plot to a file with no printer installed.** `Printer` accepts the four built-in file plotters `PDF`, `JPG`, `PNG`, `SVG` alongside real device names; with those, `PrintOut(Copies, FileName)` requires a full path and **overwrites an existing file silently**. The docs require `SetSheets` before `PrintOut`. **Verified 2026-10-07 on 26.4.0.5067:** thirteen model-space sheet frames plotted to thirteen single-page PDFs with no printer installed (`Printer` was `None`), no dialog, ~40-120 KB each. Working recipe:

```powershell
$pm.Printer     = 'PDF'
$pm.ScaleToFit  = $true
$pm.Orientation = 2                                   # Landscape
$pm.PaperSize   = 'ISO_A3_(297.00_x_420.00_MM)'       # exact name from AvailablePaperSizes()
$pm.SetSheets([string[]]@('Model'))
$pm.SetPrintRange(5, '', $true, $x1, $y1, $x2, $y2)   # 5 = SpecifyWindow, window in model units
$pm.PrintOut(1, 'C:\full\path\sheet-01.pdf')
```

- `SetClosestValidPaperSize(420,297)` resolves to the **full-bleed** variant (`ISO_full_bleed_A3_(...)`); assign `PaperSize` by exact name when you want the trimmed sheet.
- `Orientation` rotates the *named* paper: the portrait-dims name plus `2` produced `MediaBox [0 0 1191 842]` (A3 landscape). Passing an already-landscape name risks a second rotation - read `MediaBox` back to confirm.
- `PrintOut` is silent on success. Verify by file size and `MediaBox`; rasterize with `pypdfium2` + Pillow (`render(scale).to_pil().save()`) when the drawn content itself must be checked.

Runnable end to end: `scripts/com-plot-frames.ps1` (detect frames, one PDF per frame) and `scripts/verify-plot.py` (page size, ink-to-edge distance, colored-pixel fraction).
**Monochrome output needs three settings, not two.** `StyleTable = 'monochrome.ctb'` alone does nothing - the table is applied only when `UseAssignedPrintStyle = $true` (the name reads backwards: "assigned" = use the assigned plot style table). With `$false` the assignment is silently dropped and `StyleTable` reads back empty. Measured on one sheet: unstyled 4.36% colored pixels, `monochrome.ctb` + assigned `$true` -> 0.026% (anti-aliasing only), `Grayscale.ctb` + assigned `$false` -> 4.36%, unchanged.

**The third setting is `ViewDisplayStyle`, and it is the one that hides.** Default `0` = *as displayed*, which shades the sheet, so the PDF plotter emits `DeviceRGB` raster tiles; a plot style table maps pen colours and cannot touch rasterised pixels. Verified 2026-10-19 on 26.4.0.5067: `ViewStyle` 0 **with** `monochrome.ctb` applied still produced 566 non-grey colour operators, `ViewStyle` 3 (wireframe + hidden lines) produced 2, the near-black logo pair. `3` also draws hidden lines, so use `1` if hidden lines are unwanted. Shaded output is unmistakable once you look: ~1 `m ... l` pair per page and a pile of `/Subtype /Image` tiles.

**Do not verify plots by regexing PDF bytes.** Scanning the raw file for `rg` / `m` / `l` matches bytes inside embedded image streams, which is how a rasterised sheet passed a vector-content check. Decompress content streams (`FlateDecode`) before counting, or render and measure with `scripts/verify-plot.py`.

`GetAvailablePrintStyleTables([ref]$arr)` raises `DISP_E_BADCALLEE` (0x80020010) - enumerate the folder instead: `install_dir\Default Files\Print Styles\` holds `monochrome.ctb`, `Grayscale.ctb`, `default.ctb`, `Fill Patterns.ctb`, `Screening 25/50/75/100%.ctb`.

**Margins are paper-dependent and non-zero by default.** With no paper selected `GetPrintMargins` reads `0 0 0 0`, but selecting `ISO_A4_(210.00_x_297.00_MM)` gives `20/20/7.5/7.5` (top/bottom/left/right). `SetPrintMargins(0,0,0,0)` plus `PrintOnCenter=$false` puts ink flush to the paper edge - confirm by measuring the ink bounding box of a rasterized page, not by reading the property back.

`$e.Color` returns an `IColor` **object**, not an int - `[int]$e.Color` throws an argument-conversion error. Members: `GetColorIndex GetNamedColor GetRGB IsColorByIndex IsNamedColor SetByColor SetColorByIndex SetNamedColor SetRGBColor`. There is no `ColorMethod` or `PaletteIndex` property.

Second, independent path: `$doc.GetDocumentExporter().ExportToPdf(path, sheetsArray, pageLen, pageW, [ref]$ok)` and `ExportToPdf2(path, settings)` with `CreateExportSettings()`; `IExportSettings` carries its own `PrintStyleTable` and `SetPrintMargins`. Prefer it when you only want a PDF and must not disturb the session's printer state.

### Multi-document batches

`IPrintManager` plots the **active** document and nothing else, and there is no working activation call: `IDocument.GetModel().Activate()` returns without error and does not change `$app.GetActiveDocument()`. Opening is the only thing that raises a document, so the loop is close-others-then-open, with an assertion before every `PrintOut`:

```powershell
foreach ($name in 'B1.dwg','B2.dwg') {
  $cur = $app.GetActiveDocument(); $curPath = $cur.GetPathName()
  if ($curPath -notlike ('*\' + $name)) {
    if ($curPath -like (Join-Path $stage '*')) { $cur.CloseDocument($false) }   # our copy: discard is fine
    else { throw ('refusing to close user document ' + $curPath) }              # CloseDocument($false) discards silently
  }
  if ($app.GetActiveDocument().GetPathName() -notlike ('*\' + $name)) { throw ('target is not active: ' + $name) }
  # ... plot frames ...
}
```

Re-opening a staged copy after a `CloseDocument($false)` is free *only* because the script never saves the DWG - the trick depends on it.

`SelectByWindow` / `GetSelectedObjectCount(0)` read a **non-active** document, so inventory (extents + every text's `Contents`) can be dumped from all DWGs up front and the plan re-derived offline without COM: 3,145 entities in ~5 s, one round trip per document. Save and restore the print state around a batch - `Printer`, `PaperSize`, `Orientation`, `ScaleToFit`, `PrintOnCenter`, `ViewDisplayStyle`, `StyleTable`, `UseAssignedPrintStyle`, `GetPrintMargins`, `GetPrintRange` - the settings are application-wide and survive document switches.
## Introspect instead of guessing

`Get-Member` on a `__ComObject` returns the real signatures, which beats the CHM docs whenever they disagree:

```powershell
foreach ($m in ($sk | Get-Member)) { $d = [string]$m.Definition; if ($d -match 'InsertLine|InsertPolyline') { Write-Output $d } }
```

Two PowerShell gotchas that cost time:

- Cast `[string]$m.Definition` before matching. Concatenating `$m.MemberType` into a string throws `Cannot convert value "::" to type PSMemberTypes`.
- **Filter properties on `$m.MemberType -eq 'Property'`, not on `(`.** A COM property definition contains parentheses - `string Handle () {get}`, `double Radius () {get} {set}` - so an `(` filter silently drops every property and the loop prints nothing.
- **Never anchor a name filter while discovering an API.** Filtering on `^(Set|Get)(ColumnWidth|RowHeight|TextHeight|Text)$` reported no `SetColumnWidthAt`, and "per-column widths are unreachable over COM" was written down as fact. It is reachable: `SetColumnWidthAt(int, double)` is right there; the `$` anchor dropped it. Filter on a bare substring (`Column|Row|Cell`) or dump the whole list. **Absence from a filtered list is unknown, not absent.**
- **Bool methods like `IsActive` and `IsDirty` surface as `ParameterizedProperty`, not `Property`.** `$s.IsActive` yields the definition string `"bool IsActive ()"`, which is **always truthy**, so `if ($s.IsActive)` is true for every sheet and "both Model and Layout1 are active" gets reported. Call it: `$s.IsActive()` -> `True`/`False`. Same for `IDocument.IsDirty`.
- **`IModel` is not a viewport owner.** `GetActiveViewport` and `GetBoundingBox` both raise `MethodNotFound` on it. Viewports come from `ISheet.GetActiveViewport()` / `ISheet.GetViewports()`; the sheet-level props are `Width`, `Height`, `ViewHeight`, `StandardScale`, `CustomScale`, `DisplayLocked`, `IsOn`, `ShadePrintStyle`, and `Center` reads back empty - use `GetCenter()` / `GetViewCenter()`.

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
