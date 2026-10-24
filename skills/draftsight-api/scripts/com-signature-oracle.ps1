#Requires -Version 5
<#
.SYNOPSIS
  Read DraftSight's real COM contract from the shipped type library, offline.
.DESCRIPTION
  The live COM object reached from PowerShell is a late-bound __ComObject, so Get-Member on it shows only
  the IDispatch surface and cannot see overloads, out/ref parameters, or parameter names. This script loads
  DraftSight's own interop assembly with Add-Type and reflects the declared signatures instead: no DraftSight
  process, no document, no writes, and it answers in seconds which member names do not exist at all. Use it
  BEFORE probing the live app, and treat its output as the contract.

  A machine-readable type library beats the vendor help pages for signatures - the help is generated from
  this same typelib and is ~76 MB of HTML. It is also the only way to enumerate enums and read their numeric
  values, which the help pages do not print.
.PARAMETER Interop
  Path to DraftSight's interop assembly, as shipped in APISDK\tlb\ under the install root.
.PARAMETER Types
  Interface or type names to dump in full. Comma-separated works: powershell -File passes "-Types A,B" as one
  argument, so the script splits commas itself rather than forcing "-Types A -Types B".
.PARAMETER Method
  Method name pattern to match across all interfaces (default: the supported entity enumerator).
.PARAMETER Search
  Substring for a name search that prints who declares each hit - use this to settle whether a member exists.
  With -Enums it also lists matching enums; the search branch used to exit before that, reporting "no enum".
.PARAMETER Enums
  With -Search or alone, list the enums whose names match, to prove whether a published enum exists.
.PARAMETER Values
  Print every enum member with its numeric value instead of a name preview. Docs give names; only the
  typelib gives the numbers, which is what you need to decode ids read back out of a drawing.
.EXAMPLE
  powershell -File com-signature-oracle.ps1 -Search ObjectName -Enums
  Find who declares anything and whether an ObjectType-style enum exists.
.EXAMPLE
  powershell -File com-signature-oracle.ps1 -Types ISketchManager -Method InsertHatch -Values
#>
[CmdletBinding()]
param(
  [string]$Interop = 'C:\Program Files\Dassault Systemes\DraftSight\APISDK\tlb\DraftSight.Interop.dsAutomation.dll',
  [string[]]$Types  = @(),
  [string[]]$Method = @('GetEntities'),
  [string]$Search = '',
  [switch]$Enums,
  [switch]$Values
)
$ErrorActionPreference = 'Stop'
# powershell -File hands "-Types A,B" over as a single string; split commas here.
$Types  = $Types  | ForEach-Object { $_ -split ',' } | Where-Object { $_ }
$Method = $Method | ForEach-Object { $_ -split ',' } | Where-Object { $_ }
if (-not (Test-Path $Interop)) { throw "interop assembly not found: $Interop" }
Add-Type -Path $Interop
$asm = [System.AppDomain]::CurrentDomain.GetAssemblies() |
  Where-Object { $_.GetName().Name -eq 'DraftSight.Interop.dsAutomation' } | Select-Object -First 1
$all = $asm.GetTypes()

'ASSEMBLY: ' + $asm.FullName
'allTypes=' + $all.Count + '  interfaces=' + (@($all | Where-Object { $_.IsInterface }).Count) + '  enums=' + (@($all | Where-Object { $_.IsEnum }).Count)

function Format-Param([System.Reflection.ParameterInfo]$p) {
  $k = ''
  if ($p.IsOut -and $p.ParameterType.Name -like '*&') { $k = 'out ' } elseif ($p.ParameterType.Name -like '*&') { $k = 'ref ' }
  elseif (-not $p.IsIn) { $k = '[opt] ' }
  $t = $p.ParameterType.Name -replace '&$',''
  return $k + $t + ' ' + $p.Name
}

function Show-Enum([type]$e) {
  $names = [System.Enum]::GetNames($e)
  if ($Values) {
    '  ' + $e.Name + ' (' + $names.Count + ' values)'
    foreach ($n in $names) { '    ' + $n + ' = ' + [int64][System.Enum]::Parse($e, $n) }
  } else {
    '  ' + $e.Name + ' (' + $names.Count + '): ' + (($names | Select-Object -First 24) -join ', ')
  }
}

if ($Search) {
  '--- types containing "' + $Search + '"'
  foreach ($t in ($all | Where-Object { $_.Name -match $Search } | Sort-Object Name | Select-Object -First 30)) { '  ' + $t.FullName }
  '--- members matching "' + $Search + '"'
  foreach ($t in ($all | Where-Object { $_.IsInterface } | Sort-Object Name)) {
    foreach ($m in $t.GetMembers([System.Reflection.BindingFlags]'Public,Instance,Static')) {
      if ($m.Name -notmatch $Search) { continue }
      $ret = ''
      if ($m.GetType().Name -eq 'MethodInfo') {
        $mi = [System.Reflection.MethodInfo]$m
        $ps = @($mi.GetParameters() | ForEach-Object { Format-Param $_ })
        $ret = '(' + ($ps -join ', ') + ') -> ' + $mi.ReturnType.Name
      }
      '  ' + $t.Name + '.' + $m.Name + $ret
    }
  }
  if ($Enums) {
    '--- enums matching "' + $Search + '"'
    foreach ($e in ($all | Where-Object { $_.IsEnum -and $_.Name -match $Search } | Sort-Object Name | Select-Object -First 6)) { Show-Enum $e }
  }
  exit 0
}

foreach ($tn in $Types) {
  $t = $all | Where-Object { $_.Name -eq $tn } | Select-Object -First 1
  if (-not $t) { 'MISSING TYPE: ' + $tn; continue }
  '### ' + $t.FullName + '  (' + $t.GetMembers().Count + ' members)'
  foreach ($m in ($t.GetMembers() | Sort-Object Name)) {
    if ($m.GetType().Name -ne 'MethodInfo') { continue }
    $mi = [System.Reflection.MethodInfo]$m
    $ps = @($mi.GetParameters() | ForEach-Object { Format-Param $_ })
    '  ' + $mi.ReturnType.Name + ' ' + $mi.Name + '(' + ($ps -join ', ') + ')'
  }
}

$seen = @{}
foreach ($tn in ($all | Where-Object { $_.IsInterface } | Sort-Object Name)) {
  foreach ($m in $tn.GetMembers()) {
    foreach ($pat in $Method) {
      if ($m.Name -notmatch $pat) { continue }
      if ($seen.ContainsKey($tn.Name + '.' + $m.Name + $pat)) { continue }
      $seen[$tn.Name + '.' + $m.Name + $pat] = $true
      $mi = [System.Reflection.MethodInfo]$m
      $ps = @($mi.GetParameters() | ForEach-Object { Format-Param $_ })
      '[' + $pat + '] ' + $tn.Name + '.' + $mi.Name + ' -> ' + $mi.ReturnType.Name + ' ( ' + ($ps -join ', ') + ' )'
    }
  }
}

if ($Enums) {
  $pat = if ($Search) { $Search } else { '.*' }
  '--- enums matching "' + $pat + '"'
  $hits = @($all | Where-Object { $_.IsEnum -and $_.Name -match $pat } | Sort-Object Name | Select-Object -First 6)
  if ($hits.Count -eq 0) { '  no enum with that name is published' }
  foreach ($e in $hits) { Show-Enum $e }
}
'_DONE'
