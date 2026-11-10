# One-time setup for ./work.sh windows sync, pasted into an elevated
# PowerShell inside Windows: installs OpenSSH Server and trusts the host's
# sync key.
param(
  # .publicKey: the host's ssh-ed25519 public key line
  [Parameter(Mandatory)] [psobject] $Work
)
$ErrorActionPreference = 'Stop'

$cap = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'
if ($cap.State -ne 'Installed') {
  Write-Output 'Installing OpenSSH Server (takes a minute)...'
  Add-WindowsCapability -Online -Name $cap.Name | Out-Null
}
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True `
    -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

# Administrators authenticate against this file, not ~\.ssh\authorized_keys.
$keys = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
if (-not ((Test-Path $keys) -and (Select-String -Path $keys -SimpleMatch $Work.publicKey -Quiet))) {
  Add-Content -Path $keys -Value $Work.publicKey -Encoding ascii
}
icacls.exe $keys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
Write-Output 'Done. On the host, run: ./work.sh windows sync'
