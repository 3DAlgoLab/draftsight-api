# CSV -> DraftSight table, sized per column, verified by read-back. Windows PowerShell 5.1.
# powershell.exe -NoProfile -ExecutionPolicy Bypass -File com-table.ps1 -CsvPath D:\parts.CSV -PngPath D:\out.png
param(
  [Parameter(Mandatory=$true)][string]$CsvPath,
  [string]$PngPath = '',
  [double]$Left = 0.0,
  [double]$Top = 0.0,
  [double]$TextHeight = 3.0
)
$ErrorActionPreference = 'Stop'

$rows = Import-Csv -Path $CsvPath -Encoding UTF8
$headers = @($rows[0].PSObject.Properties.Name | ForEach-Object { ($_ -replace '\uFEFF', '').Trim() })
$ncol = $headers.Count
$nrow = $rows.Count + 1

# display width in ASCII units; CJK glyphs are ~1.7x wide
function Dw([string]$s) {
  $w = 0.0
  foreach ($ch in $s.ToCharArray()) { if ([int]$ch -gt 0x2E80) { $w += 1.7 } else { $w += 1.0 } }
  return $w
}
$widths = @()
for ($c=0; $c -lt $ncol; $c++) {
  $max = Dw $headers[$c]
  foreach ($r in $rows) { $v = Dw ([string]@($r.PSObject.Properties.Value)[$c]); if ($v -gt $max) { $max = $v } }
  # 2.5 mm per ASCII char at text height 3.0, plus ~10 mm of cell margin
  $widths += [Math]::Round($max * (2.5 * $TextHeight / 3.0) + 10.0, 1)
}

$app = [Runtime.InteropServices.Marshal]::GetActiveObject('DraftSight.Application')
$doc = $app.GetActiveDocument()
$sk  = $doc.GetModel().GetSketchManager()
$app.AbortRunningCommand()

$sk.StartUndoRecord()
$tbl = $sk.InsertTable($Left, $Top, $nrow, $ncol, 7.0, $widths[0], 2, 3, 3)
$tbl.SetTextHeight(2, $TextHeight * 1.15)   # 2 = dsTableCellType_Header, 3 = _Data
$tbl.SetTextHeight(3, $TextHeight)
for ($c=0; $c -lt $ncol; $c++) {
  $tbl.SetColumnWidthAt($c, $widths[$c])    # SetColumnWidth alone would make every column equal
  $tbl.SetText(0, $c, $headers[$c])
}
for ($r=0; $r -lt $rows.Count; $r++) {
  $vals = @($rows[$r].PSObject.Properties.Value)
  for ($c=0; $c -lt $ncol; $c++) { $tbl.SetText($r+1, $c, [string]$vals[$c]) }
}
$sk.StopUndoRecord()

# evidence: read geometry and cells back, never trust the call sequence
$x1=0.0;$y1=0.0;$z1=0.0;$x2=0.0;$y2=0.0;$z2=0.0
$tbl.GetBoundingBox([ref]$x1,[ref]$y1,[ref]$z1,[ref]$x2,[ref]$y2,[ref]$z2)
Write-Output ('rows=' + $tbl.TotalRowCount() + '  cols=' + $tbl.TotalColumnCount())
Write-Output ('bbox = (' + $x1 + ', ' + $y1 + ') -> (' + $x2 + ', ' + $y2 + ')')
Write-Output ('colW = ' + ((0..($ncol-1) | ForEach-Object { $tbl.GetColumnWidth($_) }) -join ', '))
Write-Output ('(0,0)=' + $tbl.GetText(0,0) + '   (' + ($nrow-1) + ',0)=' + $tbl.GetText($nrow-1,0))

if ($PngPath -ne '') {
  $app.Zoom(0, $null, $null)   # exports the current view, so fit first
  $null = $doc.GetDocumentExporter().ExportToPng($PngPath, $true)   # returns nothing over COM
  Write-Output ('png  = ' + $PngPath + '  mtime=' + (Get-Item $PngPath).LastWriteTime)
}
