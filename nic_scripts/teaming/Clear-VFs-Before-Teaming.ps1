#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Detect and clear SR-IOV Virtual Functions (VFs) from adapters before NIC Teaming.

.DESCRIPTION
    Windows LBFO teaming WILL FAIL if any target adapter has:
      - SR-IOV enabled with NumVFs > 0
      - Active VF child adapters still present
      - Hyper-V virtual switch bound to the adapter (also blocks teaming)

    This script:
      1. Scans all adapters and reports SR-IOV / VF / vSwitch status
      2. Optionally clears VFs and unbinds vSwitches so teaming can proceed

.PARAMETER AdapterNames
    Comma-separated adapter names to check (leave blank to check ALL adapters).

.PARAMETER AutoFix
    If specified, automatically clears VFs and removes vSwitch bindings without prompting.

.EXAMPLE
    # Check all adapters interactively
    powershell -ExecutionPolicy Bypass -File .\Clear-VFs-Before-Teaming.ps1

.EXAMPLE
    # Check specific adapters and auto-fix
    powershell -ExecutionPolicy Bypass -File .\Clear-VFs-Before-Teaming.ps1 -AdapterNames "PCIe Slot 21 Port 1,PCIe Slot 21 Port 2" -AutoFix
#>

param(
    [string]$AdapterNames = "",
    [switch]$AutoFix
)

$ErrorActionPreference = 'Continue'

function Write-Red    { param([string]$M) Write-Host $M -ForegroundColor Red    }
function Write-Green  { param([string]$M) Write-Host $M -ForegroundColor Green  }
function Write-Yellow { param([string]$M) Write-Host $M -ForegroundColor Yellow }
function Write-Cyan   { param([string]$M) Write-Host $M -ForegroundColor Cyan   }
function Write-Section {
    param([string]$T)
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "  $T" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
}

# ============================================================
# 1. Resolve which adapters to check
# ============================================================
Write-Section "SR-IOV / VF Pre-Teaming Check"

if ($AdapterNames.Trim() -ne "") {
    $targets = $AdapterNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    Write-Cyan "Checking specified adapters: $($targets -join ', ')"
} else {
    $targets = (Get-NetAdapter -Physical | Where-Object { $_.Status -ne 'Not Present' }).Name
    Write-Cyan "Checking ALL physical adapters ($($targets.Count) found)"
}

# ============================================================
# 2. Check each adapter for blockers
# ============================================================
Write-Section "Scan Results"

$blockers = @()   # adapters that will block teaming

foreach ($name in $targets) {
    $adapter = Get-NetAdapter -Name $name -ErrorAction SilentlyContinue
    if (-not $adapter) {
        Write-Red "  [NOT FOUND]  $name"
        continue
    }

    $issues = @()

    # --- Check SR-IOV capability and NumVFs ---
    $sriov = Get-NetAdapterSriov -Name $name -ErrorAction SilentlyContinue
    if ($sriov) {
        if ($sriov.Enabled -and $sriov.NumVFs -gt 0) {
            $issues += "SR-IOV enabled with NumVFs=$($sriov.NumVFs)"
        } elseif ($sriov.Enabled) {
            $issues += "SR-IOV enabled (NumVFs=0, likely safe but confirm)"
        }
    }

    # --- Check for VF child adapters still present ---
    $vfChildren = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InterfaceDescription -match 'Virtual Function|VF #' -or
            ($_.PhysicalMediaType -eq '802.3' -and $_.DriverDescription -match 'VF')
        } |
        Where-Object { $_.InterfaceDescription -match [regex]::Escape($adapter.InterfaceDescription -replace '#\d+','').TrimEnd() }

    if ($vfChildren) {
        $issues += "Active VF child adapters: $($vfChildren.Name -join ', ')"
    }

    # --- Check Hyper-V vSwitch binding ---
    $vswitch = Get-VMSwitch -ErrorAction SilentlyContinue |
               Where-Object { $_.NetAdapterInterfaceDescription -eq $adapter.InterfaceDescription }
    if ($vswitch) {
        $issues += "Bound to Hyper-V vSwitch: '$($vswitch.Name)' (BLOCKS teaming)"
    }

    # --- Check if adapter is already in a team ---
    $inTeam = Get-NetLbfoTeamMember -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -eq $name }
    if ($inTeam) {
        $issues += "Already a member of team: '$($inTeam.Team)'"
    }

    # --- Report ---
    if ($issues.Count -eq 0) {
        Write-Green "  [CLEAR]   $name  - No blockers found, safe to team"
    } else {
        Write-Red   "  [BLOCKED] $name"
        foreach ($iss in $issues) {
            Write-Red "            -> $iss"
        }
        $blockers += [PSCustomObject]@{
            Name    = $name
            Adapter = $adapter
            SRIOV   = $sriov
            Issues  = $issues
            VSwitch = $vswitch
        }
    }
}

# ============================================================
# 3. If no blockers, exit early
# ============================================================
if ($blockers.Count -eq 0) {
    Write-Green ""
    Write-Green "All adapters are clean. You can proceed with teaming now."
    Write-Host ""
    Read-Host "Press Enter to close"
    exit 0
}

# ============================================================
# 4. Prompt / AutoFix
# ============================================================
Write-Section "Blockers Found - Remediation"

Write-Yellow "Found $($blockers.Count) adapter(s) with issues that will prevent teaming."
Write-Host ""

if (-not $AutoFix) {
    $ans = Read-Host "Attempt to clear all blockers automatically? [y/N]"
    if ($ans -notmatch '^[Yy]$') {
        Write-Yellow "No changes made. See manual steps below."
        Write-ManualSteps
        Read-Host "Press Enter to close"
        exit 0
    }
}

# ============================================================
# 5. Clear VFs and vSwitch bindings
# ============================================================
foreach ($b in $blockers) {
    $name = $b.Name
    Write-Section "Fixing: $name"

    # Step A: Remove Hyper-V vSwitch first (must be done before SR-IOV changes)
    if ($b.VSwitch) {
        Write-Yellow "  [1] Removing Hyper-V vSwitch '$($b.VSwitch.Name)' from $name..."
        try {
            Remove-VMSwitch -Name $b.VSwitch.Name -Force -ErrorAction Stop
            Write-Green "      vSwitch removed."
        } catch {
            Write-Red "      Failed to remove vSwitch: $_"
            Write-Red "      Try manually: Remove-VMSwitch -Name '$($b.VSwitch.Name)' -Force"
        }
    }

    # Step B: Set NumVFs to 0 (disables all VFs on this adapter)
    if ($b.SRIOV -and $b.SRIOV.NumVFs -gt 0) {
        Write-Yellow "  [2] Setting NumVFs to 0 on $name (was $($b.SRIOV.NumVFs))..."
        try {
            Set-NetAdapterSriov -Name $name -NumVFs 0 -ErrorAction Stop
            Write-Green "      NumVFs set to 0."
        } catch {
            Write-Red "      Failed via Set-NetAdapterSriov: $_"
            Write-Yellow "      Trying via registry fallback..."
            try {
                # Registry path for NumVFs - works when cmdlet fails
                $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}"
                $driverKey = Get-ChildItem $regPath -ErrorAction SilentlyContinue |
                    Where-Object {
                        (Get-ItemProperty $_.PSPath -Name 'NetCfgInstanceId' -ErrorAction SilentlyContinue).NetCfgInstanceId `
                        -eq $b.Adapter.DeviceID
                    }
                if ($driverKey) {
                    Set-ItemProperty -Path $driverKey.PSPath -Name '*NumVFs' -Value 0
                    Write-Green "      NumVFs set to 0 via registry. REBOOT REQUIRED."
                } else {
                    Write-Red "      Registry key not found. Manual reboot and BIOS SR-IOV disable may be needed."
                }
            } catch {
                Write-Red "      Registry fallback also failed: $_"
            }
        }
    }

    # Step C: Disable SR-IOV entirely on the adapter
    if ($b.SRIOV -and $b.SRIOV.Enabled) {
        Write-Yellow "  [3] Disabling SR-IOV on $name..."
        try {
            Disable-NetAdapterSriov -Name $name -ErrorAction Stop
            Write-Green "      SR-IOV disabled."
        } catch {
            Write-Red "      Failed to disable SR-IOV: $_"
            Write-Yellow "      You may need to disable SR-IOV in BIOS/UEFI (iLO -> BIOS -> SR-IOV)."
        }
    }

    # Step D: Restart adapter to flush VF state
    Write-Yellow "  [4] Restarting adapter $name to flush VF state..."
    try {
        Disable-NetAdapter -Name $name -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 3
        Enable-NetAdapter  -Name $name -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 3
        Write-Green "      Adapter restarted."
    } catch {
        Write-Red "      Adapter restart failed: $_"
    }
}

# ============================================================
# 6. Re-verify after fix
# ============================================================
Write-Section "Re-Verification After Fix"
Start-Sleep -Seconds 2

$stillBlocked = @()
foreach ($b in $blockers) {
    $name   = $b.Name
    $sriov2 = Get-NetAdapterSriov -Name $name -ErrorAction SilentlyContinue
    $vs2    = Get-VMSwitch -ErrorAction SilentlyContinue |
              Where-Object { $_.NetAdapterInterfaceDescription -eq $b.Adapter.InterfaceDescription }

    $remaining = @()
    if ($sriov2 -and $sriov2.Enabled -and $sriov2.NumVFs -gt 0) { $remaining += "SR-IOV NumVFs=$($sriov2.NumVFs)" }
    if ($vs2) { $remaining += "vSwitch '$($vs2.Name)' still bound" }

    if ($remaining.Count -eq 0) {
        Write-Green "  [CLEAR]   $name  - All blockers removed"
    } else {
        Write-Red   "  [STILL BLOCKED] $name"
        foreach ($r in $remaining) { Write-Red "    -> $r" }
        $stillBlocked += $name
    }
}

# ============================================================
# 7. Final guidance
# ============================================================
Write-Host ""
if ($stillBlocked.Count -eq 0) {
    Write-Green "SUCCESS: All adapters are now clear."
    Write-Green "You can now run New-NicTeamingWizard.ps1"
} else {
    Write-Red "Some adapters still have blockers: $($stillBlocked -join ', ')"
    Write-Yellow ""
    Write-Yellow "Manual steps to try:"
    Write-Yellow "  1. Reboot the server (some VF changes need a reboot)"
    Write-Yellow "  2. In iLO -> BIOS Settings -> SR-IOV -> Set to Disabled"
    Write-Yellow "  3. In Device Manager -> NIC -> Properties -> Advanced -> SR-IOV -> Disabled"
    Write-Yellow "  4. If VMs are using the VFs, shut them down first then re-run this script"
    Write-Yellow ""
    Write-Yellow "Check current VF state with:"
    Write-Yellow "  Get-NetAdapterSriov | ft Name,Enabled,NumVFs,NumVFsInUse"
    Write-Yellow "  Get-VMSwitch | ft Name,NetAdapterInterfaceDescription"
}

Write-Host ""
Write-Host "Full SR-IOV status of all checked adapters:" -ForegroundColor Cyan
Get-NetAdapterSriov -ErrorAction SilentlyContinue |
    Where-Object { $targets -contains $_.Name } |
    Format-Table Name, Enabled, NumVFs, NumVFsInUse, SriovSupport -AutoSize

Read-Host "`nPress Enter to close"
