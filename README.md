# robocpy

A PowerShell 7 script that runs [`robocopy`](https://learn.microsoft.com/windows-server/administration/windows-commands/robocopy) jobs defined in an external **JSON config file**, and renders status, progress and a summary with stylish terminal output from [`gum`](https://github.com/charmbracelet/gum).

- **`robocpy.ps1`** — the script.
- **`README.md`** — this file.

Jobs can reference a named **preset** (`copy`, `mirror`, `move` are built in) instead of repeating a switch list, and `-DryRun` adds `/L` to every job so you can test a whole config before it changes any files.

There is no bundled config on purpose: `-ConfigPath` is mandatory and you supply your own JSON file (see the [example configs](#example-configs) for copy-paste starting points).

Path conveniences baked into the script:

- **`%VAR%` expansion** — any path or pattern in the config may use environment variables (e.g. `%USERPROFILE%\Documents`, `%TEMP%`); they are expanded before running, since robocopy itself does not expand them.
- **Relative paths anchor to the config file's folder** — a relative `source`, `destination` or `logDir` (and the default `logs`) resolves against the directory containing your JSON, **not** the current working directory. Absolute and UNC paths are used as-is. So the tool behaves identically no matter where you launch `pwsh` from.

---

## Requirements

| Tool | Why | Install |
|------|-----|---------|
| **PowerShell 7+** (`pwsh`) | The script uses PS7-only syntax and declares `#Requires -PSEdition Core`. Windows PowerShell 5.1 will refuse to run it. | `winget install Microsoft.PowerShell` |
| **gum** | Renders the header, spinner, colored status and summary. | `winget install Charm.Charm-gum` or `scoop install gum` |
| **robocopy** | Ships with Windows. | already present |

Always launch it with `pwsh`, e.g.:

```powershell
pwsh -File .\robocpy.ps1 -ConfigPath .\myjobs.json
```

---

## Usage

```powershell
pwsh -File .\robocpy.ps1 -ConfigPath <path-to-config.json> [-Job <name>] [-All] [-DryRun] [-ShowCommand]
```

| Parameter | Required | Meaning |
|-----------|----------|---------|
| `-ConfigPath` | **Yes** | Path to the JSON config. There is **no default** — you must always name the file explicitly, so the tool can never quietly run some config you did not choose. |
| `-Job <name>`  | No | Run only that one job (must exist and be enabled in the config). Skips the interactive picker. |
| `-All`         | No | Run every enabled job without prompting. |
| `-DryRun` | No | Add `/L` to **every** selected job so you can test the config without changing files. Jobs that already contain `/L` are left as-is. Status and summary show `[DRY RUN]`. |
| `-ShowCommand` | No | Print the fully resolved robocopy command line for each job before running it. Handy for verifying what a preset expands to. |

Behavior when neither `-Job` nor `-All` is given:

- **Interactive terminal** → a `gum filter` picker appears; type to filter, press `<tab>` to mark jobs, `<enter>` to run the selection.
- **Non-interactive** (CI, redirected stdout) → all enabled jobs run.

### Examples

```powershell
# pick job(s) interactively from this config
pwsh -File .\robocpy.ps1 -ConfigPath .\myjobs.json

# run a single named job
pwsh -File .\robocpy.ps1 -ConfigPath .\myjobs.json -Job NotesBackup

# run all enabled jobs from a config stored elsewhere
pwsh -File .\robocpy.ps1 -ConfigPath C:\configs\backup.json -All

# test the whole config first: /L is added to every job, nothing is changed
pwsh -File .\robocpy.ps1 -ConfigPath .\jobs.json -DryRun -ShowCommand

# see exactly which switches a preset resolves to
pwsh -File .\robocpy.ps1 -ConfigPath .\jobs.json -ShowCommand
```

---

## Configuring

The config is a JSON object with two top-level keys: `presets` (optional) and `jobs`.

```jsonc
{
  "presets": {
    // copy / mirror / move are built in — these add to (or override) them

    "quick": {
      "switches": [ "/E", "/NP", "/MT:4" ],
      "logging":  false
    },

    "mirror-local": {
      // overrides the built-in "mirror" switches: no /Z (no network), more threads
      "switches": [ "/MIR", "/XJ", "/NP", "/NDL", "/MT:16" ]
    },

    "archive": {
      "switches": [ "/E", "/MOV", "/R:1", "/W:1", "/NP" ],
      "excludeFiles": [ "*.tmp" ],
      "logDir":  "D:\\robocopy-logs",
      "spinner": "Archiving {job}..."
    }
  },

  "jobs": [
    {
      "name":        "NotesBackup",                 // required, used by -Job and the picker
      "source":      "C:\\Users\\you\\Notes",       // required, must exist
      "destination": "D:\\Backup\\Notes",           // required, created if missing
      "enabled":     true,                           // false => skipped entirely (default: true)
      "preset":      "copy",                         // named profile instead of a switch list
      "switches":    [ "/R:1" ],                     // optional extras, appended after the preset
      "excludeFiles": [ "*.tmp", "thumbs.db" ],      // becomes robocopy /XF ...
      "logDir":      "logs",                         // per-job log folder (default: <config folder>\logs)
      "spinner":     "Backing up {job}..."           // text next to the gum spinner; {job} = job name
    }
  ]
}
```

> **Upgrading:** the old `defaults` key is no longer used. Move its `switches` into a preset (or the jobs) and its `logging` / `logDir` / exclusions into the presets or jobs that need them. The script prints a warning if it still sees `defaults`.

### Presets

A preset is a **named bundle of robocopy switches and common job options** that gives an operation a readable name. Three are built in:

| Preset | Switches |
|--------|----------|
| `copy` | `/E /Z /R:2 /W:2 /NP /NDL /MT:8` |
| `mirror` | `/MIR /XJ /Z /R:2 /W:2 /NP /NDL /MT:8` — 🔴 deletes destination extras |
| `move` | `/MOVE /R:1 /W:1 /NP /NDL` — 🔴 deletes source files |

Define your own under `presets`, or **override a built-in field by field** (e.g. change `mirror.switches` to tune retries or add `TEE`). A config-defined value wins.

**How values are resolved** (most specific wins):

- **Switches:** `preset.switches` (none when the job has no preset) **+** `job.switches`. A preset supplies the whole switch list; job switches append on top.
- **Other settings:** `job > preset > built-in fallback` for `logging`, `logDir`, `excludeFiles`, `excludeDirectories` and `spinner`.
- An **unknown preset name** makes that job error out and be skipped — it is never silently run with the wrong switches.

**Testing a config:** pass **`-DryRun`** to add `/L` to *every* selected job — nothing is changed, and status/summary mark each job `[DRY RUN]`. Combine with `-ShowCommand` to see exactly what each preset expands to. `-DryRun` is the only switch the script adds on its own; it never injects destructive switches. To test a single job, add `/L` to that job's `switches` instead.

### Field reference

**`presets`** (optional — named switch/option profiles; built-ins do not need defining):

| Key | Type | Default | Notes |
|-----|------|---------|-------|
| `switches` | array | `[]` | The profile's complete robocopy switch list. |
| `logging` | boolean | `true` | Log on/off for jobs using this preset. See [Logging](#logging). |
| `logDir` | string | `<config folder>\logs` | Log folder for jobs using this preset. Relative paths resolve against the config file's folder. |
| `excludeFiles` / `excludeDirectories` | array | `[]` | Become `/XF` / `/XD`. |
| `spinner` | string | `Robocopy is syncing {job}...` | `{job}` is replaced with the job name. |

**Each job in `jobs`:**

| Key | Required | Default | Notes |
|-----|----------|---------|-------|
| `name` | ✅ | — | Unique id; use it with `-Job`, shown in the picker and summary. |
| `source` | ✅ | — | Must already exist, else the job fails validation and is skipped. |
| `destination` | ✅ | — | If it does not exist, robocopy creates it (unless `/CREATE` is set). |
| `enabled` | — | `true` | `false` skips the job. Handy to keep jobs defined but dormant. |
| `preset` | — | — | Name of a built-in or config-defined preset supplying the switch list. |
| `switches` | — | `[]` | Appended after the preset's switches. |
| `logging` | — | `preset > true` | Per-job override of the log on/off switch. |
| `excludeFiles` / `excludeDirectories` | — | from preset | Override the preset's values for this job when present. |
| `logDir` | — | `preset > <config folder>\logs` | Per-job log folder. |
| `spinner` | — | `preset > default text` | Spinner title; `{job}` is replaced with the job name. |

> **Paths:** backslashes must be escaped (`"C:\\Users\\you"`) or use forward slashes (`"C:/Users/you"`). `source`, `destination`, `logDir`, `spinner` and every `switches`/exclude entry have **`%VAR%` expanded** (e.g. `%USERPROFILE%`, `%TEMP%`). Relative paths are resolved against the **config file's folder**, not the current directory, so results are identical wherever you run it from.

---

## Logging

Every job writes a robocopy `/LOG` file by default. Set **`"logging": false`** on a preset or a single job to turn it off (the job's value wins).

Why you might care: the script reports **"copied N file(s)"** in the status line and summary. It gets that number from robocopy's `Files :` summary row, which appears in **two places**:

- **logging ON** → the script parses the `/LOG:<job>-<timestamp>.log` file it asked robocopy to write. The status/summary then point you at that log path.
- **logging OFF** → no file is written; the script instead parses robocopy's **captured stdout** (a temp file it already captures and discards). The headline count is **identical** — only the saved log file and the "check the logs" pointer go away.

So the copied count survives either way; `logging` only controls whether you keep a full on-disk report of the run. When `logging` is off, don't add your own `/LOG:` switch — robocopy's stdout is still captured for the count.

---


## robocopy switch guide (plain English)

Anything you put in a `switches` array (in a preset or a job) is passed to robocopy **verbatim**, so this is a menu, not a whitelist — you can use any switch Microsoft documents. Presets are just named collections of these switches; they lock nothing out. The ones the script adds for you (`/XF`, `/XD`, `/LOG`) are noted below; you normally don't type those yourself. `/L` can be added globally with `-DryRun`.

> 🔴 = destructive (deletes or relocates files). ⚪ = safe/no data risk.

### What to copy

| Switch | Plain-English meaning |
|--------|-----------------------|
| `/S` | Copy subfolders, **but skip empty ones**. |
| `/E` | Copy subfolders **including empty ones**. (Implies `/S`.) |
| `/L` | ⚪ **List only — a dry run.** Reports what *would* happen, changes nothing. Keep this on while testing. |
| `/CREATE` | ⚪ Create empty destination files/dirs instead of copying data (useful to pre-build a tree). |
| `/COPY:flags` | Choose *what* of each file to copy: `D` data+attributes, `S` NTFS security, `O` owner, `T` timestamps, `U` auditing, `I` copy targets for links. Default is `DAT`. |
| `/DCOPY:flags` | Same idea but for directories (e.g. `/DCOPY:T` to keep folder timestamps). |
| `/SEC` | Shortcut to also copy security (`/COPY:DATS`). |
| `/COPYALL` | Copy everything (`/COPY:DATSOU`). |
| `/NOCOPY` | Copy nothing — only use with `/SEC`-style ops that just fix attributes. |
| `/SL` | Act on the symbolic link itself, not its target. |

### Move / mirror (destructive)

| Switch | Plain-English meaning |
|--------|-----------------------|
| 🔴 `/MIR` | **Mirror.** Copy everything (`/E`) **and delete** files/folders at the *destination* that no longer exist in the source. Makes dest an exact clone of source. |
| 🔴 `/MOVE` | Copy, then **delete files AND empty folders from the SOURCE.** (Deleting from the source is the dangerous part.) |
| 🔴 `/MOV` | Like `/MOVE` but files only, leaves source folders in place. |
| `/MOVE:C` | Use with `/MOVE` to also delete locked/uncopyable source files. |
| 🔴 `/PURGE` | Delete destination files/folders that are not in the source (this is the destructive half of `/MIR`). |

### Which files to include / skip (selection & filters)

| Switch | Plain-English meaning |
|--------|-----------------------|
| `/MAX:n`, `/MIN:n` | Only copy files up to / at least `n` **bytes**. |
| `/MAXAGE:x`, `/MINAGE:x` | Only files newer than / older than `x` (days, `YYYYMMDD`, or `MMDD`). |
| `/MAXLVL:n` | Recurse at most `n` folder levels deep. |
| `/XO` | ⚪ Skip files that are **Older** at the destination (don't clobber newer dest files). |
| `/XN`, `/XC` | Skip **Newer** / already-**Changed** files. |
| `/XJ` | ⚪ Skip **junction points / symlinks** to folders (prevents following a link out of the tree). |
| `/XF pat1 pat2` | eXclude **F**iles matching these names/wildcards. *The script adds this for you from `excludeFiles`.* |
| `/XD dir1 dir2` | eXclude **D**irectories matching these names/paths. *The script adds this from `excludeDirectories`.* |
| `/XA[attrs]`, `/AD`, `/A` | Only copy files with / without certain attributes (`A` archive, `H` hidden, `D` dir, `R` read-only, etc.). |
| `/IS`, `/IT` | Also list **S**ame / **T**weaked files (they're skipped by default). |

### Retries, timing & "fatigue"

| Switch | Plain-English meaning |
|--------|-----------------------|
| `/R:n` | Retry a locked/failed file `n` times. **Default is a huge number** — set it low (e.g. `/R:2`) or a busy file can stall the whole run. |
| `/W:n` | Wait `n` seconds between retries. |
| `/TBD` | Wait for the share name to be re-published (network retries). |
| `/TIMES` | Copy source timestamps even when a file is otherwise skipped. |

### Output & logging

| Switch | Plain-English meaning |
|--------|-----------------------|
| `/V`, `/TS`, `/FP` | Verbose; add **T**ime**S**tamps; add **F**ull **P**aths to each line. |
| `/NP` | No live **P**ercentage lines (quieter progress). |
| `/NS`, `/NC` | Hide **S**izes / hide file **C**lass labels in output. |
| `/NFL`, `/NDL` | No **F**ile **L**ist / no **D**irectory **L**ist — just the final summary. |
| `/BYTES` | Show sizes in raw bytes instead of KB/MB. |
| `/LOG:file`, `/LOG+:file` | Write the report to `file` (overwrite / append). **The script manages `/LOG` via the `logging` option — don't set it yourself.** |
| `/TEE:on\|off` | Also echo the log to the console. |

### Performance & special modes

| Switch | Plain-English meaning |
|--------|-----------------------|
| `/MT[:n]` | **M**ul**t**i**threaded** copy, `n` threads (1–128, default 8). Big speedup on many small files / SSDs. |
| `/J` | Unbuffered I/O — better for very large single files. |
| `/Z`, `/ZB` | **R**estartable mode over flaky/network links; `/ZB` falls back to **B**ackup mode if access is denied. |
| `/B` | Copy in Backup mode (needs `SeBackupPrivilege`; bypasses some ACL denials). |
| `/MON:m`, `/MOT:m` | **Mon**itor: re-run the job up to `m` times / every `m` minutes if the source changes. ⚠️ These never exit on their own, so they will hang the script (it waits for robocopy to finish) — not recommended. |

---

## Example configs

Four ready-to-edit examples, all using named presets. Test any of them first with `-DryRun`.

### 1. Copying / backup (safe, additive — never deletes anything)

Adds new/updated files to the destination, leaves everything already there. The built-in `copy` preset supplies the switches; cross-cutting settings live on the job.

```jsonc
{
  "jobs": [
    {
      "name":        "DocsBackup",
      "source":      "C:\\Users\\you\\Documents",
      "destination": "D:\\Backup\\Documents",
      "preset":      "copy",
      "excludeFiles":       [ "*.tmp", "thumbs.db" ],
      "excludeDirectories": [ "$RECYCLE.BIN", "node_modules", ".git" ],
      "spinner":     "Backing up {job}..."
    }
  ]
}
```

### 2. Moving (relocates files and DELETES them from the source) 🔴

Use when you want content to end up at the destination and *be removed from the source* (e.g. archiving off a C: folder). Test with `-DryRun` first and double-check `source`/`destination`.

```jsonc
{
  "jobs": [
    {
      "name":        "ArchiveOldProjects",
      "source":      "C:\\Work\\OldProjects",
      "destination": "D:\\Archive\\OldProjects",
      "preset":      "move",
      "spinner":     "Moving {job} to archive..."
    }
  ]
}
```

```powershell
pwsh -File .\robocpy.ps1 -ConfigPath .\jobs.json -Job ArchiveOldProjects -DryRun
```

### 3. Mirroring (destination becomes an exact clone; extras deleted) 🔴

Use for keeping a mirror/drive-copy in sync. The built-in `mirror` preset uses `/MIR`, which **deletes** destination files no longer in the source — so never point `destination` somewhere holding data you'd miss.

```jsonc
{
  "jobs": [
    {
      "name":        "ProjectsMirror",
      "source":      "C:\\Users\\you\\Projects",
      "destination": "E:\\Mirror\\Projects",
      "preset":      "mirror",
      "logDir":      "D:\\robocopy-logs",
      "excludeDirectories": [ "$RECYCLE.BIN", "System Volume Information" ],
      "spinner":     "Mirroring {job}..."
    }
  ]
}
```

### 4. Several jobs with different intents, one config

This is where presets pay off: before, mixed profiles meant copy-pasting a switch list into every job. Now each job just names its operation.

```jsonc
{
  "presets": {
    "archive": { "switches": [ "/E", "/MOV", "/R:1" ] }
  },
  "jobs": [
    { "name": "DailyBackup", "source": "C:\\Data", "destination": "D:\\Backup\\Data", "preset": "copy" },
    { "name": "DriveMirror", "source": "C:\\Data", "destination": "E:\\Mirror\\Data", "preset": "mirror" },
    { "name": "OldProjects", "source": "C:\\Work", "destination": "D:\\Archive\\Work", "preset": "archive" }
  ]
}
```

Run all three with `-All`; add `-DryRun` to test them all without changing files, and `-ShowCommand` to inspect what each preset expands to.

> ⚠️ **Safety, one more time:** `/MIR`, `/MOVE`, `/MOV` and `/PURGE` delete or relocate real files. The script only does what its config says — which is exactly why `-ConfigPath` has **no default** and why `-DryRun` exists. Test a config with `-DryRun` first, check the `[DRY RUN]` results, then run it for real.

---

## Output & exit codes

While running you see a centered `gum` header, a per-job `gum spin` spinner, then a `✓ / ⚠ / ✗` summary. There are **two different codes** to keep apart:

### A. The robocopy verdict (shown in the summary, per job)

The script parses robocopy's return code and shows a friendly message + badge:

| robocopy code | Badge | Meaning shown |
|---------------|-------|---------------|
| `0` | ✓ OK | everything already in sync |
| `1` | ✓ OK | files copied successfully |
| `2` | ! WARN | extra files/dirs at destination |
| `3` | ! WARN | copied + extras |
| `4`–`7` | ! WARN | mismatched files/dirs (access or checksum problems) |
| `8`–`15` | ✗ FAIL | one or more files could not be copied |
| `16`+ | ✗ FAIL | serious error (bad drive, insufficient space, etc.) |

Codes are bit flags (`1` copied, `2` extra, `4` mismatched, `8` failing, `16` severe); the script buckets them as success `< 2`, warning `2–7`, failure `≥ 8`.

### B. The script's own process exit code

- On a normal run it exits with **the highest (worst) robocopy code** across the jobs it ran — so `pwsh -File .\robocpy.ps1 ... ; $LASTEXITCODE` tells automation whether the sync was clean (`0`/`1`) or had trouble (`≥ 2`, failures `≥ 8`).
- It exits **`2`** for setup/validation problems before any copy: `gum` not on PATH, config file missing, no enabled jobs, or an unknown `-Job` name.
- It exits **`1`** for an unexpected script error (top-level failure), and treats a job whose robocopy **fails to launch** as code **`16`** (a copy failure) in that job's verdict.

---

## Does the script cover all robocopy features?

**Yes for the options themselves** — everything in a `switches` array (in a preset or a job) is forwarded to robocopy untouched, so any documented robocopy switch (all ~60, with or without a value) works; the guide above is only a menu of the common ones. Presets are named switch bundles, not a whitelist. robocopy does the actual work; the script just assembles the command line.

What the script **adds/controls** for you, rather than exposing as its own config keys:

| Managed by the script | Config it comes from |
|-----------------------|----------------------|
| `source`, `destination` | `source` / `destination` |
| `/XF` file exclusions | `excludeFiles` |
| `/XD` directory exclusions | `excludeDirectories` |
| `/LOG:<file>` | `logging` + `logDir` |
| named switch profiles | `presets` + built-in `copy` / `mirror` / `move` |
| global `/L` dry run | `-DryRun` |
| captures stdout + the process exit code | automatic |

Known boundaries (deliberate, not bugs):

- **Don't put `/LOG:`/`/LOG+:` in `switches`** — the script manages the log via `logging`. Want append or a custom log name? Set `logging: false` and add your own `/LOG+` switch.
- **Monitor/repeat modes `/MON` and `/MOT`** don't work here: they run indefinitely, and the script waits for robocopy to exit, so they'd hang.
- The **"copied N file(s)"** number always comes from robocopy's own `Files :` summary row, so it reflects robocopy's accounting exactly (and survives `logging: false` via stdout).
- The script never injects `/MIR`, `/MOVE`, `/PURGE` or any other destructive switch on its own — they only come from a preset or from switches you write yourself. The one switch it *does* add is `/L`, and only when you pass `-DryRun`.
