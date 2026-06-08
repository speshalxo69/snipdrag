param(
    [int]$HideAfterSeconds = 5,
    [int]$MaxFiles = 40,
    [int]$BridgeFileLifetimeSeconds = 90,
    [string]$OutputDir = (Join-Path ([System.IO.Path]::GetTempPath()) 'SnipDrag')
)

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $argList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-STA',
        '-File', "`"$PSCommandPath`"",
        '-HideAfterSeconds', $HideAfterSeconds,
        '-MaxFiles', $MaxFiles,
        '-BridgeFileLifetimeSeconds', $BridgeFileLifetimeSeconds,
        '-OutputDir', "`"$OutputDir`""
    )
    Start-Process -FilePath powershell.exe -ArgumentList $argList -WindowStyle Hidden
    exit
}

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\SnipDragThumb', [ref]$createdNew)
if (-not $createdNew) {
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime

Add-Type -ReferencedAssemblies 'System.Windows.Forms.dll','System.Drawing.dll' -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public class NoActivateForm : Form
{
    protected override bool ShowWithoutActivation
    {
        get { return true; }
    }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
            cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
            return cp;
        }
    }
}

public static class ClipboardNative
{
    [DllImport("user32.dll")]
    public static extern uint GetClipboardSequenceNumber();
}

public static class WindowTools
{
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int command);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    public static bool BringProcessWindowToFront(string processName)
    {
        IntPtr found = IntPtr.Zero;

        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            if (!IsWindowVisible(hWnd)) {
                return true;
            }

            uint processId;
            GetWindowThreadProcessId(hWnd, out processId);

            try {
                using (Process process = Process.GetProcessById((int)processId)) {
                    if (String.Equals(process.ProcessName, processName, StringComparison.OrdinalIgnoreCase)) {
                        StringBuilder title = new StringBuilder(512);
                        GetWindowText(hWnd, title, title.Capacity);
                        if (title.Length > 0) {
                            found = hWnd;
                            return false;
                        }
                    }
                }
            }
            catch {
            }

            return true;
        }, IntPtr.Zero);

        if (found == IntPtr.Zero) {
            return false;
        }

        if (IsIconic(found)) {
            ShowWindow(found, 9); // SW_RESTORE
        }
        else {
            ShowWindow(found, 5); // SW_SHOW
        }

        return SetForegroundWindow(found);
    }
}

[Flags]
public enum ActivateOptions
{
    None = 0,
    DesignMode = 1,
    NoErrorUI = 2,
    NoSplashScreen = 4,
}

[ComImport]
[Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IShellItem
{
}

[ComImport]
[Guid("b63ea76d-1f85-456f-a19c-48159efa858b")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IShellItemArray
{
}

[ComImport]
[Guid("2e941141-7f97-4756-ba1d-9decde894a3d")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IApplicationActivationManager
{
    int ActivateApplication(
        [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
        [MarshalAs(UnmanagedType.LPWStr)] string arguments,
        ActivateOptions options,
        out int processId);

    int ActivateForFile(
        [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
        IShellItemArray itemArray,
        [MarshalAs(UnmanagedType.LPWStr)] string verb,
        out int processId);

    int ActivateForProtocol(
        [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
        IShellItemArray itemArray,
        out int processId);
}

[ComImport]
[Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
public class ApplicationActivationManager
{
}

public static class PackagedAppFileActivator
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHCreateItemFromParsingName(
        [MarshalAs(UnmanagedType.LPWStr)] string pszPath,
        IntPtr pbc,
        ref Guid riid,
        out IShellItem ppv);

    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern int SHCreateShellItemArrayFromShellItem(
        IShellItem psi,
        ref Guid riid,
        out IShellItemArray ppv);

    public static int ActivateForFile(string appUserModelId, string filePath)
    {
        Guid shellItemId = new Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe");
        Guid shellItemArrayId = new Guid("b63ea76d-1f85-456f-a19c-48159efa858b");

        IShellItem item;
        int hr = SHCreateItemFromParsingName(filePath, IntPtr.Zero, ref shellItemId, out item);
        Marshal.ThrowExceptionForHR(hr);

        IShellItemArray itemArray;
        hr = SHCreateShellItemArrayFromShellItem(item, ref shellItemArrayId, out itemArray);
        Marshal.ThrowExceptionForHR(hr);

        IApplicationActivationManager manager = (IApplicationActivationManager)new ApplicationActivationManager();
        int processId;
        hr = manager.ActivateForFile(appUserModelId, itemArray, "open", out processId);
        Marshal.ThrowExceptionForHR(hr);

        if (itemArray != null) {
            Marshal.ReleaseComObject(itemArray);
        }
        if (item != null) {
            Marshal.ReleaseComObject(item);
        }

        return processId;
    }
}
"@

[System.Windows.Forms.Application]::EnableVisualStyles()
[Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
[Windows.ApplicationModel.DataTransfer.SharedStorageAccessManager, Windows.ApplicationModel, ContentType = WindowsRuntime] | Out-Null

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$script:CurrentFile = $null
$script:CurrentFileIsTemporary = $false
$script:LastHash = $null
$script:LastSequence = [ClipboardNative]::GetClipboardSequenceNumber()
$script:DeleteTimers = New-Object 'System.Collections.Generic.List[System.Windows.Forms.Timer]'
$script:IsPointerDown = $false
$script:DragStarted = $false
$script:PointerDownScreen = [System.Drawing.Point]::Empty

$script:SnippingScreenshotsDir = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Screenshots'
$script:SnippingToolNotificationKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.ScreenSketch_8wekyb3d8bbwe!App'
$script:ScreenshotSearchDirs = @(
    $script:SnippingScreenshotsDir,
    (Join-Path $env:USERPROFILE 'OneDrive\Pictures\Screenshots')
) | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_)
} | Select-Object -Unique

function Get-ClipboardPngBytes {
    try {
        if (-not [System.Windows.Forms.Clipboard]::ContainsImage()) {
            return $null
        }

        $image = [System.Windows.Forms.Clipboard]::GetImage()
        if ($null -eq $image) {
            return $null
        }

        $bitmap = New-Object System.Drawing.Bitmap $image
        $stream = New-Object System.IO.MemoryStream
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $bytes = $stream.ToArray()

        $stream.Dispose()
        $bitmap.Dispose()
        $image.Dispose()

        return $bytes
    }
    catch {
        return $null
    }
}

function Wait-ClipboardPngBytes {
    for ($i = 0; $i -lt 8; $i++) {
        $bytes = Get-ClipboardPngBytes
        if ($null -ne $bytes -and $bytes.Length -gt 0) {
            return $bytes
        }

        Start-Sleep -Milliseconds 80
    }

    return $null
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-NormalizedImageHash {
    param([string]$Path)

    $loaded = $null
    $bitmap = $null
    $stream = $null

    try {
        $loaded = [System.Drawing.Image]::FromFile($Path)
        $bitmap = New-Object System.Drawing.Bitmap $loaded
        $stream = New-Object System.IO.MemoryStream
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return Get-Sha256Hex -Bytes $stream.ToArray()
    }
    catch {
        return $null
    }
    finally {
        if ($stream -ne $null) {
            $stream.Dispose()
        }
        if ($bitmap -ne $null) {
            $bitmap.Dispose()
        }
        if ($loaded -ne $null) {
            $loaded.Dispose()
        }
    }
}

function Find-MatchingSnippingToolFile {
    param(
        [string]$NormalizedHash,
        [datetime]$Since
    )

    if ([string]::IsNullOrWhiteSpace($NormalizedHash) -or $script:ScreenshotSearchDirs.Count -eq 0) {
        return $null
    }

    $createdAfter = $Since.AddSeconds(-10)

    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        $candidates = foreach ($dir in $script:ScreenshotSearchDirs) {
            Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.LastWriteTime -ge $createdAfter -and
                    $_.Extension -match '^\.(png|jpg|jpeg|bmp)$'
                }
        }

        foreach ($file in ($candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 8)) {
            if ((Get-NormalizedImageHash -Path $file.FullName) -eq $NormalizedHash) {
                return $file.FullName
            }
        }

        Start-Sleep -Milliseconds 120
    }

    return $null
}

function Remove-BridgeFileIfOwned {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    try {
        $bridgeRoot = [System.IO.Path]::GetFullPath($OutputDir).TrimEnd('\') + '\'
        $target = [System.IO.Path]::GetFullPath($Path)
        if ($target.StartsWith($bridgeRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
    }
}

function Queue-BridgeFileDelete {
    param(
        [string]$Path,
        [int]$DelaySeconds = $BridgeFileLifetimeSeconds
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [Math]::Max(5, $DelaySeconds) * 1000
    $timer.Tag = $Path
    $timer.Add_Tick({
        param($sender, $eventArgs)
        $sender.Stop()
        Remove-BridgeFileIfOwned -Path ([string]$sender.Tag)
        [void]$script:DeleteTimers.Remove($sender)
        $sender.Dispose()
    })

    [void]$script:DeleteTimers.Add($timer)
    $timer.Start()
}

function Remove-OldBridgeFiles {
    Get-ChildItem -Path $OutputDir -Filter 'snip-*.png' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddSeconds(-[Math]::Max(5, $BridgeFileLifetimeSeconds)) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Get-ChildItem -Path $OutputDir -Filter 'snip-*.png' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $MaxFiles |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Hide-Thumbnail {
    param([bool]$DeleteTemporaryFile = $true)

    $path = $script:CurrentFile
    $isTemporary = $script:CurrentFileIsTemporary
    $form.Hide()

    if ($DeleteTemporaryFile -and $isTemporary) {
        Remove-BridgeFileIfOwned -Path $path
        if ($script:CurrentFile -eq $path) {
            $script:CurrentFile = $null
            $script:CurrentFileIsTemporary = $false
        }
    }
}

function Set-SnippingToolNotificationsEnabled {
    param([bool]$Enabled)

    New-Item -Path $script:SnippingToolNotificationKey -Force | Out-Null
    $value = if ($Enabled) { 1 } else { 0 }
    New-ItemProperty -Path $script:SnippingToolNotificationKey -Name 'Enabled' -Value $value -PropertyType DWord -Force | Out-Null
}

$form = New-Object NoActivateForm
$form.Text = 'SnipDrag'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.ShowInTaskbar = $false
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.TopMost = $true
$form.Width = 248
$form.Height = 184
$form.Padding = New-Object System.Windows.Forms.Padding -ArgumentList 8
$form.BackColor = [System.Drawing.Color]::FromArgb(36, 38, 41)

$titleBar = New-Object System.Windows.Forms.Panel
$titleBar.Dock = [System.Windows.Forms.DockStyle]::Top
$titleBar.Height = 28
$titleBar.BackColor = [System.Drawing.Color]::FromArgb(36, 38, 41)

$title = New-Object System.Windows.Forms.Label
$title.Text = ''
$title.AutoSize = $false
$title.Dock = [System.Windows.Forms.DockStyle]::Fill
$title.ForeColor = [System.Drawing.Color]::White
$title.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
$title.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft

$hideButton = New-Object System.Windows.Forms.Button
$hideButton.Text = 'x'
$hideButton.Width = 28
$hideButton.Height = 24
$hideButton.Dock = [System.Windows.Forms.DockStyle]::Right
$hideButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$hideButton.FlatAppearance.BorderSize = 0
$hideButton.BackColor = [System.Drawing.Color]::FromArgb(36, 38, 41)
$hideButton.ForeColor = [System.Drawing.Color]::White
$hideButton.Cursor = [System.Windows.Forms.Cursors]::Hand

$picture = New-Object System.Windows.Forms.PictureBox
$picture.Dock = [System.Windows.Forms.DockStyle]::Fill
$picture.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$picture.BackColor = [System.Drawing.Color]::FromArgb(17, 18, 20)
$picture.Cursor = [System.Windows.Forms.Cursors]::SizeAll

$titleBar.Controls.Add($title)
$titleBar.Controls.Add($hideButton)
$form.Controls.Add($picture)
$form.Controls.Add($titleBar)

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.SetToolTip($picture, 'Click to open in Snipping Tool, or drag into any app that accepts images or files.')
$toolTip.SetToolTip($hideButton, 'Hide thumbnail')

$hideTimer = New-Object System.Windows.Forms.Timer
$hideTimer.Interval = [Math]::Max(3, $HideAfterSeconds) * 1000
$hideTimer.Add_Tick({
    $hideTimer.Stop()
    Hide-Thumbnail -DeleteTemporaryFile $true
})

function Move-ThumbnailToCorner {
    $screen = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
    $area = $screen.WorkingArea
    $x = $area.Right - $form.Width - 20
    $y = $area.Bottom - $form.Height - 20
    $form.Location = New-Object System.Drawing.Point($x, $y)
}

function Set-ThumbnailImage {
    param([string]$Path)

    if ($picture.Image -ne $null) {
        $oldImage = $picture.Image
        $picture.Image = $null
        $oldImage.Dispose()
    }

    $loaded = [System.Drawing.Image]::FromFile($Path)
    try {
        $picture.Image = New-Object System.Drawing.Bitmap $loaded
    }
    finally {
        $loaded.Dispose()
    }
}

function Show-Thumbnail {
    param(
        [string]$Path,
        [bool]$IsTemporary = $false
    )

    $script:CurrentFile = $Path
    $script:CurrentFileIsTemporary = $IsTemporary
    Set-ThumbnailImage -Path $Path
    Move-ThumbnailToCorner
    $form.Show()
    $form.BringToFront()
    $hideTimer.Stop()
    $hideTimer.Start()
}

function Get-SharedAccessTokenForFile {
    param([string]$Path)

    try {
        $operation = [Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)
        $asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() |
            Where-Object {
                $_.Name -eq 'AsTask' -and
                $_.IsGenericMethodDefinition -and
                $_.GetParameters().Count -eq 1 -and
                $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
            } |
            Select-Object -First 1

        if ($null -eq $asTaskMethod) {
            return $null
        }

        $task = $asTaskMethod.MakeGenericMethod([Windows.Storage.StorageFile]).Invoke($null, @($operation))
        $task.Wait()
        return [Windows.ApplicationModel.DataTransfer.SharedStorageAccessManager]::AddFile($task.Result)
    }
    catch {
        return $null
    }
}

function Open-ImageInSnippingToolEditor {
    param(
        [string]$Path,
        [bool]$IsTemporary
    )

    $token = Get-SharedAccessTokenForFile -Path $Path
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        $query = @(
            'source=SnipDrag',
            ('isTemporary=' + ($(if ($IsTemporary) { 'true' } else { 'false' }))),
            ('sharedAccessToken=' + [Uri]::EscapeDataString($token)),
            ('filePath=' + [Uri]::EscapeDataString($Path))
        ) -join '&'

        Start-Process -FilePath ('ms-screensketch://edit/?' + $query)
        Start-Sleep -Milliseconds 900
        [void][WindowTools]::BringProcessWindowToFront('SnippingTool')
        return
    }

    $screenSketchPackage = Get-AppxPackage -Name Microsoft.ScreenSketch -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    $snippingToolExe = if ($screenSketchPackage) {
        Join-Path $screenSketchPackage.InstallLocation 'SnippingTool\SnippingTool.exe'
    }
    else {
        $null
    }

    if (-not [string]::IsNullOrWhiteSpace($snippingToolExe) -and (Test-Path -LiteralPath $snippingToolExe)) {
        Start-Process -FilePath $snippingToolExe -ErrorAction SilentlyContinue
    }
    else {
        Start-Process -FilePath 'SnippingTool.exe' -ErrorAction SilentlyContinue
    }
}

function Open-CurrentImageInSnippingTool {
    if ([string]::IsNullOrWhiteSpace($script:CurrentFile) -or -not (Test-Path -LiteralPath $script:CurrentFile)) {
        return
    }

    $path = $script:CurrentFile
    $wasTemporary = $script:CurrentFileIsTemporary

    Open-ImageInSnippingToolEditor -Path $path -IsTemporary $wasTemporary

    Hide-Thumbnail -DeleteTemporaryFile $false
    if ($wasTemporary) {
        Queue-BridgeFileDelete -Path $path -DelaySeconds $BridgeFileLifetimeSeconds
        $script:CurrentFile = $null
        $script:CurrentFileIsTemporary = $false
    }
}

function Start-FileDrag {
    if ([string]::IsNullOrWhiteSpace($script:CurrentFile) -or -not (Test-Path -LiteralPath $script:CurrentFile)) {
        return
    }

    $data = New-Object System.Windows.Forms.DataObject
    $bitmap = $null
    $pngStream = $null

    try {
        $bitmap = New-Object System.Drawing.Bitmap $script:CurrentFile
        $pngStream = New-Object System.IO.MemoryStream(,[System.IO.File]::ReadAllBytes($script:CurrentFile))

        $data.SetData([System.Windows.Forms.DataFormats]::FileDrop, [string[]]@($script:CurrentFile))
        $data.SetData([System.Windows.Forms.DataFormats]::Bitmap, $bitmap)
        $data.SetData('PNG', $pngStream)
        $data.SetData([System.Windows.Forms.DataFormats]::Text, $script:CurrentFile)

        [void]$picture.DoDragDrop($data, [System.Windows.Forms.DragDropEffects]::Copy)

        if ($script:CurrentFileIsTemporary) {
            $droppedFile = $script:CurrentFile
            Hide-Thumbnail -DeleteTemporaryFile $false
            Queue-BridgeFileDelete -Path $droppedFile -DelaySeconds $BridgeFileLifetimeSeconds
            $script:CurrentFile = $null
            $script:CurrentFileIsTemporary = $false
        }
    }
    finally {
        if ($pngStream -ne $null) {
            $pngStream.Dispose()
        }
        if ($bitmap -ne $null) {
            $bitmap.Dispose()
        }
    }
}

$pointerDownHandler = {
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:IsPointerDown = $true
        $script:DragStarted = $false
        $script:PointerDownScreen = $sender.PointToScreen($eventArgs.Location)
    }
}

$pointerMoveHandler = {
    param($sender, $eventArgs)
    if (-not $script:IsPointerDown -or $script:DragStarted) {
        return
    }

    if (($eventArgs.Button -band [System.Windows.Forms.MouseButtons]::Left) -ne [System.Windows.Forms.MouseButtons]::Left) {
        $script:IsPointerDown = $false
        return
    }

    $current = $sender.PointToScreen($eventArgs.Location)
    $dragSize = [System.Windows.Forms.SystemInformation]::DragSize
    if ([Math]::Abs($current.X - $script:PointerDownScreen.X) -ge $dragSize.Width -or
        [Math]::Abs($current.Y - $script:PointerDownScreen.Y) -ge $dragSize.Height) {
        $script:DragStarted = $true
        $script:IsPointerDown = $false
        Start-FileDrag
    }
}

$pointerUpHandler = {
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left -and $script:IsPointerDown -and -not $script:DragStarted) {
        $script:IsPointerDown = $false
        Open-CurrentImageInSnippingTool
    }

    $script:IsPointerDown = $false
}

$picture.Add_MouseDown($pointerDownHandler)
$picture.Add_MouseMove($pointerMoveHandler)
$picture.Add_MouseUp($pointerUpHandler)
$title.Add_MouseDown($pointerDownHandler)
$title.Add_MouseMove($pointerMoveHandler)
$title.Add_MouseUp($pointerUpHandler)
$hideButton.Add_Click({ Hide-Thumbnail -DeleteTemporaryFile $true })
$form.Add_FormClosed({
    if ($picture.Image -ne $null) {
        $picture.Image.Dispose()
    }
    if ($tray -ne $null) {
        $tray.Visible = $false
        $tray.Dispose()
    }
    foreach ($timer in $script:DeleteTimers.ToArray()) {
        $timer.Stop()
        Remove-BridgeFileIfOwned -Path ([string]$timer.Tag)
        $timer.Dispose()
    }
    $mutex.ReleaseMutex()
    $mutex.Dispose()
})

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Text = 'SnipDrag'
$tray.Icon = [System.Drawing.SystemIcons]::Application
$tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$openFolder = $menu.Items.Add('Open Snipping Tool screenshots folder')
$openFolder.Add_Click({
    if (Test-Path -LiteralPath $script:SnippingScreenshotsDir) {
        Start-Process explorer.exe -ArgumentList "`"$script:SnippingScreenshotsDir`""
    }
})
$showCurrent = $menu.Items.Add('Show current thumbnail')
$showCurrent.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($script:CurrentFile) -and (Test-Path -LiteralPath $script:CurrentFile)) {
        Show-Thumbnail -Path $script:CurrentFile -IsTemporary $script:CurrentFileIsTemporary
    }
})
$openCurrent = $menu.Items.Add('Open current in Snipping Tool')
$openCurrent.Add_Click({
    Open-CurrentImageInSnippingTool
})
$menu.Items.Add('-') | Out-Null
$disableSnippingToasts = $menu.Items.Add('Disable Snipping Tool notifications')
$disableSnippingToasts.Add_Click({
    Set-SnippingToolNotificationsEnabled -Enabled $false
})
$enableSnippingToasts = $menu.Items.Add('Enable Snipping Tool notifications')
$enableSnippingToasts.Add_Click({
    Set-SnippingToolNotificationsEnabled -Enabled $true
})
$menu.Items.Add('-') | Out-Null
$exitItem = $menu.Items.Add('Exit')
$exitItem.Add_Click({
    $tray.Visible = $false
    $form.Close()
    [System.Windows.Forms.Application]::Exit()
})
$tray.ContextMenuStrip = $menu
$tray.Add_DoubleClick({
    if (-not [string]::IsNullOrWhiteSpace($script:CurrentFile) -and (Test-Path -LiteralPath $script:CurrentFile)) {
        Show-Thumbnail -Path $script:CurrentFile -IsTemporary $script:CurrentFileIsTemporary
    }
})

$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 450
$pollTimer.Add_Tick({
    $sequence = [ClipboardNative]::GetClipboardSequenceNumber()
    if ($sequence -eq $script:LastSequence) {
        return
    }

    $script:LastSequence = $sequence
    $clipboardEventTime = Get-Date
    $bytes = Wait-ClipboardPngBytes
    if ($null -eq $bytes -or $bytes.Length -eq 0) {
        return
    }

    $hash = Get-Sha256Hex -Bytes $bytes
    if ($hash -eq $script:LastHash) {
        return
    }

    $script:LastHash = $hash
    $path = Find-MatchingSnippingToolFile -NormalizedHash $hash -Since $clipboardEventTime
    $isTemporary = $false

    if ([string]::IsNullOrWhiteSpace($path)) {
        $isTemporary = $true
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $path = Join-Path $OutputDir ("snip-{0}-{1}.png" -f $stamp, $hash.Substring(0, 8))
        [System.IO.File]::WriteAllBytes($path, $bytes)
        Queue-BridgeFileDelete -Path $path -DelaySeconds $BridgeFileLifetimeSeconds
        Remove-OldBridgeFiles
    }

    Show-Thumbnail -Path $path -IsTemporary $isTemporary
})

$pollTimer.Start()
$context = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($context)
