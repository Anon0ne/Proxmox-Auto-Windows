<#
.SYNOPSIS
    Builds an unattended Proxmox VE installer ISO with an embedded answer file,
    ready to be written to USB with Rufus (DD mode) or used in a VM.

.DESCRIPTION
    Reproduces what Proxmox's own `proxmox-auto-install-assistant prepare-iso
    --fetch-from iso` does, but from Windows:

      1. Reads the ISO's version (/.cd-info) and checks it is auto-install capable (8.2+).
      2. Builds answer.toml from a JSON config, an existing answer.toml, or an interactive wizard.
         Key spelling is matched to the ISO (snake_case before 8.4, kebab-case from 8.4).
         The root password is stored as a SHA-512 crypt hash on 8.3+ ISOs.
      3. Copies the ISO and appends /answer.toml, /auto-installer-mode.toml (and optionally
         /proxmox-first-boot) with xorriso, keeping the boot images and the original volume UUID
         so the hybrid USB/UEFI/BIOS boot still works.
      4. Re-reads the new ISO to verify the embedded files and UUID.

    xorriso runs in a small Docker container (built once, "proxmox-autoiso-tools") or in a WSL
    distro that has xorriso + openssl installed.

.PARAMETER IsoPath
    The stock Proxmox VE ISO (8.2 or newer). It is never modified.

.PARAMETER OutputPath
    Where to write the new ISO. Default: <input name>-auto.iso next to the input.

.PARAMETER Config
    JSON file describing the answer file (see example-config.json). Without -Config or
    -AnswerFile an interactive wizard runs and saves its answers as JSON for reuse.

.PARAMETER AnswerFile
    An existing answer.toml to embed exactly as-is (only basic checks are done).

.PARAMETER FirstBootScript
    Optional script/binary (max 1 MiB, needs a shebang) run once on first boot (8.3+).
    Adds [first-boot] source = "from-iso" to the answer file if not already configured.

.PARAMETER Backend
    Auto (default: Docker if running, else WSL), Docker, or WSL.

.PARAMETER WslDistro
    WSL distro to use with -Backend WSL. Default: first distro that has xorriso.

.PARAMETER KeyStyle
    Auto (default, from ISO version), Kebab, or Snake.

.PARAMETER AnswerOnly
    Only generate answer.toml (next to the output path); don't build the ISO.

.PARAMETER PlainPassword
    Keep a plaintext root-password instead of hashing it.

.PARAMETER Force
    Overwrite the output files if they exist.

.EXAMPLE
    .\New-ProxmoxAutoIso.ps1 -IsoPath C:\ISO\proxmox-ve_9.0-1.iso
    Runs the wizard, then builds C:\ISO\proxmox-ve_9.0-1-auto.iso

.EXAMPLE
    .\New-ProxmoxAutoIso.ps1 -IsoPath .\proxmox-ve.iso -Config .\pve01.json -OutputPath .\pve01.iso
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$IsoPath,
    [string]$OutputPath,
    [string]$Config,
    [string]$AnswerFile,
    [string]$FirstBootScript,
    [ValidateSet('Auto', 'Docker', 'WSL')][string]$Backend = 'Auto',
    [string]$WslDistro,
    [ValidateSet('Auto', 'Kebab', 'Snake')][string]$KeyStyle = 'Auto',
    [switch]$AnswerOnly,
    [switch]$PlainPassword,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$DockerImage = 'proxmox-autoiso-tools:1'
$script:WorkDir = $null
$script:Mounts = @()
$script:DockerReady = $null
$Keyboards = @('de', 'de-ch', 'dk', 'en-gb', 'en-us', 'es', 'fi', 'fr', 'fr-be', 'fr-ca', 'fr-ch', 'hu', 'is', 'it',
    'jp', 'lt', 'mk', 'nl', 'no', 'pl', 'pt', 'pt-br', 'se', 'si', 'tr')
$ZfsRaids = @('raid0', 'raid1', 'raid10', 'raidz-1', 'raidz-2', 'raidz-3')
$BtrfsRaids = @('raid0', 'raid1', 'raid10')
# Tables whose keys are udev properties / MAC addresses and must never be renamed.
$RawKeyTables = @('filter', 'mapping')

# Runs inside the container / WSL. Kept tiny: everything else is done in PowerShell.
$HelperScript = @'
#!/usr/bin/env bash
set -euo pipefail
cmd="$1"; shift
case "$cmd" in
  check)
    command -v xorriso >/dev/null && command -v openssl >/dev/null && echo OK ;;
  info)
    iso="$1"; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    xorriso -osirrox on -indev "$iso" -extract /.cd-info "$tmp/cd-info" >/dev/null 2>&1 || true
    [ -f "$tmp/cd-info" ] && sed 's/^/CDINFO:/' "$tmp/cd-info"
    listing="$(xorriso -indev "$iso" -ls / 2>/dev/null || true)"
    if grep -q "auto-installer-capable" <<<"$listing"; then echo "CAPABLE=1"; else echo "CAPABLE=0"; fi
    if grep -q "'answer.toml'" <<<"$listing"; then echo "HAS_ANSWER=1"; else echo "HAS_ANSWER=0"; fi
    uuid="$(xorriso -indev "$iso" -report_system_area cmd 2>/dev/null | grep '^-volume_date uuid' | head -n1 | awk '{print $NF}' | tr -d "'")" || true
    echo "UUID=${uuid:-}" ;;
  hash)
    printf '%s' "$PVE_AUTOISO_PW" | openssl passwd -6 -stdin ;;
  inject)
    iso="$1"; uuid="$2"; shift 2
    args=(-boot_image any keep)
    [ -n "$uuid" ] && args+=(-volume_date uuid "$uuid")
    args+=(-dev "$iso")
    while [ $# -ge 2 ]; do args+=(-map "$1" "$2"); shift 2; done
    xorriso "${args[@]}" 2>&1 ;;
  extract)
    xorriso -osirrox on -indev "$1" -extract "$2" "$3" >/dev/null 2>&1 ;;
  *) echo "unknown command $cmd" >&2; exit 2 ;;
esac
'@

#region helpers ---------------------------------------------------------------

function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Note([string]$Text) { Write-Host "    $Text" -ForegroundColor DarkGray }

function Write-Utf8File([string]$Path, [string]$Text) {
    # LF line endings, no BOM: the installer's TOML parser is strict.
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
}

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments, [switch]$AllowFail)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>&1 | ForEach-Object { ("$_" -replace "`0", '') }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    if ($code -ne 0 -and -not $AllowFail) {
        throw "'$Exe $($Arguments -join ' ')' failed (exit $code):`n$(@($out) -join "`n")"
    }
    [pscustomobject]@{ ExitCode = $code; Output = @($out) }
}

function Test-DockerReady {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    if ($null -ne $script:DockerReady) { return $script:DockerReady }
    # A wedged Docker Desktop can make `docker info` hang forever, so give it 20 seconds.
    $p = Start-Process docker -ArgumentList 'info', '--format', '{{.ServerVersion}}' -NoNewWindow -PassThru `
        -RedirectStandardOutput ([IO.Path]::GetTempFileName()) -RedirectStandardError ([IO.Path]::GetTempFileName())
    $null = $p.Handle  # without this, ExitCode stays $null for Start-Process -PassThru
    if (-not $p.WaitForExit(20000)) {
        try { $p.Kill() } catch {}
        Write-Warning 'Docker is not responding (docker info timed out).'
        $script:DockerReady = $false
    } else { $script:DockerReady = ($p.ExitCode -eq 0) }
    $script:DockerReady
}

function Find-WslDistro {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $null }
    $names = (Invoke-Native wsl.exe @('-l', '-q') -AllowFail).Output |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^(docker-desktop|podman)' }
    if ($WslDistro) { $names = @($WslDistro) }
    foreach ($n in $names) {
        $r = Invoke-Native wsl.exe @('-d', $n, '-e', 'sh', '-c', 'command -v xorriso >/dev/null && command -v openssl >/dev/null && echo OK') -AllowFail
        if ($r.Output -contains 'OK') { return $n }
    }
    return $null
}

function Initialize-Backend {
    $script:WorkDir = Join-Path ([IO.Path]::GetTempPath()) ("pve-autoiso-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:WorkDir | Out-Null
    Write-Utf8File (Join-Path $script:WorkDir 'helper.sh') $HelperScript

    $useDocker = $false
    if ($Backend -eq 'Docker') { $useDocker = $true }
    elseif ($Backend -eq 'Auto' -and (Test-DockerReady)) { $useDocker = $true }

    if ($useDocker) {
        if (-not (Test-DockerReady)) { throw 'Docker is not running. Start Docker Desktop or use -Backend WSL.' }
        $script:BackendKind = 'Docker'
        if ((Invoke-Native docker @('image', 'inspect', $DockerImage) -AllowFail).ExitCode -ne 0) {
            Write-Step "Building helper image $DockerImage (one time, ~1 minute)"
            $df = Join-Path $script:WorkDir 'Dockerfile'
            Write-Utf8File $df "FROM debian:trixie-slim`nRUN apt-get update && apt-get install -y --no-install-recommends xorriso openssl && rm -rf /var/lib/apt/lists/*`n"
            Invoke-Native docker @('build', '-t', $DockerImage, '-f', $df, $script:WorkDir) | Out-Null
        }
        $script:Mounts = @()
        Write-Note 'Using Docker backend'
    } else {
        $d = Find-WslDistro
        if (-not $d) {
            throw ("No usable backend. Either start Docker Desktop, or install the tools in WSL:`n" +
                "    wsl -d Ubuntu -- sudo apt-get install -y xorriso openssl")
        }
        $script:BackendKind = 'WSL'
        $script:Distro = $d
        Write-Note "Using WSL backend ($d)"
    }
}

function Add-Mount([string]$HostDir, [string]$ContainerDir, [switch]$ReadOnly) {
    if ($script:BackendKind -ne 'Docker') { return }
    $script:Mounts += [pscustomobject]@{ Host = $HostDir.TrimEnd('\'); Container = $ContainerDir; ReadOnly = [bool]$ReadOnly }
}

function Get-BackendPath([string]$HostPath) {
    $full = [IO.Path]::GetFullPath($HostPath)
    if ($script:BackendKind -eq 'Docker') {
        $dir = [IO.Path]::GetDirectoryName($full).TrimEnd('\')
        # prefer a writable mount when the same folder is mounted twice (input dir = output dir)
        $m = @($script:Mounts | Where-Object { $_.Host -ieq $dir } | Sort-Object ReadOnly) | Select-Object -First 1
        if (-not $m) { throw "Internal error: no mount for $dir" }
        return "$($m.Container)/$([IO.Path]::GetFileName($full))"
    }
    (Invoke-Native wsl.exe @('-d', $script:Distro, '-e', 'wslpath', '-a', $full)).Output[0].Trim()
}

function Invoke-Helper {
    param([string[]]$HelperArgs, [hashtable]$EnvVars = @{}, [switch]$AllowFail)
    foreach ($k in $EnvVars.Keys) { Set-Item -Path "env:$k" -Value $EnvVars[$k] }
    try {
        if ($script:BackendKind -eq 'Docker') {
            $a = @('run', '--rm', '-v', "$($script:WorkDir):/work")
            foreach ($m in $script:Mounts) {
                $suffix = ''
                if ($m.ReadOnly) { $suffix = ':ro' }
                $a += @('-v', "$($m.Host):$($m.Container)$suffix")
            }
            foreach ($k in $EnvVars.Keys) { $a += @('-e', $k) }
            $a += @($DockerImage, 'bash', '/work/helper.sh') + $HelperArgs
            return Invoke-Native docker $a -AllowFail:$AllowFail
        }
        $prevWslEnv = $env:WSLENV
        if ($EnvVars.Count) { $env:WSLENV = (@($EnvVars.Keys | ForEach-Object { "$_/u" }) + @($prevWslEnv) | Where-Object { $_ }) -join ':' }
        try {
            $helper = Get-BackendPath (Join-Path $script:WorkDir 'helper.sh')
            return Invoke-Native wsl.exe (@('-d', $script:Distro, '-e', 'bash', $helper) + $HelperArgs) -AllowFail:$AllowFail
        } finally { $env:WSLENV = $prevWslEnv }
    } finally {
        foreach ($k in $EnvVars.Keys) { Remove-Item -Path "env:$k" -ErrorAction SilentlyContinue }
    }
}

function Get-IsoInfo([string]$Path) {
    $r = Invoke-Helper @('info', (Get-BackendPath $Path))
    $info = [ordered]@{ Product = ''; ProductLong = ''; Release = ''; IsoRelease = ''; Capable = $false; HasAnswer = $false; Uuid = '' }
    foreach ($line in $r.Output) {
        if ($line -match "^CDINFO:(\w+)='?([^']*)'?\s*$") {
            switch ($Matches[1]) {
                'PRODUCT' { $info.Product = $Matches[2] }
                'PRODUCTLONG' { $info.ProductLong = $Matches[2] }
                'RELEASE' { $info.Release = $Matches[2] }
                'ISORELEASE' { $info.IsoRelease = $Matches[2] }
            }
        } elseif ($line -match '^CAPABLE=(\d)') { $info.Capable = $Matches[1] -eq '1' }
        elseif ($line -match '^HAS_ANSWER=(\d)') { $info.HasAnswer = $Matches[1] -eq '1' }
        elseif ($line -match '^UUID=(.*)$') { $info.Uuid = $Matches[1].Trim() }
    }
    # Fall back to the file name (proxmox-ve_8.4-1.iso) when .cd-info is missing a field.
    if (-not $info.Release -and ([IO.Path]::GetFileName($Path) -match '_(\d+\.\d+)-(\d+)')) {
        $info.Release = $Matches[1]; $info.IsoRelease = $Matches[2]
    }
    [pscustomobject]$info
}

function Get-HashedPassword([string]$Plain) {
    $r = Invoke-Helper @('hash') -EnvVars @{ PVE_AUTOISO_PW = $Plain }
    $h = @($r.Output | Where-Object { $_ -like '$6$*' }) | Select-Object -First 1
    if (-not $h) { throw "Password hashing failed: $($r.Output -join ' ')" }
    $h.Trim()
}

#endregion
#region answer model ----------------------------------------------------------

# JSON objects -> ordered dictionaries; keys normalised to kebab-case (except raw tables);
# keys starting with "_" are treated as comments and dropped.
function ConvertTo-AnswerModel($Node, [bool]$Raw = $false) {
    if ($Node -is [Management.Automation.PSCustomObject]) {
        $d = [ordered]@{}
        foreach ($p in $Node.PSObject.Properties) {
            if ($p.Name.StartsWith('_')) { continue }
            $key = $p.Name
            if (-not $Raw) { $key = $key -replace '_', '-' }
            $d[$key] = ConvertTo-AnswerModel $p.Value ($RawKeyTables -contains $key)
        }
        return $d
    }
    if ($Node -is [Array]) { return , @($Node | ForEach-Object { ConvertTo-AnswerModel $_ $Raw }) }
    return $Node
}

function Format-TomlKey([string]$Key, [bool]$Raw, [string]$Style) {
    if (-not $Raw -and $Style -eq 'Snake') { $Key = $Key -replace '-', '_' }
    if ($Key -match '^[A-Za-z0-9_-]+$') { return $Key }
    '"' + ($Key -replace '\\', '\\' -replace '"', '\"') + '"'
}

function Format-TomlValue($Value) {
    if ($Value -is [bool]) { if ($Value) { return 'true' } return 'false' }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $Value)
    }
    if ($Value -is [Array]) { return '[' + ((@($Value) | ForEach-Object { Format-TomlValue $_ }) -join ', ') + ']' }
    $s = [string]$Value
    $s = $s -replace '\\', '\\' -replace '"', '\"' -replace "`t", '\t' -replace "`n", '\n' -replace "`r", '\r'
    '"' + $s + '"'
}

# Top-level dictionaries become [sections]; anything deeper becomes dotted keys
# (zfs.raid = "raid1"), matching the style of the Proxmox documentation.
function ConvertTo-Toml($Model, [string]$Style) {
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('# Proxmox automated installer answer file')
    $lines.Add("# Generated by New-ProxmoxAutoIso.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    foreach ($section in $Model.Keys) {
        $lines.Add('')
        $lines.Add("[$section]")
        Add-TomlKeys $lines $Model[$section] '' $false $Style
    }
    ($lines -join "`n") + "`n"
}

function Add-TomlKeys($Lines, $Table, [string]$Prefix, [bool]$Raw, [string]$Style) {
    foreach ($k in $Table.Keys) {
        $v = $Table[$k]
        $name = $Prefix + (Format-TomlKey $k $Raw $Style)
        if ($v -is [Collections.IDictionary]) {
            Add-TomlKeys $Lines $v "$name." ($Raw -or ($RawKeyTables -contains $k)) $Style
        } elseif ($null -ne $v) {
            $Lines.Add("$name = $(Format-TomlValue $v)")
        }
    }
}

function Get-Item2($Table, [string]$Key) {
    # leading comma: keep a one-element array an array instead of letting PowerShell unroll it
    if ($Key -and $Table -is [Collections.IDictionary] -and $Table.Contains($Key)) { return , $Table[$Key] }
    return $null
}

function Test-AnswerModel($Model, [version]$Ver) {
    $errors = New-Object Collections.Generic.List[string]
    $warnings = New-Object Collections.Generic.List[string]
    $g = Get-Item2 $Model 'global'
    $n = Get-Item2 $Model 'network'
    $d = Get-Item2 $Model 'disk-setup'
    if (-not $g) { $errors.Add('[global] section is missing') }
    if (-not $n) { $errors.Add('[network] section is missing') }
    if (-not $d) { $errors.Add('[disk-setup] section is missing') }

    if ($g) {
        foreach ($k in 'keyboard', 'country', 'fqdn', 'mailto', 'timezone') {
            if (-not (Get-Item2 $g $k)) { $errors.Add("global.$k is required") }
        }
        $kb = Get-Item2 $g 'keyboard'
        if ($kb -and $Keyboards -notcontains $kb) { $errors.Add("global.keyboard '$kb' is not one of: $($Keyboards -join ', ')") }
        $c = Get-Item2 $g 'country'
        if ($c -and $c -notmatch '^[a-z]{2}$') { $errors.Add("global.country must be a 2-letter lowercase code (e.g. 'us'), got '$c'") }
        $f = Get-Item2 $g 'fqdn'
        if ($f -is [string] -and $f -notmatch '^(?=.{1,253}$)([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z0-9-]{2,63}$') {
            $errors.Add("global.fqdn '$f' is not a valid FQDN (needs host.domain)")
        }
        if ($f -is [Collections.IDictionary] -and $Ver -lt [version]'8.4') { $errors.Add('fqdn from DHCP needs an 8.4+ ISO') }
        $m = Get-Item2 $g 'mailto'
        if ($m -and $m -notmatch '^[^@\s]+@[^@\s]+$') { $errors.Add("global.mailto '$m' is not an e-mail address") }
        $pw = Get-Item2 $g 'root-password'; $pwh = Get-Item2 $g 'root-password-hashed'
        if ([bool]$pw -eq [bool]$pwh) { $errors.Add('set exactly one of global.root-password / global.root-password-hashed') }
        if ($pw -and $pw.Length -lt 5) { $errors.Add('root password must be at least 5 characters') }
        if ($pwh -and $Ver -lt [version]'8.3') { $errors.Add('root-password-hashed needs an 8.3+ ISO') }
        if ((Get-Item2 $g 'reboot-mode') -and $Ver -lt [version]'8.4') { $errors.Add('reboot-mode needs an 8.4+ ISO') }
        if ((Get-Item2 $g 'subscription-key') -and $Ver -lt [version]'9.2') { $errors.Add('subscription-key needs a 9.2+ ISO') }
        $keys = Get-Item2 $g 'root-ssh-keys'
        if ($null -ne $keys -and $keys -isnot [Array]) { $errors.Add('global.root-ssh-keys must be a list') }
    }

    if ($n) {
        $src = Get-Item2 $n 'source'
        if ($src -eq 'from-dhcp') {
            foreach ($k in 'cidr', 'gateway', 'dns', 'filter') { if ($n.Contains($k)) { $errors.Add("network.$k must not be set with source = from-dhcp") } }
        } elseif ($src -eq 'from-answer') {
            foreach ($k in 'cidr', 'gateway', 'dns', 'filter') { if (-not $n.Contains($k)) { $errors.Add("network.$k is required with source = from-answer") } }
            $cidr = Get-Item2 $n 'cidr'
            if ($cidr -and $cidr -notmatch '^[0-9a-fA-F:.]+/\d{1,3}$') { $errors.Add("network.cidr '$cidr' should look like 192.168.1.10/24") }
        } else { $errors.Add("network.source must be 'from-dhcp' or 'from-answer'") }
        if ((Get-Item2 $n 'interface-name-pinning') -and $Ver -lt [version]'9.1') { $errors.Add('interface-name-pinning needs a 9.1+ ISO') }
    }

    if ($d) {
        $fs = Get-Item2 $d 'filesystem'
        if (@('ext4', 'xfs', 'zfs', 'btrfs') -notcontains $fs) { $errors.Add("disk-setup.filesystem must be ext4, xfs, zfs or btrfs") }
        $list = Get-Item2 $d 'disk-list'; $filter = Get-Item2 $d 'filter'
        if ([bool]$list -eq [bool]$filter) { $errors.Add('set exactly one of disk-setup.disk-list / disk-setup.filter') }
        if ($list -and $list -isnot [Array]) { $errors.Add('disk-setup.disk-list must be a list, e.g. ["sda"]') }
        foreach ($opt in 'zfs', 'lvm', 'btrfs') {
            if ($d.Contains($opt)) {
                $ok = ($opt -eq 'zfs' -and $fs -eq 'zfs') -or ($opt -eq 'btrfs' -and $fs -eq 'btrfs') -or ($opt -eq 'lvm' -and @('ext4', 'xfs') -contains $fs)
                if (-not $ok) { $errors.Add("disk-setup.$opt options don't apply to filesystem '$fs'") }
            }
        }
        $raid = Get-Item2 (Get-Item2 $d $fs) 'raid'
        if ($fs -eq 'zfs' -and $ZfsRaids -notcontains $raid) { $errors.Add("disk-setup.zfs.raid must be one of: $($ZfsRaids -join ', ')") }
        if ($fs -eq 'btrfs' -and $BtrfsRaids -notcontains $raid) { $errors.Add("disk-setup.btrfs.raid must be one of: $($BtrfsRaids -join ', ')") }
        if ($list -is [Array]) {
            $cnt = $list.Count
            $min = @{ 'raid1' = 2; 'raid10' = 4; 'raidz-1' = 3; 'raidz-2' = 4; 'raidz-3' = 5 }
            if ($raid -and $min.ContainsKey($raid) -and $cnt -lt $min[$raid]) { $errors.Add("$raid needs at least $($min[$raid]) disks, disk-list has $cnt") }
            if ($raid -eq 'raid10' -and $cnt % 2) { $errors.Add('raid10 needs an even number of disks') }
            if (@('ext4', 'xfs') -contains $fs -and $cnt -gt 1) { $warnings.Add("$fs installs to a single disk; only '$($list[0])' will be used") }
            foreach ($disk in $list) { if ($disk -match '^/dev/') { $errors.Add("disk-list entries are bare names like 'sda' or 'nvme0n1', not '$disk'") } }
        }
    }

    if ((Get-Item2 $Model 'first-boot') -and $Ver -lt [version]'8.3') { $errors.Add('[first-boot] needs an 8.3+ ISO') }
    if ((Get-Item2 $Model 'post-installation-webhook') -and $Ver -lt [version]'8.3') { $errors.Add('[post-installation-webhook] needs an 8.3+ ISO') }
    [pscustomobject]@{ Errors = $errors; Warnings = $warnings }
}

#endregion
#region wizard ----------------------------------------------------------------

function Read-Value([string]$Prompt, [string]$Default = '', [scriptblock]$Validate = $null, [switch]$AllowEmpty) {
    while ($true) {
        $label = $Prompt
        if ($Default) { $label += " [$Default]" }
        $v = (Read-Host $label).Trim()
        if (-not $v) { $v = $Default }
        if (-not $v -and $AllowEmpty) { return '' }
        if (-not $v) { Write-Host '    A value is required.' -ForegroundColor Yellow; continue }
        if ($Validate) {
            $msg = & $Validate $v
            if ($msg) { Write-Host "    $msg" -ForegroundColor Yellow; continue }
        }
        return $v
    }
}

function Read-Choice([string]$Prompt, [string[]]$Choices, [string]$Default) {
    Read-Value "$Prompt ($($Choices -join '/'))" $Default { param($v) if ($Choices -notcontains $v) { "Choose one of: $($Choices -join ', ')" } }
}

function Read-Password {
    while ($true) {
        if ([Console]::IsInputRedirected) {
            # -AsSecureString only reads the keyboard; accept piped answers for scripted runs
            $pa = Read-Host 'Root password'; $pb = Read-Host 'Confirm root password'
            if ($pa -ne $pb) { throw 'Passwords do not match.' }
            if ($pa.Length -lt 8) { throw 'Use at least 8 characters.' }
            return $pa
        }
        $a = Read-Host 'Root password' -AsSecureString
        $b = Read-Host 'Confirm root password' -AsSecureString
        $pa = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($a))
        $pb = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($b))
        if ($pa -ne $pb) { Write-Host '    Passwords do not match.' -ForegroundColor Yellow; continue }
        if ($pa.Length -lt 8) { Write-Host '    Use at least 8 characters.' -ForegroundColor Yellow; continue }
        return $pa
    }
}

function Get-DefaultTimezone {
    $map = @{
        'Eastern Standard Time' = 'America/New_York'; 'Central Standard Time' = 'America/Chicago'
        'Mountain Standard Time' = 'America/Denver'; 'US Mountain Standard Time' = 'America/Phoenix'
        'Pacific Standard Time' = 'America/Los_Angeles'; 'Alaskan Standard Time' = 'America/Anchorage'
        'Hawaiian Standard Time' = 'Pacific/Honolulu'; 'GMT Standard Time' = 'Europe/London'
        'W. Europe Standard Time' = 'Europe/Berlin'; 'Romance Standard Time' = 'Europe/Paris'
        'Central Europe Standard Time' = 'Europe/Budapest'; 'AUS Eastern Standard Time' = 'Australia/Sydney'
        'Tokyo Standard Time' = 'Asia/Tokyo'; 'UTC' = 'UTC'
    }
    $id = [TimeZoneInfo]::Local.Id
    if ($map.ContainsKey($id)) { return $map[$id] }
    'UTC'
}

function Invoke-Wizard {
    Write-Host ''
    Write-Host 'Proxmox automated install - answer file wizard' -ForegroundColor Green
    Write-Host 'Press Enter to accept [defaults].' -ForegroundColor DarkGray
    Write-Host ''
    $g = [ordered]@{}
    $g['fqdn'] = Read-Value 'Hostname (FQDN, e.g. pve01.home.lan)' '' { param($v) if ($v -notmatch '^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$') { 'Needs host.domain form' } }
    $g['root-password'] = Read-Password
    $g['mailto'] = Read-Value 'Admin e-mail' "root@$($g['fqdn'] -replace '^[^.]+\.', '')"
    $g['timezone'] = Read-Value 'Timezone (IANA)' (Get-DefaultTimezone)
    $g['keyboard'] = Read-Choice 'Keyboard' $Keyboards 'en-us'
    $g['country'] = Read-Value 'Country code' 'us' { param($v) if ($v -notmatch '^[a-z]{2}$') { '2 lowercase letters, e.g. us' } }
    $ssh = Read-Value 'SSH public key for root (paste key or path to .pub, blank = none)' '' -AllowEmpty
    if ($ssh) {
        if (Test-Path -LiteralPath $ssh) { $ssh = (Get-Content -LiteralPath $ssh -Raw).Trim() }
        $g['root-ssh-keys'] = @($ssh)
    }
    $g['reboot-on-error'] = $false

    Write-Host ''
    $n = [ordered]@{}
    $mode = Read-Choice 'Network' @('dhcp', 'static') 'dhcp'
    if ($mode -eq 'dhcp') { $n['source'] = 'from-dhcp' }
    else {
        $n['source'] = 'from-answer'
        $n['cidr'] = Read-Value 'IP/prefix (e.g. 192.168.1.50/24)' '' { param($v) if ($v -notmatch '^[0-9a-fA-F:.]+/\d{1,3}$') { 'Format: 192.168.1.50/24' } }
        $gwDefault = ''
        if ($n['cidr'] -match '^(\d+\.\d+\.\d+)\.\d+/') { $gwDefault = "$($Matches[1]).1" }
        $n['gateway'] = Read-Value 'Gateway' $gwDefault
        $n['dns'] = Read-Value 'DNS server' $n['gateway']
        $nic = Read-Value 'NIC to use: MAC address (recommended) or interface name/glob (e.g. eno1, enp*)' 'en*'
        if ($nic -match '^([0-9a-fA-F]{2}[:-]?){5}[0-9a-fA-F]{2}$') {
            $n['filter'] = [ordered]@{ 'ID_NET_NAME_MAC' = '*' + ($nic -replace '[:-]', '').ToLower() }
        } else {
            $n['filter'] = [ordered]@{ 'ID_NET_NAME' = $nic }
        }
    }

    Write-Host ''
    Write-Host '    Disk names are as Linux sees them on the target: sda, sdb, nvme0n1 ...' -ForegroundColor DarkGray
    Write-Host '    Or give a udev filter instead, e.g. ID_MODEL=Samsung*  (ALL matching disks are wiped!)' -ForegroundColor DarkGray
    $d = [ordered]@{}
    $d['filesystem'] = Read-Choice 'Filesystem' @('ext4', 'xfs', 'zfs', 'btrfs') 'ext4'
    $disks = Read-Value 'Target disk(s), comma separated' 'sda'
    $count = 1
    if ($disks -match '^\s*(\w+)\s*=\s*(.+)$') {
        $d['filter'] = [ordered]@{ $Matches[1] = $Matches[2].Trim() }
        $count = [int](Read-Value 'How many disks will match that filter?' '1')
    } else {
        $list = @($disks -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { $_ -replace '^/dev/', '' })
        $d['disk-list'] = $list
        $count = $list.Count
    }
    if ($d['filesystem'] -eq 'zfs') {
        $def = 'raid0'; if ($count -ge 2) { $def = 'raid1' }
        $d['zfs'] = [ordered]@{ raid = (Read-Choice 'ZFS RAID level' $ZfsRaids $def) }
    } elseif ($d['filesystem'] -eq 'btrfs') {
        $def = 'raid0'; if ($count -ge 2) { $def = 'raid1' }
        $d['btrfs'] = [ordered]@{ raid = (Read-Choice 'Btrfs RAID level' $BtrfsRaids $def) }
    }

    [ordered]@{ 'global' = $g; 'network' = $n; 'disk-setup' = $d }
}

function ConvertTo-PlainObject($Node) {
    # ordered dictionaries -> PSCustomObject so ConvertTo-Json keeps key order in PS 5.1
    if ($Node -is [Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in $Node.Keys) { $o[$k] = ConvertTo-PlainObject $Node[$k] }
        return [pscustomobject]$o
    }
    if ($Node -is [Array]) { return , @($Node | ForEach-Object { ConvertTo-PlainObject $_ }) }
    $Node
}

#endregion
#region main ------------------------------------------------------------------

$IsoPath = (Resolve-Path -LiteralPath $IsoPath).ProviderPath
if (-not $OutputPath) {
    $OutputPath = Join-Path (Split-Path $IsoPath) ([IO.Path]::GetFileNameWithoutExtension($IsoPath) + '-auto.iso')
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if ($OutputPath -ieq $IsoPath) { throw 'OutputPath must differ from IsoPath; the source ISO is never modified.' }
$outDir = Split-Path $OutputPath
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
$answerOut = [IO.Path]::ChangeExtension($OutputPath, '.answer.toml')
if (-not $Force) {
    foreach ($p in @($OutputPath, $answerOut)) {
        if ((Test-Path -LiteralPath $p) -and -not ($AnswerOnly -and $p -eq $OutputPath)) { throw "$p already exists (use -Force to overwrite)" }
    }
}
if ($Config -and $AnswerFile) { throw 'Use either -Config or -AnswerFile, not both.' }
if ($FirstBootScript) {
    $FirstBootScript = (Resolve-Path -LiteralPath $FirstBootScript).ProviderPath
    if ((Get-Item -LiteralPath $FirstBootScript).Length -gt 1MB) { throw 'First-boot script must be 1 MiB or smaller.' }
}

try {
    Initialize-Backend
    Add-Mount (Split-Path $IsoPath) '/in' -ReadOnly
    Add-Mount $outDir '/out'
    if ($FirstBootScript) { Add-Mount (Split-Path $FirstBootScript) '/fb' -ReadOnly }

    Write-Step "Reading $([IO.Path]::GetFileName($IsoPath))"
    $info = Get-IsoInfo $IsoPath
    $product = $info.ProductLong; if (-not $product) { $product = 'unknown product' }
    Write-Note "$product $($info.Release)-$($info.IsoRelease)   uuid $($info.Uuid)"
    if (-not $info.Capable) { throw 'This ISO has no /auto-installer-capable flag. Automated installs need Proxmox VE 8.2 or newer.' }
    if ($info.HasAnswer) { Write-Warning 'This ISO already contains an answer.toml; it will be replaced.' }
    if (-not $info.Uuid) { Write-Warning 'Could not read the ISO volume UUID; the result may not boot from USB.' }
    if ($info.Product -and $info.Product -ne 'pve') { Write-Warning "Built for Proxmox VE; '$product' uses a different version scheme - consider -KeyStyle." }

    $ver = [version]'8.2'
    if ($info.Release -match '^\d+\.\d+$') { $ver = [version]$info.Release }
    $style = $KeyStyle
    if ($style -eq 'Auto') { if ($ver -ge [version]'8.4') { $style = 'Kebab' } else { $style = 'Snake' } }

    $savedConfig = $null
    if ($AnswerFile) {
        Write-Step "Using answer file $AnswerFile as-is"
        $toml = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $AnswerFile).ProviderPath)
        foreach ($s in '[global]', '[network]', '[disk-setup]') {
            if ($toml -notmatch [regex]::Escape($s)) { throw "Answer file has no $s section." }
        }
        if ($FirstBootScript -and $toml -notmatch '\[first-boot\]') {
            $toml = $toml.TrimEnd() + "`n`n[first-boot]`nsource = `"from-iso`"`n"
        }
    } else {
        if ($Config) {
            Write-Step "Loading config $Config"
            $model = ConvertTo-AnswerModel (Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json)
        } else {
            $model = Invoke-Wizard
            $savedConfig = [IO.Path]::ChangeExtension($OutputPath, '.config.json')
        }
        if ($FirstBootScript -and -not (Get-Item2 $model 'first-boot')) {
            $model['first-boot'] = [ordered]@{ source = 'from-iso'; ordering = 'fully-up' }
        }
        $fbSection = Get-Item2 $model 'first-boot'
        if ($fbSection -and (Get-Item2 $fbSection 'source') -eq 'from-iso' -and -not $FirstBootScript) {
            throw '[first-boot] source = "from-iso" needs -FirstBootScript.'
        }

        $g = Get-Item2 $model 'global'
        $plain = Get-Item2 $g 'root-password'
        if ($plain -and -not $PlainPassword -and $ver -ge [version]'8.3') {
            Write-Step 'Hashing root password (SHA-512 crypt)'
            $hashed = [ordered]@{}
            foreach ($k in $g.Keys) {
                if ($k -eq 'root-password') { $hashed['root-password-hashed'] = Get-HashedPassword $plain }
                else { $hashed[$k] = $g[$k] }
            }
            $model['global'] = $hashed
        }

        $check = Test-AnswerModel $model $ver
        foreach ($w in $check.Warnings) { Write-Warning $w }
        if ($check.Errors.Count) { throw ("Answer file is not valid:`n  - " + ($check.Errors -join "`n  - ")) }
        $toml = ConvertTo-Toml $model $style

        if ($savedConfig) {
            $toSave = $model
            if (Get-Item2 $model['global'] 'root-password') {
                # never persist a plaintext password; leave a placeholder to fill in
                $toSave = [ordered]@{}
                foreach ($k in $model.Keys) { $toSave[$k] = $model[$k] }
                $gg = [ordered]@{}
                foreach ($k in $model['global'].Keys) { $gg[$k] = $model['global'][$k] }
                $gg['root-password'] = 'CHANGE-ME'
                $toSave['global'] = $gg
            }
            [IO.File]::WriteAllText($savedConfig, ((ConvertTo-PlainObject $toSave) | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
        }
    }

    Write-Utf8File $answerOut $toml
    Write-Step "Answer file ($style keys) -> $answerOut"
    Write-Host ($toml -replace '(?m)^(root[-_]password(_hashed|-hashed)?\s*=\s*).*$', '$1"********"') -ForegroundColor Gray
    if ($savedConfig) { Write-Note "Wizard answers saved for reuse: $savedConfig (-Config)" }
    if ($AnswerOnly) { return }

    # Same file the official prepare-iso writes; partition_label only exists from 8.3.
    $modeToml = "mode = `"iso`"`n"
    if ($ver -ge [version]'8.3') { $modeToml += "partition_label = `"proxmox-ais`"`n" }
    $modeToml += "`n[http]`n"
    Write-Utf8File (Join-Path $script:WorkDir 'auto-installer-mode.toml') $modeToml
    Write-Utf8File (Join-Path $script:WorkDir 'answer.toml') $toml

    $need = (Get-Item -LiteralPath $IsoPath).Length + 64MB
    $free = (New-Object IO.DriveInfo([IO.Path]::GetPathRoot($OutputPath))).AvailableFreeSpace
    if ($free -lt $need) { throw "Not enough free space on $([IO.Path]::GetPathRoot($OutputPath)) ($([math]::Round($free/1GB,1)) GB free)." }

    Write-Step "Copying ISO -> $OutputPath"
    Copy-Item -LiteralPath $IsoPath -Destination $OutputPath -Force

    Write-Step 'Embedding answer file with xorriso'
    $workPrefix = '/work'
    if ($script:BackendKind -eq 'WSL') { $workPrefix = (Get-BackendPath (Join-Path $script:WorkDir 'helper.sh')) -replace '/helper\.sh$', '' }
    $maps = @("$workPrefix/auto-installer-mode.toml", '/auto-installer-mode.toml', "$workPrefix/answer.toml", '/answer.toml')
    if ($FirstBootScript) { $maps += @((Get-BackendPath $FirstBootScript), '/proxmox-first-boot') }
    $r = Invoke-Helper (@('inject', (Get-BackendPath $OutputPath), $info.Uuid) + $maps) -AllowFail
    if ($r.ExitCode -ne 0) {
        Remove-Item -LiteralPath $OutputPath -ErrorAction SilentlyContinue
        throw "xorriso failed:`n$($r.Output -join "`n")"
    }
    $r.Output | Where-Object { $_ -match 'Writing to|Written to medium|sessions' } | ForEach-Object { Write-Note $_ }

    Write-Step 'Verifying'
    $after = Get-IsoInfo $OutputPath
    $chk = Join-Path $script:WorkDir 'verify.toml'
    Invoke-Helper @('extract', (Get-BackendPath $OutputPath), '/answer.toml', "$workPrefix/verify.toml") | Out-Null
    $problems = @()
    if (-not (Test-Path -LiteralPath $chk) -or [IO.File]::ReadAllText($chk) -ne ($toml -replace "`r`n", "`n")) { $problems += 'answer.toml on the ISO does not match' }
    if ($info.Uuid -and $after.Uuid -ne $info.Uuid) { $problems += "volume UUID changed ($($info.Uuid) -> $($after.Uuid))" }
    if (-not $after.Capable) { $problems += 'auto-installer-capable flag missing' }
    if ($problems) { throw "Verification failed: $($problems -join '; ')" }
    Write-Note 'answer.toml embedded, volume UUID preserved, boot images kept'

    $size = [math]::Round((Get-Item -LiteralPath $OutputPath).Length / 1MB)
    Write-Host ''
    Write-Host "Done: $OutputPath ($size MB)" -ForegroundColor Green
    Write-Host '  Rufus: select the ISO, click START, and choose "Write in DD Image mode" when asked.' -ForegroundColor Green
    Write-Host '  On boot the "Automated Installation" entry starts by itself after a short countdown' -ForegroundColor Yellow
    Write-Host '  and WIPES the configured disks. Keep the stick away from machines you care about.' -ForegroundColor Yellow
} finally {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) { Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
}

#endregion
