import { spawn } from 'node:child_process';
import path from 'node:path';

export interface PrivateMemoryAclPort {
    ensureDirectory(directory: string): Promise<void>;
    verifyFile(file: string): Promise<void>;
}

export const WINDOWS_MEMORY_ACL_POLICY = Object.freeze({ owner: 'currentUser', principals: ['currentUser', 'SYSTEM', 'BuiltinAdministrators'], protectedDirectory: true });

// Constant program only. Paths are a bounded JSON document on stdin, never shell code.
export const WINDOWS_MEMORY_ACL_SCRIPT = String.raw`
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
if ($request.kind -notin @('directory','file') -or $request.path -isnot [string] -or $request.path.Length -gt 32768) { throw 'Invalid ACL request' }
$target = [IO.Path]::GetFullPath($request.path)
$user = [Security.Principal.WindowsIdentity]::GetCurrent().User
$principals = @($user.Value, 'S-1-5-18', 'S-1-5-32-544') | Select-Object -Unique
function Assert-Private([string] $itemPath, [bool] $directory) {
    $item = Get-Item -LiteralPath $itemPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.PSIsContainer -ne $directory) { throw 'Unexpected private storage identity' }
    # Use the fixed .NET Framework API directly. Inherited PowerShell module
    # search paths must not select a different Security module for this check.
    $acl = if ($directory) { [IO.Directory]::GetAccessControl($itemPath) } else { [IO.File]::GetAccessControl($itemPath) }
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if (($directory -and $owner -ne $user.Value) -or (-not $directory -and $owner -notin $principals)) { throw 'Unexpected private storage owner' }
    if ($directory -and -not $acl.AreAccessRulesProtected) { throw 'Directory inheritance is not protected' }
    $rules = @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne $principals.Count) { throw 'Unexpected private storage rules' }
    $seen = @{}
    foreach ($rule in $rules) {
        $sid = $rule.IdentityReference.Value
        if ($sid -notin $principals -or $seen.ContainsKey($sid) -or $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl) { throw 'Unexpected private storage permission' }
        if ($directory -and ($rule.IsInherited -or $rule.InheritanceFlags -ne ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit) -or $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None)) { throw 'Unexpected directory inheritance' }
        $seen[$sid] = $true
    }
}
if ($request.kind -eq 'directory') {
    if (-not (Test-Path -LiteralPath $target)) {
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetOwner($user)
        $acl.SetAccessRuleProtection($true,$false)
        foreach ($sid in $principals) {
            $identity = [Security.Principal.SecurityIdentifier]::new($sid)
            $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity,[Security.AccessControl.FileSystemRights]::FullControl,([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
            $acl.AddAccessRule($rule)
        }
        # Framework overload applies the DACL only when creating new directories;
        # an existing path is verified below and is never repaired or replaced.
        [IO.Directory]::CreateDirectory($target,$acl) | Out-Null
    }
    Assert-Private $target $true
} else {
    Assert-Private ([IO.Path]::GetDirectoryName($target)) $true
    Assert-Private $target $false
}
[Console]::Out.Write('{"ok":true}')
`;

export class WindowsPrivateMemoryAcl implements PrivateMemoryAclPort {
    private run(kind: 'directory' | 'file', file: string): Promise<void> {
        if (Buffer.byteLength(file) > 32_768 || file.includes('\0') || !path.win32.isAbsolute(file)) return Promise.reject(new Error('Invalid private-memory path.'));
        const systemRoot = process.env.SystemRoot || 'C:\\Windows';
        if (!path.win32.isAbsolute(systemRoot)) return Promise.reject(new Error('Windows security tools unavailable.'));
        const executable = path.win32.join(systemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
        return new Promise((resolve, reject) => {
            const child = spawn(executable, ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', WINDOWS_MEMORY_ACL_SCRIPT], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'], shell: false });
            let output = '', bytes = 0, settled = false;
            const finish = (ok: boolean) => { if (settled) return; settled = true; clearTimeout(timer); if (ok) resolve(); else reject(new Error('Windows private-memory ACL verification failed. No selected fact was written.')); };
            const timer = setTimeout(() => { child.kill(); finish(false); }, 10_000);
            child.on('error', () => finish(false));
            child.stdout.on('data', (data: Buffer) => { bytes += data.length; if (bytes > 4096) { child.kill(); finish(false); } else output += data.toString('utf8'); });
            child.stderr.on('data', (data: Buffer) => { bytes += data.length; if (bytes > 4096) { child.kill(); finish(false); } });
            child.stdin.on('error', () => finish(false));
            child.on('close', code => finish(code === 0 && output.trim() === '{"ok":true}'));
            child.stdin.end(JSON.stringify({ kind, path: file }));
        });
    }
    ensureDirectory(directory: string): Promise<void> { return this.run('directory', directory); }
    verifyFile(file: string): Promise<void> { return this.run('file', file); }
}
