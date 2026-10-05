# pi-draftsight-api

Optional pi package: a skill for driving **DraftSight 2026** through its local HTTP/JSON API on
`127.0.0.1:7776` - draw, edit, save, and export DWG files programmatically, and verify results by
reading geometry back instead of trusting return codes.

**Platform: Windows only.** DraftSight's API broker, the `C:\ProgramData\Dassault Systemes\DraftSight\`
sandbox, and the `hh.exe` help decompiler are all Windows-specific.

## Install

```bash
pi install C:/dev-pi/draftsight-api
```

Try it once without adding it to settings:

```bash
pi -e C:/dev-pi/draftsight-api
```

## Remove

```bash
pi remove C:/dev-pi/draftsight-api
```

The skill stays on disk; only the declaration in `~/.pi/agent/settings.json` is dropped. Delete
`C:/dev-pi/draftsight-api` to reclaim the ~76 MB of decompiled help.

## Contents

```
skills/draftsight-api/
├── SKILL.md              routing, the hard rules, trust table, do-not-call list
├── references/
│   ├── protocol.md       failure catalogue, crash log, sandbox proof
│   └── signatures.md     verified signatures and enum values
├── scripts/
│   ├── ds-call.sh        handshake + one-call API client
│   ├── decompile-chm.sh  regenerate docs/ from the installed DraftSight help
│   └── html2txt.sh       strip tags from help pages for grepping
└── docs/                 NOT in git - 6,457 decompiled help pages, ~76 MB
```

## Regenerate the reference

`docs/` is gitignored: it is Dassault-copyrighted help and rebuilds in seconds.

```bash
bash skills/draftsight-api/scripts/decompile-chm.sh
```

Requires DraftSight installed at `C:\Program Files\Dassault Systemes\DraftSight\`.
