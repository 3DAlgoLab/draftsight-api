# Early-bound entity inventory for the open DraftSight document - verification without screenshots.
#
# Why early binding: the supported enumerator is
#   ISketchManager.GetEntities(in SelectionFilter, in Object LayerNamesStrArray,
#                              out Object EntityTypeLongArray, out Object EntitiesArray)
# and PowerShell's late-bound COM binder cannot express it - it refuses `$null` for an Object-typed
# parameter and refuses to box a scalar into one. Loading the shipped interop assembly and compiling
# inline C# takes the same call in one line, and PowerShell 5.1 is .NET Framework so GetActiveObject
# still exists.
#
# Verified 2026-10-24: 56 entities / 56 type ids from a known 56-entity section drawing, and LineWeight
# read back as the symbolic dsLnWt_035 instead of the bare 35 the late-bound path returns.
#
# Read-only - it enumerates, never writes. Run it against the document you mean:
#   .\com-entities-dump.ps1
param(
  [string] $Interop = 'C:\Program Files\Dassault Systemes\DraftSight\APISDK\tlb\DraftSight.Interop.dsAutomation.dll'
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Interop)) { throw ('interop assembly not found: ' + $Interop) }

# LOAD the assembly into the process. A bare -ReferencedAssemblies compiles and then fails at run time
# with "cannot load file or assembly", which reads like a broken DLL but is only a missing load.
Add-Type -Path $Interop
$src = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using DraftSight.Interop.dsAutomation;

public static class EntityDump {
  public static string Run() {
    StringBuilder sb = new StringBuilder();
    IApplication app = (IApplication)Marshal.GetActiveObject("DraftSight.Application");
    Document doc = app.GetActiveDocument();
    sb.AppendLine("ACTIVE: " + doc.GetPathName());
    ISketchManager sk = doc.GetModel().GetSketchManager();

    object types; object ents;
    sk.GetEntities(null, null, out types, out ents);   // typed null = "any SelectionFilter"
    Array ea = ents as Array;
    Array ta = types as Array;
    if (ea == null) { return "GetEntities returned " + (ents == null ? "null" : ents.GetType().Name) + ", not an array"; }
    sb.AppendLine("ENTITIES: " + ea.Length + "  typeIds: " + (ta == null ? -1 : ta.Length));

    Dictionary<int, int> hist = new Dictionary<int, int>();
    if (ta != null) {
      for (int i = 0; i < ta.Length; i++) {
        int id = Convert.ToInt32(ta.GetValue(i));
        hist[id] = hist.ContainsKey(id) ? hist[id] + 1 : 1;
      }
      List<KeyValuePair<int, int>> sorted = new List<KeyValuePair<int, int>>(hist);
      sorted.Sort(delegate(KeyValuePair<int, int> a, KeyValuePair<int, int> b) { return b.Value.CompareTo(a.Value); });
      StringBuilder h = new StringBuilder();
      foreach (KeyValuePair<int, int> kv in sorted) { h.Append(kv.Key + "=" + kv.Value + " "); }
      sb.AppendLine("TYPE HISTOGRAM (no published enum in the type library - calibrate ids once): " + h);
    }

    // Per-layer counts come from the same call; the second argument is a string array of layer names.
    try {
      object layersObj = doc.GetLayerManager().GetLayers();
      Array layers = layersObj as Array;
      if (layers == null) {
        sb.AppendLine("LAYERS: GetLayers() returned " + (layersObj == null ? "null" : layersObj.GetType().Name));
      } else {
        for (int i = 0; i < layers.Length; i++) {
          Layer l = layers.GetValue(i) as Layer;
          if (l == null) { continue; }
          object t2; object e2;
          sk.GetEntities(null, new string[] { l.Name }, out t2, out e2);
          Array a2 = e2 as Array;
          int n = a2 == null ? 0 : a2.Length;
          sb.AppendLine("  LAYER " + l.Name.PadRight(14) + " entities=" + n + "  lineWeight=" + l.LineWeight);
        }
      }
    }
    catch (Exception ex) { sb.AppendLine("LAYERS skipped: " + ex.GetType().Name + " :: " + ex.Message); }
    return sb.ToString();
  }
}
'@
# PowerShell 5.1 spells the language "CSharp"; "C#" is rejected outright.
Add-Type -TypeDefinition $src -Language CSharp -ReferencedAssemblies @($Interop, 'mscorlib', 'System', 'System.Core')
[EntityDump]::Run()
'DONE'
