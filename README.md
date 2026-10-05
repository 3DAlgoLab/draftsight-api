# pi-draftsight-api

A [pi](https://pi.dev) package: a skill for driving **DraftSight 2026** through its local HTTP/JSON
API on `127.0.0.1:7776` - draw, edit, save, and export DWG files programmatically, and verify
results by reading geometry back instead of trusting return codes.

**Platform: Windows only.** DraftSight's API broker, the
`C:\ProgramData\Dassault Systemes\DraftSight\` file sandbox, and the `hh.exe` help decompiler are all
Windows-specific.

## Install

```bash
pi install git:github.com/3DAlgoLab/draftsight-api
```

Pin a ref instead of tracking the default branch (`master`):

```bash
pi install git:github.com/3DAlgoLab/draftsight-api@v1.0.0
```

Try it for a single invocation without writing anything to settings:

```bash
pi -e git:github.com/3DAlgoLab/draftsight-api
```

## Remove

```bash
pi remove git:github.com/3DAlgoLab/draftsight-api
```

## After installing

The decompiled API reference is **not** in git - it is Dassault-copyrighted and rebuilds in seconds,
so a fresh install has no `docs/` until you generate it:

```bash
cd ~/.pi/agent/git/github.com/3DAlgoLab/draftsight-api
bash skills/draftsight-api/scripts/decompile-chm.sh
```

Requires DraftSight installed at `C:\Program Files\Dassault Systemes\DraftSight\`. The skill is
useful without `docs/`; the reference just makes it able to look signatures up instead of guessing.

**`pi update --extensions` deletes `docs/`.** Pi cleans untracked files when it reconciles a git
package, so the reference is removed on every update. Re-run the command above afterwards.

Pi clones git sources to `~/.pi/agent/git/github.com/3DAlgoLab/draftsight-api` and identifies them by
repository URL, so a local copy of this folder and the installed clone never load twice.

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
└── docs/                 NOT in git - ~6,500 decompiled help pages, ~76 MB
```

## What the skill encodes

The rules that cost the most to rediscover:

- Echo `{id, macroId, type}` back verbatim on every call; `macroId` is a session epoch that resets when DraftSight restarts.
- API file I/O is confined to `C:\ProgramData\Dassault Systemes\DraftSight\`; any file crossing the boundary must be staged there first.
- Enum parameters take symbolic names as strings (`"dsDocumentSave_R2018_DWG"`), not integers.
- `SaveAs` is obsolete - use `SaveAs2`.
- `ExportTo*` and `SaveAs2` return values are evidence; `RunCommand`'s `"Succeeded"` is not.
- DraftSight command names are not AutoCAD's: there is no `ZoomExtents`, the command is `ZoomFit`.

## Develop

Edit the skill, commit, push, then reconcile:

```bash
pi update --extensions
```

`docs/` and the `*.sh` line endings are protected by `.gitignore` and `.gitattributes` respectively -
`core.autocrlf=true` would otherwise rewrite the shebangs to CRLF and break the scripts under git-bash.
