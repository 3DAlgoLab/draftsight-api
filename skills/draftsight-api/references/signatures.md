# Verified signatures

All from `C:\Program Files\Dassault Systemes\DraftSight\APISDK\djLibrary\*.js`, confirmed by live calls.

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

Annotation: `InsertAlignedDimension`, `InsertRotatedDimension`, `InsertAngularDimension3Point`, `InsertDiameterDimensionCircle`, `InsertRadialDimensionCircle`, `InsertOrdinateDimension`, `InsertTolerance`, `InsertLeader`, `InsertNote`, `InsertTable`.

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
