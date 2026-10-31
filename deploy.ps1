# Copies the plugin's Lua files, plugin.json and resources/ (bundled images)
# into the RuneScape BETA dev_plugins folder.
# Usage: .\deploy.ps1   (run from anywhere; paths are relative to this script)
 
$ErrorActionPreference = 'Stop'
 
$Source = $PSScriptRoot
$Target = 'C:\ProgramData\Jagex\RuneScape-BETA\dev_plugins\rune-auras'
 
if (-not (Test-Path $Target)) {
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
    Write-Host "Created $Target"
}
 
# All .lua files (recursive, skipping .git) plus plugin.json at the repo root
$files = @(Get-ChildItem -Path $Source -Recurse -File -Filter '*.lua' |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })
$files += Get-Item (Join-Path $Source 'plugin.json')
# Bundled images, reached in Lua through Plugin.resources
$resources = Join-Path $Source 'resources'
if (Test-Path $resources) {
    $files += @(Get-ChildItem -Path $resources -Recurse -File -Filter '*.png')
}
 
foreach ($file in $files) {
    $relative = $file.FullName.Substring($Source.Length).TrimStart('\', '/')
    $dest = Join-Path $Target $relative
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    Copy-Item -Path $file.FullName -Destination $dest -Force
    Write-Host "Copied $relative"
}
 
Write-Host "Deployed $($files.Count) file(s) to $Target"

# Marks the deployed copy as a dev build: the debug options only show when
# this module is there (see UI/Windows/debug-options.lua), and it's never in
# the repo, so a release doesn't have it.
Set-Content -Path (Join-Path $Target 'UI\Windows\dev-build.lua') -Value 'return { isDevBuild = true }' -Encoding ascii
Write-Host "Wrote UI\Windows\dev-build.lua"
