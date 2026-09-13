<#
.SYNOPSIS
  Memory dashboard + game mode for Windows. Console or localhost web UI.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\memguard.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File .\memguard.ps1 -Overlay -Game auto
  powershell -NoProfile -ExecutionPolicy Bypass -File .\memguard.ps1 -Game WeatherExpress
  powershell -NoProfile -ExecutionPolicy Bypass -File .\memguard.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [string]$Game,                 # game mode: process name (.exe optional), or 'auto' for foreground app
    [int]$Top = 15,
    [int]$Interval = 3,            # console mode: seconds between refreshes
    [int]$TrimAtPct = 80,          # game mode: only trim when RAM usage >= this %
    [switch]$Overlay,              # translucent always-on-top widget (WPF)
    [switch]$Hidden,              # launch with no visible window (off Task Manager's Apps list)
    [switch]$Once,
    [switch]$NoElevate,            # run without the UAC relaunch (fewer processes reachable)
    [switch]$Child,               # internal: set on the hidden relaunch to stop it looping
    [switch]$Install,             # register logon auto-start + create the app shortcut
    [switch]$Uninstall,           # remove the auto-start task
    [switch]$Shortcut,            # just (re)create the desktop / Start Menu app shortcut
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

# Never touch these - trimming them destabilises the session.
$Protected = @(
    'System', 'Idle', 'Registry', 'Memory Compression', 'csrss', 'wininit',
    'services', 'lsass', 'smss', 'winlogon', 'dwm', 'MsMpEng', 'fontdrvhost'
)

Add-Type -Name Psapi -Namespace Mem -MemberDefinition @'
[DllImport("psapi.dll", SetLastError=true)]
public static extern bool EmptyWorkingSet(IntPtr hProcess);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern IntPtr OpenProcess(int access, bool inherit, int pid);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool CloseHandle(IntPtr handle);
[DllImport("user32.dll")]
public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll", SetLastError=true)]
public static extern int GetWindowThreadProcessId(IntPtr hWnd, out int pid);
[DllImport("user32.dll", SetLastError=true)]
public static extern bool DestroyIcon(IntPtr hIcon);
'@

Add-Type -Namespace Sh -Name Tray -MemberDefinition @"
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public struct NID {
    public int cbSize; public System.IntPtr hWnd; public int uID; public int uFlags;
    public int uCallbackMessage; public System.IntPtr hIcon;
    [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst=128)] public string szTip;
}
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool Shell_NotifyIcon(int msg, ref NID d);
"@

# Consoles/shells/browsers are never the game - if one is in front, keep the previous pick.
# Browsers matter here: you view this dashboard in one, and it must not steal the game slot.
$NotAGame = @(
    'powershell', 'pwsh', 'WindowsTerminal', 'conhost', 'cmd', 'explorer',
    'chrome', 'msedge', 'firefox', 'brave', 'whale', 'opera'
)

# PROCESS_SET_QUOTA | PROCESS_QUERY_INFORMATION - the least a trim needs.
# Process.Handle asks for ALL_ACCESS and gets denied on most system processes.
$OPEN_FOR_TRIM = 0x0500

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

# Works both as a .ps1 and as a ps2exe-packaged MEMGUARD.exe. When packaged,
# $PSCommandPath is empty, so resolve the real running file and default to the widget.
$ExePath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$AsExe = $ExePath -notmatch '(?i)(powershell|pwsh)\.exe$'
$SelfPath = if ($AsExe) { $ExePath } elseif ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
if ($AsExe -and -not ($Overlay -or $Install -or $Uninstall -or $Shortcut -or $SelfTest -or $Once)) { $Overlay = $true }

function Invoke-Elevate {
    param([hashtable]$Bound)
    $argList = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $SelfPath)
    foreach ($k in $Bound.Keys) {
        $v = $Bound[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $argList += "-$k" } }
        else { $argList += @("-$k", "$v") }
    }
    Start-Process powershell -Verb RunAs -ArgumentList $argList
}

function Get-MemStat {
    $os = Get-CimInstance Win32_OperatingSystem
    $total = [int]($os.TotalVisibleMemorySize / 1KB)
    $free = [int]($os.FreePhysicalMemory / 1KB)
    [pscustomobject]@{
        TotalMB = $total
        FreeMB  = $free
        UsedPct = [int](100 * ($total - $free) / $total)
    }
}

# Fast system utilisation via formatted perf counters. GPU/disk fall back to 0 when unavailable.
function Get-SysStat {
    $m = Get-MemStat
    $cpu = 0; $gpu = 0; $ssd = 0
    try { $cpu = [int]((Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime) } catch { }
    try {
        $eng = Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop
        $gpu = [int][Math]::Min(100, (($eng | Measure-Object UtilizationPercentage -Maximum).Maximum))
    } catch { }
    try {
        $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        if ($d.Size) { $ssd = [int](100 * ($d.Size - $d.FreeSpace) / $d.Size) }
    } catch { }
    [pscustomobject]@{ cpu = $cpu; gpu = $gpu; ram = $m.UsedPct; ssd = $ssd }
}

# Reads the existing "AI Token Monitor" cache in ~/.claude (read-only). Claude+Codex combined.
function Get-TokenStat {
    $base = Join-Path $env:USERPROFILE '.claude'
    $tok = $null; $planC = $null; $planX = $null
    # Claude plan from credentials (tier fields are not secrets)
    try {
        $cr = Get-Content (Join-Path $base '.credentials.json') -Raw | ConvertFrom-Json
        $sub = $cr.claudeAiOauth.subscriptionType; $tier = $cr.claudeAiOauth.rateLimitTier
        if ($sub) { $planC = (Get-Culture).TextInfo.ToTitleCase([string]$sub); if ($tier -match 'max_(\d+x)') { $planC = "$planC $($Matches[1])" } }
    } catch { }
    # Codex plan from ~/.codex id_token (decode the plan claim only)
    try {
        $ca = Get-Content (Join-Path $env:USERPROFILE '.codex\auth.json') -Raw | ConvertFrom-Json
        $pl = $ca.tokens.id_token.Split('.')[1].Replace('-', '+').Replace('_', '/')
        $pl = $pl.PadRight($pl.Length + (4 - $pl.Length % 4) % 4, '=')
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pl)) | ConvertFrom-Json
        $cp = $claims.'https://api.openai.com/auth'.chatgpt_plan_type
        if ($cp) { $planX = (Get-Culture).TextInfo.ToTitleCase([string]$cp) }
    } catch { }
    # monthly Claude tokens from the AI Token Monitor cache
    try {
        $cache = Get-Content (Join-Path $base 'ai-token-monitor-cache.json') -Raw | ConvertFrom-Json
        $mon = $cache.months.((Get-Date -Format 'yyyy-MM'))
        if ($mon -and $mon.model_usage) { $tt = 0; foreach ($mu in $mon.model_usage.PSObject.Properties) { $tt += ([long]$mu.Value.output_tokens + [long]$mu.Value.input_tokens + [long]$mu.Value.cache_read + [long]$mu.Value.cache_write) }; $tok = $tt }
    } catch { }
    $now = Get-Date
    $reset = (Get-Date -Year $now.Year -Month $now.Month -Day 1).AddMonths(1).ToString('MMM d')
    [pscustomobject]@{ planClaude = $planC; planCodex = $planX; tokens = $tok; reset = $reset }
}

# Static hardware detail for the hover tooltips (product names / specs).
function Get-HwInfo {
    $cpu = 'CPU'; $gpu = 'GPU'; $ram = 'RAM'; $ssd = 'SSD'
    try { $c = Get-CimInstance Win32_Processor | Select-Object -First 1
        $cpu = "$($c.Name.Trim())`n$($c.NumberOfCores)C / $($c.NumberOfLogicalProcessors)T  @ $([math]::Round($c.MaxClockSpeed / 1000, 2)) GHz" } catch { }
    try { $gs = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic|Remote|Meta|Virtual|Mirror' })
        $gpu = (($gs | ForEach-Object { $_.Name.Trim() }) -join "`n") } catch { }
    try { $m = @(Get-CimInstance Win32_PhysicalMemory); $f = $m | Select-Object -First 1
        $tot = [math]::Round((($m | Measure-Object Capacity -Sum).Sum) / 1GB)
        $ram = "$tot GB  @ $($f.Speed) MHz`n$($m.Count) x $($f.Manufacturer.Trim()) $([math]::Round($f.Capacity / 1GB)) GB" } catch { }
    try { $ds = @(Get-CimInstance Win32_DiskDrive | Sort-Object Index)
        $ssd = (($ds | ForEach-Object { "$($_.Model.Trim())  $([math]::Round($_.Size / 1GB)) GB" }) -join "`n") } catch { }
    [pscustomobject]@{ cpu = $cpu; gpu = $gpu; ram = $ram; ssd = $ssd }
}

function Get-TopMemory {
    param([int]$Count = 15)   # Count <= 0 returns every process, not a top slice
    $all = Get-Process | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{
            Name  = $_.Name
            Procs = $_.Count
            MB    = [math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1MB, 1)
        }
    } | Sort-Object MB -Descending
    if ($Count -le 0) { $all } else { $all | Select-Object -First $Count }
}

function Get-ForegroundProcessName {
    $hwnd = [Mem.Psapi]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return $null }
    $procId = 0
    [void][Mem.Psapi]::GetWindowThreadProcessId($hwnd, [ref]$procId)
    (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName
}

function Resolve-GameName {
    param([string]$Detected, [string]$Current)
    if (-not $Detected) { return $Current }
    if ($NotAGame -contains $Detected) { return $Current }
    return $Detected
}

function Get-TrimTargets {
    param([string[]]$Keep = @())
    $skip = $Protected + $Keep
    Get-Process | Where-Object { $skip -notcontains $_.ProcessName -and $_.Id -ne $PID }
}

# ponytail: EmptyWorkingSet pushes pages to the pagefile. Frees physical RAM now,
# costs page faults when that app is used again - hence the TrimAtPct gate.
function Invoke-Trim {
    param([string[]]$Keep = @())
    $before = (Get-MemStat).FreeMB
    $ok = 0
    $denied = 0
    foreach ($p in Get-TrimTargets -Keep $Keep) {
        $h = [Mem.Psapi]::OpenProcess($OPEN_FOR_TRIM, $false, $p.Id)
        if ($h -eq [IntPtr]::Zero) { $denied++; continue }
        if ([Mem.Psapi]::EmptyWorkingSet($h)) { $ok++ } else { $denied++ }
        [void][Mem.Psapi]::CloseHandle($h)
    }
    [pscustomobject]@{ Trimmed = $ok; Denied = $denied; FreedMB = (Get-MemStat).FreeMB - $before }
}

# Kill every process of a name, minus the protected list. Destructive - callers gate on a click.
function Invoke-KillByName {
    param([string]$Name)
    if (-not $Name -or $Protected -contains $Name) {
        return [pscustomobject]@{ Name = $Name; Killed = 0; Blocked = $true }
    }
    $killed = 0
    foreach ($p in Get-Process -Name $Name -ErrorAction SilentlyContinue) {
        if ($p.Id -eq $PID) { continue }
        try { $p.Kill(); $killed++ } catch { }
    }
    [pscustomobject]@{ Name = $Name; Killed = $killed; Blocked = $false }
}

# What else closes when you END this: how many processes share the name, and any child
# processes it spawned (those may close too). Helps avoid breaking a linked program.
function Get-KillImpact {
    param([string]$Name)
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $targets = @($all | Where-Object { ($_.Name -replace '\.exe$', '') -ieq $Name })
    $procIds = @($targets.ProcessId)
    $children = @($all | Where-Object { $procIds -contains $_.ParentProcessId -and $procIds -notcontains $_.ProcessId } |
            ForEach-Object { ($_.Name -replace '\.exe$', '') } | Sort-Object -Unique)
    [pscustomobject]@{ Count = $targets.Count; Children = $children }
}

# Trim only the named processes' working sets (multi-select trim).
function Invoke-TrimNames {
    param([string[]]$Names)
    $before = (Get-MemStat).FreeMB; $ok = 0
    foreach ($nm in $Names) {
        foreach ($pp in Get-Process -Name $nm -ErrorAction SilentlyContinue) {
            if ($pp.Id -eq $PID) { continue }
            $h = [Mem.Psapi]::OpenProcess($OPEN_FOR_TRIM, $false, $pp.Id)
            if ($h -ne [IntPtr]::Zero) { [void][Mem.Psapi]::EmptyWorkingSet($h); [void][Mem.Psapi]::CloseHandle($h); $ok++ }
        }
    }
    [pscustomobject]@{ Trimmed = $ok; FreedMB = (Get-MemStat).FreeMB - $before }
}

# Rule-based memory-management advisor. Read-only inspection -> concrete suggestions.
# 'apply' is set only for safe, reversible OS toggles; BIOS/pagefile stay suggest-only.
function Get-Suggestions {
    $out = @()
    $stat = Get-MemStat

    # RAM running below its rated speed -> XMP/EXPO almost certainly off in BIOS.
    try {
        $dimm = Get-CimInstance Win32_PhysicalMemory | Select-Object -First 1
        if ($dimm -and $dimm.ConfiguredClockSpeed -and $dimm.Speed -and $dimm.ConfiguredClockSpeed -lt $dimm.Speed) {
            $out += [pscustomobject]@{
                level = 'warn'; title = "RAM at $($dimm.ConfiguredClockSpeed) MHz, rated $($dimm.Speed) MHz"
                detail = 'Enable XMP/EXPO in BIOS to run memory at its rated speed. Manual - reboot into BIOS (Del/F2), turn on the XMP/EXPO profile.'
                apply = $null
            }
        }
    } catch { }

    # Memory Compression: keep it ON when RAM is tight (fits more in physical RAM).
    try {
        $mc = (Get-MMAgent).MemoryCompression
        if (-not $mc) {
            $out += [pscustomobject]@{ level = 'warn'; title = 'Memory Compression is OFF'
                detail = 'Turning it on packs more into physical RAM before paging to disk.'; apply = 'mc-on' }
        } else {
            $out += [pscustomobject]@{ level = 'ok'; title = 'Memory Compression is ON'; detail = 'Good - staying enabled.'; apply = $null }
        }
    } catch { }

    # Too many startup apps eat RAM before you do anything.
    try {
        $startup = @(Get-CimInstance Win32_StartupCommand).Count
        if ($startup -ge 12) {
            $out += [pscustomobject]@{ level = 'warn'; title = "$startup startup programs"
                detail = 'Trim autostart apps in Task Manager > Startup to free boot-time RAM.'; apply = $null }
        }
    } catch { }

    # Free RAM already low -> a standby-list flush (trim) is the quick win.
    if ($stat.UsedPct -ge 85) {
        $out += [pscustomobject]@{ level = 'bad'; title = "$($stat.UsedPct)% RAM in use"
            detail = 'Press TRIM NOW to reclaim working sets, or close the top consumers below.'; apply = 'trim' }
    }

    if (-not $out) { $out += [pscustomobject]@{ level = 'ok'; title = 'No memory issues found'; detail = 'System looks healthy.'; apply = $null } }
    $out
}

# Apply a whitelisted, reversible action. No BIOS, no pagefile - those stay manual.
function Invoke-Apply {
    param([string]$Id)
    switch ($Id) {
        'mc-on'  { try { Enable-MMAgent -MemoryCompression -ErrorAction Stop; return [pscustomobject]@{ ok = $true; msg = 'Memory Compression enabled' } } catch { return [pscustomobject]@{ ok = $false; msg = "$($_.Exception.Message)" } } }
        'mc-off' { try { Disable-MMAgent -MemoryCompression -ErrorAction Stop; return [pscustomobject]@{ ok = $true; msg = 'Memory Compression disabled' } } catch { return [pscustomobject]@{ ok = $false; msg = "$($_.Exception.Message)" } } }
        'trim'   { $r = Invoke-Trim -Keep @($script:target | Where-Object { $_ }); return [pscustomobject]@{ ok = $true; msg = "trimmed $($r.Trimmed), freed $($r.FreedMB) MB" } }
        default  { return [pscustomobject]@{ ok = $false; msg = "unknown action '$Id'" } }
    }
}

function Set-GamePriority {
    param([string]$Name)
    $gp = Get-Process -Name $Name -ErrorAction SilentlyContinue
    if (-not $gp) { return $false }
    foreach ($g in $gp) { try { $g.PriorityClass = 'High' } catch { } }
    return $true
}

# One tick of game mode. In web mode the browser's poll is the tick.
function Invoke-GameTick {
    param([int]$UsedPct)
    if (-not $Game) { return [pscustomobject]@{ Note = $null; Trimmed = $false } }

    if ($script:auto) {
        $script:target = Resolve-GameName -Detected (Get-ForegroundProcessName) -Current $script:target
    }
    if ($script:target -and $script:target -ne $script:boosted -and (Set-GamePriority $script:target)) {
        $script:boosted = $script:target
    }
    if (-not $script:target) {
        return [pscustomobject]@{ Note = 'GAME MODE [auto] waiting for a foreground app'; Trimmed = $false }
    }
    if ($UsedPct -lt $TrimAtPct) {
        return [pscustomobject]@{ Note = "GAME MODE [$script:target] standby - trims at $TrimAtPct% used"; Trimmed = $false }
    }
    $r = Invoke-Trim -Keep @($script:target)
    [pscustomobject]@{
        Note    = "GAME MODE [$script:target] trimmed $($r.Trimmed) procs (denied $($r.Denied)), freed $($r.FreedMB) MB"
        Trimmed = $true
    }
}

function Get-Snapshot {
    param([int]$RowCount = $Top)   # web passes 0 to show the full process list
    $stat = Get-MemStat
    $tick = Invoke-GameTick -UsedPct $stat.UsedPct
    if ($tick.Trimmed) { $stat = Get-MemStat }
    [pscustomobject]@{
        time    = (Get-Date -Format 'HH:mm:ss')
        totalMB = $stat.TotalMB
        freeMB  = $stat.FreeMB
        usedPct = $stat.UsedPct
        admin   = [bool]$IsAdmin
        game    = $script:target
        note    = $tick.Note
        rows    = @(Get-TopMemory -Count $RowCount)
    }
}

function Show-Dashboard {
    param($Snap)
    $bar = ('#' * [int]($Snap.usedPct / 2)).PadRight(50, '.')
    $color = if ($Snap.usedPct -ge 90) { 'Red' } elseif ($Snap.usedPct -ge 75) { 'Yellow' } else { 'Green' }
    $mode = if ($Snap.admin) { 'ADMIN' } else { 'USER (limited reach)' }

    Clear-Host
    Write-Host "MEMGUARD  $($Snap.time)   [$mode]   Ctrl+C to quit" -ForegroundColor Cyan
    Write-Host ("[{0}] {1}% used  ({2} MB free / {3} MB)" -f $bar, $Snap.usedPct, $Snap.freeMB, $Snap.totalMB) -ForegroundColor $color
    if ($Snap.note) { Write-Host $Snap.note -ForegroundColor Magenta }
    Write-Host ''
    Write-Host ('{0,-30}{1,7}{2,12}' -f 'PROCESS', 'COUNT', 'MEMORY MB') -ForegroundColor DarkGray
    foreach ($r in $Snap.rows) {
        $c = if ($r.MB -ge 1000) { 'Red' } elseif ($r.MB -ge 300) { 'Yellow' } else { 'Gray' }
        Write-Host ('{0,-30}{1,7}{2,12}' -f $r.Name, $r.Procs, $r.MB) -ForegroundColor $c
    }
}


# Translucent, borderless, always-on-top widget. Native WPF - zero dependencies.
# Reuses the same Get-MemStat / Get-TopMemory / Invoke-Trim / Invoke-KillByName in-process.
$OverlayXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ResizeMode="CanResizeWithGrip" ShowInTaskbar="False" Title="MEMGUARD"
        SizeToContent="Manual" Width="340" Height="600" MinWidth="300" MinHeight="380" Left="40" Top="40" FontFamily="Segoe UI">
  <Border x:Name="root" CornerRadius="14" Background="#E60B0F14" BorderBrush="#332B3644" BorderThickness="1" Padding="16">
    <DockPanel LastChildFill="True">
      <Grid DockPanel.Dock="Top">
        <TextBlock Text="MEMGUARD" Foreground="#58A6FF" FontWeight="Bold" FontSize="13"/>
        <Button x:Name="closeBtn" Content="&#10005;" HorizontalAlignment="Right" Width="22" Height="22"
                Foreground="#8B949E" Background="Transparent" BorderThickness="0" FontSize="12" Cursor="Hand"/>
      </Grid>
      <Grid DockPanel.Dock="Top" Margin="0,10,0,12">
        <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
        <StackPanel x:Name="cpuCell" Grid.Column="0"><TextBlock Text="CPU" Foreground="#7D8998" FontSize="11"/><TextBlock x:Name="cpuP" FontSize="21" FontWeight="Bold" Foreground="#E6EDF3" Margin="0,1,0,0"/></StackPanel>
        <StackPanel x:Name="gpuCell" Grid.Column="1"><TextBlock Text="GPU" Foreground="#7D8998" FontSize="11"/><TextBlock x:Name="gpuP" FontSize="21" FontWeight="Bold" Foreground="#E6EDF3" Margin="0,1,0,0"/></StackPanel>
        <StackPanel x:Name="ramCell" Grid.Column="2"><TextBlock Text="RAM" Foreground="#7D8998" FontSize="11"/><TextBlock x:Name="ramP2" FontSize="21" FontWeight="Bold" Foreground="#E6EDF3" Margin="0,1,0,0"/></StackPanel>
        <StackPanel x:Name="ssdCell" Grid.Column="3"><TextBlock Text="SSD" Foreground="#7D8998" FontSize="11"/><TextBlock x:Name="ssdP" FontSize="21" FontWeight="Bold" Foreground="#E6EDF3" Margin="0,1,0,0"/></StackPanel>
      </Grid>
      <Border DockPanel.Dock="Top" BorderBrush="#1A222C" BorderThickness="0,1,0,1" Padding="0,8" Margin="0,0,0,10">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0" Orientation="Horizontal" Margin="0,0,14,0"><TextBlock Text="Claude " Foreground="#7D8998" FontSize="12"/><TextBlock x:Name="tokToday" Foreground="#E6EDF3" FontSize="12"/></StackPanel>
          <StackPanel Grid.Column="1" Orientation="Horizontal"><TextBlock Text="Codex " Foreground="#7D8998" FontSize="12"/><TextBlock x:Name="tokMonth" Foreground="#E6EDF3" FontSize="12"/></StackPanel>
          <StackPanel Grid.Column="2" Orientation="Horizontal" HorizontalAlignment="Right"><TextBlock Text="resets " Foreground="#7D8998" FontSize="12"/><TextBlock x:Name="tokReset" Foreground="#7D8998" FontSize="12"/></StackPanel>
        </Grid>
      </Border>      <TextBlock x:Name="listHdr" DockPanel.Dock="Top" Foreground="#7D8998" FontSize="10" Margin="0,0,0,4"/>
      <TextBlock x:Name="noteText" DockPanel.Dock="Bottom" Foreground="#D2A8FF" FontSize="10" TextWrapping="Wrap" Margin="0,8,0,0"/>
      <Grid DockPanel.Dock="Bottom" Margin="0,2,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <Button x:Name="trimBtn" Grid.Column="0" Content="TRIM NOW" Height="30" Foreground="#E6EDF3" Background="#1B2430"
                BorderBrush="#2B3644" BorderThickness="1" FontWeight="SemiBold" FontSize="12" Cursor="Hand"/>
        <Button x:Name="trimSelBtn" Grid.Column="1" Content="TRIM SELECTED" Height="30" Margin="8,0,0,0" Padding="10,0,10,0"
                Foreground="#E6EDF3" Background="#1B2430" BorderBrush="#2B3644" BorderThickness="1"
                FontWeight="SemiBold" FontSize="12" Cursor="Hand"/>
        <Button x:Name="applyBtn" Grid.Column="2" Content="APPLY FIX" Height="30" Margin="8,0,0,0" Padding="12,0,12,0"
                Foreground="#5FDC8A" Background="#12301C" BorderBrush="#1F5130" BorderThickness="1"
                FontWeight="SemiBold" FontSize="12" Cursor="Hand" Visibility="Collapsed"/>
      </Grid>
      <TextBlock x:Name="sugText" DockPanel.Dock="Bottom" Foreground="#E3B341" FontSize="11" TextWrapping="Wrap" Margin="0,8,0,4"/>
      <ScrollViewer x:Name="listScroll" VerticalScrollBarVisibility="Auto">
        <StackPanel x:Name="rowHost"/>
      </ScrollViewer>
    </DockPanel>  </Border>
</Window>
'@

function Invoke-Overlay {
    # Single instance: closing the app frees the mutex so relaunch works; a second
    # launch while one is already up exits quietly instead of stacking tray icons.
    $created = $false
    $script:mutex = New-Object Threading.Mutex($true, 'Local\MEMGUARD_Widget', [ref]$created)
    # Shared signal: a second launch pings this so the already-running widget re-shows itself.
    $script:showEvt = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, 'Local\MEMGUARD_Show')
    if (-not $created) { [void]$script:showEvt.Set(); return }   # already running -> wake it, then exit

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
    $reader = New-Object Xml.XmlNodeReader ([xml]$OverlayXaml)
    $win = [Windows.Markup.XamlReader]::Load($reader)

    # Live tray icon, Task-Manager style: a bottom-up fill bar coloured by load.
    # Tray via Win32 Shell_NotifyIcon on the window's own HWND - WinForms NotifyIcon would not
    # register under this ps2exe/WPF host. Added on SourceInitialized once the HWND exists.
    $WM_TRAY = 0x8001
    $restore = { $win.Show(); $win.Visibility = 'Visible'; $win.WindowState = 'Normal'; $win.Topmost = $false; $win.Topmost = $true; [void]$win.Activate() }
    $trayMenu = New-Object Windows.Controls.ContextMenu; $trayMenu.Placement = 'MousePoint'
    $miShow = New-Object Windows.Controls.MenuItem; $miShow.Header = 'Show widget'; $miShow.Add_Click($restore); [void]$trayMenu.Items.Add($miShow)
    $miTrim = New-Object Windows.Controls.MenuItem; $miTrim.Header = 'Trim now'; $miTrim.Add_Click({ [void](Invoke-Trim -Keep @($script:target | Where-Object { $_ })) }); [void]$trayMenu.Items.Add($miTrim)
    $miExit = New-Object Windows.Controls.MenuItem; $miExit.Header = 'Exit'; $miExit.Add_Click({ $win.Close() }); [void]$trayMenu.Items.Add($miExit)
    $win.Add_SourceInitialized({
            $hwnd = (New-Object Windows.Interop.WindowInteropHelper $win).Handle
            $ico = $null
            try { if ($AsExe) { $ico = [Drawing.Icon]::ExtractAssociatedIcon($SelfPath) } else { $ic = Join-Path (Split-Path $SelfPath) 'MEMGUARD.ico'; if (Test-Path $ic) { $ico = New-Object Drawing.Icon $ic } } } catch { }
            if (-not $ico) { $ico = [Drawing.SystemIcons]::Application }
            $script:trayIco = $ico
            $d = New-Object 'Sh.Tray+NID'
            $d.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($d); $d.hWnd = $hwnd; $d.uID = 1
            $d.uFlags = 7; $d.uCallbackMessage = $WM_TRAY; $d.hIcon = $ico.Handle; $d.szTip = 'MEMGUARD'
            $script:nid = $d
            [void][Sh.Tray]::Shell_NotifyIcon(0, [ref]$script:nid)
            $src = [Windows.Interop.HwndSource]::FromHwnd($hwnd)
            $src.AddHook([Windows.Interop.HwndSourceHook]{
                    param($h, $m, $wp, $lp, $handled)
                    if ($m -eq 0x8001) {
                        $ev = $lp.ToInt32()
                        if ($ev -eq 0x203 -or $ev -eq 0x202) { & $restore }
                        elseif ($ev -eq 0x205) { $trayMenu.IsOpen = $true }
                    }
                    return [IntPtr]::Zero
                })
        })
    $pctText = $win.FindName('pctText'); $freeText = $win.FindName('freeText')
    $bar = $win.FindName('bar'); $noteText = $win.FindName('noteText'); $rowHost = $win.FindName('rowHost')
    $listHdr = $win.FindName('listHdr'); $sugText = $win.FindName('sugText'); $applyBtn = $win.FindName('applyBtn')
    $listScroll = $win.FindName('listScroll')
    $cpuP = $win.FindName('cpuP'); $gpuP = $win.FindName('gpuP'); $ramP2 = $win.FindName('ramP2'); $ssdP = $win.FindName('ssdP')
    $tokToday = $win.FindName('tokToday'); $tokMonth = $win.FindName('tokMonth'); $tokReset = $win.FindName('tokReset'); $tokTokens = $win.FindName('tokTokens')
    $cpuCell = $win.FindName('cpuCell'); $gpuCell = $win.FindName('gpuCell'); $ramCell = $win.FindName('ramCell'); $ssdCell = $win.FindName('ssdCell')
    try { $hw = Get-HwInfo; $cpuCell.ToolTip = $hw.cpu; $gpuCell.ToolTip = $hw.gpu; $ramCell.ToolTip = $hw.ram; $ssdCell.ToolTip = $hw.ssd } catch { }
    $brush = { param($hex) [Windows.Media.BrushConverter]::new().ConvertFrom($hex) }
    $script:descCache = @{}
    if ($null -eq $script:collapsed) { $script:collapsed = @{} }
    if ($null -eq $script:selected) { $script:selected = @{} }
    $rowInfo = {
        param($name)
        if (-not $script:descCache.ContainsKey($name)) {
            $desc = ''; $co = ''; $path = ''
            try {
                $pp = Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($pp) { $desc = [string]$pp.Description; $co = [string]$pp.Company; try { $path = [string]$pp.Path } catch { } }
            } catch { }
            $ln = $name.ToLower(); $pl = $path.ToLower(); $cat = 'App'
            $browsers = 'chrome msedge firefox brave whale opera vivaldi arc iexplore'
            $office = 'winword excel powerpnt outlook onenote onedrive hwp acrobat acrord32 notepad notepad++ wordpad'
            $dev = 'code devenv node python python3 java git powershell pwsh cmd windowsterminal conhost docker rider pycharm goland idea sublime_text'
            $comms = 'discord slack teams kakaotalk telegram whatsapp zoom skype line messenger'
            $media = 'spotify vlc wmplayer potplayer foobar2000 musicbee itunes'
            $games = 'leagueclient leagueclientux leagueclientuxrender valorant valorant-win64-shipping riotclientservices vgc csgo cs2 dota2 steam steamwebhelper epicgameslauncher gog galaxyclient battle.net'
            if ($browsers.Split(' ') -contains $ln) { $cat = 'Browser' }
            elseif ($comms.Split(' ') -contains $ln) { $cat = 'Communication' }
            elseif ($office.Split(' ') -contains $ln) { $cat = 'Office' }
            elseif ($dev.Split(' ') -contains $ln) { $cat = 'Dev tools' }
            elseif ($media.Split(' ') -contains $ln) { $cat = 'Media' }
            elseif (($games.Split(' ') -contains $ln) -or ($pl -match 'steamapps|epic games|gog|riot games|battle\.net')) { $cat = 'Game' }
            $script:descCache[$name] = [pscustomobject]@{ friendly = $(if ($desc) { $desc } else { "$name.exe" }); company = $co; category = $cat }
        }
        $script:descCache[$name]
    }
    $trackWidth = 288.0
    $script:applyId = $null
    $sugEvery = 5   # refresh suggestions every Nth tick (they change slowly)
    $script:tickN = 0

    $col = { param($p) if ($p -ge 90) { '#F85149' } elseif ($p -ge 75) { '#E3B341' } else { '#3FB950' } }
    $fmt = { param($mb) if ($mb -ge 1024) { '{0:N1} GB' -f ($mb / 1024) } else { '{0:N0} MB' -f $mb } }

    $refresh = {
        $stat = Get-MemStat
        $tick = Invoke-GameTick -UsedPct $stat.UsedPct
        if ($tick.Trimmed) { $stat = Get-MemStat }
        $sys = Get-SysStat
        $cpuP.Text = "$($sys.cpu)%"; $cpuP.Foreground = (& $brush (& $col $sys.cpu))
        $gpuP.Text = "$($sys.gpu)%"; $gpuP.Foreground = (& $brush (& $col $sys.gpu))
        $ramP2.Text = "$($sys.ram)%"; $ramP2.Foreground = (& $brush (& $col $sys.ram))
        $ssdP.Text = "$($sys.ssd)%"; $ssdP.Foreground = (& $brush (& $col $sys.ssd))
        if ($script:tickN % 10 -eq 0) {
            $tk = Get-TokenStat
            $cmp = { param($x) if ($null -eq $x) { '--' } elseif ($x -ge 1e9) { '{0:N1}B' -f ($x / 1e9) } elseif ($x -ge 1e6) { '{0:N1}M' -f ($x / 1e6) } elseif ($x -ge 1e3) { '{0:N0}K' -f ($x / 1e3) } else { "$x" } }
            $tokToday.Text = if ($tk.planClaude) { $tk.planClaude } else { '--' }
            $tokMonth.Text = if ($tk.planCodex) { $tk.planCodex } else { '--' }
            $tokReset.Text = $tk.reset
        }
        $noteText.Text = $tick.Note
        $noteText.Visibility = if ($tick.Note) { 'Visible' } else { 'Collapsed' }

        $blk = [char]0x2588; $emp = [char]0x2591
        $b5 = { param($v) $ff = [int][math]::Round(([double]$v) / 20); if ($ff -lt 0) { $ff = 0 } elseif ($ff -gt 5) { $ff = 5 }; ([string]$blk * $ff) + ([string]$emp * (5 - $ff)) }
        $tt = "CPU $(& $b5 $sys.cpu) $($sys.cpu)%`nGPU $(& $b5 $sys.gpu) $($sys.gpu)%`nRAM $(& $b5 $sys.ram) $($sys.ram)%`nSSD $(& $b5 $sys.ssd) $($sys.ssd)%"
        try { $script:nid.szTip = $tt; [void][Sh.Tray]::Shell_NotifyIcon(1, [ref]$script:nid) } catch { }

        # Suggestions change slowly - recompute every few ticks, not every second.
        if ($script:tickN % $sugEvery -eq 0) {
            $top = @(Get-Suggestions) | Sort-Object { @{ bad = 0; warn = 1; ok = 2 }[$_.level] } | Select-Object -First 1
            if ($top) {
                $sugText.Text = "> $($top.title): $($top.detail)"
                $script:applyId = $top.apply
                $applyBtn.Visibility = if ($top.apply) { 'Visible' } else { 'Collapsed' }
            }
        }
        $script:tickN++

        $allRows = @(Get-TopMemory -Count 0)
        $listHdr.Text = "PROCESSES BY CATEGORY ($($allRows.Count))"
        $rowHost.Children.Clear()
        $annot = foreach ($r in $allRows) {
            $info = & $rowInfo $r.Name
            if ($Protected -contains $r.Name) { $cat = 'System'; $col = '#7D8998'; $safe = 'System process - never trimmed' }
            elseif ($script:target -and $r.Name -eq $script:target) { $cat = 'Game'; $col = '#58A6FF'; $safe = 'Your game - kept out of trim' }
            elseif ($info.category -eq 'Game') { $cat = 'Game'; $col = '#58A6FF'; $safe = 'Game - safe to trim when not playing' }
            else { $cat = $info.category; $col = '#3FB950'; $safe = 'Safe to trim - frees RAM now, reloads on next use' }
            [pscustomobject]@{ Name = $r.Name; MB = $r.MB; friendly = $info.friendly; company = $info.company; cat = $cat; col = $col; safe = $safe }
        }
        $groups = $annot | Group-Object cat | ForEach-Object {
            [pscustomobject]@{ cat = $_.Name; col = $_.Group[0].col; items = @($_.Group | Sort-Object MB -Descending); total = (($_.Group | Measure-Object MB -Sum).Sum) }
        } | Sort-Object total -Descending
        foreach ($grp in $groups) {
            $isCol = [bool]$script:collapsed[$grp.cat]
            $chev = if ($isCol) { [char]0x25B6 } else { [char]0x25BC }
            $hg = New-Object Windows.Controls.Grid
            $h0 = New-Object Windows.Controls.ColumnDefinition; $h0.Width = '*'
            $h1 = New-Object Windows.Controls.ColumnDefinition; $h1.Width = 'Auto'
            [void]$hg.ColumnDefinitions.Add($h0); [void]$hg.ColumnDefinitions.Add($h1)
            $hl = New-Object Windows.Controls.TextBlock; $hl.Text = "$chev  $($grp.cat.ToUpper())  ($($grp.items.Count))"; $hl.Foreground = $grp.col; $hl.FontSize = 10; $hl.FontWeight = 'Bold'; [Windows.Controls.Grid]::SetColumn($hl, 0)
            $ht = New-Object Windows.Controls.TextBlock; $ht.Text = (& $fmt $grp.total); $ht.Foreground = '#7D8998'; $ht.FontSize = 10; $ht.VerticalAlignment = 'Center'; [Windows.Controls.Grid]::SetColumn($ht, 1)
            [void]$hg.Children.Add($hl); [void]$hg.Children.Add($ht)
            $bd = New-Object Windows.Controls.Border; $bd.BorderBrush = '#1A222C'; $bd.BorderThickness = '0,0,0,1'; $bd.Padding = '0,2,0,3'; $bd.Margin = '0,8,0,4'; $bd.Child = $hg
            $bd.Background = '#01000000'; $bd.Cursor = 'Hand'; $bd.Tag = $grp.cat
            $bd.ToolTip = 'Click to collapse / expand'
            $bd.Add_MouseLeftButtonDown({ param($s, $e); $script:collapsed[$s.Tag] = -not [bool]$script:collapsed[$s.Tag]; $e.Handled = $true; & $refresh })
            [void]$rowHost.Children.Add($bd)
            if (-not $isCol) {
                foreach ($it in $grp.items) {
                    $g = New-Object Windows.Controls.Grid; $g.Margin = '0,3,0,3'
                    $tip = $it.friendly; if ($it.company) { $tip += "  -  $($it.company)" }
                    $g.ToolTip = "$tip`n$($it.safe)"
                    $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = 'Auto'
                    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = '*'
                    $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = 'Auto'
                    $c3 = New-Object Windows.Controls.ColumnDefinition; $c3.Width = 'Auto'
                    [void]$g.ColumnDefinitions.Add($c0); [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2); [void]$g.ColumnDefinitions.Add($c3)
                    $cb = New-Object Windows.Controls.CheckBox; $cb.IsChecked = [bool]$script:selected[$it.Name]; $cb.Tag = $it.Name; $cb.VerticalAlignment = 'Center'; $cb.Margin = '0,0,7,0'; [Windows.Controls.Grid]::SetColumn($cb, 0)
                    $cb.Add_Click({ if ($this.IsChecked) { $script:selected[$this.Tag] = $true } else { [void]$script:selected.Remove($this.Tag) } })
                    $nn = New-Object Windows.Controls.TextBlock; $nn.Text = $it.friendly; $nn.Foreground = '#C9D1D9'; $nn.FontSize = 12; $nn.TextTrimming = 'CharacterEllipsis'; $nn.VerticalAlignment = 'Center'; [Windows.Controls.Grid]::SetColumn($nn, 1)
                    $m = New-Object Windows.Controls.TextBlock; $m.Text = (& $fmt $it.MB); $m.Foreground = $(if ($it.MB -ge 1000) { '#F85149' } elseif ($it.MB -ge 300) { '#E3B341' } else { '#7D8998' }); $m.FontSize = 12; $m.Margin = '8,0,8,0'; $m.VerticalAlignment = 'Center'; [Windows.Controls.Grid]::SetColumn($m, 2)
                    $k = New-Object Windows.Controls.Button; $k.Content = 'END'; $k.FontSize = 10; $k.Foreground = '#F0A0A8'; $k.Background = '#1A1418'; $k.BorderBrush = '#3A2530'; $k.Padding = '6,2,6,2'; $k.Cursor = 'Hand'; $k.Tag = $it.Name; $k.VerticalAlignment = 'Center'; [Windows.Controls.Grid]::SetColumn($k, 3)
                    $k.Add_Click({
                            $nm = $this.Tag
                            $imp = Get-KillImpact -Name $nm
                            $msg = "End '$nm'?`n`n$($imp.Count) process(es) with this name will close."
                            if ($imp.Children.Count) { $msg += "`n`nPrograms it launched (these may close too):`n" + ($imp.Children -join ', ') }
                            $msg += "`n`nIf you have unsaved work in this app, save it first."
                            if ([System.Windows.MessageBox]::Show($msg, 'MEMGUARD - end process', 'YesNo', 'Warning') -eq 'Yes') { [void](Invoke-KillByName -Name $nm); & $refresh }
                        }.GetNewClosure())
                    [void]$g.Children.Add($cb); [void]$g.Children.Add($nn); [void]$g.Children.Add($m); [void]$g.Children.Add($k)
                    [void]$rowHost.Children.Add($g)
                }
            }
        }
    }

    # Tear the tray icon down with the window, or its ghost lingers in the notification area.
    $win.Add_Closed({
            try { [void][Sh.Tray]::Shell_NotifyIcon(2, [ref]$script:nid) } catch { }
            try { $script:mutex.ReleaseMutex(); $script:mutex.Dispose() } catch { }
            try { $script:showEvt.Dispose() } catch { }
        })
    # X hides the widget to the tray (icon stays); full quit is tray -> Exit.
    $win.FindName('closeBtn').Add_Click({ $win.Hide() })
    $win.FindName('trimBtn').Add_Click({ [void](Invoke-Trim -Keep @($script:target | Where-Object { $_ })); & $refresh })
    $applyBtn.Add_Click({ if ($script:applyId) { [void](Invoke-Apply -Id $script:applyId); & $refresh } })
    $trimSelBtn = $win.FindName('trimSelBtn')
    $trimSelBtn.Add_Click({ $names = @($script:selected.Keys); if ($names.Count) { $rr = Invoke-TrimNames -Names $names; $noteText.Text = "trimmed $($rr.Trimmed) selected procs, freed $($rr.FreedMB) MB" } else { $noteText.Text = 'Select processes with the checkboxes first' }; & $refresh })
    # Double-click = maximise to the work area (not over the taskbar) / restore; single drag = move.
    $script:restoreBounds = $null
    $win.Add_MouseLeftButtonDown({
            param($s, $e)
            if ($e.ClickCount -eq 2) {
                if ($script:restoreBounds) {
                    $b = $script:restoreBounds; $script:restoreBounds = $null
                    $win.Left = $b[0]; $win.Top = $b[1]; $win.Width = $b[2]; $win.Height = $b[3]
                } else {
                    $script:restoreBounds = @($win.Left, $win.Top, $win.Width, $win.Height)
                    $wa = [Windows.SystemParameters]::WorkArea
                    $win.Left = $wa.Left; $win.Top = $wa.Top; $win.Width = $wa.Width; $win.Height = $wa.Height
                }
            } else {
                $win.DragMove()
            }
        })

    # Opacity + size are adjustable and persist across the auto-start relaunch.
    # Script scope so the wheel handler and the apply/save blocks share one copy.
    $script:wSettings = Join-Path (Split-Path $SelfPath) 'memguard-widget.json'
    $script:wOp = 0.95; $script:wScale = 1.0
    if (Test-Path $script:wSettings) {
        try { $s = Get-Content $script:wSettings -Raw | ConvertFrom-Json; $script:wOp = [double]$s.opacity; $script:wScale = [double]$s.scale } catch { }
    }
    $script:wOp = [Math]::Round([Math]::Max(0.25, [Math]::Min(1.0, $script:wOp)), 2)
    $script:wScale = [Math]::Round([Math]::Max(0.6, [Math]::Min(2.0, $script:wScale)), 2)
    $root = $win.FindName('root')
    $applyLook = {
        $win.Opacity = $script:wOp
        $root.LayoutTransform = New-Object Windows.Media.ScaleTransform $script:wScale, $script:wScale
    }
    $saveLook = { @{ opacity = $script:wOp; scale = $script:wScale } | ConvertTo-Json -Compress | Set-Content $script:wSettings -Encoding UTF8 }
    & $applyLook
    & $refresh

    # Plain wheel scrolls the process list (left unhandled so the ScrollViewer gets it).
    # Ctrl+wheel = widget size; Shift+wheel = transparency.
    $win.Add_PreviewMouseWheel({
            param($s, $e)   # WPF passes (sender, args) - $_ is NOT the event args here
            $mod = [Windows.Input.Keyboard]::Modifiers
            $step = if ($e.Delta -gt 0) { 1 } else { -1 }
            if ($mod -band [Windows.Input.ModifierKeys]::Control) {
                $script:wScale = [Math]::Round([Math]::Max(0.6, [Math]::Min(2.0, $script:wScale + 0.1 * $step)), 2)
            } elseif ($mod -band [Windows.Input.ModifierKeys]::Shift) {
                $script:wOp = [Math]::Round([Math]::Max(0.25, [Math]::Min(1.0, $script:wOp + 0.05 * $step)), 2)
            } else {
                return   # no modifier: let the list scroll
            }
            & $applyLook; & $saveLook
            $e.Handled = $true
        })

    # Poll the wake signal so relaunching the app brings a hidden widget back to front.
    $showTimer = New-Object Windows.Threading.DispatcherTimer
    $showTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $showTimer.Add_Tick({
            if ($script:showEvt.WaitOne(0)) {
                $win.WindowState = 'Normal'; $win.Show(); $win.Visibility = 'Visible'
                $win.Topmost = $false; $win.Topmost = $true; [void]$win.Activate()
            }
        })
    $showTimer.Start()

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds([Math]::Max(1, $Interval))
    $timer.Add_Tick($refresh)
    $timer.Start()
    [void]$win.ShowDialog()
}

$TaskName = 'MEMGUARD Widget'

# Create a double-click "app" shortcut (Desktop + Start Menu) that (re)launches the widget.
# So after closing the widget you just double-click MEMGUARD to start it again.
function New-WidgetShortcut {
    $game = if ($Game) { $Game } else { 'auto' }
    $exe = Join-Path (Split-Path $SelfPath) 'MEMGUARD.exe'
    if (Test-Path $exe) {
        $target = $exe; $arg = "-Game $game"; $icon = "$exe,0"
    } else {
        $target = (Get-Command powershell).Source
        $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SelfPath`" -Overlay -Child -Game $game"
        $icon = "$env:SystemRoot\System32\imageres.dll,-109"
    }
    $dirs = @(
        [Environment]::GetFolderPath('Desktop'),
        (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs')
    )
    $sh = New-Object -ComObject WScript.Shell
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) { continue }
        $lnk = $sh.CreateShortcut((Join-Path $d 'MEMGUARD.lnk'))
        $lnk.TargetPath = $target
        $lnk.Arguments = $arg
        $lnk.WorkingDirectory = Split-Path $SelfPath
        $lnk.IconLocation = $icon
        $lnk.Description = 'MEMGUARD memory widget'
        $lnk.Save()
    }
    Write-Host 'Created MEMGUARD app shortcut on Desktop and Start Menu.' -ForegroundColor Green
}

# Register a logon-triggered scheduled task so the widget is always up after sign-in.
# RunLevel Highest = starts elevated with no UAC prompt each login (needed for full trim reach).
function Install-Autostart {
    $game = if ($Game) { $Game } else { 'auto' }
    $exe = Join-Path (Split-Path $SelfPath) 'MEMGUARD.exe'
    if (Test-Path $exe) {
        $exec = $exe; $a = "-Game $game"
    } else {
        $exec = (Get-Command powershell).Source
        $a = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SelfPath`" -Overlay -Child -Game $game"
    }
    $action = New-ScheduledTaskAction -Execute $exec -Argument $a
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "Installed auto-start task '$TaskName' (runs the widget at logon)." -ForegroundColor Green
    New-WidgetShortcut
    Start-Process $exec -ArgumentList $a -WindowStyle Hidden   # launch now too
}

function Uninstall-Autostart {
    # Full uninstall: stop the widget, remove the task, shortcuts, and settings.
    Get-Process MEMGUARD -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*memguard*-Overlay*' -and $_.ProcessId -ne $PID } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $dirs = @([Environment]::GetFolderPath('Desktop'), (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'))
    foreach ($d in $dirs) { $lnk = Join-Path $d 'MEMGUARD.lnk'; if (Test-Path $lnk) { Remove-Item $lnk -Force -ErrorAction SilentlyContinue } }
    $cfg = Join-Path (Split-Path $SelfPath) 'memguard-widget.json'
    if (Test-Path $cfg) { Remove-Item $cfg -Force -ErrorAction SilentlyContinue }
    Write-Host 'MEMGUARD uninstalled - widget stopped; auto-start task, shortcuts, and settings removed.' -ForegroundColor Green
    Write-Host 'The MEMGUARD.exe / .ico / .ps1 files are still in this folder - delete them manually if you want.' -ForegroundColor Yellow
}

function Invoke-SelfTest {
    $stat = Get-MemStat
    if ($stat.TotalMB -le 0) { throw 'FAIL: TotalMB' }
    if ($stat.FreeMB -gt $stat.TotalMB) { throw 'FAIL: FreeMB > TotalMB' }
    if ($stat.UsedPct -lt 0 -or $stat.UsedPct -gt 100) { throw 'FAIL: UsedPct range' }

    $rows = @(Get-TopMemory -Count 5)
    if ($rows.Count -gt 5) { throw 'FAIL: Top count' }
    for ($i = 1; $i -lt $rows.Count; $i++) {
        if ($rows[$i - 1].MB -lt $rows[$i].MB) { throw 'FAIL: not sorted descending' }
    }
    $allRows = @(Get-TopMemory -Count 0)
    if ($allRows.Count -le $rows.Count) { throw 'FAIL: -Count 0 did not return the full list' }

    $targets = @(Get-TrimTargets -Keep @('explorer'))
    if ($targets | Where-Object { $Protected -contains $_.ProcessName }) { throw 'FAIL: protected process in targets' }
    if ($targets | Where-Object { $_.ProcessName -eq 'explorer' }) { throw 'FAIL: kept process in targets' }
    if ($targets | Where-Object { $_.Id -eq $PID }) { throw 'FAIL: self in targets' }

    $h = [Mem.Psapi]::OpenProcess($OPEN_FOR_TRIM, $false, $PID)
    if ($h -eq [IntPtr]::Zero) { throw 'FAIL: OpenProcess on self' }
    if (-not [Mem.Psapi]::CloseHandle($h)) { throw 'FAIL: CloseHandle' }

    if ((Resolve-GameName -Detected 'powershell' -Current 'Doom') -ne 'Doom') { throw 'FAIL: console stole the game slot' }
    if ((Resolve-GameName -Detected $null -Current 'Doom') -ne 'Doom') { throw 'FAIL: null detection dropped current' }
    if ((Resolve-GameName -Detected 'Doom' -Current $null) -ne 'Doom') { throw 'FAIL: detection ignored' }
    [void](Get-ForegroundProcessName)   # must not throw

    $json = Get-Snapshot | ConvertTo-Json -Depth 4 -Compress | ConvertFrom-Json
    if ($null -eq $json.usedPct) { throw 'FAIL: snapshot usedPct missing' }
    if (@($json.rows).Count -lt 1) { throw 'FAIL: snapshot rows empty' }
    if ($null -eq $json.rows[0].Name) { throw 'FAIL: snapshot row shape' }
    $blocked = Invoke-KillByName -Name 'csrss'
    if (-not $blocked.Blocked) { throw 'FAIL: kill did not block a protected process' }
    if ($blocked.Killed -ne 0) { throw 'FAIL: kill touched a protected process' }

    $sug = @(Get-Suggestions)
    if ($sug.Count -lt 1) { throw 'FAIL: no suggestions produced' }
    if (-not $sug[0].PSObject.Properties['level']) { throw 'FAIL: suggestion shape' }
    if ((Invoke-Apply -Id 'no-such-action').ok) { throw 'FAIL: unknown apply id was accepted' }

    if ($OverlayXaml -notmatch 'closeBtn') { throw 'FAIL: overlay missing close button' }
    if ($OverlayXaml -notmatch 'x:Name="root"') { throw 'FAIL: overlay missing scalable root' }

    # Tray icon draw: a 16x16 bitmap -> HICON must succeed and be releasable (no GDI leak).
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object Drawing.Bitmap 16, 16
    $hicon = $bmp.GetHicon()
    if ($hicon -eq [IntPtr]::Zero) { throw 'FAIL: tray HICON' }
    if (-not [Mem.Psapi]::DestroyIcon($hicon)) { throw 'FAIL: DestroyIcon on tray HICON' }
    $bmp.Dispose()
    if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) { throw 'FAIL: ScheduledTasks module missing' }

    Write-Host "SelfTest OK (admin=$IsAdmin)" -ForegroundColor Green
}

$script:auto = ($Game -eq 'auto')
$script:target = if ($Game -and -not $script:auto) { [IO.Path]::GetFileNameWithoutExtension($Game) } else { $null }
$script:boosted = $null

if ($SelfTest) { Invoke-SelfTest; return }
if ($Shortcut) { New-WidgetShortcut; return }   # user-folder shortcut, no elevation needed

# -Hidden: relaunch once with no window so it stays off Task Manager's Apps list.
# Honest scope: it still shows under Details as a powershell process. Truly cloaking a
# process from the Details/Processes tab needs rootkit techniques - not something this does.
if ($Hidden -and -not $Child) {
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $SelfPath, '-Child')
    foreach ($k in $PSBoundParameters.Keys) {
        if ($k -in 'Hidden', 'Child') { continue }
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $args += "-$k" } } else { $args += @("-$k", "$v") }
    }
    $sp = @{ FilePath = 'powershell'; ArgumentList = $args; WindowStyle = 'Hidden' }
    if (-not $IsAdmin -and -not $NoElevate) { $sp.Verb = 'RunAs' }
    Start-Process @sp
    return
}

if (-not $IsAdmin -and -not $NoElevate -and -not $Child -and -not $AsExe) {
    Write-Host 'Not elevated - relaunching as admin to reach every process...' -ForegroundColor Yellow
    Invoke-Elevate -Bound $PSBoundParameters
    return
}

# Expected to fail when non-elevated. In the noConsole exe a Write-Warning becomes a
# popup dialog, so only surface it in console (.ps1) mode.
try { [Diagnostics.Process]::EnterDebugMode() } catch { if (-not $AsExe) { Write-Warning 'SeDebugPrivilege unavailable' } }

if ($Uninstall) { Uninstall-Autostart; return }
if ($Install) { Install-Autostart; return }

if ($script:target -and -not $AsExe -and -not (Get-Process -Name $script:target -ErrorAction SilentlyContinue)) {
    Write-Warning "Game process '$script:target' not running yet - will still free RAM for it."
}

if ($Overlay) { Invoke-Overlay; return }

do {
    Show-Dashboard -Snap (Get-Snapshot)
    if (-not $Once) { Start-Sleep -Seconds $Interval }
} while (-not $Once)
