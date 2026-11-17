#Requires -PSEdition Core
<#
.SYNOPSIS
    Config-driven robocopy orchestrator with stylish gum output.
.DESCRIPTION
    Reads a JSON configuration file describing one or more robocopy jobs,
    validates them, runs robocopy for each selected job and renders status,
    progress and a summary with gum (charmbracelet).

    Jobs may reference a named "preset" (copy / mirror / move are built in, and
    the config can define or override others). A preset bundles the robocopy
    switches and common options for one kind of operation. Use -DryRun to add
    /L to every selected job and test a config before letting it change files.

    PowerShell 7 is mandatory (Set-StrictMode Latest plus null-coalescing,
    ternary and other PS7-only syntax are used on purpose; Windows PowerShell
    5.1 cannot even parse this file). Run it with: pwsh -File .\robocpy.ps1
.PARAMETER ConfigPath
    Path to the JSON config file. MANDATORY — there is no default, so you must
    always point the script at an explicit config file.
.PARAMETER Job
    Run only the named job (must exist in the config). Skips the interactive picker.
.PARAMETER All
    Run every enabled job without prompting.
.PARAMETER DryRun
    Add /L to every selected job so the whole config can be tested without
    changing any files. Has no effect on jobs that already contain /L.
.PARAMETER ShowCommand
    Print the fully resolved robocopy command line for each job before running.
.EXAMPLE
    pwsh -File .\robocpy.ps1 -ConfigPath .\myjobs.json
.EXAMPLE
    pwsh -File .\robocpy.ps1 -ConfigPath .\myjobs.json -Job NotesBackup
.EXAMPLE
    pwsh -File .\robocpy.ps1 -ConfigPath C:\configs\backup.json -All
.EXAMPLE
    pwsh -File .\robocpy.ps1 -ConfigPath .\jobs.json -DryRun -ShowCommand
.NOTES
    Requirements: PowerShell 7+, gum (winget install Charm.Charm-gum / scoop install gum), robocopy.
    Exit code: the highest (worst) robocopy exit code across the executed jobs.
    Paths in the config support %VAR% expansion, and relative paths are resolved
    against the config file's own folder (not the current directory).
    A destructive job is only as destructive as its config: test the config with
    -DryRun, read the result, then run it for real.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ConfigPath,
    [string] $Job,
    [switch] $All,
    [switch] $DryRun,
    [switch] $ShowCommand
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# gum helpers
# ---------------------------------------------------------------------------

function Write-Gum {
    param(
        [Parameter(Position = 0)][ValidateSet('green', 'yellow', 'red', 'white')]$Kind,
        [Parameter(Position = 1)][string]$Text
    )
    $icon, $rgb = switch ($Kind) {
        'green'  { '✓', '42' }
        'yellow' { '⚠', '214' }
        'red'    { '✗', '196' }
        default  { '·', '250' }
    }
    # Host output on purpose: styled status must never pollute the pipeline.
    gum style --foreground $rgb -- "$icon  $Text" | Out-Host
}

function Write-Header {
    param([string]$Title, [string]$Subtitle)
    gum style --foreground 212 --bold --align center --width 72 -- "$Title"
    if ($Subtitle) {
        gum style --foreground 245 --italic --align center --width 72 -- "$Subtitle"
    }
}

function Select-Jobs {
    <# Interactive multi-select via gum filter; returns the chosen plan objects. #>
    param([psobject[]]$Plans)
    $names = [string[]]$Plans.Name
    if ($names.Count -eq 1) { return , $Plans[0] }
    # gum filter defaults to --limit 1 (single pick). --no-limit enables the
    # documented behaviour: tab marks any number of jobs, enter runs them all.
    # (With nothing marked, enter still picks the item under the cursor.)
    $picked = $names | gum filter --no-limit --placeholder 'Select job(s) [filter with keys, tab marks, enter starts]'
    # gum may echo framing on earlier lines; match back to real plan objects.
    return @($Plans | Where-Object { $_.Name -in $picked })
}

# ---------------------------------------------------------------------------
# config loading + validation
# ---------------------------------------------------------------------------

function Get-Prop {
    <# Safe property access for JSON objects under Set-StrictMode -Version Latest. #>
    param([psobject]$InputObject, [string]$Name, $Default = $null)
    if ($null -ne $InputObject -and $InputObject.PSObject.Properties[$Name]) {
        $v = $InputObject.$Name
        return ($null -eq $v ? $Default : $v)
    }
    return $Default
}

function Get-StrList {
    <#
        Coerce a JSON value to a clean [string[]]:
        - $null / missing   -> @()
        - single string     -> one-element array
        - array             -> elements stringified
        Each entry gets %VAR% environment expansion (robocopy does not do this
        itself, so patterns/paths written with env vars still work).
        Empty/whitespace entries are dropped, because [string[]]@() casts to @('')
        under Set-StrictMode and a bare '' after /XF makes robocopy fail (exit 1).
    #>
    param($Value)
    if ($null -eq $Value) { return @() }
    $arr = @($Value | ForEach-Object { [Environment]::ExpandEnvironmentVariables([string]$_) })
    return @($arr | Where-Object { $_ -ne '' -and $_.Trim() -ne '' })
}

function Resolve-ConfigPath {
    <#
        Expand %VAR% and anchor RELATIVE paths to the config file's folder, so the
        tool behaves the same no matter where pwsh was launched from. Absolute and
        UNC paths are left untouched. Returns '' for empty input.
    #>
    param([AllowNull()][string]$Path, [string]$BaseDir)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if ([IO.Path]::IsPathRooted($expanded)) { return [IO.Path]::GetFullPath($expanded) }
    return [IO.Path]::GetFullPath((Join-Path $BaseDir $expanded))
}

function ConvertTo-ProcessArgument {
    <#
        Start-Process joins -ArgumentList elements with plain spaces and does NOT
        quote elements that contain spaces. robocopy (and gum) would then receive
        "C:\My Folder" as two arguments and fail. Quote every element so Windows
        parses each one as a single argument; escape any embedded double quotes.
    #>
    param([AllowEmptyCollection()][string[]]$Values)
    return @($Values | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' })
}

# Ready-to-use switch profiles. A config "presets" object can add new ones or
# override any of these by name (field by field). A preset owns the full switch
# list; cross-cutting options (logging, exclusions, logDir, spinner) may also be
# set on a preset, with the job's own values taking precedence.
$script:BuiltinPresets = @{
    copy   = @{ switches = @('/E', '/Z', '/R:2', '/W:2', '/NP', '/NDL', '/MT:8') }
    mirror = @{ switches = @('/MIR', '/XJ', '/Z', '/R:2', '/W:2', '/NP', '/NDL', '/MT:8') }
    move   = @{ switches = @('/MOVE', '/R:1', '/W:1', '/NP', '/NDL') }
}

function Get-Preset {
    <#
        Resolve a preset by name. Config-defined presets override built-ins of
        the same name one property at a time. Returns $null when the name is
        unknown or empty.
    #>
    param([AllowNull()][psobject]$Config, [AllowNull()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }

    $custom  = Get-Prop (Get-Prop $Config 'presets') $Name
    $builtin = $script:BuiltinPresets[$Name]
    if ($null -eq $custom -and $null -eq $builtin) { return $null }

    $merged = [ordered]@{}
    if ($null -ne $builtin) {
        foreach ($p in ([pscustomobject]$builtin).PSObject.Properties) { $merged[$p.Name] = $p.Value }
    }
    if ($null -ne $custom) {
        foreach ($p in ([pscustomobject]$custom).PSObject.Properties) { $merged[$p.Name] = $p.Value }
    }
    return [pscustomobject]$merged
}

function ConvertTo-JobPlan {
    <#
        Merges an optional named preset and the per-job fields into one plan per
        enabled job. A preset supplies the full switch list; job switches append
        on top. Other settings resolve as job > preset > built-in fallback.
    #>
    param(
        [psobject]$Config,
        [string]$ConfigDir,
        [switch]$DryRun
    )

    foreach ($entry in @(Get-Prop $Config 'jobs' @() | ForEach-Object { [pscustomobject]$_ })) {
        if ((Get-Prop $entry 'enabled' $true) -eq $false) { continue }

        $name       = [string](Get-Prop $entry 'name' '')
        $presetName = [string](Get-Prop $entry 'preset' '')
        $preset     = Get-Preset $Config $presetName
        if ($presetName -and $null -eq $preset) {
            Write-Gum red "[$name] unknown preset '$presetName' — job will be skipped."
            continue
        }

        $baseSw   = if ($null -ne $preset) { Get-StrList (Get-Prop $preset 'switches') } else { @() }
        $switches = @($baseSw + (Get-StrList (Get-Prop $entry 'switches')))

        # One global dry-run switch for the whole config: add /L unless it is
        # already there, so -ShowCommand and the summary both reflect it.
        $isDry = [bool]($DryRun -or ($switches -contains '/L'))
        if ($DryRun -and $switches -notcontains '/L') { $switches = @($switches + '/L') }

        [pscustomobject]@{
            Name        = $name
            Source      = Resolve-ConfigPath (Get-Prop $entry 'source' '') $ConfigDir
            Destination = Resolve-ConfigPath (Get-Prop $entry 'destination' '') $ConfigDir
            Preset      = $presetName
            DryRun      = $isDry
            Switches    = $switches
            ExcludeFile = Get-StrList (Get-Prop $entry 'excludeFiles' (Get-Prop $preset 'excludeFiles'))
            ExcludeDir  = Get-StrList (Get-Prop $entry 'excludeDirectories' (Get-Prop $preset 'excludeDirectories'))
            LogDir      = Resolve-ConfigPath ([string](Get-Prop $entry 'logDir' (Get-Prop $preset 'logDir' 'logs'))) $ConfigDir
            Logging     = [bool](Get-Prop $entry 'logging' (Get-Prop $preset 'logging' $true))
            Spinner     = [Environment]::ExpandEnvironmentVariables([string](Get-Prop $entry 'spinner' (Get-Prop $preset 'spinner' 'Robocopy is syncing {job}...')))
        }
    }
}

function Test-JobPlan {
    <# Returns $true when the plan is runnable; prints gum diagnostics otherwise. #>
    param([psobject]$Plan)

    if (-not $Plan.Name) { Write-Gum red 'Job is missing a "name" and will be skipped.'; return $false }
    if (-not $Plan.Source) { Write-Gum red "[$($Plan.Name)] missing `"source`""; return $false }
    if (-not $Plan.Destination) { Write-Gum red "[$($Plan.Name)] missing `"destination`""; return $false }

    if (-not (Test-Path -LiteralPath $Plan.Source -Type Container)) {
        Write-Gum red "[$($Plan.Name)] source not found: $($Plan.Source)"
        return $false
    }
    if (-not (Test-Path -LiteralPath $Plan.Destination -Type Container) `
        -and $Plan.Switches -notcontains '/CREATE') {
        Write-Gum yellow "[$($Plan.Name)] destination does not exist yet (robocopy will create it): $($Plan.Destination)"
    }
    try {
        if ($Plan.Logging -and -not (Test-Path -LiteralPath $Plan.LogDir)) {
            New-Item -ItemType Directory -Path $Plan.LogDir -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        Write-Gum red "[$($Plan.Name)] cannot create log folder '$($Plan.LogDir)': $($_.Exception.Message)"
        return $false
    }
    return $true
}

# Shared presentation map: keeps the per-job status line and the final summary
# in sync (badge, colour and the Write-Gum "kind" all live in one place).
$script:VerdictStyles = @{
    success = @{ Kind = 'green';  Badge = '✓ OK  '; Rgb = '42'  }
    warning = @{ Kind = 'yellow'; Badge = '! WARN'; Rgb = '214' }
    failed  = @{ Kind = 'red';    Badge = '✗ FAIL'; Rgb = '196' }
    default = @{ Kind = 'white';  Badge = '·     '; Rgb = '250' }
}

# ---------------------------------------------------------------------------
# robocopy execution
# ---------------------------------------------------------------------------

function Get-RobocopyVerdict {
    <#
        robocopy returns bit flags that can be combined:
        1 copied | 2 extra | 4 mismatched | 8 failing | 16 severe (bad drive/out of space)
        | 32 fatal | 64 cancelled. Success < 2, warning 2..7, failure >= 8.
    #>
    param([int]$Code)
    $msg = if ($Code -eq 0)          { 'everything already in sync' }
        elseif ($Code -band 64)      { 'the copy was cancelled' }
        elseif ($Code -band 32)      { 'a fatal error occurred (e.g. sharing violation)' }
        elseif ($Code -band 16)      { 'a serious error stopped the copy (bad drive or out of space)' }
        elseif ($Code -band 8)       { 'one or more files could not be copied' }
        elseif ($Code -band 4)       { 'mismatched files/dirs detected (checksum differences)' }
        elseif ($Code -band 2)       { 'extra files/dirs detected at destination' }
        elseif ($Code -band 1)       { 'files copied successfully' }
        else                         { "robocopy exit code $Code" }
    $class = if ($Code -ge 8) { 'failed' } elseif ($Code -ge 2) { 'warning' } else { 'success' }
    [pscustomobject]@{ Class = $class; Code = $Code; Message = $msg }
}

function Get-CopiedFileCount {
    <#
        Reads the "Files :" row of robocopy's summary table:
            Files :  <total>  <copied>  <skipped>  <mismatch>  <failed>  <extras>
        Anchoring on 'Files ... :' keeps the column header line ("Total Copied ...")
        out of the match. Horizontal whitespace only, so the ^ anchor cannot
        accidentally consume the newline before the matching line.
    #>
    param([AllowNull()][string]$LogContent)
    $m = [regex]::Match($LogContent, '(?m)^[ \t]*Files[ \t]*:[ \t]*(\d+)[ \t]+(\d+)')
    return [int]($m.Groups[2].Value ?? 0)
}

function Invoke-RobocopyJob {
    param([psobject]$Plan, [switch]$ShowCommand)

    # The copied-file count is parsed from robocopy's summary table ("Files :"
    # row), which is available from the /LOG file when logging is ON, or from
    # robocopy's captured stdout when logging is OFF. The log is preferred.
    # The log folder was already created and checked by Test-JobPlan.
    $logFile = $null
    if ($Plan.Logging) {
        $logFile = Join-Path $Plan.LogDir ('{0}-{1:yyyyMMdd-HHmmss}.log' -f $Plan.Name, (Get-Date))
    }

    $rcArgs = @(@($Plan.Source, $Plan.Destination) + $Plan.Switches)
    # @() wrappers: an empty array stored in a pscustomobject property comes back as $null
    if (@($Plan.ExcludeFile).Count) { $rcArgs = @($rcArgs + '/XF') + $Plan.ExcludeFile }
    if (@($Plan.ExcludeDir).Count)  { $rcArgs = @($rcArgs + '/XD') + $Plan.ExcludeDir }
    if ($logFile) { $rcArgs += "/LOG:$logFile" }

    if ($ShowCommand) { Write-Gum white ("[$($Plan.Name)] robocopy " + ($rcArgs -join ' ')) }

    $title = $Plan.Spinner -replace '\{job\}', $Plan.Name

    # Robocopy is launched directly (not wrapped by gum spin): with gum v2.0.2 a
    # wrapped robocopy fails to spawn reliably when our stdout is not a TTY.
    # gum spin also REQUIRES a child command — given none it prints usage and exits
    # immediately (code 80), so the old sibling call never showed a spinner at all.
    # It now wraps a tiny PowerShell waiter that follows robocopy's PID, so the
    # spinner lives exactly as long as the copy and exits on its own.
    # robocopy's stdout goes to a temp file that doubles as the summary source in
    # no-logging mode, so the temp files are only removed after we parse them.
    $outTmp = [IO.Path]::GetTempFileName(); $errTmp = [IO.Path]::GetTempFileName()
    $spinner = $null
    $code = 0
    try {
        $proc = Start-Process robocopy -ArgumentList (ConvertTo-ProcessArgument $rcArgs) `
            -NoNewWindow -PassThru -RedirectStandardOutput $outTmp -RedirectStandardError $errTmp
        # Spinner is cosmetic: skip it when stdout is redirected (CI/logs) so we
        # don't spray ANSI control codes into captured output.
        if (-not [Console]::IsOutputRedirected) {
            try {
                $waiter = 'Wait-Process -Id {0} -ErrorAction SilentlyContinue' -f $proc.Id
                $spinArgs = @('spin', '--spinner', 'dot', '--title', $title, '--',
                              'pwsh', '-NoProfile', '-Command', $waiter)
                $spinner = Start-Process gum -ArgumentList (ConvertTo-ProcessArgument $spinArgs) `
                    -PassThru -NoNewWindow
            } catch {
                # Never let the spinner break an otherwise valid job.
                $spinner = $null
            }
        }
        $proc.WaitForExit()
        $code = $proc.ExitCode
    } catch {
        Write-Gum red "[$($Plan.Name)] could not start robocopy: $($_.Exception.Message)"
        $code = 16
    } finally {
        if ($spinner) {
            if (-not $spinner.WaitForExit(2000)) {
                Stop-Process -Id $spinner.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $verdict = Get-RobocopyVerdict $code
    $summaryText = if ($logFile -and (Test-Path -LiteralPath $logFile)) {
        Get-Content -LiteralPath $logFile -Raw            # from the /LOG file
    } elseif (Test-Path -LiteralPath $outTmp) {
        Get-Content -LiteralPath $outTmp -Raw             # from captured stdout (logging off)
    } else { '' }
    $copied = Get-CopiedFileCount $summaryText
    Remove-Item $outTmp, $errTmp -Force -ErrorAction SilentlyContinue

    $label   = if ($Plan.Preset) { "$($Plan.Name) [$($Plan.Preset)]" } else { $Plan.Name }
    $logNote = if ($logFile) { $logFile } else { 'logging off' }
    $dry     = if ($Plan.DryRun) { ' [DRY RUN]' } else { '' }
    $text    = '{0}: {1} — copied {2} file(s), log: {3}{4}' -f $label, $verdict.Message, $copied, $logNote, $dry
    $style   = $script:VerdictStyles[$verdict.Class] ?? $script:VerdictStyles['default']
    Write-Gum $style.Kind $text

    [pscustomobject]@{
        Name = $Plan.Name; Label = $label; Verdict = $verdict
        Copied = $copied; Log = $logNote; DryRun = $Plan.DryRun
    }
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

try {
    if (-not (Get-Command gum -ErrorAction SilentlyContinue)) {
        Write-Gum red 'gum not found on PATH. Install it with: winget install Charm.Charm-gum  (or: scoop install gum)'
        exit 2
    }
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Gum red "Config file not found: $ConfigPath"
        exit 2
    }

    $ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    $ConfigDir  = Split-Path -Parent $ConfigPath
    $config     = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

    if (Get-Prop $config 'defaults') {
        Write-Gum yellow 'Config key "defaults" is no longer used — move its settings into a preset or the jobs.'
    }

    $plans = @(ConvertTo-JobPlan -Config $config -ConfigDir $ConfigDir -DryRun:$DryRun)
    if ($plans.Count -eq 0) {
        Write-Gum red 'No enabled jobs found in the configuration.'
        exit 2
    }

    Write-Header -Title 'ROBOCOPY ORCHESTRATOR' -Subtitle "config: $ConfigPath"
    if ($DryRun) { Write-Gum yellow 'Dry run (/L) enabled — no files will be changed.' }

    # --- choose which jobs to run ------------------------------------------
    $selected =
        if ($Job) {
            $hit = @($plans | Where-Object Name -eq $Job)
            if ($hit.Count -eq 0) {
                Write-Gum red "Unknown job '$Job'. Available: $($plans.Name -join ', ')"
                exit 2
            }
            $hit
        } elseif ($All) {
            Write-Gum white "Running all $($plans.Count) enabled job(s)."
            $plans
        } elseif (-not [Environment]::UserInteractive) {
            Write-Gum white 'Non-interactive session — running every enabled job.'
            $plans
        } else {
            Select-Jobs -Plans $plans
        }

    if (-not $selected -or @($selected).Count -eq 0) {
        Write-Gum yellow 'Nothing selected — exiting.'
        exit 0
    }
    $selected = @($selected)

    # --- validate -----------------------------------------------------------
    $runnable = @($selected | Where-Object { Test-JobPlan $_ })
    if ($runnable.Count -eq 0) {
        Write-Gum red 'No job passed validation — aborting.'
        exit 1
    }

    # --- run ----------------------------------------------------------------
    $results = foreach ($plan in $runnable) { Invoke-RobocopyJob $plan -ShowCommand:$ShowCommand }

    # --- summary ------------------------------------------------------------
    Write-Gum white ''
    gum style --bold --foreground 212 --underline -- 'SUMMARY'
    foreach ($r in @($results)) {
        $style = $script:VerdictStyles[$r.Verdict.Class] ?? $script:VerdictStyles['default']
        $dry   = $r.DryRun ? ' [DRY RUN]' : ''
        $line  = '{0}  {1,-22} copied {2,6} file(s)   exit {3,-3} {4}{5}' -f $style.Badge, $r.Label, $r.Copied, $r.Verdict.Code, $r.Log, $dry
        gum style --foreground $style.Rgb -- $line | Out-Host
    }

    $hasFailure = [bool]($results | Where-Object { $_.Verdict.Class -eq 'failed' })
    Write-Gum ($hasFailure ? 'red' : 'green') ($hasFailure `
        ? 'Finished with errors — check the logs above.' `
        : 'Finished. Sync completed.')

    $maxExit = ($results.Verdict.Code | Measure-Object -Maximum).Maximum
    exit $maxExit
} catch {
    Write-Gum red "Unexpected error: $($_.Exception.Message)"
    if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
        Write-Gum white ("at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim())
    }
    Write-Debug $_.ScriptStackTrace
    exit 1
}
