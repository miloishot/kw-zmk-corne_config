#Requires -Version 7.0
<#
.SYNOPSIS
    Download the latest CI-built firmware and flash it to the Eyelash Corne.

.DESCRIPTION
    Replaces the manual loop of: open GitHub Actions, find the run, download
    firmware.zip, unzip it, double-tap reset, drag the right .uf2 onto the
    drive, repeat for the other half.

    Downloads are cached per run id under $env:TEMP\kw-corne-fw, so flashing
    the second half does not re-download.

    Only ever writes to a volume whose label is exactly NICENANO. It never
    takes a drive letter, so it cannot be pointed at the wrong disk.

.PARAMETER Target
    Which firmware to flash, in order. Defaults to left then right.
      left    plain left (central) half
      right   right (peripheral) half
      studio  left half with ZMK Studio over USB -- flash instead of 'left'
      reset   settings_reset, clears BLE pairings. Flash to BOTH halves.

.PARAMETER Branch
    Branch whose latest successful build to pull. Default: main.

.PARAMETER RunId
    Flash a specific workflow run instead of the latest successful one.

.PARAMETER DownloadOnly
    Fetch and resolve the .uf2 paths, then stop. Touches no drive.

.PARAMETER Yes
    Skip the per-half confirmation prompt.

.EXAMPLE
    .\scripts\flash.ps1
    Flash the latest left + right builds.

.EXAMPLE
    .\scripts\flash.ps1 -Target studio, right
    Flash the Studio-enabled left half, then the right half.

.EXAMPLE
    .\scripts\flash.ps1 -Target reset
    Clear pairings. Run it once per half.
#>
[CmdletBinding()]
param(
    [ValidateSet('left', 'right', 'studio', 'reset')]
    [string[]]$Target = @('left', 'right'),

    [string]$Branch = 'main',

    [long]$RunId,

    [switch]$DownloadOnly,

    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

$WorkflowName = 'Build ZMK firmware'
$ArtifactName = 'firmware'
$VolumeLabel = 'NICENANO'

# Each entry: a glob to find the .uf2, and globs to exclude. 'left' has to
# exclude studio, otherwise '*left*' matches eyelash_corne_studio_left.uf2 too.
$Patterns = @{
    left   = @{ Include = '*left*.uf2'; Exclude = @('*studio*') }
    right  = @{ Include = '*right*.uf2'; Exclude = @() }
    studio = @{ Include = '*studio*.uf2'; Exclude = @() }
    reset  = @{ Include = '*settings_reset*.uf2'; Exclude = @() }
}

function Resolve-Repo {
    $url = git -C $PSScriptRoot/.. remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $url) {
        throw "Not a git repo with an 'origin' remote. Run this from inside the config repo."
    }
    if ($url -notmatch 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/.]+)') {
        throw "Could not parse a GitHub owner/repo out of origin: $url"
    }
    "$($Matches.owner)/$($Matches.repo)"
}

function Get-FirmwareDir {
    param([string]$Repo)

    if (-not $RunId) {
        Write-Host "Finding the latest successful '$WorkflowName' run on $Branch..."
        # Quoted: an unquoted comma list is parsed by PowerShell as an array and
        # arrives at gh as three separate arguments.
        $json = gh run list -R $Repo -b $Branch -w $WorkflowName --status success `
            --limit 1 --json 'databaseId,displayTitle,createdAt'
        if ($LASTEXITCODE -ne 0) { throw "gh run list failed. Is gh installed and authenticated? Try: gh auth status" }

        $run = $json | ConvertFrom-Json | Select-Object -First 1
        if (-not $run) { throw "No successful '$WorkflowName' run found on branch '$Branch'." }

        $script:RunId = $run.databaseId
        Write-Host "  run $($run.databaseId) -- $($run.displayTitle) ($($run.createdAt))"
    }

    $dir = Join-Path $env:TEMP "kw-corne-fw\$RunId"

    if ((Test-Path $dir) -and (Get-ChildItem $dir -Filter *.uf2 -Recurse -File)) {
        Write-Host "Using cached download: $dir"
        return $dir
    }

    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Write-Host "Downloading '$ArtifactName' artifact..."
    gh run download $RunId -R $Repo -n $ArtifactName -D $dir
    if ($LASTEXITCODE -ne 0) { throw "gh run download failed for run $RunId." }

    $dir
}

function Resolve-Uf2 {
    param([string]$Dir, [string]$Name)

    $p = $Patterns[$Name]
    $hits = @(Get-ChildItem $Dir -Filter $p.Include -Recurse -File |
        Where-Object { $f = $_.Name; -not ($p.Exclude | Where-Object { $f -like $_ }) })

    if ($hits.Count -eq 0) {
        $have = (Get-ChildItem $Dir -Filter *.uf2 -Recurse -File).Name -join ', '
        throw "No .uf2 matching '$($p.Include)' for target '$Name'. Artifact contains: $have"
    }
    if ($hits.Count -gt 1) {
        throw "Ambiguous match for target '$Name': $(($hits.Name) -join ', ')"
    }
    $hits[0]
}

function Wait-NiceNano {
    param([int]$TimeoutSeconds = 120)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $v = Get-Volume -FileSystemLabel $VolumeLabel -ErrorAction SilentlyContinue |
            Where-Object DriveLetter | Select-Object -First 1
        if ($v) { return "$($v.DriveLetter):\" }
        Start-Sleep -Milliseconds 500
    }
    $null
}

function Wait-NiceNanoGone {
    param([int]$TimeoutSeconds = 30)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $v = Get-Volume -FileSystemLabel $VolumeLabel -ErrorAction SilentlyContinue |
            Where-Object DriveLetter | Select-Object -First 1
        if (-not $v) { return $true }
        Start-Sleep -Milliseconds 500
    }
    $false
}

function Invoke-Flash {
    param([System.IO.FileInfo]$Uf2, [string]$Name)

    Write-Host ""
    Write-Host "=== $Name ===" -ForegroundColor Cyan
    Write-Host "  $($Uf2.Name)  ($([math]::Round($Uf2.Length / 1KB))KB)"

    # If a previous flash left the drive mounted, wait for it to clear first --
    # otherwise we would write this half's firmware to the previous half.
    if (Get-Volume -FileSystemLabel $VolumeLabel -ErrorAction SilentlyContinue) {
        Write-Host "  A $VolumeLabel drive is still mounted from the last step. Waiting for it to eject..."
        if (-not (Wait-NiceNanoGone -TimeoutSeconds 30)) {
            throw "A $VolumeLabel volume is still mounted. Unplug it, then re-run for '$Name' only."
        }
    }

    Write-Host "  Double-tap the reset button on the $Name half now..." -ForegroundColor Yellow
    $drive = Wait-NiceNano -TimeoutSeconds 120
    if (-not $drive) { throw "No $VolumeLabel volume appeared within 120s. Double-tap reset and try again." }

    $info = Join-Path $drive 'INFO_UF2.TXT'
    $model = if (Test-Path $info) {
        (Get-Content $info -ErrorAction SilentlyContinue | Select-String '^Model:' | Select-Object -First 1).Line
    }
    if ($model) { Write-Host "  Found $drive -- $($model.Trim())" } else { Write-Host "  Found $drive" }

    if (-not $Yes) {
        $answer = Read-Host "  Write $($Uf2.Name) to $drive ? [y/N]"
        if ($answer -notmatch '^(y|yes)$') {
            Write-Host "  Skipped." -ForegroundColor DarkGray
            return
        }
    }

    try {
        Copy-Item -LiteralPath $Uf2.FullName -Destination $drive -Force
    }
    catch {
        # A UF2 bootloader reboots the moment it has the whole file, so the
        # volume can vanish mid-copy. Gone == flashed; still there == real error.
        Start-Sleep -Milliseconds 1500
        if (Get-Volume -FileSystemLabel $VolumeLabel -ErrorAction SilentlyContinue) {
            throw "Copy to $drive failed and the drive is still mounted: $($_.Exception.Message)"
        }
    }

    if (Wait-NiceNanoGone -TimeoutSeconds 30) {
        Write-Host "  Flashed. Drive ejected itself." -ForegroundColor Green
    }
    else {
        Write-Warning "  Copy finished but $drive did not eject. It may not have taken -- check the half before flashing the next one."
    }
}

# --- main ---

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "gh not found on PATH. Install the GitHub CLI, or add it: `$env:PATH = `"`$env:USERPROFILE\tools\gh\bin;`$env:PATH`""
}

$repo = Resolve-Repo
Write-Host "Repo: $repo"

$dir = Get-FirmwareDir -Repo $repo
$resolved = foreach ($t in $Target) { [pscustomobject]@{ Name = $t; File = (Resolve-Uf2 -Dir $dir -Name $t) } }

if ($DownloadOnly) {
    Write-Host ""
    Write-Host "Resolved (no drive touched):"
    $resolved | ForEach-Object { Write-Host "  $($_.Name.PadRight(7)) -> $($_.File.FullName)" }
    return
}

foreach ($r in $resolved) { Invoke-Flash -Uf2 $r.File -Name $r.Name }

Write-Host ""
Write-Host "Done. Firmware from run $RunId." -ForegroundColor Green
