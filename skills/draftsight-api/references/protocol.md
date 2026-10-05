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

## The three ports, and who owns them

From `C:\ProgramData\Dassault Systemes\DraftSight\addinConfigs\dsJServerAddin.xml`:

| Port | Element | Owner |
|---|---|---|
| 7775 | `dsJServerAddin` | DraftSight itself (the `jsServer` addin) |
| 7776 | `dsHttpApiService` | the broker, a Windows service |
| 7800 | `dsJServerAuth` | DraftSight (auth addin) |

The broker is the service **DraftSight API Service** - `StartType Automatic`, `LocalSystem`, registered `WIN32_OWN_PROCESS (interactive)`. Starting it from SCM logs `7030`: marked as an interactive service, but the system is configured not to allow interactive services.

**DraftSight auto-starts that service only when it is itself elevated.** A normally-launched DraftSight leaves it stopped and opens no ports at all. Do not conclude the API is dead from a stopped service - check whether the app was elevated.

## Broker failure signature

Observed 2026-10-05 and reproduced on **SP4 (26.4.0.43)** and **SP3 (26.3.0.56)**, on a `D:` install and on a clean `C:` install. The broker is stable while idle and dies on the first JS-RPC request, every time, at the same instruction:

    faulting app     dsHttpApiService.exe 26.4.0.43  /  26.3.0.56
    faulting module  Qt5Core.dll 5.15.11.5238  /  5.15.11.5237
    exception        0xc0000005 (access violation)
    fault offset     0x0000000000001726   <- identical in both builds
    SCM 7034 "terminated unexpectedly"  x6 in one afternoon

The offset resolves inside Qt5Core's export table:

    export 0x1720  ??0QString@@QEAA@AEBV0@@Z              QString::QString(const QString&)
    export 0x1740  QVector<QPoint>::QVector(QArrayDataPointerRef<int>)
    fault  0x1726  6 bytes into the QString copy constructor

The broker copies a `QString` out of a null object.

The split that localizes it, on a freshly started broker:

    GET  /APISDK/djLibrary/djConnect.js   -> 200, 5187 bytes    broker ALIVE
    POST JS-RPC getApplication            -> ECONNRESET         broker DEAD

HTTP server, socket layer, Qt event loop, and static file serving are healthy; only the JS-RPC handler faults - and it faults even though the broker holds **established** connections to `7775` (jsServer) and `7800` (auth). The transport to DraftSight is up; the handler still dereferences null.

Ruled out, each by direct test: install drive, reboot, service vs `-e` regular-application mode, app elevation, start order, proxy settings, `linkedDirectory` path, version mismatch (all four binaries match), DLL integrity (Authenticode valid, signed by Dassault), ABI completeness (196 Qt5Core + 42 Qt5Network imports, 0 missing), and request format (the identical request returned real geometry for 3 h 07 m earlier the same day).

Recovery attempts that **failed**: reboot with a clean `Automatic` start, `msiexec /fa` repair, full uninstall plus clean reinstall on `C:`, downgrade SP4 -> SP3. Do not chase this from the client side - **use COM** (`references/com-api.md`).

Start order does change one thing: whether `7775` opens at all - the addin opens `7800` but skips `7775` when the service was already running before DraftSight launched.

`dsHttpApiService.exe` is a QtService binary: `-i | -u | -e | -t | -c | -v | -h`. `-e` runs it as a regular application, which is how to debug it without SCM noise.

The same XML hardcodes `linkedDirectory path="C:\Program Files\Dassault Systemes\DraftSight\APISDK"`, which does not exist on a D: drive install. Repoint it at the real install root.

## Running djLibrary as real JavaScript

`djLibrary` is a **client-side** library: `djConnect.js` marshals each call to JSON and POSTs it over `XMLHttpRequest`/`ActiveXObject`. It is not a server-side script API. Two hosts fail outright:

- `cscript` / WSH JScript - ES3, no `JSON`, and the library calls `JSON.stringify` / `JSON.parse` unconditionally.
- Naive concat-load of the whole directory - `dsTemplate.js` is a broken template stub (`djObjectExtendCollection.ds[Replace with class] = ...`) and kills the parse. Exclude it by name; the filename gives no hint.

Working pattern under Node: load every `*.js` except `dsTemplate.js`, then replace the transport and keep the library verbatim:

    djSendCommand = async function (command) {
      const res = await fetch('http://127.0.0.1:7776', {
        method: 'POST', headers: { 'Content-Type': 'text/json;charset=UTF-8' }, body: command });
      return djProcessReturn(await res.text());
    };

Every wrapper then returns a promise, so reads become `await e.get_Handle()` and independent reads go out together under `Promise.all`. This removes the manual `{id, macroId, type}` echoing entirely - `djProcessCommand` supplies the owner - and it fails loudly instead of returning blank fields the way a `curl | sed` pipeline does.
