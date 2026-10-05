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

1. The document was opened **through the API** (`OpenDocument2`). A UI-opened document reached via `GetActiveDocument`, or an unsaved `NONAME_0.dwg`, exports `false`.
2. Both the source document and the output path are inside `C:\ProgramData\Dassault Systemes\DraftSight\`.

With both satisfied: `{"Success":true}`, 871x634 RGB PNG, clean line art.

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
