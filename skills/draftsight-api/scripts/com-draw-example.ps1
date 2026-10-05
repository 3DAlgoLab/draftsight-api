# Draw, fit, export - the minimal COM loop. Windows PowerShell 5.1.
# powershell.exe -NoProfile -ExecutionPolicy Bypass -File com-draw-example.ps1
$ErrorActionPreference = 'Continue'

$app = [Runtime.InteropServices.Marshal]::GetActiveObject('DraftSight.Application')
$doc = $app.GetActiveDocument()
$sk  = $doc.GetModel().GetSketchManager()
$png = 'D:\my-vault\42-manufacturing\com-example.png'

$ok = 0; $bad = 0
function L($x1,$y1,$x2,$y2) {
  if ($sk.InsertLine([double]$x1,[double]$y1,[double]0,[double]$x2,[double]$y2,[double]0) -eq $null) {
    $script:bad++ } else { $script:ok++ }
}
function P($pts, $closed) {
  if ($sk.InsertPolyline2D([double[]]$pts, [bool]$closed) -eq $null) { $script:bad++ } else { $script:ok++ }
}
function C($x,$y,$r) {
  if ($sk.InsertCircle([double]$x,[double]$y,[double]0,[double]$r) -eq $null) { $script:bad++ } else { $script:ok++ }
}

L -75 0 75 0                      # ground
P @(-38,8, 38,8, 26,95, -26,95) $true   # robe
L 0 8 0 95                        # centre split
C 0 118 17                        # head
C -6 122 3.0
C  6 122 3.0
L 52 8 52 150                     # staff
C 52 160 10                       # orb

Write-Output ('created=' + $ok + '  failed=' + $bad)
$app.Zoom(0, $null, $null)        # 0 = fit; exports the current view, so fit first
$doc.GetDocumentExporter().ExportToPng($png, $true)
Write-Output ('exported ' + $png)
