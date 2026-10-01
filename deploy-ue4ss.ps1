<#
  Copies UE4SS and the server-side mods from your game install to the Coolify host,
  as one tarball over scp, into the folder RSE-Server mounts (/srv/dragonwilds/ue4ss).

  Example:
    .\deploy-ue4ss.ps1 -Server root@your-host
    .\deploy-ue4ss.ps1 -Server kevin@your-host -Mods RSE-Transmog -WhatIf

  Only what a server needs is sent: dwmapi.dll, UE4SS.dll, its settings (hot reload
  off), the shared Lua helpers, and the mods you name. Logs, crash dumps, mod saves
  and UI-only mods stay on your PC. It connects twice (scp, then ssh to unpack), so you
  enter your key passphrase twice; load the key into ssh-agent (ssh-add) to skip both.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$Server,                       # user@host
    [string]$GameBin = 'E:\Games\Steam\steamapps\common\RSDragonwilds\RSDragonwilds\Binaries\Win64',
    [string]$Remote = '/srv/dragonwilds/ue4ss',
    [string[]]$Mods = @('RSE-Transmog', 'RSE-Toolbag'),
    [int]$Port = 22
)
$ErrorActionPreference = 'Stop'
$ue4ss = Join-Path $GameBin 'ue4ss'
if (-not (Test-Path "$GameBin\dwmapi.dll") -or -not (Test-Path "$ue4ss\UE4SS.dll")) {
    throw "UE4SS not found in $GameBin (need dwmapi.dll and ue4ss\UE4SS.dll)"
}

# Remote path (relative to $Remote) -> local file
$files = [ordered]@{}
$files['dwmapi.dll'] = "$GameBin\dwmapi.dll"
foreach ($name in 'UE4SS.dll', 'LICENSE') {
    if (Test-Path "$ue4ss\$name") { $files["ue4ss/$name"] = "$ue4ss\$name" }
}

function Add-Tree([string]$dir) {
    if (-not (Test-Path $dir)) { throw "missing: $dir" }
    Get-ChildItem $dir -File -Recurse | Where-Object {
        $_.FullName -notmatch '\\saves\\' -and $_.Extension -notin '.log', '.dmp' -and $_.Name -ne 'ui-dump.txt'
    } | ForEach-Object {
        $rel = $_.FullName.Substring($ue4ss.Length + 1) -replace '\\', '/'
        $files["ue4ss/$rel"] = $_.FullName
    }
}
Add-Tree "$ue4ss\UE4SS_SDK_Backends"
Add-Tree "$ue4ss\Mods\shared"                                     # UEHelpers, required by the RSE mods
foreach ($mod in $Mods) { Add-Tree "$ue4ss\Mods\$mod" }

# Server copies of the settings and mods list, made in a temp folder (your PC's stay as they are).
$stage = Join-Path $env:TEMP 'rse-server-ue4ss'
New-Item -ItemType Directory -Force $stage -WhatIf:$false | Out-Null
(Get-Content "$ue4ss\UE4SS-settings.ini") `
    -replace '^(EnableHotReloadSystem\s*=\s*).*', '${1}0' `
    -replace '^(ConsoleEnabled\s*=\s*).*', '${1}0' `
    -replace '^(GuiConsoleEnabled\s*=\s*).*', '${1}0' `
    -replace '^(GuiConsoleVisible\s*=\s*).*', '${1}0' |
    Set-Content "$stage\UE4SS-settings.ini" -Encoding ascii -WhatIf:$false
$files['ue4ss/UE4SS-settings.ini'] = "$stage\UE4SS-settings.ini"
($Mods | ForEach-Object { "$_ : 1" }) + '' | Set-Content "$stage\mods.txt" -Encoding ascii -WhatIf:$false
$files['ue4ss/Mods/mods.txt'] = "$stage\mods.txt"

# Lay the files out as they go on the server, pack them into one tarball, then send it
# with one scp and unpack it with one ssh: two connections instead of one per file.
$tree = Join-Path $stage 'tree'
if (Test-Path $tree) { Remove-Item $tree -Recurse -Force -WhatIf:$false }
foreach ($rel in $files.Keys) {
    $dest = Join-Path $tree ($rel -replace '/', '\')
    New-Item -ItemType Directory -Force (Split-Path $dest -Parent) -WhatIf:$false | Out-Null
    Copy-Item -LiteralPath $files[$rel] -Destination $dest -WhatIf:$false
}
$tarball = Join-Path $stage 'ue4ss.tgz'
# Windows' own tar; the Git for Windows one on PATH misreads C:\ paths.
& "$env:SystemRoot\System32\tar.exe" -czf $tarball -C $tree .
if ($LASTEXITCODE -ne 0) { throw "tar failed ($LASTEXITCODE)" }
$size = '{0:N1} MB' -f ((Get-Item $tarball).Length / 1MB)
Write-Host "Packed $($files.Count) files ($size)" -ForegroundColor Cyan
$files.Keys | ForEach-Object { Write-Verbose $_ }

$remoteTar = '/tmp/rse-server-ue4ss.tgz'
if ($PSCmdlet.ShouldProcess("${Server}:$remoteTar", "scp $tarball")) {
    scp -P $Port "$tarball" "${Server}:$remoteTar"
    if ($LASTEXITCODE -ne 0) { throw "scp failed ($LASTEXITCODE)" }
}

# Unpack over the existing folder, then hand it to uid 1000, which the container runs as.
# Windows tar marks everything world-writable; --no-same-permissions applies the server's umask instead.
$unpack = "mkdir -p '$Remote' && tar -xzf '$remoteTar' --no-same-owner --no-same-permissions -C '$Remote' && rm -f '$remoteTar' && " +
          "(sudo chown -R 1000:1000 '$Remote' || chown -R 1000:1000 '$Remote')"
if ($PSCmdlet.ShouldProcess($Server, "unpack into $Remote, chown -R 1000:1000")) {
    ssh -t -p $Port $Server $unpack
    if ($LASTEXITCODE -ne 0) { throw "unpack on server failed ($LASTEXITCODE)" }
}
Write-Host "Done. Redeploy (or restart) the server in Coolify to load them." -ForegroundColor Green
