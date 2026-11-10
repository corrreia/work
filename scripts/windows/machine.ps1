# Machine-wide part of ./work.sh windows sync, run elevated over SSH.
# Trusts the host's CA files (self-signed into Root, the rest into
# Intermediate), lets Edge and Chrome answer Negotiate/NTLM for the SSO sites,
# and resyncs the clock: Kerberos rejects more than 5 minutes of skew.
param(
  # .certs: base64 of each certificate file (DER or PEM)
  # .sites: comma-separated host patterns for silent login, or ''
  [Parameter(Mandatory)] [psobject] $Work
)
$ErrorActionPreference = 'Stop'
# Exit non-zero on any error so work.sh reports the sync as failed. Without
# this an exception inside try/finally is printed but powershell exits 0.
trap { [Console]::Error.WriteLine("error: $_"); exit 1 }

$certs = @($Work.certs | Where-Object { $_ })
foreach ($b64 in $certs) {
  $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($b64))
  $storeName = if ($cert.Subject -eq $cert.Issuer) { 'Root' } else { 'CA' }
  $store = [System.Security.Cryptography.X509Certificates.X509Store]::new($storeName, 'LocalMachine')
  $store.Open('ReadWrite')
  try {
    if ($store.Certificates.Find('FindByThumbprint', $cert.Thumbprint, $false).Count -eq 0) {
      $store.Add($cert)
      Write-Output "  certificate added ($storeName): $($cert.Subject)"
    }
  } finally { $store.Close() }
}
Write-Output "  certificates: $($certs.Count) in sync"

if ($Work.sites) {
  foreach ($key in 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'HKLM:\SOFTWARE\Policies\Google\Chrome') {
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    Set-ItemProperty -Path $key -Name AuthServerAllowlist -Value $Work.sites -Type String
  }
  Write-Output "  browser policy: Edge + Chrome allow silent login to $($Work.sites)"
}

try {
  Start-Service w32time
  w32tm /resync /force | Out-Null
} catch {
  Write-Verbose "clock resync skipped: $_"
}
