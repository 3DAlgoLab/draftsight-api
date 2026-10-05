# Failure catalogue

Every entry below was reproduced on this machine against DraftSight 26.4.0.5067.

## `jsServer connection Failed`

Returned as `{"name":"dsJServerError","message":"jsServer connection Failed"}`.

Observed causes, in order of likelihood:

1. **Owner object was incomplete.** Echoing only `{id,type}` and dropping `macroId` triggers it every time. This is the single most common cause.
2. **Stale epoch.** Ids from a previous DraftSight session after a restart.
3. **A toxic call took the jsServer down.** `ExportToEmf` did this.

## Crashes observed

| Session | Trigger sequence | Evidence |
|---|---|---|
| 1 | read-only chain that included `GetDocuments` | DraftSight PID 20672 died; could not be proven or ruled out |
| 2 | `ExportToPng/Svg/Bmp/Jpg` then `ExportToEmf` | PID 20672 -> 15040 at 10:15:28, broker 6428 -> 22284, `GetVersion` went `null` |

Read-only probes (`GetVersion`, `GetActiveDocument`, `GetPathName`, `GetModel`, `GetSketchManager`) ran many times without incident. Treat `GetDocuments` and `ExportToEmf` as unsafe.

## Why `ExportTo*` returned `{"Success":false}`

Not a broken API. Two conditions must both hold:

1. The **output path** is outside `C:\ProgramData\Dassault Systemes\DraftSight\`.
2. The document is an unsaved `NONAME_0.dwg`.

An earlier revision of this file claimed the document itself had to be opened through `OpenDocument2`, and that a UI-opened document exports `false`. **That claim is wrong.** A document opened in the UI at `D:\my-vault\41-dpi-kl61\test\draw-table.dwg`, reached through `GetActiveDocument`, exported `{"Success":true}` to a path inside the root. The sandbox checks the path argument, not where the document lives.

## The path sandbox - how it was proven

| Test | Result |
|---|---|
| shipped `B-44563.DWG` opened in place | opens |
| same file copied to the vault | `null` |
| agent-drawn file copied to `%TEMP%` | `null` |
| any file under `C:\ProgramData\Dassault Systemes\DraftSight\**` | opens |
| `C:\Users\three\Documents`, `C:\temp`, `C:\Users\three` | `null` |

The failure follows the **path**, not the file. Stale `test.dwl` / `test.dwl2` locks were removed and retried - still `null`, so locks were never the cause.

`SaveAs2` shows the same boundary: `dsDocumentSave_Succeeded` inside the root, `dsDocumentSave_GenericError` writing to the vault.

## Epochs churn inside a session

`macroId` is not stable for the length of a working session. Observed `1 -> 3 -> 7 -> 8` across a single table-drawing session with no manual restart of DraftSight. Any script that caches `id`/`macroId` across separate runs will eventually hit `jsServer connection Failed`.

Re-walk `getApplication -> GetActiveDocument -> GetModel -> GetSketchManager` at the top of **every** script run, not only after a restart. Treat the epoch as per-invocation, not per-session.

## The sandbox binds path arguments, not documents

`OpenDocument2`, `SaveAs2`, and `ExportTo*` validate the path they are handed. They do not validate where an already-open document lives.

| Call | Path argument | Result |
|---|---|---|
| `OpenDocument2` | vault | `null` |
| `SaveAs2` | vault | `dsDocumentSave_GenericError` |
| `SaveAs2` | inside the root | `dsDocumentSave_Succeeded` |
| `ExportToPng` | inside the root, document lives in the vault | `{"Success":true}` |
| `Save()` - no path | document already at `D:\my-vault\...` | `"dsDocumentSave_Succeeded"` |

Drawing into a DWG the user already has open, and saving it in place, needs **no staging at all**. Stage only to open a file by path, or to save it to a new path.

## Staging workflow

```
vault file -> cp -> C:\ProgramData\Dassault Systemes\DraftSight\stage\
             OpenDocument2 -> draw -> Zoom -> ExportToPng / SaveAs2
           <- cp <- result
```

Delete the staging directory afterwards and `CloseDocument` every document opened through the API - leaving them open clutters the user's session.

## RunCommand is not evidence

`RunCommand('ZoomExtents', false)` returned `"dsRunCommand_Succeeded"` while the DraftSight command window printed `Unrecognized command ZoomExtents`. The correct programmatic zoom is `dsModel.Zoom(Range, ll, ur)` with `dsZoomRange_e` `Fit=0`, `Bounds=1`, `Window=2`.

Resolved from `docs/DraftSight/cmdref/command_reference_chart.htm`: DraftSight has **no `ZoomExtents` command**. The real names are `ZoomFit`, `Zoom`, `ZoomIn`, `ZoomOut`, `ZoomBack`, `ZoomDynamic`, `ZoomFactor`. `ZoomExtents` is an AutoCAD-ism. Check `cmdref/` before passing any command string to `RunCommand`.

## Screen capture facts

| Method | Result |
|---|---|
| `PrintWindow` with `PW_RENDERFULLCONTENT` (flag 2) | returns `False` - DraftSight is a Qt5 app (`Qt51511QWindowIcon` on every child window) and the GL surface does not blit |
| `CopyFromScreen` over `GetWindowRect(mainWindowHandle)` | works; includes ribbon, tabs, palettes |
| `SetProcessDPIAware()` first | needed for correct pixel coordinates |
