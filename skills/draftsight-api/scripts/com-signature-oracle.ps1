# Offline signature oracle for DraftSight's shipped interop assembly.
#
# DraftSight ships a tlbimp wrapper over its own type library. Reflecting over it answers "what is the
# real signature of this call?" in about two seconds, with DraftSight closed and no document touched,
# which beats asking the running app through IDispatch: there, out-parameters are invisible, every
# array parameter is typed `Object`, and the member list contains things the type library does not
# declare. Verified 2026-10-24 against DraftSight 26.4.0.5067 (assembly 26.4.0.43, 723 types).
#
#   .\com-signature-oracle.ps1                                                # hot interfaces
#   .\com-signature-oracle.ps1 -Search Hatch                                  # who declares what
#   .\com-signature-oracle.ps1 -Types ISketchManager -Method GetEntities
#   .\com-signature-oracle.ps1 -Search EntityType -Enums                      # is there a published enum?
param(
  [string] $Interop = 'C:\Program Files\Dassault Systemes\DraftSight\APISDK\tlb\DraftSight.Interop.dsAutomation.dll',
  [string[]] $Types = @('IApplication','IDocument','IModel','ISketchManager','ILayerManager','IDimensionStyleManager','ISelectionManager'),
  [string[]] $Method = @(),
  [string] $Search = '',
  [switch] $Enums
)
$ErrorActionPreference = 'Stop'
# powershell -File hands "-Types A,B" over as a single string, so split commas here rather than
# requiring "-Types A -Types B" at the prompt.
$Types  = $Types  | ForEach-Object { $_ -split ',' } | Where-Object { $_ }
$Method = $Method | ForEach-Object { $_ -split ',' } | Where-Object { $_ }
if (-not (Test-Path $Interop)) { throw ('interop assembly not found: ' + $Interop + ' - check the DraftSight install path') }
$asm = [System.Reflection.Assembly]::LoadFile($Interop)
'ASSEMBLY: ' + $asm.FullName
'allTypes=' + $asm.GetTypes().Count + '  interfaces=' + @($asm.GetTypes() | Where-Object { $_.IsInterface }).Count + '  enums=' + @($asm.GetTypes() | Where-Object { $_.IsEnum }).Count

if ($Search) {
  '--- types matching "' + $Search + '"'
  foreach ($t in ($asm.GetTypes() | Where-Object { $_.Name -match $Search } | Sort-Object Name | Select-Object -First 25)) {
    $k = if ($t.IsEnum) { 'enum' } elseif ($t.IsInterface) { 'interface' } elseif ($t.IsValueType) { 'struct' } else { 'class' }
    '  ' + $k + ' ' + $t.Name
  }
  '--- members matching "' + $Search + '"'
  foreach ($t in ($asm.GetTypes() | Where-Object { $_.IsInterface } | Sort-Object Name)) {
    foreach ($m in ($t.GetMembers() | Where-Object { $_.Name -match $Search })) {
      $ret = ''
      if ($m -is [System.Reflection.MethodInfo]) { $ret = ' -> ' + $m.ReturnType.Name }
      '  ' + $t.Name + '.' + $m.Name + $ret
    }
  }
  exit 0
}

function Show-Sig($m) {
  if ($m -is [System.Reflection.PropertyInfo]) {
    '  prop  ' + $m.PropertyType.Name + ' ' + $m.Name + $(if ($m.CanRead) { ' {get' } else { ' {' }) + $(if ($m.CanWrite) { '; set' } else { '' }) + ' }'
    return
  }
  $ps = ($m.GetParameters() | ForEach-Object {
    $kind = 'in'
    if ($_.IsOut) { $kind = 'out' }
    elseif ($_.ParameterType.IsByRef) { $kind = 'ref' }
    $tt = $_.ParameterType
    if ($tt.IsByRef) { $tt = $tt.GetElementType() }
    $kind + ' ' + $tt.Name + ' ' + $_.Name
  }) -join ', '
  '  ' + $m.ReturnType.Name + ' ' + $m.Name + '(' + $ps + ')'
}

foreach ($tn in $Types) {
  $t = $asm.GetTypes() | Where-Object { $_.Name -eq $tn -and $_.IsInterface } | Select-Object -First 1
  if (-not $t) { 'MISSING INTERFACE: ' + $tn + '  (names come from the type library - find it with -Search first)'; continue }
  $members = $t.GetMembers() | Where-Object { $_ -is [System.Reflection.MethodInfo] -or $_ -is [System.Reflection.PropertyInfo] }
  if ($Method.Count -gt 0) { $members = $members | Where-Object { $Method -contains $_.Name } }
  '### ' + $t.FullName + '  (' + @($t.GetMembers()).Count + ' members)'
  foreach ($m in ($members | Sort-Object Name)) { Show-Sig $m }
}

if ($Enums) {
  '### enums'
  foreach ($e in ($asm.GetTypes() | Where-Object { $_.IsEnum } | Sort-Object Name | Select-Object -First 12)) {
    $names = [System.Enum]::GetNames($e)
    '  ' + $e.Name + ' (' + $names.Count + '): ' + (($names | Select-Object -First 8) -join ', ')
  }
}
'DONE'
