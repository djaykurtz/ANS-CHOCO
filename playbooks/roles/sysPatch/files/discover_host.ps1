<#
.SYNOPSIS
    Standalone onboarding survey for a sysPatch maintenance target. Read-only.

.DESCRIPTION
    Run this ON the target machine, from an RDP session, as a local
    administrator. It needs no network path back to the Ansible control node
    and no WinRM. It writes two files next to each other, a readable report and
    a JSON copy, which you then carry back by whatever route works.

    It answers the questions the sysPatch role cannot answer from the outside:
      - can the control node reach this host at all, and what is blocking it
      - is Windows Update redirected to an internal WSUS
      - which Dell update tool is installed, if any
      - what the SQL services and instances are actually called
      - what the scheduled tasks are actually called, and their real state
      - whether the application endpoints respond from this host

    It finishes by printing an inventory group_vars block, filled in from what
    it found, ready to paste into the repository.

    NOTHING HERE MODIFIES THE HOST. It starts nothing, stops nothing, installs
    nothing, and applies no updates. It is safe to run during business hours.

.PARAMETER OutDir
    Where to write the report and JSON. Defaults to the current user's Desktop
    so the files are easy to find and drag back over an RDP session.

.PARAMETER TaskFilter
    Regular expression matched against scheduled task names and folders. The
    default is empty, which lists every task outside the built-in \Microsoft\
    folder. That is almost always the set you want, because application jobs do
    not live under \Microsoft\. Supply a regex to narrow it, or '.' to list
    every task on the host including the operating system's own.

.PARAMETER ProbeUrl
    Endpoints to request from this host. Empty by default. Supply the URLs this
    system is expected to serve or depend on.

.PARAMETER ControlNode
    The Ansible control node. The script reports whether this host can reach it
    and what its own inbound WinRM exposure looks like, which is what you need
    to diagnose a one-way routing problem.

.EXAMPLE
    # The normal case. RDP in, open an elevated PowerShell, run it.
    powershell -ExecutionPolicy Bypass -File .\discover_host.ps1

.EXAMPLE
    # Narrow the task list and probe the endpoints this system serves.
    .\discover_host.ps1 -TaskFilter '(?i)mail|report' -ProbeUrl 'https://app.example.com'

.EXAMPLE
    # List every scheduled task, including the built-in Microsoft ones.
    .\discover_host.ps1 -TaskFilter '.'
#>
[CmdletBinding()]
param(
    [string]   $OutDir      = [Environment]::GetFolderPath('Desktop'),
    [string]   $TaskFilter  = '',
    [string[]] $ProbeUrl    = @(),
    [string]   $ControlNode = 'ansible-ctl-01.example.com'
)

$ErrorActionPreference = 'SilentlyContinue'

$lines = New-Object System.Collections.Generic.List[string]
function Emit    { param([string]$Text = '') ; $lines.Add($Text) ; Write-Host $Text }
function Section {
    param([string]$Title)
    Emit ''
    Emit ('== ' + $Title + ' ' + ('=' * [Math]::Max(0, 66 - $Title.Length)))
}

$d = [ordered]@{}

Emit 'sysPatch onboarding survey. Read-only. Nothing on this host is modified.'
Emit ("Started {0} UTC" -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Emit ''
    Emit 'WARNING: not running elevated. Scheduled task and firewall sections will be incomplete.'
}

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
$cs   = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$os   = Get-CimInstance Win32_OperatingSystem

$d['identity'] = [ordered]@{
    hostname       = $env:COMPUTERNAME
    fqdn           = ([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME)).HostName
    domain         = [string]$cs.Domain
    part_of_domain = [bool]$cs.PartOfDomain
    manufacturer   = [string]$cs.Manufacturer
    model          = [string]$cs.Model
    service_tag    = [string]$bios.SerialNumber
    bios_version   = [string]$bios.SMBIOSBIOSVersion
    is_dell        = ([string]$cs.Manufacturer -match '(?i)dell')
    os_caption     = [string]$os.Caption
    os_version     = [string]$os.Version
    os_build       = [string]$os.BuildNumber
    uptime_days    = if ($os.LastBootUpTime) { [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 2) } else { 0 }
    last_boot_utc  = if ($os.LastBootUpTime) { $os.LastBootUpTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { '' }
    survey_utc     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    surveyed_by    = "$env:USERDOMAIN\$env:USERNAME"
    elevated       = $isAdmin
}

Section 'IDENTITY'
$d['identity'].GetEnumerator() | ForEach-Object { Emit ('  {0,-16} {1}' -f $_.Key, $_.Value) }

# ---------------------------------------------------------------------------
# Network and reachability
# ---------------------------------------------------------------------------
# This section exists because the control node cannot currently reach this host
# over WinRM. The answer is almost always one of three things: no route between
# the subnets, no listener, or a firewall rule scoped to a RemoteAddress set
# that does not include the control node.
$addresses = @(
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' } |
        ForEach-Object {
            [ordered]@{
                ip        = $_.IPAddress
                prefix    = $_.PrefixLength
                interface = $_.InterfaceAlias
            }
        }
)

$routes = @(
    Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        ForEach-Object { [ordered]@{ gateway = $_.NextHop; interface = $_.InterfaceAlias; metric = $_.RouteMetric } }
)

$dns = @(
    Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.ServerAddresses.Count -gt 0 } |
        ForEach-Object { [ordered]@{ interface = $_.InterfaceAlias; servers = @($_.ServerAddresses) } }
)

# Reaching the control node from here does not prove the reverse path works,
# but a failure here means the two hosts have no path at all.
$controlReach = [ordered]@{ target = $ControlNode; dns_resolves = $false; resolved_to = @(); ssh_22 = $false; ping = $false }
try {
    $r = [System.Net.Dns]::GetHostAddresses($ControlNode)
    if ($r) { $controlReach['dns_resolves'] = $true; $controlReach['resolved_to'] = @($r | ForEach-Object { $_.IPAddressToString }) }
} catch {}
try { $controlReach['ping']   = (Test-Connection -ComputerName $ControlNode -Count 1 -Quiet -ErrorAction SilentlyContinue) } catch {}
try { $controlReach['ssh_22'] = (Test-NetConnection -ComputerName $ControlNode -Port 22 -WarningAction SilentlyContinue).TcpTestSucceeded } catch {}

$d['network'] = [ordered]@{
    addresses     = @($addresses)
    gateways      = @($routes)
    dns_servers   = @($dns)
    control_node  = $controlReach
}

Section 'NETWORK'
$addresses | ForEach-Object { Emit ('  address        {0}/{1} on {2}' -f $_.ip, $_.prefix, $_.interface) }
$routes    | ForEach-Object { Emit ('  gateway        {0} via {1} metric {2}' -f $_.gateway, $_.interface, $_.metric) }
$dns       | ForEach-Object { Emit ('  dns            {0} -> {1}' -f $_.interface, ($_.servers -join ', ')) }
Emit ('  control node   {0}' -f $ControlNode)
Emit ('    dns resolves {0} {1}' -f $controlReach['dns_resolves'], ($controlReach['resolved_to'] -join ', '))
Emit ('    icmp         {0}' -f $controlReach['ping'])
Emit ('    tcp 22       {0}' -f $controlReach['ssh_22'])

# ---------------------------------------------------------------------------
# WinRM exposure
# ---------------------------------------------------------------------------
$listeners = @()
try {
    Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue | ForEach-Object {
        $cfg = Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue
        $listeners += [ordered]@{
            transport = [string]($cfg | Where-Object Name -eq 'Transport').Value
            port      = [string]($cfg | Where-Object Name -eq 'Port').Value
            enabled   = [string]($cfg | Where-Object Name -eq 'Enabled').Value
            address   = [string]($cfg | Where-Object Name -eq 'Address').Value
        }
    }
} catch {}

$auth = [ordered]@{}
try {
    Get-ChildItem WSMan:\localhost\Service\Auth -ErrorAction SilentlyContinue | ForEach-Object { $auth[$_.Name] = $_.Value }
} catch {}

# A RemoteAddress that is not 'Any' is the usual reason a host answers WinRM
# locally but refuses the control node.
$fwRules = @()
try {
    Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match '(?i)windows remote management' } |
        ForEach-Object {
            $filter = $_ | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
            $port   = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            $fwRules += [ordered]@{
                name           = $_.DisplayName
                enabled        = [string]$_.Enabled
                profile        = [string]$_.Profile
                action         = [string]$_.Action
                direction      = [string]$_.Direction
                local_port     = [string]$port.LocalPort
                remote_address = @($filter.RemoteAddress) -join ', '
            }
        }
} catch {}

$d['winrm'] = [ordered]@{
    service_status = [string](Get-Service WinRM -ErrorAction SilentlyContinue).Status
    start_type     = [string](Get-Service WinRM -ErrorAction SilentlyContinue).StartType
    listeners      = @($listeners)
    auth           = $auth
    firewall_rules = @($fwRules)
    local_probe    = $false
}
try { $d['winrm']['local_probe'] = (Test-NetConnection -ComputerName 'localhost' -Port 5985 -WarningAction SilentlyContinue).TcpTestSucceeded } catch {}

Section 'WINRM EXPOSURE'
Emit ('  service        {0} ({1})' -f $d['winrm']['service_status'], $d['winrm']['start_type'])
Emit ('  localhost:5985 {0}' -f $d['winrm']['local_probe'])
if ($listeners.Count -eq 0) { Emit '  listeners      NONE. Nothing is listening, so no inbound WinRM is possible.' }
$listeners | ForEach-Object { Emit ('  listener       {0} port {1} enabled={2} address={3}' -f $_.transport, $_.port, $_.enabled, $_.address) }
Emit ('  auth enabled   {0}' -f (($auth.GetEnumerator() | Where-Object { $_.Value -eq $true } | ForEach-Object { $_.Key }) -join ', '))
$fwRules | ForEach-Object {
    Emit ('  firewall       {0}' -f $_.name)
    Emit ('                 enabled={0} action={1} profile={2} port={3}' -f $_.enabled, $_.action, $_.profile, $_.local_port)
    Emit ('                 remote_address={0}' -f $_.remote_address)
}

# ---------------------------------------------------------------------------
# Windows Update source
# ---------------------------------------------------------------------------
$pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$wu  = Get-ItemProperty $pol -ErrorAction SilentlyContinue
$au  = Get-ItemProperty "$pol\AU" -ErrorAction SilentlyContinue

$d['windows_update'] = [ordered]@{
    wu_server            = [string]$wu.WUServer
    wu_status_server     = [string]$wu.WUStatusServer
    use_wu_server        = $au.UseWUServer
    target_group         = [string]$wu.TargetGroup
    au_options           = $au.AUOptions
    no_auto_update       = $au.NoAutoUpdate
    do_not_connect_to_mu = $wu.DoNotConnectToWindowsUpdateInternetLocations
    source_verdict       = if ($wu.WUServer -and $au.UseWUServer -eq 1) { 'WSUS (redirected)' } else { 'Microsoft Update (direct)' }
    wuauserv_status      = [string](Get-Service wuauserv -ErrorAction SilentlyContinue).Status
    wuauserv_start_type  = [string](Get-Service wuauserv -ErrorAction SilentlyContinue).StartType
}

# A live search is the only way to answer whether unattended patching will
# actually find content. ServerSelection 1 uses whatever source this host is
# configured for, so it answers the interception question directly.
Emit ''
Emit 'Searching for applicable updates. This takes a minute or two.'
try {
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $searcher.ServerSelection = 1
    $found = $searcher.Search('IsInstalled=0 and IsHidden=0')
    $d['windows_update']['pending_count']  = @($found.Updates).Count
    $d['windows_update']['pending_titles'] = @($found.Updates | ForEach-Object { $_.Title })
    $d['windows_update']['search_error']   = ''
} catch {
    $d['windows_update']['pending_count']  = -1
    $d['windows_update']['pending_titles'] = @()
    $d['windows_update']['search_error']   = $_.Exception.Message
}

# History proves whether anything has been patching this host at all.
$history = @()
try {
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $total    = $searcher.GetTotalHistoryCount()
    if ($total -gt 0) {
        foreach ($e in $searcher.QueryHistory(0, [Math]::Min(25, $total))) {
            $history += [ordered]@{
                title    = [string]$e.Title
                date_utc = if ($e.Date) { $e.Date.ToUniversalTime().ToString('yyyy-MM-dd HH:mm') } else { '' }
                result   = switch ([int]$e.ResultCode) { 2 {'succeeded'} 3 {'succeeded_with_errors'} 4 {'failed'} 5 {'aborted'} default {'unknown'} }
            }
        }
    }
} catch {}
$d['windows_update']['history'] = @($history)

Section 'WINDOWS UPDATE'
$d['windows_update'].GetEnumerator() |
    Where-Object { $_.Key -notin @('pending_titles', 'history') } |
    ForEach-Object { Emit ('  {0,-22} {1}' -f $_.Key, $_.Value) }
if ($d['windows_update']['pending_titles'].Count -gt 0) {
    Emit '  pending updates:'
    $d['windows_update']['pending_titles'] | ForEach-Object { Emit ("    - $_") }
}
if ($history.Count -gt 0) {
    Emit '  recent history:'
    $history | ForEach-Object { Emit ('    {0}  {1,-22} {2}' -f $_.date_utc, $_.result, $_.title) }
}

# ---------------------------------------------------------------------------
# Dell update tooling
# ---------------------------------------------------------------------------
$dellCandidates = @(
    'C:\Program Files\Dell\DELL EMC System Update\dsu.exe',
    'C:\Program Files\Dell\DELL EMC System Update\bin\dsu.exe',
    'C:\Program Files (x86)\Dell\UpdatePackage\bin\dsu.exe',
    'C:\Program Files\Dell\CommandUpdate\dcu-cli.exe',
    'C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe'
)
$dellFound = @()
foreach ($c in $dellCandidates) {
    if (Test-Path -LiteralPath $c) {
        $dellFound += [ordered]@{
            path    = $c
            version = [string](Get-Item -LiteralPath $c).VersionInfo.ProductVersion
            flavor  = if ((Split-Path -Leaf $c) -match '(?i)^dcu-cli') { 'dcu' } else { 'dsu' }
        }
    }
}
# Catch an install in a non-standard location.
$dellStray = @(
    Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)dell' } | ForEach-Object { $_.FullName }
)

$d['dell'] = [ordered]@{
    is_dell          = $d['identity']['is_dell']
    tools_found      = @($dellFound)
    candidates_tried = $dellCandidates
    dell_dirs        = @($dellStray)
    services         = @(
        Get-Service -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match '(?i)dell|openmanage' } |
            ForEach-Object { [ordered]@{ name = $_.Name; display_name = $_.DisplayName; status = [string]$_.Status } }
    )
}

Section 'DELL TOOLING'
if ($dellFound.Count -eq 0) {
    Emit '  No Dell update tool found at any known path.'
    $dellCandidates | ForEach-Object { Emit ("    tried: $_") }
    if ($dellStray.Count -gt 0) {
        Emit '  Dell directories that DO exist, check these by hand:'
        $dellStray | ForEach-Object { Emit ("    $_") }
    }
} else {
    $dellFound | ForEach-Object { Emit ('  {0,-5} {1}  (v{2})' -f $_.flavor, $_.path, $_.version) }
}
$d['dell']['services'] | ForEach-Object { Emit ('  service  {0,-28} {1,-9} {2}' -f $_.name, $_.status, $_.display_name) }

# ---------------------------------------------------------------------------
# SQL Server
# ---------------------------------------------------------------------------
# This is what fills in the service name for a SQL check. A default instance is
# MSSQLSERVER. A named instance is MSSQL$<INSTANCE>.
$sqlServices = @(
    Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)^(MSSQL|SQLAgent|SQLSERVERAGENT|SQLBrowser|SQLWriter|ReportServer)' } |
        ForEach-Object {
            [ordered]@{
                name         = $_.Name
                display_name = $_.DisplayName
                status       = [string]$_.Status
                start_type   = [string]$_.StartType
            }
        }
)

$instances = @()
try {
    $key = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction SilentlyContinue
    if ($key) {
        foreach ($p in $key.PSObject.Properties) {
            if ($p.Name -notmatch '^PS') { $instances += [ordered]@{ instance = $p.Name; internal = [string]$p.Value } }
        }
    }
} catch {}

$databases = @()
try {
    foreach ($inst in $instances) {
        $target = if ($inst.instance -eq 'MSSQLSERVER') { '.' } else { ".\$($inst.instance)" }
        $conn = New-Object System.Data.SqlClient.SqlConnection("Server=$target;Database=master;Integrated Security=True;Connect Timeout=8")
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT name, state_desc, recovery_model_desc FROM sys.databases ORDER BY name"
        $rdr = $cmd.ExecuteReader()
        while ($rdr.Read()) {
            $databases += [ordered]@{ instance = $inst.instance; name = $rdr[0]; state = $rdr[1]; recovery = $rdr[2] }
        }
        $rdr.Close(); $conn.Close()
    }
} catch {
    $d['sql_query_error'] = $_.Exception.Message
}

$d['sql'] = [ordered]@{ services = @($sqlServices); instances = @($instances); databases = @($databases) }

Section 'SQL SERVER'
if ($sqlServices.Count -eq 0) { Emit '  No SQL services found on this host.' }
$sqlServices | ForEach-Object { Emit ('  {0,-26} {1,-10} {2,-12} {3}' -f $_.name, $_.status, $_.start_type, $_.display_name) }
$instances   | ForEach-Object { Emit ('  instance  {0} -> {1}' -f $_.instance, $_.internal) }
if ($databases.Count -gt 0) {
    Emit '  databases:'
    $databases | ForEach-Object { Emit ('    {0,-14} {1,-34} {2,-10} {3}' -f $_.instance, $_.name, $_.state, $_.recovery) }
} elseif ($d['sql_query_error']) {
    Emit ('  database list unavailable: {0}' -f $d['sql_query_error'])
}

# ---------------------------------------------------------------------------
# Scheduled tasks
# ---------------------------------------------------------------------------
# full_path is exactly what the role's scheduled_task check wants.
#
# An empty filter means every task outside the built-in \Microsoft\ folder.
# Application jobs never live under \Microsoft\, so this surfaces what matters
# without burying it in operating system maintenance tasks.
$tasks = @()
try {
    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object {
            if ([string]::IsNullOrWhiteSpace($TaskFilter)) {
                $_.TaskPath -notmatch '^\\Microsoft\\'
            } else {
                $_.TaskName -match $TaskFilter -or $_.TaskPath -match $TaskFilter
            }
        } |
        ForEach-Object {
            $info = Get-ScheduledTaskInfo -InputObject $_ -ErrorAction SilentlyContinue
            $tasks += [ordered]@{
                full_path   = ($_.TaskPath + $_.TaskName)
                task_name   = $_.TaskName
                task_path   = $_.TaskPath
                state       = [string]$_.State
                enabled     = [bool]$_.Settings.Enabled
                run_as      = [string]$_.Principal.UserId
                logon_type  = [string]$_.Principal.LogonType
                last_run    = if ($info -and $info.LastRunTime -and $info.LastRunTime.Year -gt 1980) { $info.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss') } else { 'never' }
                last_result = if ($info) { [int]$info.LastTaskResult } else { $null }
                next_run    = if ($info -and $info.NextRunTime) { $info.NextRunTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
                triggers    = @($_.Triggers | ForEach-Object { $_.CimClass.CimClassName })
                actions     = @($_.Actions | ForEach-Object { (([string]$_.Execute) + ' ' + ([string]$_.Arguments)).Trim() })
                working_dir = (@($_.Actions | ForEach-Object { [string]$_.WorkingDirectory }) -join '; ')
            }
        }
} catch {}

$d['scheduled_tasks'] = [ordered]@{
    filter        = $TaskFilter
    matched       = @($tasks)
    total_on_host = @(Get-ScheduledTask -ErrorAction SilentlyContinue).Count
}

$taskScope = if ([string]::IsNullOrWhiteSpace($TaskFilter)) { 'excluding the built-in \Microsoft\ folder' } else { "matching /$TaskFilter/" }
Section ("SCHEDULED TASKS $taskScope")
Emit ('  {0} of {1} tasks on this host matched.' -f $tasks.Count, $d['scheduled_tasks']['total_on_host'])
if ($tasks.Count -eq 0) {
    Emit "  Nothing matched. Re-run with -TaskFilter '.' to list every task on the host."
}
$tasks | ForEach-Object {
    Emit ''
    Emit ('  path         {0}' -f $_.full_path)
    Emit ('  state        {0}   enabled={1}' -f $_.state, $_.enabled)
    Emit ('  run as       {0} ({1})' -f $_.run_as, $_.logon_type)
    Emit ('  last run     {0}   result={1}' -f $_.last_run, $_.last_result)
    Emit ('  next run     {0}' -f $_.next_run)
    Emit ('  triggers     {0}' -f ($_.triggers -join ', '))
    Emit ('  action       {0}' -f ($_.actions -join ' | '))
    Emit ('  working dir  {0}' -f $_.working_dir)
}

# ---------------------------------------------------------------------------
# HTTP endpoints
# ---------------------------------------------------------------------------
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.ServicePointManager]::SecurityProtocol
} catch {}

$probes = @()
foreach ($u in $ProbeUrl) {
    if (-not $u) { continue }
    $row = [ordered]@{ url = $u; status = $null; ms = $null; title = ''; error = '' }
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r  = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 30 -MaximumRedirection 5
        $sw.Stop()
        $row['status'] = [int]$r.StatusCode
        $row['ms']     = [math]::Round($sw.Elapsed.TotalMilliseconds)
        if ($r.Content -match '(?is)<title>(.*?)</title>') { $row['title'] = $Matches[1].Trim() }
    } catch {
        $row['error'] = $_.Exception.Message
    }
    $probes += $row
}
$d['http_probes'] = @($probes)

Section 'HTTP PROBES from this host'
if ($probes.Count -eq 0) {
    Emit '  No endpoints supplied. Re-run with -ProbeUrl to test the URLs this'
    Emit '  system serves or depends on.'
}
$probes | ForEach-Object {
    if ($_.error) { Emit ('  {0}' -f $_.url) ; Emit ('    FAILED: {0}' -f $_.error) }
    else          { Emit ('  {0}' -f $_.url) ; Emit ('    HTTP {0} in {1} ms   {2}' -f $_.status, $_.ms, $_.title) }
}

# ---------------------------------------------------------------------------
# Sessions, disk, pending reboot
# ---------------------------------------------------------------------------
$sessions = @()
try {
    $q = & quser.exe 2>$null
    if ($LASTEXITCODE -eq 0 -and $q) {
        foreach ($line in ($q | Select-Object -Skip 1)) {
            $f = ($line.TrimStart('>', ' ')) -split '\s{2,}'
            if ($f.Count -ge 3) { $sessions += [ordered]@{ user = $f[0]; state = $f[$f.Count - 3]; logon = $f[$f.Count - 1] } }
        }
    }
} catch {}

$disks = @(
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
        ForEach-Object {
            [ordered]@{
                drive    = $_.DeviceID
                free_gb  = [math]::Round($_.FreeSpace / 1GB, 1)
                total_gb = [math]::Round($_.Size / 1GB, 1)
            }
        }
)

$rebootReasons = @()
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $rebootReasons += 'CBS:RebootPending' }
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $rebootReasons += 'WU:RebootRequired' }

$d['state'] = [ordered]@{
    sessions       = @($sessions)
    session_count  = @($sessions).Count
    disks          = @($disks)
    reboot_pending = ($rebootReasons.Count -gt 0)
    reboot_reasons = @($rebootReasons)
    choco_version  = ''
}
try { $d['state']['choco_version'] = (& choco --version 2>&1 | Out-String).Trim() } catch {}

Section 'STATE'
$disks | ForEach-Object { Emit ('  disk {0}  {1} GB free of {2} GB' -f $_.drive, $_.free_gb, $_.total_gb) }
Emit ('  sessions       {0}' -f $d['state']['session_count'])
$sessions | ForEach-Object { Emit ('    {0} ({1}) since {2}' -f $_.user, $_.state, $_.logon) }
Emit ('  reboot pending {0} {1}' -f $d['state']['reboot_pending'], ($rebootReasons -join ', '))
Emit ('  chocolatey     {0}' -f $(if ($d['state']['choco_version']) { $d['state']['choco_version'] } else { 'not installed' }))

# ---------------------------------------------------------------------------
# Suggested inventory group_vars
# ---------------------------------------------------------------------------
Section 'SUGGESTED group_vars BLOCK'
Emit 'Paste into the inventory group_vars for this system, then correct the'
Emit 'critical flags and the age thresholds. Every value below was read off'
Emit 'this host, so the names are real rather than guessed.'
Emit ''

Emit 'syspatch_verify:'
foreach ($svc in ($sqlServices | Where-Object { $_.name -match '(?i)^(MSSQL|SQLSERVERAGENT|SQLAgent)' })) {
    $key = ($svc.name -replace '[^A-Za-z0-9]', '_').ToLower()
    Emit ("  - key: $key")
    Emit ("    label: $($svc.display_name)")
    Emit  '    type: service'
    Emit ("    name: '$($svc.name)'")
    Emit  '    state: Running'
    Emit  '    critical: true'
    Emit ("    notes: 'Observed $($svc.status), start type $($svc.start_type), at survey time.'")
}
foreach ($t in $tasks) {
    $key = ($t.task_name -replace '[^A-Za-z0-9]', '_').ToLower()
    Emit ("  - key: $key")
    Emit ("    label: $($t.task_name)")
    Emit  '    type: scheduled_task'
    Emit ("    path: '$($t.full_path)'")
    Emit  '    require_ready: true'
    Emit  '    max_age_hours: 24'
    Emit  '    expect_result: 0'
    Emit  '    critical: true'
    Emit ("    notes: 'Observed state $($t.state), last run $($t.last_run), last result $($t.last_result).'")
}
foreach ($p in $probes) {
    if ($p.error) { continue }
    $host_ = ([uri]$p.url).Host
    $key   = ($host_ -replace '[^A-Za-z0-9]', '_').ToLower()
    Emit ("  - key: $key")
    Emit ("    label: $host_")
    Emit  '    type: http'
    Emit ("    url: '$($p.url)'")
    Emit  '    from: target'
    Emit ("    status: $($p.status)")
    Emit  '    validate_certs: true'
    Emit  '    critical: true'
}
Emit  '  - key: manual_end_to_end'
Emit  '    label: End to end application check'
Emit  '    type: manual'
Emit  '    critical: true'
Emit  "    instruction: 'Describe the human verification this system needs. Automation cannot assert it.'"

Emit ''
if ($dellFound.Count -gt 0) {
    Emit '# Dell tool resolved on this host:'
    Emit 'syspatch_dsu_candidates:'
    Emit ("  - '$($dellFound[0].path)'")
} else {
    Emit '# No Dell tool found. Either install one or set:'
    Emit 'syspatch_dsu_enabled: false'
}
Emit ''
Emit '# Reboot authorization, added deliberately per host:'
Emit 'syspatch_reboot_allowed_hosts:'
Emit ('  - ' + $d['identity']['hostname'].ToLower())

# ---------------------------------------------------------------------------
# Write the files
# ---------------------------------------------------------------------------
Section 'OUTPUT'
$stamp    = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$baseName = "{0}_{1}_survey" -f $stamp, $env:COMPUTERNAME

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

$txtPath  = Join-Path $OutDir "$baseName.txt"
$jsonPath = Join-Path $OutDir "$baseName.json"

$lines | Out-File -FilePath $txtPath -Encoding utf8
$d | ConvertTo-Json -Depth 8 | Out-File -FilePath $jsonPath -Encoding utf8

Write-Host ''
Write-Host "  report  $txtPath"  -ForegroundColor Green
Write-Host "  json    $jsonPath" -ForegroundColor Green
Write-Host ''
Write-Host '  Copy both files back and hand them to whoever is building the role.' -ForegroundColor Green
