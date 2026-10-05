# Read the current DraftSight selection over COM. Windows PowerShell 5.1 only.
# powershell.exe -NoProfile -ExecutionPolicy Bypass -File com-inspect.ps1
$ErrorActionPreference = 'Continue'

try {
  $app = [Runtime.InteropServices.Marshal]::GetActiveObject('DraftSight.Application')
} catch {
  Write-Output 'DraftSight is not registered in the ROT (MK_E_UNAVAILABLE).'
  Write-Output 'It must be COM-activated; that may replace the running instance.'
  exit 1
}

$doc  = $app.GetActiveDocument()
$selm = $doc.GetSelectionManager()
Write-Output ('version = ' + $app.GetVersion())
Write-Output ('doc     = ' + $doc.GetPathName())

# A live mouse pick lands in set 1, not set 0.
$set = -1
foreach ($t in 0,1,2,3) {
  $c = $selm.GetSelectedObjectCount($t)
  Write-Output ('  set ' + $t + ' count = ' + $c)
  if ($set -lt 0 -and $c -gt 0) { $set = $t }
}
if ($set -lt 0) { Write-Output 'nothing selected'; exit 0 }

$n = $selm.GetSelectedObjectCount($set)
for ($i = 0; $i -lt $n; $i++) {
  $e = $null
  foreach ($ot in 0,1,2,3,4,5,6,7,8) {
    try { $e = $selm.GetSelectedObject($set, $i, $ot) } catch { continue }
    if ($e -ne $null) { break }
  }
  if ($e -eq $null) { Write-Output ('entity[' + $i + '] unresolved'); continue }

  Write-Output ('--- entity[' + $i + ']  set=' + $set + '  dsObjectType_e=' + $ot)
  foreach ($m in ($e | Get-Member)) {
    # Property Definitions contain "() {get}", so filter on MemberType, never on "("
    if ($m.MemberType -ne 'Property') { continue }
    try { $v = $e.($m.Name) } catch { continue }
    if ($v -is [double] -or $v -is [int] -or $v -is [bool] -or $v -is [string]) {
      Write-Output ('    ' + $m.Name + ' = ' + $v)
    }
  }
  try { Write-Output ('    GetArea()   = ' + $e.GetArea()) }     catch { }
  try { Write-Output ('    GetLength() = ' + $e.GetLength()) }   catch { }
  $x1=0.0;$y1=0.0;$z1=0.0;$x2=0.0;$y2=0.0;$z2=0.0
  try {
    $e.GetBoundingBox([ref]$x1,[ref]$y1,[ref]$z1,[ref]$x2,[ref]$y2,[ref]$z2)
    Write-Output ('    bbox = (' + $x1 + ', ' + $y1 + ', ' + $z1 + ') -> (' + $x2 + ', ' + $y2 + ', ' + $z2 + ')')
  } catch { }
}
