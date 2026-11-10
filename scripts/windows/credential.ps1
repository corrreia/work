# Stores the AD credential in Credential Manager for each SSO site, so Windows
# answers their login challenge itself. Started by user.ps1 as a scheduled task
# with an interactive logon (an SSH session cannot write Credential Manager).
# Reports through a .log next to itself, which user.ps1 waits for.
param(
  # JSON file { user, password, targets: [host patterns] }, deleted once read.
  [Parameter(Mandatory)] [string] $DataPath
)
$ErrorActionPreference = 'Stop'
$log = [IO.Path]::ChangeExtension($PSCommandPath, '.log')

try {
  $data = [IO.File]::ReadAllText($DataPath) | ConvertFrom-Json
  Remove-Item -LiteralPath $DataPath -Force

  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class WorkCred {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct CREDENTIAL {
    public int Flags; public int Type; public string TargetName; public string Comment;
    public long LastWritten; public int CredentialBlobSize; public IntPtr CredentialBlob;
    public int Persist; public int AttributeCount; public IntPtr Attributes;
    public string TargetAlias; public string UserName;
  }
  [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern bool CredWrite(ref CREDENTIAL credential, int flags);
  public static void Write(string target, string user, string pass) {
    var c = new CREDENTIAL();
    c.Type = 2;     // CRED_TYPE_DOMAIN_PASSWORD: used by Negotiate, Kerberos, NTLM
    c.Persist = 2;  // CRED_PERSIST_LOCAL_MACHINE
    c.TargetName = target;
    c.UserName = user;
    c.Comment = "Managed by work.sh";
    byte[] blob = System.Text.Encoding.Unicode.GetBytes(pass);
    c.CredentialBlobSize = blob.Length;
    c.CredentialBlob = Marshal.AllocCoTaskMem(blob.Length);
    try {
      Marshal.Copy(blob, 0, c.CredentialBlob, blob.Length);
      if (!CredWrite(ref c, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
    } finally {
      Marshal.FreeCoTaskMem(c.CredentialBlob);
    }
  }
}
'@

  $targets = @($data.targets)
  foreach ($target in $targets) { [WorkCred]::Write($target, $data.user, $data.password) }
  $result = "  credentials: $($data.user) stored for $($targets -join ', ')"
} catch {
  $result = "error: $_"
} finally {
  Remove-Item -LiteralPath $DataPath -Force -ErrorAction SilentlyContinue
}

# Write then rename, so the waiting side never reads a partial file.
Set-Content -Path "$log.tmp" -Value $result
Move-Item -Path "$log.tmp" -Destination $log -Force
