$ErrorActionPreference = 'Stop'

$installDir = Join-Path $env:LOCALAPPDATA 'Programs\SnipDrag'
$startupDir = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDir 'SnipDrag.lnk'
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) 'SnipDrag'

Write-Host 'Uninstalling SnipDrag...'

Get-CimInstance Win32_Process |
    Where-Object {
        $_.ProcessId -ne $PID -and
        ($_.CommandLine -match '(?i)-File\s+("?)[^"]*(SnipDrag|snip-drag-thumb)\.ps1\1')
    } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'SnipDrag has been removed.'
