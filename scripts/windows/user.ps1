# Per-user part of ./work.sh windows sync, run over the key's SSH session.
# Copies the host's guest SSH files into ~\.ssh, then stores the SSO
# credentials. An SSH login is a network logon, which has no Credential
# Manager, so that part runs as a one-shot scheduled task logged on with the
# VM password (credential.ps1). The task, its script and its data file sit in
# the user-only %TEMP% and are removed afterwards.
param(
  # .sshFiles:   [{ name, data (base64) }]
  # .credential: $null, or { script (credential.ps1), user, password,
  #              targets: [host patterns], vmPassword }
  [Parameter(Mandatory)] [psobject] $Work
)
$ErrorActionPreference = 'Stop'
# Exit non-zero on any error so work.sh reports the sync as failed. Without
# this an exception inside try/finally is printed but powershell exits 0.
trap { [Console]::Error.WriteLine("error: $_"); exit 1 }

$sshFiles = @($Work.sshFiles | Where-Object { $_ })
if ($sshFiles.Count) {
  $dir = Join-Path $env:USERPROFILE '.ssh'
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  foreach ($file in $sshFiles) {
    [IO.File]::WriteAllBytes((Join-Path $dir $file.name), [Convert]::FromBase64String($file.data))
  }
  Write-Output "  windows ssh: $(($sshFiles | ForEach-Object { $_.name }) -join ' ')"
}

$cred = $Work.credential
if (-not $cred) { return }

$task = 'work.sh credentials'
$base = Join-Path $env:TEMP "work-cred-$([guid]::NewGuid())"
$scriptPath = "$base.ps1"
$data = "$base.json"
$log = "$base.log"   # credential.ps1 reports here
try {
  [IO.File]::WriteAllText($scriptPath, $cred.script)
  $payload = @{ user = $cred.user; password = $cred.password; targets = @($cred.targets) }
  [IO.File]::WriteAllText($data, ($payload | ConvertTo-Json -Compress))

  $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" `"$data`""
  Register-ScheduledTask -TaskName $task -Action $action -Force `
    -User "$env:COMPUTERNAME\$env:USERNAME" -Password $cred.vmPassword | Out-Null
  Start-ScheduledTask -TaskName $task

  $deadline = (Get-Date).AddSeconds(60)
  while (-not (Test-Path $log)) {
    if ((Get-Date) -gt $deadline) { throw 'the credential task did not finish within 60 s' }
    Start-Sleep -Milliseconds 300
  }
  $result = (Get-Content -Path $log -Raw).TrimEnd()
  if ($result -like 'error:*') { throw $result }
  Write-Output $result
} finally {
  Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
  Remove-Item -Path $scriptPath, $data, $log, "$log.tmp" -Force -ErrorAction SilentlyContinue
}
