#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Apply', 'Status', 'Undo')]
    [string]$Action = 'Status',
    [string]$SteamPath
)

# Per-application Winsock categories only. Does not uninstall any LSP.
# This script intentionally leaves pre-existing application categories unchanged.
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This script requires Windows.' }
$SystemCategory = [uint32]2147483648
$StateDirectory = Join-Path $env:ProgramData 'SteamLspCompatibility'
$StateFile = Join-Path $StateDirectory 'state.json'
$ScriptLock = $null
$Failures = 0

if (-not [Environment]::Is64BitProcess) {
    throw 'Run this script in 64-bit Windows PowerShell (not Windows PowerShell x86).'
}
if ($Action -ne 'Status') {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Apply and Undo require Windows PowerShell opened with Run as administrator.'
    }
    $running = @(Get-Process -Name steam, steamwebhelper -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        $processList = ($running | ForEach-Object { '{0} (PID {1})' -f $_.ProcessName, $_.Id }) -join ', '
        throw "Exit Steam completely, including its tray icon and WebHelpers, then retry. Running: $processList"
    }
}

if (-not ('SteamLspCompatibility.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace SteamLspCompatibility {
    public static class Native {
        [DllImport("ws2_32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        public static extern int WSCGetApplicationCategory(
            string path, uint pathLength, string extra, uint extraLength,
            out uint category, out int error);
        [DllImport("ws2_32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        public static extern int WSCSetApplicationCategory(
            string path, uint pathLength, string extra, uint extraLength,
            uint category, out uint previous, out int error);
    }
}
'@
}

function Get-LspCategory([string]$Path) {
    [uint32]$category = 0
    [int]$nativeError = 0
    $result = [SteamLspCompatibility.Native]::WSCGetApplicationCategory(
        $Path, [uint32]$Path.Length, [System.Management.Automation.Language.NullString]::Value,
        0, [ref]$category, [ref]$nativeError)
    if ($result -eq 0) {
        return [pscustomobject]@{ Exists = $true; Category = $category }
    }
    if ($nativeError -eq 10108) {
        return [pscustomobject]@{ Exists = $false; Category = [uint32]0 }
    }
    throw "WSCGetApplicationCategory failed: error=$nativeError, path=$Path"
}

function Set-LspCategory([string]$Path, [uint32]$Category) {
    [uint32]$previous = 0
    [int]$nativeError = 0
    $result = [SteamLspCompatibility.Native]::WSCSetApplicationCategory(
        $Path, [uint32]$Path.Length, [System.Management.Automation.Language.NullString]::Value, 0, $Category,
        [ref]$previous, [ref]$nativeError)
    if ($result -ne 0) {
        throw "WSCSetApplicationCategory failed: error=$nativeError, path=$Path"
    }
    return $previous
}

function Get-SteamRoot {
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    if ($SteamPath) {
        $candidates.Add($SteamPath)
    } else {
        foreach ($hive in @([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryHive]::LocalMachine)) {
            foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
                $baseKey = $null
                $steamKey = $null
                try {
                    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
                    $steamKey = $baseKey.OpenSubKey('Software\Valve\Steam')
                    if ($null -ne $steamKey) {
                        foreach ($valueName in @('SteamPath', 'InstallPath', 'SteamExe')) {
                            $value = $steamKey.GetValue($valueName)
                            if ($value -is [string] -and $value.Trim()) { $candidates.Add($value) }
                        }
                    }
                } catch {
                    Write-Verbose "Could not read Steam registry location: $hive / $view"
                } finally {
                    if ($null -ne $steamKey) { $steamKey.Dispose() }
                    if ($null -ne $baseKey) { $baseKey.Dispose() }
                }
            }
        }
    }
    $roots = @(
        foreach ($candidate in $candidates) {
            $candidatePath = [Environment]::ExpandEnvironmentVariables($candidate.Trim().Trim('"')).Replace('/', '\')
            if (-not (Test-Path -LiteralPath $candidatePath)) { continue }
            $item = Get-Item -LiteralPath $candidatePath
            if (-not $item.PSIsContainer) {
                if ($item.Name -ine 'steam.exe') { continue }
                $candidatePath = $item.DirectoryName
            } else {
                $candidatePath = $item.FullName
            }
            if (Test-Path -LiteralPath (Join-Path $candidatePath 'steam.exe') -PathType Leaf) {
                [IO.Path]::GetFullPath($candidatePath).TrimEnd('\')
            }
        }
    ) | Sort-Object -Unique
    $roots = @($roots)
    if ($roots.Count -eq 0) {
        throw 'Steam installation not found. Supply -SteamPath "D:\Steam" (the folder containing steam.exe).'
    }
    if ($roots.Count -gt 1) {
        throw ('Multiple Steam installations found. Choose one with -SteamPath: ' + ($roots -join '; '))
    }
    return $roots[0]
}

function Get-SteamTargets([string]$Root) {
    $targets = @(Join-Path $Root 'steam.exe')
    $binDirectory = Join-Path $Root 'bin'
    if (Test-Path -LiteralPath $binDirectory -PathType Container) {
        $targets += @(Get-ChildItem -LiteralPath $binDirectory -Filter 'steamwebhelper.exe' -File -Recurse |
            Select-Object -ExpandProperty FullName)
    }
    return @($targets | Sort-Object -Unique)
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
        return [pscustomobject]@{ Version = 1; Entries = @() }
    }
    $state = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.Version -ne 1 -or $null -eq $state.PSObject.Properties['Entries']) {
        throw "Unsupported or damaged state file: $StateFile"
    }
    foreach ($entry in @($state.Entries)) {
        if (-not $entry.Path -or $entry.OriginalState -ne 'Absent' -or
            [uint64]$entry.ExpectedCategory -ne 2147483648 -or
            $entry.State -notin @('Pending', 'Applied', 'Conflict') -or
            [IO.Path]::GetFileName([string]$entry.Path) -notin @('steam.exe', 'steamwebhelper.exe') -or
            -not [IO.Path]::IsPathRooted([string]$entry.Path)) {
            throw "Invalid entry in state file; no changes made: $StateFile"
        }
    }
    $state.Entries = @($state.Entries)
    return $state
}

function Save-State($State) {
    $temporaryFile = Join-Path $StateDirectory ('state.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $State | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText($temporaryFile, $json, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($StateFile)) {
            [IO.File]::Replace($temporaryFile, $StateFile, [System.Management.Automation.Language.NullString]::Value)
        } else {
            [IO.File]::Move($temporaryFile, $StateFile)
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryFile) { Remove-Item -LiteralPath $temporaryFile -Force }
    }
}

function Show-RunningModules {
    $processes = @(Get-Process -Name steam, steamwebhelper -ErrorAction SilentlyContinue)
    Write-Host ''
    Write-Host 'Running Steam process modules (snapshot):'
    if ($processes.Count -eq 0) {
        Write-Host 'Steam/WebHelper is not running; module loading cannot be verified yet.'
        return
    }
    foreach ($process in $processes) {
        try {
            if ($process.HasExited) { throw 'Process exited during inspection.' }
            $modules = @($process.Modules)
            if ($modules.Count -eq 0) { throw 'Module list is unavailable.' }
            $matching = @($modules | Where-Object { $_.ModuleName -like 'ASProxy*.dll' })
            if ($matching.Count -gt 0) {
                Write-Host ('LOADED: {0} PID={1}: {2}' -f $process.ProcessName, $process.Id,
                    (($matching | ForEach-Object { $_.FileName }) -join '; '))
            } else {
                Write-Host ('NOT LOADED at this snapshot: {0} PID={1}' -f $process.ProcessName, $process.Id)
            }
        } catch {
            Write-Host ('UNKNOWN: {0} PID={1}: {2}' -f $process.ProcessName, $process.Id, $_.Exception.Message)
        }
    }
}

try {
    if ($Action -ne 'Status') {
        [void](New-Item -ItemType Directory -Path $StateDirectory -Force)
        try {
            $ScriptLock = [IO.File]::Open((Join-Path $StateDirectory 'operation.lock'),
                [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch {
            throw 'Cannot acquire the operation lock. Another Apply/Undo may be running, or access is denied.'
        }
    }
    $state = Read-State
    if ($Action -eq 'Undo') {
        if (@($state.Entries).Count -eq 0) { Write-Host 'No changes recorded by this tool.' }
        foreach ($entry in @($state.Entries)) {
            try {
                if ($entry.State -eq 'Conflict') {
                    throw 'A concurrent category change was recorded. Automatic Undo is disabled for this entry.'
                }
                $current = Get-LspCategory $entry.Path
                if ($current.Exists -and $current.Category -ne $SystemCategory) {
                    throw ('Current category 0x{0:X8} differs from this tool''s expected value. Left unchanged.' -f $current.Category)
                }
                if ($current.Exists) {
                    [void](Set-LspCategory $entry.Path 0)
                    $after = Get-LspCategory $entry.Path
                    if ($after.Exists) { throw 'Undo verification failed: an application category still exists.' }
                }
                $state.Entries = @($state.Entries | Where-Object { $_.Path -ine $entry.Path })
                Save-State $state
                Write-Host ('UNDONE / already absent: ' + $entry.Path)
            } catch {
                $Failures++
                Write-Warning ('Undo skipped/failed for {0}: {1}' -f $entry.Path, $_.Exception.Message)
            }
        }
    } else {
        $root = Get-SteamRoot
        $targets = @(Get-SteamTargets $root)
        Write-Host ('Steam installation: ' + $root)
        Write-Host ('Mode: ' + $Action)
        Write-Host ''
        foreach ($target in $targets) {
            try {
                $current = Get-LspCategory $target
                if ($Action -eq 'Status') {
                    if ($current.Exists) {
                        Write-Host ('Category 0x{0:X8}: {1}' -f $current.Category, $target)
                    } else {
                        Write-Host ('UNCATEGORIZED: ' + $target)
                    }
                    continue
                }
                $entry = @($state.Entries | Where-Object { $_.Path -ieq $target }) | Select-Object -First 1
                if ($null -ne $entry -and $entry.State -eq 'Conflict') {
                    throw 'A concurrent category change was recorded. Automatic Apply/Undo is disabled for this entry.'
                }
                if ($current.Exists) {
                    if ($null -ne $entry -and $current.Category -eq $SystemCategory) {
                        $entry.State = 'Applied'
                        Save-State $state
                        Write-Host ('ALREADY APPLIED: ' + $target)
                    } else {
                        Write-Host ('SKIPPED existing category 0x{0:X8} (not changed): {1}' -f $current.Category, $target)
                    }
                    continue
                }
                if ($null -eq $entry) {
                    $entry = [pscustomobject]@{
                        Path = $target
                        OriginalState = 'Absent'
                        ExpectedCategory = [uint32]2147483648
                        State = 'Pending'
                        CreatedUtc = [DateTime]::UtcNow.ToString('o')
                    }
                    $state.Entries = @($state.Entries) + @($entry)
                } else {
                    $entry.State = 'Pending'
                }
                # Write-ahead record: a later Undo can recover an interrupted Apply.
                Save-State $state
                $previous = Set-LspCategory $target $SystemCategory
                if ($previous -ne 0) {
                    $entry.State = 'Conflict'
                    $entry | Add-Member -NotePropertyName ConflictPreviousCategory -NotePropertyValue $previous -Force
                    Save-State $state
                    $after = Get-LspCategory $target
                    throw 'The category changed concurrently. Inspect the current category before attempting Undo.'
                }
                $after = Get-LspCategory $target
                if (-not $after.Exists -or $after.Category -ne $SystemCategory) {
                    $entry.State = 'Conflict'
                    Save-State $state
                    throw 'Apply verification failed: the resulting category is not exactly LSP_SYSTEM.'
                }
                $entry.State = 'Applied'
                Save-State $state
                Write-Host ('APPLIED: ' + $target)
            } catch {
                $Failures++
                if ($Action -eq 'Status') {
                    Write-Host ('UNKNOWN category: {0}: {1}' -f $target, $_.Exception.Message)
                } else {
                    Write-Warning ('{0}: {1}' -f $target, $_.Exception.Message)
                }
            }
        }
        if ($Action -eq 'Status') { Show-RunningModules }
    }
    Write-Host ''
    Write-Host ('Recovery state: ' + $StateFile)
    if ($Action -eq 'Apply') {
        Write-Host 'Start Steam normally, then run -Action Status to inspect ASProxy module loading.'
        Write-Host 'This changes LSP loading only. It does not guarantee that downloads bypass VPN routes.'
    }
} finally {
    if ($null -ne $ScriptLock) { $ScriptLock.Dispose() }
}
if ($Failures -gt 0) { exit 2 }
exit 0
