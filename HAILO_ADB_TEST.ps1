param(
    # Path to adb.exe. If empty: ./adb.exe, script dir, ANDROID_HOME/ANDROID_SDK_ROOT platform-tools, PATH.
    [string]$AdbExe = '',
    [string]$Serial = '',
    [switch]$TryAdbRoot,
    [switch]$LoadModule,
    [switch]$StartService,
    [switch]$StopService
)

$ErrorActionPreference = 'Stop'

function Resolve-Adb {
    param([string]$Requested)

    $candidates = @()
    if ($Requested) { $candidates += $Requested }
    $candidates += (Join-Path (Get-Location) 'adb.exe')
    $candidates += (Join-Path $PSScriptRoot 'adb.exe')
    foreach ($sdk in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)) {
        if ($sdk) { $candidates += (Join-Path $sdk 'platform-tools\adb.exe') }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
    }

    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    throw 'adb.exe not found. Pass -AdbExe <path> or put adb.exe into the current directory / PATH.'
}

$script:Adb = Resolve-Adb -Requested $AdbExe
$script:Results = New-Object System.Collections.Generic.List[object]
$script:IsRoot = $false

function Invoke-Adb {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$AdbArgs,
        [switch]$Quiet
    )

    $fullArgs = @()
    if ($Serial) { $fullArgs += @('-s', $Serial) }
    $fullArgs += $AdbArgs

    if (-not $Quiet) { Write-Host "`n> adb $($fullArgs -join ' ')" }

    # adb writes progress (e.g. "daemon started") to stderr; PS 5.1 turns that into
    # terminating errors under 'Stop', so relax the preference for the native call.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $script:Adb @fullArgs 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }

    $lines = @($raw | ForEach-Object { "$_".TrimEnd() })
    if (-not $Quiet) { $lines | ForEach-Object { Write-Host $_ } }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Lines    = $lines
        Text     = ($lines -join "`n")
    }
}

# Runs a command as root: directly if adbd is root, else via 'su 0'.
function Invoke-Priv {
    param([string]$Command, [switch]$Quiet)

    if ($script:IsRoot) {
        return Invoke-Adb -AdbArgs @('shell', $Command) -Quiet:$Quiet
    }
    return Invoke-Adb -AdbArgs @('shell', "su 0 sh -c '$Command'") -Quiet:$Quiet
}

function Add-Result {
    param(
        [string]$Id,
        [string]$Name,
        [ValidateSet('PASS', 'FAIL', 'WARN', 'SKIP')][string]$Status,
        [string]$Detail = ''
    )

    $script:Results.Add([pscustomobject]@{ Id = $Id; Check = $Name; Status = $Status; Detail = $Detail })
    $color = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } default { 'Gray' } }
    Write-Host ("[{0}] {1} - {2} {3}" -f $Status, $Id, $Name, $Detail) -ForegroundColor $color
}

function Test-RemoteFile {
    param([string]$Path)
    $r = Invoke-Adb -AdbArgs @('shell', "ls $Path") -Quiet
    return ($r.ExitCode -eq 0 -and $r.Text -notmatch 'No such file')
}

Write-Host "Hailo ADB test start (adb: $script:Adb)"

Invoke-Adb -AdbArgs @('start-server') | Out-Null

if ($TryAdbRoot) {
    Invoke-Adb -AdbArgs @('root') | Out-Null
    Start-Sleep -Seconds 2
    Invoke-Adb -AdbArgs @('wait-for-device') -Quiet | Out-Null
}

# --- Connectivity -----------------------------------------------------------
$devices = Invoke-Adb -AdbArgs @('devices')
$attached = @($devices.Lines | Where-Object { $_ -match '^\S+\s+device$' })
if ($attached.Count -eq 0) {
    Add-Result 'A1' 'ADB device attached' 'FAIL' 'no device in state "device"'
    exit 1
}
if ($attached.Count -gt 1 -and -not $Serial) {
    Add-Result 'A1' 'ADB device attached' 'FAIL' 'multiple devices attached, pass -Serial <id>'
    exit 1
}
Add-Result 'A1' 'ADB device attached' 'PASS' $attached[0]

$script:IsRoot = ((Invoke-Adb -AdbArgs @('shell', 'id', '-u') -Quiet).Text.Trim() -eq '0')
if ($script:IsRoot) {
    Add-Result 'A2' 'Root shell' 'PASS'
} else {
    Add-Result 'A2' 'Root shell' 'WARN' 'not root; falling back to "su 0" (use -TryAdbRoot on userdebug builds)'
}

# --- Phase 0: hardware / PCIe -----------------------------------------------
$pci = Invoke-Priv 'for d in /sys/bus/pci/devices/*; do echo $d $(cat $d/vendor) $(cat $d/device); done' -Quiet
if ($pci.Text -match '0x1e60\s+0x2864') {
    Add-Result 'P1' 'Hailo-8 enumerated on PCIe (1e60:2864)' 'PASS'
} elseif ($pci.Text -match '0x1e60') {
    Add-Result 'P1' 'Hailo device enumerated on PCIe' 'WARN' 'vendor 1e60 found but device id is not 2864 (Hailo-8)'
} else {
    Add-Result 'P1' 'Hailo-8 enumerated on PCIe (1e60:2864)' 'FAIL' 'not on bus; check dtparam=pciex1 in boot/config.txt and M.2 HAT+ seating'
}

# --- Phase 1: kernel module / firmware --------------------------------------
if (Test-RemoteFile '/vendor/lib/modules/hailo_pci.ko') {
    Add-Result 'K1' 'hailo_pci.ko packaged in vendor' 'PASS'
} else {
    Add-Result 'K1' 'hailo_pci.ko packaged in vendor' 'FAIL' 'run export_android_rpi5_kernel and rebuild vendor image'
}

$fwMissing = @()
foreach ($f in @('hailo8_fw.bin', 'hailo8_board_cfg.bin', 'hailo8_fw_cfg.bin')) {
    if (-not (Test-RemoteFile "/vendor/firmware/hailo/$f")) { $fwMissing += $f }
}
if ($fwMissing.Count -eq 0) {
    Add-Result 'K5' 'Hailo firmware files present' 'PASS'
} elseif ($fwMissing -contains 'hailo8_fw.bin') {
    Add-Result 'K5' 'Hailo firmware files present' 'FAIL' ('missing: ' + ($fwMissing -join ', ') + ' (hailo8_fw.bin is mandatory)')
} else {
    Add-Result 'K5' 'Hailo firmware files present' 'WARN' ('optional files missing: ' + ($fwMissing -join ', '))
}

$cmdline = Invoke-Adb -AdbArgs @('shell', 'cat', '/proc/cmdline') -Quiet
if ($cmdline.Text -match 'firmware_class\.path=/vendor/firmware') {
    Add-Result 'K6' 'Kernel firmware search path set' 'PASS'
} else {
    Add-Result 'K6' 'Kernel firmware search path set' 'FAIL' 'cmdline lacks firmware_class.path=/vendor/firmware (rebuild boot image)'
}

if ($LoadModule) {
    $ins = Invoke-Priv 'insmod /vendor/lib/modules/hailo_pci.ko'
    if ($ins.Text -match 'File exists') {
        Add-Result 'K2' 'insmod hailo_pci.ko' 'PASS' 'already loaded'
    } elseif ($ins.Text -match 'rror|denied|not permitted|Exec format|Unknown symbol|Invalid') {
        Add-Result 'K2' 'insmod hailo_pci.ko' 'FAIL' $ins.Text.Trim()
    } else {
        Add-Result 'K2' 'insmod hailo_pci.ko' 'PASS'
    }
    Start-Sleep -Seconds 3
}

if ($StartService) {
    Invoke-Priv 'setprop persist.vendor.hailo.enabled 1' | Out-Null
    # Wait up to 30 s for the service to report vendor.hailo.status=ready (it polls every 5 s).
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 2
        $st = (Invoke-Adb -AdbArgs @('shell', 'getprop', 'vendor.hailo.status') -Quiet).Text.Trim()
        if ($st -eq 'ready') { break }
    }
}

if ($StopService) {
    Invoke-Priv 'setprop persist.vendor.hailo.enabled 0' | Out-Null
    Start-Sleep -Seconds 1
}

$lsmod = Invoke-Priv 'cat /proc/modules' -Quiet
if ($lsmod.Text -match '(?m)^hailo_pci\s') {
    Add-Result 'K3a' 'hailo_pci module loaded' 'PASS'
} else {
    Add-Result 'K3a' 'hailo_pci module loaded' 'FAIL' 'module not loaded (boot-time insmod failed? try -LoadModule and check dmesg)'
}

if (Test-RemoteFile '/dev/hailo0') {
    Add-Result 'K3' '/dev/hailo0 exists' 'PASS'
} else {
    Add-Result 'K3' '/dev/hailo0 exists' 'FAIL' 'driver did not probe the device (see dmesg)'
}

# --- Kernel log -------------------------------------------------------------
$dmesg = Invoke-Priv 'dmesg' -Quiet
if ($dmesg.Text -match 'Operation not permitted|Permission denied') {
    Add-Result 'K4' 'dmesg readable' 'WARN' 'cannot read dmesg without root'
} else {
    $hailoLines = @($dmesg.Lines | Where-Object { $_ -match '(?i)hailo' })
    if ($hailoLines.Count -gt 0) {
        Add-Result 'K4' 'Hailo messages in dmesg' 'PASS' "$($hailoLines.Count) lines"
        Write-Host "`n--- Hailo dmesg (last 40) ---"
        $hailoLines | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
    } else {
        Add-Result 'K4' 'Hailo messages in dmesg' 'FAIL' 'no hailo lines'
    }

    if ($dmesg.Text -match 'NNC Firmware loaded successfully|FW loaded, took') {
        Add-Result 'K7' 'Hailo firmware loaded' 'PASS'
    } elseif ($dmesg.Text -match 'Failed to allocate memory for file|Failed writing NNC firmware|Firmware load failed') {
        Add-Result 'K7' 'Hailo firmware loaded' 'FAIL' 'firmware request failed (path/files)'
    } else {
        Add-Result 'K7' 'Hailo firmware loaded' 'SKIP' 'no firmware messages yet'
    }

    if ($dmesg.Text -match 'avc:\s+denied.*hailo') {
        Add-Result 'S1' 'SELinux denials for hailo' 'WARN' 'avc denials present (permissive: informational)'
    }
}

# --- Phase 2: vendor service ------------------------------------------------
$prop = Invoke-Adb -AdbArgs @('shell', 'getprop', 'persist.vendor.hailo.enabled') -Quiet
Write-Host "persist.vendor.hailo.enabled = $($prop.Text.Trim())"

if (Test-RemoteFile '/vendor/etc/hailo/hailo_service.conf') {
    Add-Result 'V5' 'hailo_service.conf present' 'PASS'
} else {
    Add-Result 'V5' 'hailo_service.conf present' 'FAIL'
}

$svcState = (Invoke-Adb -AdbArgs @('shell', 'getprop', 'init.svc.vendor.hailo_service') -Quiet).Text.Trim()
if ($svcState -eq 'running') {
    Add-Result 'V3' 'vendor.hailo_service running' 'PASS'
} elseif ($StartService) {
    Add-Result 'V3' 'vendor.hailo_service running' 'FAIL' "state='$svcState'"
} else {
    Add-Result 'V3' 'vendor.hailo_service running' 'SKIP' "state='$svcState' (use -StartService)"
}

$hailoStatus = (Invoke-Adb -AdbArgs @('shell', 'getprop', 'vendor.hailo.status') -Quiet).Text.Trim()
switch ($hailoStatus) {
    'ready'          { Add-Result 'V6' 'vendor.hailo.status' 'PASS' 'ready (device probed via ioctl, firmware loaded)' }
    ''               { Add-Result 'V6' 'vendor.hailo.status' 'SKIP' 'not set (service not started)' }
    'stopped'        { Add-Result 'V6' 'vendor.hailo.status' 'SKIP' 'stopped' }
    'fw_missing'     { Add-Result 'V6' 'vendor.hailo.status' 'FAIL' 'firmware files missing in /vendor/firmware/hailo' }
    'waiting_device' { Add-Result 'V6' 'vendor.hailo.status' 'FAIL' '/dev/hailo0 not available' }
    'fw_not_loaded'  { Add-Result 'V6' 'vendor.hailo.status' 'FAIL' 'device found but firmware not loaded' }
    default          { Add-Result 'V6' 'vendor.hailo.status' 'FAIL' $hailoStatus }
}

# The runtime probe (libhailort + model) starts after the driver is ready and can take a few seconds.
$rtStatus = (Invoke-Adb -AdbArgs @('shell', 'getprop', 'vendor.hailo.rt_status') -Quiet).Text.Trim()
if ($hailoStatus -eq 'ready') {
    for ($i = 0; $i -lt 10 -and $rtStatus -eq 'not_probed'; $i++) {
        Start-Sleep -Seconds 2
        $rtStatus = (Invoke-Adb -AdbArgs @('shell', 'getprop', 'vendor.hailo.rt_status') -Quiet).Text.Trim()
    }
}
switch ($rtStatus) {
    'ok'            { Add-Result 'V7' 'HailoRT runtime probe' 'PASS' 'libhailort loaded, vdevice created, model configured' }
    ''              { Add-Result 'V7' 'HailoRT runtime probe' 'SKIP' 'not set (service not started)' }
    'not_probed'    { Add-Result 'V7' 'HailoRT runtime probe' 'SKIP' 'driver not ready yet' }
    'lib_missing'   { Add-Result 'V7' 'HailoRT runtime probe' 'WARN' '/vendor/lib64/libhailort.so not installed (tools/build_hailort_android.sh)' }
    'model_missing' { Add-Result 'V7' 'HailoRT runtime probe' 'WARN' 'vdevice ok, but no model at model_path (tools/fetch_hailo_model.ps1)' }
    default         { Add-Result 'V7' 'HailoRT runtime probe' 'FAIL' "$rtStatus (see logcat -s hailo_service)" }
}

if ($svcState -ne '' -or $hailoStatus -ne '') {
    Write-Host "`n--- hailo_service logcat ---"
    Invoke-Adb -AdbArgs @('logcat', '-d', '-s', 'hailo_service:*') | Out-Null
}

# --- Summary ----------------------------------------------------------------
Write-Host "`n=== Summary ==="
$script:Results | Format-Table Status, Id, Check, Detail -AutoSize | Out-String | Write-Host

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host "Hailo ADB test finished: $($failed.Count) failed."
if ($failed.Count -gt 0) { exit 1 }
exit 0
