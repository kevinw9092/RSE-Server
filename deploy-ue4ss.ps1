<#
  Copies UE4SS and the server-side mods from your game install to the Coolify host,
  file by file with scp, into the folder RSE-Server mounts (/srv/dragonwilds/ue4ss).

  Example:
    .\deploy-ue4ss.ps1 -Server root@your-host
    .\deploy-ue4ss.ps1 -Server kevin@your-host -Mods RSE-Transmog -WhatIf

  Only what a server needs is sent: dwmapi.dll, UE4SS.dll, its settings (hot reload
  off), the shared Lua helpers, and the mods you name. Logs, crash dumps, mod saves
  and UI-only mods stay on your PC. Use an SSH key, or you type the password per file.
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
New-Item -ItemType Directory -Force $stage | Out-Null
(Get-Content "$ue4ss\UE4SS-settings.ini") `
    -replace '^(EnableHotReloadSystem\s*=\s*).*', '${1}0' `
    -replace '^(ConsoleEnabled\s*=\s*).*', '${1}0' `
    -replace '^(GuiConsoleEnabled\s*=\s*).*', '${1}0' `
    -replace '^(GuiConsoleVisible\s*=\s*).*', '${1}0' |
    Set-Content "$stage\UE4SS-settings.ini" -Encoding ascii
$files['ue4ss/UE4SS-settings.ini'] = "$stage\UE4SS-settings.ini"
($Mods | ForEach-Object { "$_ : 1" }) + '' | Set-Content "$stage\mods.txt" -Encoding ascii
$files['ue4ss/Mods/mods.txt'] = "$stage\mods.txt"

# Folders first (one ssh call), then each file.
$dirs = $files.Keys | ForEach-Object { $d = Split-Path $_ -Parent; if ($d) { "$Remote/" + ($d -replace '\\', '/') } } | Sort-Object -Unique
$dirs = @($Remote) + $dirs
Write-Host "Sending $($files.Count) files to ${Server}:$Remote" -ForegroundColor Cyan
if ($PSCmdlet.ShouldProcess($Server, "mkdir -p $($dirs.Count) folders")) {
    ssh -p $Port $Server ("mkdir -p " + (($dirs | ForEach-Object { "'$_'" }) -join ' '))
    if ($LASTEXITCODE -ne 0) { throw "ssh mkdir failed ($LASTEXITCODE)" }
}
$i = 0
foreach ($rel in $files.Keys) {
    $i++
    $target = "${Server}:$Remote/$rel"
    if ($PSCmdlet.ShouldProcess($target, "scp $($files[$rel])")) {
        Write-Host ("[{0}/{1}] {2}" -f $i, $files.Count, $rel)
        scp -q -P $Port "$($files[$rel])" "$target"
        if ($LASTEXITCODE -ne 0) { throw "scp failed for $rel ($LASTEXITCODE)" }
    }
}

# The container runs as uid 1000.
if ($PSCmdlet.ShouldProcess($Server, "chown -R 1000:1000 $Remote")) {
    ssh -t -p $Port $Server "sudo chown -R 1000:1000 '$Remote' || chown -R 1000:1000 '$Remote'"
}
Write-Host "Done. Redeploy (or restart) the server in Coolify to load them." -ForegroundColor Green
