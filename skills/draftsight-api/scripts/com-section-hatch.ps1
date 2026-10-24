param([string]$OutDir = (Get-Location).Path)
# Hatched, dimensioned section drawing over COM - layers, point-loop hatch, style-level annotation,
# save, and the reopen check that proves the file on disk.
#
# Verified 2026-10-24 against DraftSight 26.4.0.5067 (Windows PowerShell 5.1): produced a 283 mm
# section whose four dimensions read back as 35.000 / 248.000 / 283.000 / 23.000, hatch as
# ANSI31 @ 1.5 on both walls, and a DWG that reopened carrying all five layers.
#
# WIPES THE ACTIVE DOCUMENT - that is what makes it repeatable. Run it against a scratch document,
# never production work:
#   DS_WIPE_OK=1 powershell -NoProfile -ExecutionPolicy Bypass -File com-section-hatch.ps1 -OutDir C:\\temp
$ErrorActionPreference = 'Stop'
if ($env:DS_WIPE_OK -ne '1') {
  Write-Output 'refusing to wipe the active document - set DS_WIPE_OK=1 to confirm a scratch document'
  exit 1
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$app  = [Runtime.InteropServices.Marshal]::GetActiveObject('DraftSight.Application')
$doc  = $app.GetActiveDocument()
$sk   = $doc.GetModel().GetSketchManager()
$mu   = $app.GetMathUtility()
$selm = $doc.GetSelectionManager()
$doc.GetModel().Activate()
try { $app.AbortRunningCommand() } catch { }
try { $app.StartUndoRecord('section-hatch') } catch { try { $app.StartUndoRecord() } catch { } }

# ---- 0. wipe, so the script is repeatable
0..3 | ForEach-Object { $selm.ClearSelections($_) }
[void]$selm.SelectByWindow($mu.CreatePoint(-1e7,-1e7,0), $mu.CreatePoint(1e7,1e7,0), $true)
$junk = @()
for ($i=0; $i -lt $selm.GetSelectedObjectCount(0); $i++) { $e = $selm.GetSelectedObject(0,$i,0); if ($e) { $junk += $e } }
0..3 | ForEach-Object { $selm.ClearSelections($_) }
foreach ($e in $junk) { $sk.SetObjectErased($e, $true) }
'WIPED: ' + $junk.Count

# ---- 1. layers. CreateLayer(Name, out ILayer, out Result) needs a live IDispatch in slot 2;
#      [ref]$null raises NullReferenceException, Type.Missing raises DISP_E_TYPEMISMATCH.
$lm = $doc.GetLayerManager()
$proto = $lm.GetLayer('0')
function Ensure-Layer($name, $lw) {
  $lay = $lm.GetLayer($name)
  if (-not $lay) { $made = $proto; $res = 0; $lm.CreateLayer($name, $made, $res); $lay = $lm.GetLayer($name) }
  if ($lay) { $lay.LineWeight = $lw; $lay.Shown = $true; $lay.Frozen = $false; $lay.Locked = $false }
  if (-not $lay) { throw ('layer not created: ' + $name) }
  return $lay
}
$L_OUT = Ensure-Layer '1-OUTLINE' 35
$L_HAT = Ensure-Layer '2-HATCH'   18
$L_CEN = Ensure-Layer '3-CENTER'  18
$L_DIM = Ensure-Layer '4-DIM'     18
$L_TEX = Ensure-Layer '5-TEXT'    18
foreach ($l in $lm.GetLayers()) { 'LAYER: ' + $l.Name + ' lw=' + $l.LineWeight }

# ---- 2. geometry (mm): a stepped bore in a plain bar. Swap in real numbers - this is a shape template.
$ODr  = 42.5      # half of an UNDEFINED outside diameter - the sheet footnotes it as REF
$BR   = 11.5      # through-bore radius
$TR   = 8.75      # tapped-end radius
$Ytap = 35.0      # shoulder
$Ytop = 283.0     # far end
$PI2 = [math]::Pi / 2.0     # property, not a method - [math]::PI() throws

function Line($x1,$y1,$x2,$y2,$layer,$lw) {
  $e = $sk.InsertLine($x1,$y1,0, $x2,$y2,0)
  if (-not $e) { throw ('line failed: ' + $x1 + ',' + $y1 + ' -> ' + $x2 + ',' + $y2) }
  $sk.SetObjectLayer($e, $layer.Name)
  if ($lw) { $e.LineWeight = $lw }
  return $e
}

# ---- 3. outline, mirrored
$ents = @()
foreach ($s in @(1,-1)) {
  $ents += Line ($s*$ODr) 0      ($s*$ODr) $Ytop $L_OUT 35
  $ents += Line ($s*$BR)  $Ytap  ($s*$BR)  $Ytop $L_OUT 35
  $ents += Line ($s*$TR)  0      ($s*$TR)  $Ytap $L_OUT 35
  $ents += Line ($s*$BR)  $Ytop  ($s*$ODr) $Ytop $L_OUT 35
  $ents += Line ($s*$TR)  0      ($s*$ODr) 0     $L_OUT 35
  $ents += Line ($s*$TR)  $Ytap  ($s*$BR)  $Ytap $L_OUT 35
}
'OUTLINE: ' + $ents.Count

# ---- 4. hatch: boundary as POINTS. The by-entities overloads return null over COM.
function Hatch-Poly($pts, $counts) {
  $h = $sk.InsertHatchByBoundary($counts, $pts, 'ANSI31', 1.5, 0.0)
  if (-not $h) { throw 'hatch failed' }
  $sk.SetObjectLayer($h, $L_HAT.Name)
  return $h
}
$hatR = Hatch-Poly ([double[]]@($BR,$Ytop, $ODr,$Ytop, $ODr,0, $TR,0, $TR,$Ytap, $BR,$Ytap)) ([int[]]@(6))
$hatL = Hatch-Poly ([double[]]@((-$BR),$Ytop, (-$ODr),$Ytop, (-$ODr),0, (-$TR),0, (-$TR),$Ytap, (-$BR),$Ytap)) ([int[]]@(6))
'HATCH: ok'

# ---- 5. centre line as dash-dot segments (no CENTER linetype is loaded)
$y = -14.0; $n = 0
while ($y -lt ($Ytop + 17.0)) {
  $ents2 = Line 0 $y 0 ([math]::Min($y+14.0, $Ytop + 17.0)) $L_CEN 18; $n++
  $y += 17.5
  if ($y -ge ($Ytop + 17.0)) { break }
  $ents2 = Line 0 $y 0 ($y+1.4) $L_CEN 18; $n++
  $y += 4.4
}
'CENTER segments: ' + $n

# ---- 6. dimension style: fit scale FIRST, then height - both are style-level
$dm = $doc.GetDimensionStyleManager()
$styleName = 'ISO-25'
$ds = $dm.GetDimensionStyle($styleName)
$fo = $ds.GetDimensionStyleFitOptions(); $fo.SetDimensionScale(1, 1.0)   # 1 = dsDimensionScale_UseScaleFactor
$to = $ds.GetDimensionStyleTextOptions(); $to.Height = 12.0; $to.OffsetFromDimensionLines = 2.5
$ao = $ds.GetDimensionStyleArrowsOptions(); $ao.Size = 5.0
$lo = $ds.GetDimensionStyleLineOptions();   $lo.ExtensionLineOffset = 2.5; $lo.ExtensionLineDistancePastDimensionLines = 4.0
$sc = 0.0
$dm.GetDimensionStyle($styleName).GetDimensionStyleFitOptions().GetDimensionScale(1, [ref]$sc)
'DIMSTYLE: ' + $styleName + ' txt=' + $dm.GetDimensionStyle($styleName).GetDimensionStyleTextOptions().Height + ' scalefit=' + $sc

# InsertRotatedDimension's 4th string argument is a TEXT OVERRIDE, not a style name.
function Dim($x1,$y1,$x2,$y2,$dx,$dy,$rot,$text) {
  $d = $sk.InsertRotatedDimension([double[]]@($x1,$y1,0), [double[]]@($x2,$y2,0), [double[]]@($dx,$dy,0), $text, $rot)
  if (-not $d) { throw 'dim failed' }
  $gd = $d.GetGeneralDimension()
  $sk.SetObjectLayer($gd, $L_DIM.Name)
  return ('  dim measure=' + ('{0:F3}' -f $gd.Measurement) + ' override=[' + $gd.TextOverride + '] style=' + $gd.DimensionStyle)
}
'DIMENSIONS:'
Dim ($ODr) 0      ($ODr) $Ytap  ($ODr+28) ($Ytap/2)         $PI2 '35'
Dim ($ODr) $Ytap  ($ODr) $Ytop  ($ODr+28) (($Ytap+$Ytop)/2) $PI2 '248'
Dim ($ODr) 0      ($ODr) $Ytop  ($ODr+56) ($Ytop/2)         $PI2 '283'
Dim (-$BR) $Ytop  ($BR)  $Ytop  0         ($Ytop+28)        0.0 '%%c23'

# ---- 7. leader to the tapped end, then the section title
function Note($x,$y,$h,$s) {
  $t = $sk.InsertSimpleNote($x,$y,0, $h, 0.0, $s)
  if (-not $t) { throw ('note failed: ' + $s) }
  $sk.SetObjectLayer($t, $L_TEX.Name)
  return $t
}
$tx = $TR; $ty = 0.0; $mx = 26.0; $my = -38.0; $ex = 78.0
$ents3 = Line $tx $ty $mx $my $L_TEX 18
$ents3 = Line $mx $my $ex $my $L_TEX 18
$len = [math]::Sqrt(($mx-$tx)*($mx-$tx) + ($my-$ty)*($my-$ty))
$ux = ($mx-$tx)/$len; $uy = ($my-$ty)/$len; $px = -$uy; $py = $ux
$bx = $tx + $ux*7.0; $by = $ty + $uy*7.0
$ents3 = Line $tx $ty ($bx + $px*2.0) ($by + $py*2.0) $L_TEX 18
$ents3 = Line $tx $ty ($bx - $px*2.0) ($by - $py*2.0) $L_TEX 18
$t1 = Note ($ex+4) ($my-6) 12.0 'M20 TAP, DP35'
$tw = 0.72 * 18.0 * 11
$t2 = Note (-$tw/2) (-80) 18.0 'SECTION A-A'
$ents3 = Line (-$tw/2 - 6) (-85) ($tw/2 + 6) (-85) $L_TEX 18
$ents3 = Line (-$tw/2 - 6) (-89) ($tw/2 + 6) (-89) $L_TEX 35
$t3 = Note (-$tw/2 - 6) (-106) 8.0 'NOTE: OUTSIDE DIA NOT DIMENSIONED IN SOURCE SKETCH - DRAWN %%c85 (REF)'
'ANNOTATION: ok'
try { $app.StopUndoRecord() } catch { }

# ---- 8. export, save, and prove the file on disk
$png  = Join-Path $OutDir 'verify-section.png'
$app.Zoom(1, [double[]]@(-170,-140,0), [double[]]@(180,340,0))
$doc.GetDocumentExporter().ExportToPng($png, $true)
'PNG: ' + (Test-Path $png)
# close-up of the dimension stack - a whole-part export cannot show legibility
$png2 = Join-Path $OutDir 'verify-dims-zoom.png'
$app.Zoom(2, [double[]]@(35,0,0), [double[]]@(150,300,0))
$doc.GetDocumentExporter().ExportToPng($png2, $true)
'DIMZOOM: ' + (Test-Path $png2)
$app.Zoom(0, $null, $null)
$dwg = Join-Path $OutDir 'section-a-a.dwg'
$serr = 0
$doc.SaveAs($dwg, 28, [ref]$serr)          # 28 = R2018 DWG; 0 = saved
'SAVEAS: ' + $serr + ' exists=' + (Test-Path $dwg)
# reopen it and read the layers back - proof the version code wrote a file DraftSight can use
$chk = $app.OpenDocument($dwg, 0)
if ($chk) {
  $names = @(); foreach ($l in $chk.GetLayerManager().GetLayers()) { $names += [string]$l.Name }
  'REOPEN LAYERS: ' + ($names -join ' | ')
  $app.CloseDocument($dwg, $false)
} else {
  'REOPEN: FAILED'
}
'DONE'