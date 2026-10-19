#requires -Version 5.1
<#
.SYNOPSIS
  Plot every sheet frame in model space to its own PDF, over COM.
.DESCRIPTION
  Sheet frames are found geometrically, not by name: real DWGs rarely carry a TITLE / BORDER /
  SHEET layer or block, and ISelectionManager has no SelectByLayer. The signature that holds up on
  production drawings is a closed polyline (dsPolyLineType = 27) whose bounding box has an ISO
  A-series aspect ratio (~1.414). Borders are drawn as nested triples (outer / middle / inner), so
  frames with coincident top-left corners are collapsed to one.

  Each frame is plotted with SetPrintRange(5, ...) - dsPrintRange_SpecifyWindow - to the built-in
  'PDF' file plotter, so no printer has to be installed. Print settings are saved and restored unless
  -LeaveAsDefault is given.

  Monochrome needs THREE settings: StyleTable, UseAssignedPrintStyle, and ViewDisplayStyle = 3. The
  default ViewDisplayStyle = 0 plots "as displayed", shading the sheet into DeviceRGB raster tiles, so
  the plot style table has nothing to act on and colour survives - see -ViewStyle.

  Sheets whose border is drawn with LINE entities instead of a closed polyline are invisible to the
  geometric matcher: step 2b reports every entity outside all frames, and -AddLineFrames promotes an
  ISO-aspect unframed mass to a sheet. Only the active document can be plotted - open one DWG per run.

  Verified on DraftSight 26.4.0.5067: a 5,020-entity model space holding 13 sheet frames produced 13
  single-page PDFs, A4 landscape, zero margins, monochrome.
.EXAMPLE
  .\com-plot-frames.ps1 -OutDir C:\out
.EXAMPLE
  .\com-plot-frames.ps1 -Paper 'ISO_A3_(297.00_x_420.00_MM)' -Color
.EXAMPLE
  .\com-plot-frames.ps1 -MinFrameWidth 1000 -MaxFrameWidth 2500   # only the large frames
#>
param(
  [string]$OutDir = (Join-Path (Get-Location) 'pdf-out'),
  [string]$Paper = 'ISO_A4_(210.00_x_297.00_MM)',   # exact name from $pm.AvailablePaperSizes()
  [double]$Margins = 0.0,
  [string]$StyleTable = 'monochrome.ctb',
  [switch]$Color,                                    # skip the plot style table
  [int]$ViewStyle = 3,                               # 3 = wireframe + hidden lines; 0 = as displayed -> shaded RASTER
  [switch]$AddLineFrames,                            # promote an ISO-aspect unframed entity mass to a sheet
  [int]$Orientation = 2,                             # 1 = Portrait, 2 = Landscape
  [string]$Sheet = 'Model',
  [double]$MinFrameWidth = 400,
  [double]$MaxFrameWidth = 0,                        # 0 = no upper bound
  [string]$Prefix = 'sheet',
  [string]$ExtentsCsv = '',                          # reuse a previous dump instead of re-scanning
  [switch]$LeaveAsDefault
)
$ErrorActionPreference = 'Continue'
function Msg($e) { return [string]$e.Exception.Message }

$app = [Runtime.InteropServices.Marshal]::GetActiveObject('DraftSight.Application')
$doc = $app.GetActiveDocument()
$pm  = $app.GetPrintManager()
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

# ---- 1. entity extents, one row per entity: handle;type;layer;x1;y1;x2;y2 ----
if ($ExtentsCsv -and (Test-Path $ExtentsCsv)) {
  "extents: reusing $ExtentsCsv"
} else {
  $ExtentsCsv = Join-Path $env:TEMP 'ds-extents.csv'
  $mu = $app.GetMathUtility(); $selm = $doc.GetSelectionManager()
  $doc.GetModel().Activate()
  $selm.ClearSelections(0)
  [void]$selm.SelectByWindow($mu.CreatePoint(-1e7, -1e7, 0), $mu.CreatePoint(1e7, 1e7, 0), $true)
  $n = $selm.GetSelectedObjectCount(0)
  $sb = New-Object System.Text.StringBuilder
  for ($i = 0; $i -lt $n; $i++) {
    $e = $selm.GetSelectedObject(0, $i, 0); if (-not $e) { continue }
    $t = $app.GetObjectType($e)
    $x1 = 0.0; $y1 = 0.0; $z1 = 0.0; $x2 = 0.0; $y2 = 0.0; $z2 = 0.0
    try { $e.GetBoundingBox([ref]$x1, [ref]$y1, [ref]$z1, [ref]$x2, [ref]$y2, [ref]$z2) } catch {}
    [void]$sb.AppendLine($e.Handle + ';' + $t + ';' + $e.Layer + ';' + $x1 + ';' + $y1 + ';' + $x2 + ';' + $y2)
  }
  # SelectByWindow leaves hits in sets 0, 2 and 3 - clear all of them, the drawing is not ours to dirty
  0..3 | ForEach-Object { $selm.ClearSelections($_) }
  [IO.File]::WriteAllText($ExtentsCsv, $sb.ToString(), [Text.Encoding]::UTF8)
  "extents: $n entities -> $ExtentsCsv"
}
$rows = Get-Content $ExtentsCsv -Encoding UTF8 | Where-Object { $_ }

# ---- 2. frames: closed polylines with an ISO A-series aspect ratio ----
$ents = @(); $cand = @()
foreach ($l in $rows) {
  $p = $l.Split(';')
  if ($p.Count -lt 7) { continue }
  $x1 = [double]$p[3]; $y1 = [double]$p[4]; $x2 = [double]$p[5]; $y2 = [double]$p[6]
  if ([Math]::Abs($x1) -gt 1e18) { continue }        # degenerate bbox = no geometry
  $xa = [Math]::Min($x1, $x2); $xb = [Math]::Max($x1, $x2)
  $ya = [Math]::Min($y1, $y2); $yb = [Math]::Max($y1, $y2)
  $ents += [pscustomobject]@{x1 = $xa; y1 = $ya; x2 = $xb; y2 = $yb}
  if ([int]$p[1] -ne 27) { continue }
  $w = $xb - $xa; $h = $yb - $ya
  if ($w -lt $MinFrameWidth) { continue }
  if ($MaxFrameWidth -gt 0 -and $w -gt $MaxFrameWidth) { continue }
  if ($w / $h -lt 1.30 -or $w / $h -gt 1.50) { continue }
  $cand += [pscustomobject]@{handle = $p[0]; x1 = $xa; y1 = $ya; x2 = $xb; y2 = $yb; w = $w; h = $h; area = $w * $h}
}
$frames = @()
foreach ($f in ($cand | Sort-Object area -Descending)) {
  $dup = $false
  foreach ($k in $frames) { if ([Math]::Abs($k.x1 - $f.x1) -lt 30 -and [Math]::Abs($k.y1 - $f.y1) -lt 30) { $dup = $true; break } }
  if (-not $dup) { $frames += $f }
}
"frames: $($cand.Count) candidate polylines -> $($frames.Count) distinct sheets"
if ($frames.Count -eq 0) { 'nothing to plot - widen -MinFrameWidth or check the ratio band'; exit 1 }

# ---- 2b. completeness gate: entities outside every frame are a sheet you are about to lose ----
$outside = @()
foreach ($e in $ents) {
  $cx = ($e.x1 + $e.x2) / 2; $cy = ($e.y1 + $e.y2) / 2
  $ins = $false
  foreach ($f in $frames) { if ($cx -ge $f.x1 -and $cx -le $f.x2 -and $cy -ge $f.y1 -and $cy -le $f.y2) { $ins = $true; break } }
  if (-not $ins) { $outside += $e }
}
if ($outside.Count -gt 0) {
  $ox1 = ($outside | Measure-Object -Property x1 -Minimum).Minimum
  $oy1 = ($outside | Measure-Object -Property y1 -Minimum).Minimum
  $ox2 = ($outside | Measure-Object -Property x2 -Maximum).Maximum
  $oy2 = ($outside | Measure-Object -Property y2 -Maximum).Maximum
  $ow = $ox2 - $ox1; $oh = $oy2 - $oy1
  $asp = [Math]::Max($ow, $oh) / [Math]::Max(1e-9, [Math]::Min($ow, $oh))
  ('gate: {0} of {1} entities outside every frame, bbox ({2}, {3}) - ({4}, {5}), aspect {6}' -f $outside.Count, $ents.Count, [Math]::Round($ox1, 0), [Math]::Round($oy1, 0), [Math]::Round($ox2, 0), [Math]::Round($oy2, 0), [Math]::Round($asp, 3))
  if ($AddLineFrames -and $asp -gt 1.30 -and $asp -lt 1.55) {
    $frames += [pscustomobject]@{ handle = 'lines'; x1 = $ox1; y1 = $oy1; x2 = $ox2; y2 = $oy2; w = $ow; h = $oh; area = $ow * $oh }
    'gate: outside mass has an ISO aspect ratio, added as a sheet (border drawn with LINE entities, no closed polyline)'
  } else {
    'gate: CHECK THIS - an unframed title block or BOM cluster is a sheet whose border is not a closed polyline'
  }
}

# ---- 3. save print state ----
$sPrinter = $pm.Printer; $sPaper = $pm.PaperSize; $sFit = $pm.ScaleToFit
$sOrient = $pm.Orientation; $sCenter = $pm.PrintOnCenter
$sStyle = $pm.StyleTable; $sAssigned = $pm.UseAssignedPrintStyle; $sView = $pm.ViewDisplayStyle
$st = 0.0; $sb2 = 0.0; $sl = 0.0; $sr2 = 0.0
$pm.GetPrintMargins([ref]$st, [ref]$sb2, [ref]$sl, [ref]$sr2)
$pr = 0; $pnv = ''; $pwin = $false; $px1 = 0.0; $py1 = 0.0; $px2 = 0.0; $py2 = 0.0
$pm.GetPrintRange([ref]$pr, [ref]$pnv, [ref]$pwin, [ref]$px1, [ref]$py1, [ref]$px2, [ref]$py2)
"saved: printer=$sPrinter paper=$sPaper margins=$st/$sb2/$sl/$sr2 style=[$sStyle] assigned=$sAssigned"

# ---- 4. plot ----
$pm.Printer = 'PDF'
$pm.PaperSize = $Paper
$pm.Orientation = $Orientation
$pm.ScaleToFit = $true
$pm.PrintOnCenter = $false
try { $pm.SetPrintMargins($Margins, $Margins, $Margins, $Margins) } catch { "SetPrintMargins err: $(Msg $_)" }
if (-not $Color) {
  $pm.StyleTable = $StyleTable
  $pm.UseAssignedPrintStyle = $true      # the table is ignored unless this is $true
}
$pm.ViewDisplayStyle = $ViewStyle        # 0 = as displayed -> shaded raster, the CTB cannot touch it
try { $pm.SetSheets([string[]]@($Sheet)) } catch { "SetSheets err: $(Msg $_)" }
$t = 0.0; $bo = 0.0; $le = 0.0; $ri = 0.0
$pm.GetPrintMargins([ref]$t, [ref]$bo, [ref]$le, [ref]$ri)
"plotting: paper=$($pm.PaperSize) margins=$t/$bo/$le/$ri style=[$($pm.StyleTable)] assigned=$($pm.UseAssignedPrintStyle) fit=$($pm.ScaleToFit) orient=$($pm.Orientation) view=$($pm.ViewDisplayStyle)"

$i = 0
foreach ($f in $frames) {
  $i++
  try { $pm.SetPrintRange(5, '', $true, $f.x1, $f.y1, $f.x2, $f.y2) } catch { "SetPrintRange err: $(Msg $_)" }
  $target = Join-Path $OutDir ('{0}-{1:d2}_{2}x{3}.pdf' -f $Prefix, $i, [Math]::Round($f.w, 0), [Math]::Round($f.h, 0))
  if (Test-Path $target) { Remove-Item $target -Force }
  $cnt = 0
  foreach ($e in $ents) { $cx = ($e.x1 + $e.x2) / 2; $cy = ($e.y1 + $e.y2) / 2; if ($cx -ge $f.x1 -and $cx -le $f.x2 -and $cy -ge $f.y1 -and $cy -le $f.y2) { $cnt++ } }
  try { $pm.PrintOut(1, $target); $res = 'ok' } catch { $res = 'THREW: ' + (Msg $_) }
  $sz = 0; $mb = '-'
  if (Test-Path $target) {
    $sz = (Get-Item $target).Length
    $m = (Select-String -Path $target -Pattern 'MediaBox \[[^\]]*\]' -AllMatches).Matches
    if ($m) { $mb = $m[0].Value }
  }
  "S{0:d2} frame={1}x{2} ents={3} {4} bytes={5} {6}" -f $i, [Math]::Round($f.w, 0), [Math]::Round($f.h, 0), $cnt, $res, $sz, $mb
}

# ---- 5. restore ----
if ($LeaveAsDefault) {
  "left as default: printer=$($pm.Printer) paper=$($pm.PaperSize) style=[$($pm.StyleTable)]"
} else {
  $pm.Printer = $sPrinter; $pm.PaperSize = $sPaper; $pm.ScaleToFit = $sFit
  $pm.Orientation = $sOrient; $pm.PrintOnCenter = $sCenter
  $pm.StyleTable = $sStyle; $pm.UseAssignedPrintStyle = $sAssigned; $pm.ViewDisplayStyle = $sView
  try { $pm.SetPrintMargins($st, $sb2, $sl, $sr2) } catch {}
  try { $pm.SetPrintRange($pr, $pnv, $pwin, $px1, $py1, $px2, $py2) } catch {}
  "restored: printer=$($pm.Printer) paper=$($pm.PaperSize) style=[$($pm.StyleTable)] view=$($pm.ViewDisplayStyle)"
}
