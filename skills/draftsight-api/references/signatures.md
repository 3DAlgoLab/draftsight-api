# Verified signatures

All from `<install root>\APISDK\djLibrary\*.js`, confirmed by live calls. The install root is **not** always on `C:` - this machine has it at `D:\Program Files\Dassault Systemes\DraftSight\`, while `C:\Program Files\Dassault Systemes\DraftSight\` survives as a `Fonts`-only stub. Locate it by probing for `APISDK\djLibrary`, never by assuming a drive.

## Handshake and session

```
jsScriptManager.getApplication()                       -> dsApplication
dsApplication.GetVersion()                             -> "26.4.0.5067"   (liveness probe)
dsApplication.GetActiveDocument()                      -> dsDocument
dsApplication.AbortRunningCommand()                    -> null
dsApplication.OpenDocument2(name, option, encoding)    -> dsDocument | null
dsApplication.CloseDocument(pathName, saveChanges)     -> null
dsDocument.GetPathName()                               -> "C:\\..."
dsDocument.IsReadOnly()                                -> {"ReadOnly":false}
dsDocument.GetModel()                                  -> dsModel
dsModel.GetSketchManager()                             -> dsSketchManager
dsDocument.GetDocumentExporter()                       -> dsDocumentExporter
dsModel.Zoom(range, lowerLeft, upperRight)             -> null
```

## Geometry creation (dsSketchManager)

```
InsertLine(StartX, StartY, StartZ, EndX, EndY, EndZ)
InsertCircle(CenterX, CenterY, CenterZ, Radius)
InsertArc(CenterX, CenterY, CenterZ, Radius, StartAngle, EndAngle)   # radians
InsertPolyline2D(CoordinateDblArray, Closed)          # flat array [x1,y1,x2,y2,...]
InsertSpline(CoordinateDblArray, Closed, sTx,sTy,sTz, eTx,eTy,eTz)
InsertBlock(BlockName, InsertX, InsertY, InsertZ, Scale, Rotation)
```

Also available: `InsertCircleBy3Points`, `InsertArcByCenter2Points`, `InsertEllipseArcRotation`, `InsertPolyline3D`, `InsertPoint`, `InsertRay`, `InsertInfiniteLine`, `InsertHatchByBoundary`, `InsertHatchByEntities(EntitiesArray, PatternName, PatternScale, PatternAngle)`.

Annotation: `InsertAlignedDimension`, `InsertRotatedDimension`, `InsertAngularDimension3Point`, `InsertDiameterDimensionCircle`, `InsertRadialDimensionCircle`, `InsertOrdinateDimension`, `InsertTolerance`, `InsertLeader`. Text and tables get their own sections below - their signatures are the ones most often guessed wrong.

Edit: `MoveEntities`, `CopyEntities`, `RotateEntities`, `MirrorEntities`, `ScaleEntities`, `FilletEntities`, `ChamferEntities`, `TrimEntities`, `ExtendEntities`, `ExplodeEntities`, `AlignEntities1Point`.

## Read-back and safety

```
GetEntities(Filter, LayerNamesStrArray)   -> {"EntitiesArray":[...],"EntityTypeLongArray":[...]}
GetBoundingBox()                          -> {"X1":..,"X2":..,"Y1":..,"Y2":..,"Z1":..,"Z2":..}
SetObjectErased(Obj, Value)
IsObjectErased(Obj)
SetObjectLayer(Obj, Layer)
StartUndoRecord()
StopUndoRecord()
```

`GetEntities(0, [])` returns every entity in model space. Entity handles are `{id, macroId, type}` and must be echoed back whole.

**`GetEntities` is on `dsSketchManager`, not `dsModel`.** Called on the model object it returns `null`, which is indistinguishable from a dead jsServer link. On the sketch manager the same call returns `{"EntitiesArray":[],"EntityTypeLongArray":[]}` for an empty drawing - an empty array means a live connection, `null` means the wrong owner.

## Text

There is **no `InsertText`** on `dsSketchManager` - zero hits for `dsObj.InsertText` across the entire `djLibrary`. Use:

```
dsSketchManager.InsertSimpleNote(StartX, StartY, StartZ, Height, Angle, Value)
dsSketchManager.InsertNote(X1, Y1, Z1, X2, Y2, Z2, StrArray)
dsSketchManager.InsertNoteWithParameters(X1, Y1, Z1, X2, Y2, Z2, StrArray,
    Angle, Height, Justify, LineSpacingStyle, LineSpaceDistance, TextStyle, Width)
dsSketchManager.InsertRichLine(CoordinateDblArray, Justification, Scale, StyleName, Closed)
```

Text that belongs to a table cell goes through `dsTable.SetText`, never as a separate note entity.

## Tables

```
dsSketchManager.InsertTable(Left, Top, Rows, Columns, RowHeight, ColumnWidth,
    FirstRowStyle, SecondRowStyle, OtherRowStyle)          -> dsTable
```

`Left`/`Top` are the **upper-left corner**; the table grows down and to the right, so `Y` goes negative. The three style arguments are `dsTableCellType_e`: `dsTableCellType_Title` 1, `dsTableCellType_Header` 2, `dsTableCellType_Data` 3.

**The bundled example is wrong.** `docs/draftsightapi/Create_Table_Example_JS.htm` shows `InsertTable(X, Y, X0, Y0, rowHeight, colWidth, ...)` - six arguments, with coordinates where the row and column counts belong. Trust the `djLibrary` signature above: 6 rows x 5 columns drew and read back correctly with it.

Cell text; rows and columns are 0-based:

```
dsTable.SetText(Row, Column, CellText)
dsTable.GetText(Row, Column)            -> formatted text
dsTable.GetSimplifiedText(Row, Column)  -> raw text; use this to verify
dsTable.GetCellType(Row, Column)        -> "dsTableCellType_Header" / _Data
```

Sizing. Getter and setter names are **asymmetric** - `GetColumnWidthAt` does not exist and returns `null`:

```
dsTable.SetColumnWidthAt(Column, Width)      dsTable.GetColumnWidth(Column)
dsTable.SetRowHeightAt(Row, Height)          dsTable.GetRowHeight(Row)
dsTable.SetColumnWidth(Width)                # every column
dsTable.SetRowHeight(Height)                 # every row
dsTable.SetTextHeight(CellType, Height)      dsTable.GetCellTextHeight(Row, Column)
```

Rows grow to fit text height plus cell margins; they never clip. Columns behave the other way: cells **wrap** rather than clip, so a column too narrow for its text silently grows the row instead of truncating. At text height 3.0 the default font needs ~2.5 mm per ASCII character plus ~10 mm of margin (CJK ~1.7x). The `*At` setters exist over COM as well; only `GetColumnWidthAt` is absent on both transports. Requesting `RowHeight = 7` with text height 3.0 read back as ~8.68, and the header row as ~10.49.

Also: `SetCellType`, `SetCellAlignment(Row, Column, Alignment)`, `SetCellBackgroundColor`, `SetCellTextColor`, `MergeCells(MinRow, MaxRow, MinColumn, MaxColumn)`, `UnmergeCells`, `InsertRow(Row, Height)`, `InsertColumn(Column, Width)`, `DeleteRow`, `DeleteColumn`, `GetPosition`, `SetPosition(X, Y, Z)`, `GetBoundingBox`, `SaveAsCSVFile(FileName)`.

A table is **one entity** in `GetEntities`, not a grid of lines.

## Export

```
dsDocumentExporter.ExportToPng(PathName)   -> {"Success":bool}
dsDocumentExporter.ExportToSvg(PathName)
dsDocumentExporter.ExportToJpg / ExportToBmp / ExportToTiff / ExportToStl / ExportToSld
dsDocumentExporter.ExportToPdf(PathName, SheetsStrArray, PageLength, PageWidth)
dsDocumentExporter.ExportToPdf2(PathName, ExportSettings)
dsDocumentExporter.CreateExportSettings()
```

Exports **the current view**. `ExportToEmf` took the jsServer down - do not call.

## Save

```
dsDocument.Save()                                        -> "dsDocumentSave_Succeeded"
dsDocument.SaveAs2(Name, Options, Overwrite)             -> {"Errors":"dsDocumentSave_Succeeded"}
dsDocument.SaveAs(Name, Options)                         # OBSOLETE - do not use
```

## Enums (pass the symbolic name as a string)

`dsDocumentSaveAsOption_e` - `dsDocumentSaveAs_R2018_DWG` (28), `dsDocumentSaveAs_R2013_DWG` (24), `dsDocumentSaveAs_R2010_DWG` (1), `dsDocumentSaveAs_Default` (23), plus DXF/DWT/DWS variants.

`dsZoomRange_e` - `dsZoomRange_Fit` (0), `dsZoomRange_Bounds` (1), `dsZoomRange_Window` (2).

`dsDocumentSaveError_e` - `Succeeded` 0x0, `GenericError` 0x1, `ReadOnlyError` 0x2, `FileLockError` 0x4, `InvalidPathName` 0x8, `EditComponentIsActive` 0x10.

Full enum listings: `APISDK/headers/cpp/dsConstants.h`, or grep `docs/api/`.

## DWG file signatures

`AC1032` = AutoCAD 2018 format. Check with `head -c 8 file.dwg`.
