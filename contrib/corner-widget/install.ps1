<#
.SYNOPSIS
    Installs the Ghostty corner-widget service for the current user.

.DESCRIPTION
    - Finds Python 3 and installs the media-session package it needs
      (winsdk on Python 3.12 and older, the winrt-* packages on newer).
    - Copies widgetd.py and glyph_fog.glsl to %LOCALAPPDATA%\ghostty-widget
      and creates the settings file (env) there if it doesn't exist.
    - Registers a Task Scheduler task, "ghostty-widget", that starts the
      service hidden (pythonw.exe) at logon, and starts it now.
    - Makes Ghostty's config include the fog settings the service writes
      (copies contrib\ghostty-config\config.ghostty if you have no config).

    Run it again after changing the settings, or after updating the files;
    it is safe to repeat.

.PARAMETER Uninstall
    Removes the task (and the Startup shortcut, if one was used). Settings
    and caches stay in %LOCALAPPDATA%\ghostty-widget.

.PARAMETER NoConfig
    Leaves Ghostty's config file alone.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File contrib\corner-widget\install.ps1
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$NoConfig
)

$ErrorActionPreference = 'Stop'
$TaskName = 'ghostty-widget'
$Data = Join-Path $env:LOCALAPPDATA 'ghostty-widget'
$Here = $PSScriptRoot
$Startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'ghostty-widget.lnk'

function Stop-Widget {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    # A copy started from the Startup shortcut or by hand.
    Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe' OR Name = 'python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*ghostty-widget*widgetd.py*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

if ($Uninstall) {
    Stop-Widget
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $Startup -ErrorAction SilentlyContinue
    Write-Host "Removed the $TaskName service. Settings and caches stay in $Data."
    return
}

# Windows PowerShell 5.1 turns a native program's stderr output into a
# terminating error under ErrorActionPreference=Stop, even when redirected;
# pip prints harmless warnings there. Run native programs with Continue and
# check $LASTEXITCODE instead.
function Invoke-Native([scriptblock]$Block) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Block } finally { $ErrorActionPreference = $saved }
}

# --- 1. Python ---------------------------------------------------------------

function Find-Python {
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($py) {
        $exe = Invoke-Native { & $py.Source -3 -c 'import sys; print(sys.executable)' 2>$null }
        if ($LASTEXITCODE -eq 0 -and $exe) { return $exe.Trim() }
    }
    # Skip the Microsoft Store "python.exe" stub that only opens the Store.
    $p = Get-Command python.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notlike '*\Microsoft\WindowsApps\python.exe' } |
        Select-Object -First 1
    if ($p) {
        $exe = Invoke-Native { & $p.Source -c 'import sys; print(sys.executable)' 2>$null }
        if ($LASTEXITCODE -eq 0 -and $exe) { return $exe.Trim() }
    }
    throw 'Python 3 was not found. Install it from https://www.python.org/downloads/windows/ and run this again.'
}

$Python = Find-Python
$Pythonw = Join-Path (Split-Path $Python) 'pythonw.exe'
if (-not (Test-Path $Pythonw)) { throw "pythonw.exe was not found next to $Python" }
# No double quotes inside -c code: Windows PowerShell 5.1 drops them when
# passing arguments to native programs.
$Version = (Invoke-Native { & $Python -c 'import sys; print(''%d.%d'' % sys.version_info[:2])' }).Trim()
Write-Host "Python $Version at $Python"

# --- 2. Media-session package --------------------------------------------------

if ([version]$Version -le [version]'3.12') {
    $Packages = @('winsdk')
} else {
    $Packages = @('winrt-runtime', 'winrt-Windows.Foundation', 'winrt-Windows.Media.Control', 'winrt-Windows.Storage.Streams')
}
Write-Host "Installing $($Packages -join ', ')..."
Invoke-Native { & $Python -m pip install --user --upgrade --disable-pip-version-check --quiet @Packages }
if ($LASTEXITCODE -ne 0) { throw 'pip install failed (see above).' }
Invoke-Native { & $Python -c 'exec(''try:\n import winsdk.windows.media.control\nexcept ImportError:\n import winrt.windows.media.control'')' 2>$null }
if ($LASTEXITCODE -ne 0) { throw 'The media-session package does not import; music will not show.' }

# --- 3. Files and settings -----------------------------------------------------

New-Item -ItemType Directory -Force -Path $Data | Out-Null
Copy-Item (Join-Path $Here 'widgetd.py') $Data -Force
Copy-Item (Join-Path $Here 'glyph_fog.glsl') $Data -Force

$EnvFile = Join-Path $Data 'env'
if (-not (Test-Path $EnvFile)) {
    @(
        '# Settings for the Ghostty corner widget. Run install.ps1 again after editing.',
        '# City for the weather (leave empty for no weather) and its country code.',
        'WIDGET_CITY=',
        'WIDGET_COUNTRY=',
        '# Glyph fog background shader, and its ripple where you click: on/off.',
        'WIDGET_FOG=on',
        'WIDGET_RIPPLE=on'
    ) | Set-Content -Path $EnvFile -Encoding ASCII
    Write-Host "Created $EnvFile; put your city in it for the weather."
}

# --- 4. Start at logon, hidden ----------------------------------------------------

Stop-Widget
$Script = Join-Path $Data 'widgetd.py'
$User = "$env:USERDOMAIN\$env:USERNAME"
try {
    $action = New-ScheduledTaskAction -Execute $Pythonw -Argument "`"$Script`"" -WorkingDirectory $Data
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $User
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Description 'Data for the Ghostty corner widget (weather, music, lyrics).' -Force | Out-Null
    Remove-Item $Startup -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Registered and started the '$TaskName' Task Scheduler task."
} catch {
    # Some managed PCs don't let users register tasks: use the Startup folder.
    Write-Warning "Could not register a scheduled task ($($_.Exception.Message)); using a Startup shortcut instead."
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Startup)
    $lnk.TargetPath = $Pythonw
    $lnk.Arguments = "`"$Script`""
    $lnk.WorkingDirectory = $Data
    $lnk.Save()
    Start-Process -FilePath $Pythonw -ArgumentList "`"$Script`"" -WorkingDirectory $Data -WindowStyle Hidden
    Write-Host "Added $Startup and started the service."
}

# --- 5. Ghostty config --------------------------------------------------------------

if (-not $NoConfig) {
    if ($env:XDG_CONFIG_HOME) {
        $ConfigDir = Join-Path $env:XDG_CONFIG_HOME 'ghostty'
        $Include = 'config-file = ?' + ((Join-Path $Data 'shaders.conf') -replace '\\', '/')
    } else {
        $ConfigDir = Join-Path $env:LOCALAPPDATA 'ghostty'
        $Include = 'config-file = ?../ghostty-widget/shaders.conf'
    }
    $Config = Join-Path $ConfigDir 'config.ghostty'
    $Legacy = Join-Path $ConfigDir 'config'
    if (-not (Test-Path $Config) -and (Test-Path $Legacy)) { $Config = $Legacy }
    $Template = Join-Path $Here '..\ghostty-config\config.ghostty'

    if (-not (Test-Path $Config)) {
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
        if ($env:XDG_CONFIG_HOME) {
            # UTF-8 without a BOM, which Windows PowerShell 5.1 would add.
            $text = [IO.File]::ReadAllText((Resolve-Path $Template), [Text.Encoding]::UTF8)
            $text = $text.Replace('config-file = ?../ghostty-widget/shaders.conf', $Include)
            [IO.File]::WriteAllText($Config, $text, (New-Object Text.UTF8Encoding $false))
        } else {
            Copy-Item $Template $Config
        }
        Write-Host "Copied the fork's config to $Config."
    } elseif (-not (Select-String -Path $Config -Pattern 'ghostty-widget/shaders\.conf' -Quiet)) {
        Add-Content -Path $Config -Value @('', '# Glyph fog shader, managed by the ghostty-widget service', $Include)
        Write-Host "Added the fog include to $Config."
    } else {
        Write-Host "$Config already includes the fog settings."
    }
}

Write-Host ''
Write-Host 'Done. Settings:' (Join-Path $Data 'env')
Write-Host 'Log:          ' (Join-Path $Data 'widgetd.log')
