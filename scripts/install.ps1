$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceScript = Join-Path $repoRoot 'SnipDrag.ps1'
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\SnipDrag'
$installedScript = Join-Path $installDir 'SnipDrag.ps1'
$startupDir = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDir 'SnipDrag.lnk'

if (-not (Test-Path -LiteralPath $sourceScript)) {
    throw "Could not find SnipDrag.ps1 next to the installer."
}

Write-Host 'Installing SnipDrag...'

Get-CimInstance Win32_Process |
    Where-Object {
        $_.ProcessId -ne $PID -and
        ($_.CommandLine -match '(?i)-File\s+("?)[^"]*(SnipDrag|snip-drag-thumb)\.ps1\1')
    } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Copy-Item -LiteralPath $sourceScript -Destination $installedScript -Force

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$installedScript`""
$shortcut.WorkingDirectory = $installDir
$shortcut.WindowStyle = 7
$shortcut.IconLocation = "$env:WINDIR\System32\SnippingTool.exe,0"
$shortcut.Description = 'Mac-style draggable screenshot thumbnail for Windows Snipping Tool'
$shortcut.Save()

Start-Process -FilePath powershell.exe -ArgumentList @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-STA',
    '-File', "`"$installedScript`""
) -WindowStyle Hidden

Write-Host ''
Write-Host 'SnipDrag is installed and running.'
Write-Host 'Use Win+Shift+S. A small thumbnail appears at the bottom-right.'
Write-Host 'Click it to edit in Snipping Tool, or drag it into an app.'
Write-Host ''
Write-Host "Installed to: $installDir"
Write-Host "Starts with Windows via: $shortcutPath"
