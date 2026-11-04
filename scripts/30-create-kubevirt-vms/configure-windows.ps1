$ErrorActionPreference = 'Stop'
$scriptPath = $MyInvocation.MyCommand.Path
if (-not $scriptPath) { $scriptPath = 'configure-windows.ps1' }
$seedRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($scriptPath))
$logDirectory = 'C:\ProgramData\microsegmentation-iac'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
Start-Transcript -Path "$logDirectory\setup.log" -Append | Out-Null

$driverRoot = Get-PSDrive -PSProvider FileSystem | Where-Object {
    Test-Path (Join-Path $_.Root 'NetKVM')
} | Select-Object -First 1 -ExpandProperty Root
if (-not $driverRoot) { throw 'Attached VirtIO driver media was not found.' }
$networkDriver = Join-Path $driverRoot 'NetKVM\2k25\amd64\netkvm.inf'
if (-not (Test-Path $networkDriver)) { throw 'The Windows Server 2025 VirtIO network driver is missing.' }
& pnputil.exe /add-driver $networkDriver /install
if ($LASTEXITCODE -notin @(0, 3010)) { throw "Network driver installation failed: $LASTEXITCODE" }

$serialDriver = Join-Path $driverRoot 'vioserial\2k25\amd64\vioser.inf'
if (-not (Test-Path $serialDriver)) { throw 'The VirtIO serial driver is missing.' }
& pnputil.exe /add-driver $serialDriver /install
if ($LASTEXITCODE -notin @(0, 3010)) { throw "Serial driver installation failed: $LASTEXITCODE" }

$guestAgent = Join-Path $driverRoot 'guest-agent\qemu-ga-x86_64.msi'
if (-not (Test-Path $guestAgent)) { throw 'The QEMU guest-agent installer is missing.' }
$agentInstall = Start-Process msiexec.exe -ArgumentList @('/i', "`"$guestAgent`"", '/qn', '/norestart') -Wait -PassThru
if ($agentInstall.ExitCode -notin @(0, 3010)) { throw "Guest-agent installation failed: $($agentInstall.ExitCode)" }
Start-Service QEMU-GA
Set-Service QEMU-GA -StartupType Automatic

$deadline = (Get-Date).AddMinutes(5)
while (-not (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)) {
    if ((Get-Date) -gt $deadline) { throw 'No DHCP default route after driver installation.' }
    Start-Sleep -Seconds 5
}
$sshCapability = Get-WindowsCapability -Online -Name 'OpenSSH.Server*'
if ($sshCapability.State -ne 'Installed') {
    Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
}
$seedRoot = Get-PSDrive -PSProvider FileSystem | Where-Object {
    Test-Path (Join-Path $_.Root 'administrator.pub')
} | Select-Object -First 1 -ExpandProperty Root
if (-not $seedRoot) { throw 'The administrator public-key seed is missing.' }
$sshDirectory = 'C:\ProgramData\ssh'
New-Item -ItemType Directory -Path $sshDirectory -Force | Out-Null
$authorizedKeys = Join-Path $sshDirectory 'administrators_authorized_keys'
Get-Content (Join-Path $seedRoot 'administrator.pub') | Set-Content -Encoding ascii $authorizedKeys
& icacls.exe $authorizedKeys /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not secure administrator SSH keys.' }
$sshConfig = Join-Path $sshDirectory 'sshd_config'
if (-not (Test-Path $sshConfig)) {
    Copy-Item "$env:WINDIR\System32\OpenSSH\sshd_config_default" $sshConfig
}
$settings = Get-Content $sshConfig -Raw
$settings = $settings -replace '(?m)^#?PasswordAuthentication\s+\w+', 'PasswordAuthentication no'
$settings = $settings -replace '(?m)^#?PubkeyAuthentication\s+\w+', 'PubkeyAuthentication yes'
Set-Content -Path $sshConfig -Value $settings -Encoding ascii
& "$env:WINDIR\System32\OpenSSH\sshd.exe" -t
if ($LASTEXITCODE -ne 0) { throw 'sshd_config validation failed.' }
Set-Service sshd -StartupType Automatic
Start-Service sshd
if (-not (Get-NetFirewallRule -Name 'Microsegmentation-Lab-SSH' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'Microsegmentation-Lab-SSH' -DisplayName 'Lab key-authenticated SSH' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 | Out-Null
}
New-Item -ItemType File -Path "$logDirectory\setup-complete" -Force | Out-Null
$pantherLogDirectory = Join-Path $logDirectory 'panther'
New-Item -ItemType Directory -Path $pantherLogDirectory -Force | Out-Null
foreach ($logName in @('setuperr.log', 'setupact.log')) {
    $source = Join-Path 'C:\Windows\Panther' $logName
    if (Test-Path $source) {
        Copy-Item $source (Join-Path $pantherLogDirectory $logName) -Force
    }
}
Stop-Transcript | Out-Null