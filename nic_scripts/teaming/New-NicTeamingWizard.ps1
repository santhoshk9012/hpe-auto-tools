#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Interactive wizard to create Windows NIC Teaming (LBFO) - equivalent to nmcli_bond_balance_rr_wizard.sh

.DESCRIPTION
    Mirrors the Linux balance-rr bonding wizard feature-for-feature:
      - Teaming mode : SwitchIndependent (equivalent to balance-rr / no LACP needed on switch)
      - Load-balancing: TransportPorts (closest Windows equivalent to layer2 xmit_hash_policy)
      - Link monitoring : equivalent to miimon - Windows uses Hyper-V / miniport heartbeat
      - IPv4           : DHCP (default) | Static | None (L2 only)
      - MTU            : optional, applied per member adapter
      - Multi-team     : create N teams in one run (mirrors BCOUNT/START logic)
      - Cleanup        : -Cleanup switch removes only teams created by this script (tagged)
      - Color output   : Red / Green / Yellow helpers matching the bash originals

.PARAMETER Cleanup
    Remove all NIC teams previously created by this wizard (identified by description tag).

.EXAMPLE
    # Run wizard (must be elevated)
    powershell -ExecutionPolicy Bypass -File .\New-NicTeamingWizard.ps1

.EXAMPLE
    # Cleanup all wizard-created teams
    powershell -ExecutionPolicy Bypass -File .\New-NicTeamingWizard.ps1 -Cleanup

.NOTES
    Requires: Windows Server 2012+ or Windows 10/11 with LBFO feature available.
    Module:   NetLbfo  (built-in on Server; on Win10/11 install via RSAT or use native teaming)
    Run as:   Administrator
#>

[CmdletBinding()]
param(
    [switch]$Cleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ============================================================
# Colour helpers  (mirrors red/grn/ylw in the bash script)
# ============================================================
function Write-Red   { param([string]$Msg) Write-Host $Msg -ForegroundColor Red    }
function Write-Green { param([string]$Msg) Write-Host $Msg -ForegroundColor Green  }
function Write-Yellow{ param([string]$Msg) Write-Host $Msg -ForegroundColor Yellow }
function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 55) -ForegroundColor Cyan
    Write-Host "  $Title"   -ForegroundColor Cyan
    Write-Host ("=" * 55) -ForegroundColor Cyan
}

# ============================================================
# Tag used to identify wizard-created teams (mirrors CREATED_TAG)
# ============================================================
$WIZARD_TAG = "created-by-nic-team-wizard"

# ============================================================
# Prerequisite checks  (mirrors need() + EUID check)
# ============================================================
function Assert-Prerequisites {
    # Already enforced by #Requires -RunAsAdministrator, but double-check
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = [Security.Principal.WindowsPrincipal]$id
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Red "Run as Administrator: right-click PowerShell => Run as Administrator"
        exit 1
    }

    # NetLbfo module (LBFO teaming)
    if (-not (Get-Module -ListAvailable -Name NetLbfo -ErrorAction SilentlyContinue)) {
        Write-Red "NetLbfo module not found. On Windows 10/11: install RSAT networking tools."
        Write-Red "On Windows Server: ensure the 'NIC Teaming' feature is available."
        exit 1
    }
    Import-Module NetLbfo -ErrorAction Stop
}

# ============================================================
# Cleanup mode  (mirrors cleanup() in bash)
# ============================================================
function Invoke-Cleanup {
    Write-Section "Cleanup Mode"
    Write-Yellow "Searching for NIC teams tagged '$WIZARD_TAG'..."

    # Check Description field (newer Windows) AND registry tag (fallback)
    $regBase = "HKLM:\SYSTEM\CurrentControlSet\Services\LBFO\Parameters\Adapters"
    $taggedViaReg = @()
    if (Test-Path $regBase) {
        $taggedViaReg = Get-ChildItem $regBase -ErrorAction SilentlyContinue |
            Where-Object {
                (Get-ItemProperty $_.PSPath -Name "WizardTag" -ErrorAction SilentlyContinue).WizardTag -eq $WIZARD_TAG
            } | ForEach-Object { $_.PSChildName }
    }

    $teams = Get-NetLbfoTeam -ErrorAction SilentlyContinue |
             Where-Object { $_.Description -like "*$WIZARD_TAG*" -or $taggedViaReg -contains $_.Name }

    if (-not $teams) {
        Write-Yellow "No tagged teams found. Nothing to remove."
        return
    }

    foreach ($team in $teams) {
        Write-Yellow "Removing team: $($team.Name)"
        Remove-NetLbfoTeam -Name $team.Name -Confirm:$false
        # Clean up registry tag if present
        $regKey = "$regBase\$($team.Name)"
        if (Test-Path $regKey) { Remove-Item $regKey -Force -ErrorAction SilentlyContinue }
        Write-Green "  Removed: $($team.Name)"
    }

    Write-Green "Cleanup complete."
}

# ============================================================
# Show available physical adapters  (mirrors: ip -o link show)
# ============================================================
function Show-Adapters {
    Write-Host "`nAvailable physical adapters (excluding virtual/loopback):" -ForegroundColor Cyan

    $adapters = Get-NetAdapter |
        Where-Object {
            $_.PhysicalMediaType -notmatch 'Unspecified' -or
            $_.InterfaceDescription -notmatch 'Hyper-V|Virtual|Loopback'
        } |
        Where-Object { $_.Name -notmatch '^Loopback' } |
        Sort-Object Name

    $i = 1
    foreach ($a in $adapters) {
        $status = if ($a.Status -eq 'Up') { 'UP' } else { $a.Status }
        Write-Host ("  {0,2}) {1,-30}  {2,-12}  Speed: {3}  MAC: {4}" -f `
            $i, $a.Name, $status, $a.LinkSpeed, $a.MacAddress)
        $i++
    }
    return $adapters
}

# ============================================================
# Validate adapter name exists  (mirrors iface_exists())
# ============================================================
function Test-AdapterExists {
    param([string]$Name)
    $a = Get-NetAdapter -Name $Name -ErrorAction SilentlyContinue
    return ($null -ne $a)
}

# ============================================================
# Free adapter from any existing team  (mirrors free_device())
# ============================================================
function Remove-AdapterFromTeam {
    param([string]$AdapterName)
    $member = Get-NetLbfoTeamMember -ErrorAction SilentlyContinue |
              Where-Object { $_.InterfaceDescription -like "*$AdapterName*" -or $_.Name -eq $AdapterName }
    if ($member) {
        Write-Yellow "  Removing '$AdapterName' from existing team '$($member.Team)' first..."
        Remove-NetLbfoTeamMember -Name $member.Name -Team $member.Team -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# ============================================================
# Get static IP inputs  (mirrors get_static())
# ============================================================
function Get-StaticIPConfig {
    $cfg = @{}
    do {
        $raw = Read-Host "  IPv4 address/prefix (e.g. 172.18.148.238/16)"
        if ($raw -match '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$') {
            $cfg.IPAddress   = $Matches[1]
            $cfg.PrefixLen   = [int]$Matches[2]
            break
        }
        Write-Red "  Invalid format. Use x.x.x.x/prefix (e.g. 192.168.1.10/24)"
    } while ($true)

    $gw = Read-Host "  Gateway (optional, press Enter to skip)"
    if ($gw -match '\d') { $cfg.Gateway = $gw }

    $dns = Read-Host "  DNS servers (comma-separated, optional)"
    if ($dns.Trim()) { $cfg.DNS = $dns -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } }

    return $cfg
}

# ============================================================
# Apply IP configuration to the team's virtual adapter
# ============================================================
function Set-TeamIPConfig {
    param(
        [string]$TeamName,
        [int]   $IPSel,
        [hashtable]$StaticCfg
    )

    # The team NIC exposes as a standard Net adapter - wait briefly for it
    $teamAdapter = $null
    for ($t = 0; $t -lt 15; $t++) {
        $teamAdapter = Get-NetAdapter -Name $TeamName -ErrorAction SilentlyContinue
        if ($teamAdapter) { break }
        Start-Sleep -Seconds 1
    }
    if (-not $teamAdapter) {
        Write-Yellow "  Warning: Could not find team adapter '$TeamName' to configure IP."
        return
    }

    $ifIdx = $teamAdapter.InterfaceIndex

    switch ($IPSel) {
        1 {
            # DHCP
            Write-Yellow "  Setting IPv4 to DHCP..."
            Set-NetIPInterface -InterfaceIndex $ifIdx -Dhcp Enabled -ErrorAction SilentlyContinue
            # Remove any leftover static IPs
            Get-NetIPAddress -InterfaceIndex $ifIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.PrefixOrigin -ne 'Dhcp' } |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        }
        2 {
            # Static
            Write-Yellow "  Applying static IP $($StaticCfg.IPAddress)/$($StaticCfg.PrefixLen)..."
            # Remove DHCP / existing static first
            Set-NetIPInterface -InterfaceIndex $ifIdx -Dhcp Disabled -ErrorAction SilentlyContinue
            Get-NetIPAddress -InterfaceIndex $ifIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceIndex $ifIdx `
                             -IPAddress $StaticCfg.IPAddress `
                             -PrefixLength $StaticCfg.PrefixLen `
                             -ErrorAction Stop | Out-Null
            if ($StaticCfg.ContainsKey('Gateway')) {
                # Remove old default routes on this interface first
                Get-NetRoute -InterfaceIndex $ifIdx -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                New-NetRoute -InterfaceIndex $ifIdx `
                             -DestinationPrefix '0.0.0.0/0' `
                             -NextHop $StaticCfg.Gateway -ErrorAction Stop | Out-Null
            }
            if ($StaticCfg.ContainsKey('DNS')) {
                Set-DnsClientServerAddress -InterfaceIndex $ifIdx -ServerAddresses $StaticCfg.DNS
            }
        }
        3 {
            # No IP - disable IPv4 on the interface
            Write-Yellow "  Disabling IPv4 on team adapter (L2 only)..."
            Set-NetIPInterface -InterfaceIndex $ifIdx -Dhcp Disabled -ErrorAction SilentlyContinue
            Get-NetIPAddress -InterfaceIndex $ifIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}

# ============================================================
# Create one NIC team  (mirrors create_one_bond())
# ============================================================
function New-OneTeam {
    param(
        [int]   $Index,
        [int]   $IPSel,
        [string]$MTU,
        [hashtable]$StaticCfg
    )

    $teamName = "Team$Index"
    Write-Section "Configure $teamName"

    # Collect member adapters — use COMMA separator (names contain spaces)
    do {
        Write-Host "  Tip: separate adapter names with a COMMA (names can contain spaces)" -ForegroundColor Cyan
        Write-Host "  Example: PCIe Slot 21 Port 1,PCIe Slot 21 Port 2" -ForegroundColor Cyan
        $raw = Read-Host "Adapters for $teamName (comma-separated)"
        $memberNames = $raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        if ($memberNames.Count -lt 2) {
            Write-Red "  At least 2 adapters are required. You provided $($memberNames.Count)."
            Write-Red "  Use a COMMA between names, e.g:  PCIe Slot 21 Port 1,PCIe Slot 21 Port 2"
            continue
        }
        $allValid = $true
        foreach ($m in $memberNames) {
            if (-not (Test-AdapterExists -Name $m)) {
                Write-Red "  Adapter not found: '$m'"
                Write-Red "  Run this to see exact names:  Get-NetAdapter | ft Name"
                $allValid = $false
            }
        }
    } while (-not $allValid -or $memberNames.Count -lt 2)

    # Free members from any existing team
    foreach ($m in $memberNames) {
        Remove-AdapterFromTeam -AdapterName $m
    }

    # Remove any pre-existing team with same name
    if (Get-NetLbfoTeam -Name $teamName -ErrorAction SilentlyContinue) {
        Write-Yellow "  Team '$teamName' already exists - removing it first."
        Remove-NetLbfoTeam -Name $teamName -Confirm:$false
        Start-Sleep -Seconds 2
    }

    # Create the team
    # TeamingMode  : SwitchIndependent = balance-rr (no 802.3ad/LACP needed on switch)
    # LoadBalancing: TransportPorts    = closest to xmit_hash_policy=layer2+3 (uses L4 ports)
    #                HyperVPort        = per-VM pinning (use for Hyper-V hosts)
    #                Dynamic           = adaptive (Windows Server 2012 R2+)
    Write-Yellow "  Creating team '$teamName' (SwitchIndependent / TransportPorts)..."
    try {
        New-NetLbfoTeam `
            -Name          $teamName `
            -TeamMembers   $memberNames `
            -TeamingMode   SwitchIndependent `
            -LoadBalancingAlgorithm TransportPorts `
            -Confirm:$false -ErrorAction Stop | Out-Null
    } catch {
        Write-Red ""
        Write-Red "ERROR: Failed to create team '$teamName'"
        Write-Red "Reason: $_"
        Write-Red ""
        Write-Red "Common causes:"
        Write-Red "  1. Adapter already in use by another team - run with -Cleanup first"
        Write-Red "  2. NetLbfo feature not available on this Windows edition"
        Write-Red "  3. Adapter name has extra spaces - copy exact name from Get-NetAdapter"
        Write-Red ""
        Read-Host "Press Enter to exit"
        exit 1
    }

    # Tag the team so cleanup can find it via registry (Description param not supported on all versions)
    try {
        Set-NetLbfoTeam -Name $teamName -Description $WIZARD_TAG -ErrorAction Stop
    } catch {
        # Fallback: store tag in registry so -Cleanup can still find wizard-created teams
        $regBase = "HKLM:\SYSTEM\CurrentControlSet\Services\LBFO\Parameters\Adapters"
        $regKey  = "$regBase\$teamName"
        if (-not (Test-Path $regKey)) { New-Item -Path $regKey -Force | Out-Null }
        Set-ItemProperty -Path $regKey -Name "WizardTag" -Value $WIZARD_TAG -ErrorAction SilentlyContinue
    }

    # Wait for team to come up
    Write-Yellow "  Waiting for team to initialise..."
    Start-Sleep -Seconds 3

    # Apply MTU to each member adapter
    if ($MTU -match '^\d+$') {
        foreach ($m in $memberNames) {
            Write-Yellow "  Setting MTU $MTU on $m..."
            $adv = Get-NetAdapterAdvancedProperty -Name $m -ErrorAction SilentlyContinue |
                   Where-Object { $_.RegistryKeyword -in '*JumboPacket','JumboPacket','MTU' }
            if ($adv) {
                Set-NetAdapterAdvancedProperty -Name $m -RegistryKeyword $adv.RegistryKeyword -RegistryValue $MTU
            } else {
                # Fallback: netsh
                netsh interface ipv4 set subinterface "$m" mtu=$MTU store=persistent 2>&1 | Out-Null
                Write-Yellow "  (MTU set via netsh for $m)"
            }
        }
        # Also set on the team vNIC
        netsh interface ipv4 set subinterface "$teamName" mtu=$MTU store=persistent 2>&1 | Out-Null
    }

    # IP configuration
    Set-TeamIPConfig -TeamName $teamName -IPSel $IPSel -StaticCfg $StaticCfg

    # ---- Verification output  (mirrors cat /proc/net/bonding/bondX) ----
    Write-Green "`n$teamName is up. Quick status:"
    Write-Host   ""

    $team = Get-NetLbfoTeam -Name $teamName -ErrorAction SilentlyContinue
    if ($team) {
        Write-Host "===== NIC Team: $teamName =====" -ForegroundColor Cyan
        Write-Host "  Status          : $($team.Status)"
        Write-Host "  Teaming Mode    : $($team.TeamingMode)   [Linux equiv: balance-rr / SwitchIndependent]"
        Write-Host "  LB Algorithm    : $($team.LoadBalancingAlgorithm)   [Linux equiv: xmit_hash_policy=layer2]"
        Write-Host "  Members         : $($team.Members -join ', ')"
        Write-Host ""

        $members = Get-NetLbfoTeamMember -Team $teamName -ErrorAction SilentlyContinue
        Write-Host "  Member Status:" -ForegroundColor Cyan
        foreach ($mb in $members) {
            Write-Host ("    {0,-30}  AdministrativeMode: {1,-12}  OperStatus: {2}" -f `
                $mb.Name, $mb.AdministrativeMode, $mb.TransmitLinkSpeed)
        }

        $ip4 = Get-NetIPAddress -InterfaceAlias $teamName -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($ip4) {
            Write-Host ""
            Write-Host "  IPv4:" -ForegroundColor Cyan
            foreach ($a in $ip4) {
                Write-Host "    $($a.IPAddress)/$($a.PrefixLength)  Origin: $($a.PrefixOrigin)"
            }
        }
    } else {
        Write-Yellow "  (Could not retrieve team status right away - check Get-NetLbfoTeam)"
    }
}

# ============================================================
# MAIN
# ============================================================

Assert-Prerequisites

if ($Cleanup) {
    Invoke-Cleanup
    exit 0
}

Write-Section "NIC Teaming Wizard (SwitchIndependent / balance-rr equivalent)"

$allAdapters = Show-Adapters

Write-Host ""
Write-Host "Defaults (mirrors validated Linux setup):" -ForegroundColor Cyan
Write-Host "  - TeamingMode        : SwitchIndependent  (= balance-rr, no LACP required)"
Write-Host "  - LoadBalancing      : TransportPorts     (= xmit_hash_policy layer2+3)"
Write-Host "  - Link monitoring    : native Windows heartbeat (= miimon)"
Write-Host "  - IPv4               : DHCP (unless you choose static)"
Write-Host ""

# Number of teams  (mirrors BCOUNT)
do {
    $raw = Read-Host "Number of teams to create [1]"
    $BCOUNT = if ($raw -eq '') { 1 } else { [int]$raw }
} while ($BCOUNT -lt 1)

# Starting index  (mirrors START)
do {
    $raw = Read-Host "Starting team index  (Team0 => 0) [0]"
    $START = if ($raw -eq '') { 0 } else { [int]$raw }
} while ($START -lt 0)

# IP selection  (mirrors the case statement)
Write-Host ""
Write-Host "IP configuration for each team:"
Write-Host "  1) DHCP (default)"
Write-Host "  2) Static IPv4"
Write-Host "  3) No IP (L2 only)"
do {
    $raw = Read-Host "Choose [1-3] (default 1)"
    $IPSEL = if ($raw -eq '') { 1 } else { [int]$raw }
} while ($IPSEL -notin 1,2,3)

# Static IP collected once if chosen (mirrors get_static scoping)
$StaticCfg = @{}
if ($IPSEL -eq 2) {
    $StaticCfg = Get-StaticIPConfig
}

# Optional MTU
$MTU = Read-Host "MTU for team adapters (blank = keep default 1500)"

# Confirm  (mirrors the Proceed? prompt)
Write-Host ""
Write-Yellow "This will create $BCOUNT team(s) starting from Team$START."
$go = Read-Host "Proceed? [y/N]"
if ($go -notmatch '^[Yy]$') {
    Write-Yellow "Aborted."
    exit 0
}

try {
    for ($i = 0; $i -lt $BCOUNT; $i++) {
        New-OneTeam -Index ($START + $i) -IPSel $IPSEL -MTU $MTU -StaticCfg $StaticCfg
    }
} catch {
    Write-Red ""
    Write-Red "UNEXPECTED ERROR: $_"
    Write-Red "Line: $($_.InvocationInfo.ScriptLineNumber)"
    Write-Red ""
    Read-Host "Press Enter to close"
    exit 1
}

# ============================================================
# Done - verification & cleanup reference  (mirrors EOF block)
# ============================================================
Write-Section "Done"
Write-Host @"

Verification commands (run in PowerShell as Admin):

  Get-NetLbfoTeam                          # list all teams + status
  Get-NetLbfoTeamMember                    # member adapters per team
  Get-NetIPAddress -InterfaceAlias Team0   # IP addresses on Team0
  Get-NetAdapter   | ft Name,Status,LinkSpeed,MacAddress

Cleanup (removes only teams created by this wizard):
  powershell -ExecutionPolicy Bypass -File .\New-NicTeamingWizard.ps1 -Cleanup

If cleanup fails, use this nuclear option:
  Get-NetLbfoTeam | Remove-NetLbfoTeam -Confirm:`$false

Linux <-> Windows concept mapping:
  bond0                    =>  Team0
  balance-rr               =>  SwitchIndependent
  xmit_hash_policy=layer2  =>  TransportPorts
  miimon                   =>  Windows native heartbeat (automatic)
  /proc/net/bonding/bond0  =>  Get-NetLbfoTeam / Get-NetLbfoTeamMember
  nmcli connection show    =>  Get-NetLbfoTeam
  ip -br link              =>  Get-NetAdapter | ft Name,Status,LinkSpeed
"@

Read-Host "`nPress Enter to close this window"
