<#
  firefox-border-radius: set one corner radius for (almost) everything in Firefox.

  Windows version of install.sh. Finds every Firefox install on the machine
  (installer, Microsoft Store, and Firefox-based browsers like LibreWolf),
  lists all of their profiles, and lets you choose which ones to apply it to.
  Each selected profile gets a clean chrome\ folder containing just
  userChrome.css and userContent.css; whatever was in chrome\ before is moved
  to a backup.

  Runs on Windows PowerShell 5.1 and PowerShell 7. Kept ASCII-only because
  5.1 reads scripts without a BOM in the ANSI code page.

  Run .\install.ps1 -Help for options.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
  [Alias('r')] [string]$Radius = '4px',
  [Alias('a')] [switch]$All,
  [Alias('p')] [string[]]$ProfileDir,
  [Alias('l')] [switch]$List,
  [Alias('u')] [switch]$Uninstall,
  [switch]$NoContent,
  [Alias('y')] [switch]$Yes,
  [Alias('h')] [switch]$Help
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$Name = 'firefox-border-radius'
# install.sh writes the same marker, ending in "install.sh"; either counts as ours.
$MarkerPrefix = "/* Installed by $Name."
$Marker = "$MarkerPrefix Re-run install.ps1 to change it; edits to this file are overwritten. */"
$PrefName = 'toolkit.legacyUserProfileCustomizations.stylesheets'
$PrefLine = "user_pref(`"$PrefName`", true); // $Name"
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$SrcDir = Join-Path $PSScriptRoot 'src'
$Sep = [IO.Path]::DirectorySeparatorChar

function Write-Part([string]$Text, [string]$Color) {
  if ($Color) { Write-Host $Text -NoNewline -ForegroundColor $Color } else { Write-Host $Text -NoNewline }
}
function Say([string]$Text = '') { Write-Host $Text }
function Ok([string]$Text, [string]$Dim = '') {
  Write-Part '+ ' Green; Write-Part $Text; if ($Dim) { Write-Part " $Dim" DarkGray }; Write-Host
}
function Die([string]$Text) { Write-Part 'error: ' Red; Write-Host $Text; exit 1 }
function Get-Tilde([string]$Path) {
  if ($Path.StartsWith("$HOME$Sep", 'OrdinalIgnoreCase')) { '~' + $Path.Substring($HOME.Length) } else { $Path }
}

function Show-Usage {
  Say @"
Usage: .\install.ps1 [options]

Set the border radius of Firefox's tabs, toolbar, URL bar, menus, panels and
about: pages to a single value. Without options it lists every Firefox
profile it can find and asks which ones to apply it to.

Options:
  -Radius VALUE        Corner radius, e.g. 0, 4, 8px (default: 4px)
  -All                 Apply to every profile found, without the menu
  -ProfileDir DIR,...  Apply to these profile directories (skips the menu)
  -List                List Firefox installs and profiles, then exit
  -Uninstall           Remove $Name from the profiles you choose
  -NoContent           Leave about: pages alone (don't install userContent.css)
  -Yes                 Don't ask for confirmation
  -Help                Show this help

Options can be shortened to their first letter (-r 8, -a, -y).

Examples:
  .\install.ps1                 # pick profiles from a list, 4px
  .\install.ps1 -Radius 0       # sharp corners
  .\install.ps1 -a -r 8 -y      # every profile, no questions
  .\install.ps1 -Uninstall
"@
}

# ---------------------------------------------------------------- arguments --

if ($Help) { Show-Usage; exit 0 }
if (-not $env:APPDATA -or -not $env:LOCALAPPDATA) { Die 'install.ps1 is for Windows; on Linux and macOS use install.sh.' }

$BackupRoot = Join-Path $env:LOCALAPPDATA "$Name\backups"
$Mode = if ($List) { 'list' } elseif ($Uninstall) { 'uninstall' } else { 'install' }

if ($Mode -eq 'install') {
  $r = $Radius -replace 'px$', ''
  if ($r -notmatch '^[0-9]+(\.[0-9]+)?$') { Die "invalid radius '$Radius' (use a number like 4 or 4px)" }
  $Radius = "${r}px"

  foreach ($f in 'userChrome.css', 'userContent.css') {
    if (-not (Test-Path -LiteralPath (Join-Path $SrcDir $f) -PathType Leaf)) {
      Die "missing $(Join-Path $SrcDir $f) (run install.ps1 from a full checkout of the repo)"
    }
  }
}

# ---------------------------------------------------------- install detection --

$ProgramDirs = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs'), $env:LOCALAPPDATA) |
  Where-Object { $_ }

# Is one of these executables installed: registered under App Paths, on PATH
# (Scoop, winget portable), or in one of the given folders under Program Files?
function Find-App([string[]]$Exe, [string[]]$Dirs) {
  foreach ($e in $Exe) {
    foreach ($hive in 'HKCU:', 'HKLM:') {
      if (Test-Path "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$e") { return $true }
    }
    if (Get-Command $e -CommandType Application -ErrorAction SilentlyContinue) { return $true }
    foreach ($base in $ProgramDirs) {
      foreach ($d in $Dirs) {
        if (Test-Path -LiteralPath (Join-Path (Join-Path $base $d) $e) -PathType Leaf) { return $true }
      }
    }
  }
  $false
}

# Profile roots, each with a label and whether the browser itself was found.
$Installs = New-Object System.Collections.Generic.List[object]
function Add-Install([string]$Label, [bool]$Installed, [string]$Root) {
  $Installs.Add([pscustomobject]@{ Label = $Label; Installed = $Installed; Root = [IO.Path]::GetFullPath($Root) })
}

function Find-Installs {
  $appData = $env:APPDATA
  # The Microsoft Store build usually keeps its profiles in the normal
  # %APPDATA% folder, but some versions redirect them into the package.
  $store = Join-Path $env:LOCALAPPDATA 'Packages\Mozilla.Firefox_n80bbvh6b1yt2'
  $hasStore = Test-Path -LiteralPath $store -PathType Container
  $firefox = $hasStore -or (Find-App 'firefox.exe' 'Mozilla Firefox', 'Firefox Developer Edition', 'Firefox Nightly')

  Add-Install 'Firefox' $firefox (Join-Path $appData 'Mozilla\Firefox')
  Add-Install 'Firefox (Store)' $false (Join-Path $store 'LocalCache\Roaming\Mozilla\Firefox')

  # Firefox-based browsers use the same profile layout and userChrome.css.
  Add-Install 'LibreWolf' (Find-App 'librewolf.exe' 'LibreWolf') (Join-Path $appData 'librewolf')
  Add-Install 'Floorp' (Find-App 'floorp.exe' 'Ablaze Floorp', 'Floorp') (Join-Path $appData 'Floorp')
  Add-Install 'Zen' (Find-App 'zen.exe' 'Zen Browser', 'Zen') (Join-Path $appData 'zen')
  Add-Install 'Waterfox' (Find-App 'waterfox.exe' 'Waterfox') (Join-Path $appData 'Waterfox')
}

# ---------------------------------------------------------- profile detection --

# Profiles listed in <root>\profiles.ini.
function Get-IniProfiles([string]$Root) {
  $ini = Join-Path $Root 'profiles.ini'
  if (-not (Test-Path -LiteralPath $ini -PathType Leaf)) { return }
  $sections = [ordered]@{}
  $installDefaults = @{}
  $hasInstalls = $false
  $sec = ''
  foreach ($line in [IO.File]::ReadAllLines($ini)) {
    if ($line.StartsWith('[')) { $sec = $line.Trim(); continue }
    $eq = $line.IndexOf('=')
    if ($eq -lt 0) { continue }
    $key = $line.Substring(0, $eq)
    $val = $line.Substring($eq + 1)
    if ($sec -match '^\[Profile[0-9]+\]$') {
      if (-not $sections.Contains($sec)) { $sections[$sec] = @{ Name = ''; Path = ''; Relative = '1'; Default = $false } }
      $s = $sections[$sec]
      switch -CaseSensitive ($key) {
        'Name' { $s.Name = $val }
        'Path' { $s.Path = $val }
        'IsRelative' { $s.Relative = $val }
        'Default' { if ($val -eq '1') { $s.Default = $true } }
      }
    } elseif ($sec.StartsWith('[Install') -and $key -eq 'Default') {
      $hasInstalls = $true
      $installDefaults[$val] = $true
    }
  }
  foreach ($s in $sections.Values) {
    if (-not $s.Path) { continue }
    $path = if ($s.Relative -eq '0') { $s.Path } else { Join-Path $Root $s.Path }
    $default = if ($hasInstalls) { $installDefaults.ContainsKey($s.Path) } else { $s.Default }
    [pscustomobject]@{ Name = $s.Name; Path = $path; Default = [bool]$default }
  }
}

# Profiles that aren't in profiles.ini (e.g. newer Firefox profile groups):
# any directory that has a prefs.js.
function Get-ScannedProfiles([string]$Root) {
  foreach ($dir in $Root, (Join-Path $Root 'Profiles')) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
    foreach ($d in Get-ChildItem -LiteralPath $dir -Directory -Force) {
      if (-not (Test-Path -LiteralPath (Join-Path $d.FullName 'prefs.js') -PathType Leaf)) { continue }
      $dot = $d.Name.IndexOf('.')
      $name = if ($dot -ge 0) { $d.Name.Substring($dot + 1) } else { $d.Name }
      [pscustomobject]@{ Name = $name; Path = $d.FullName; Default = $false }
    }
  }
}

$Profiles = New-Object System.Collections.Generic.List[object]

function Resolve-Dir([string]$Path) {
  [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).ProviderPath).TrimEnd('\', '/')
}

function Add-Profile([string]$Label, [string]$Name, [string]$Path, [bool]$Default) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
  $Path = Resolve-Dir $Path
  foreach ($p in $Profiles) { if ($p.Path -eq $Path) { return } }
  $Profiles.Add([pscustomobject]@{ Label = $Label; Name = $Name; Path = $Path; Default = $Default })
}

function Find-Profiles {
  foreach ($inst in $Installs) {
    if (-not (Test-Path -LiteralPath $inst.Root -PathType Container)) { continue }
    foreach ($p in @(Get-IniProfiles $inst.Root) + @(Get-ScannedProfiles $inst.Root)) {
      Add-Profile $inst.Label $p.Name $p.Path $p.Default
    }
  }
}

function Test-Ours([string]$File) {
  if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $false }
  $first = Get-Content -LiteralPath $File -TotalCount 1
  [bool]($first -and $first.StartsWith($MarkerPrefix))
}
function Test-Installed([string]$Dir) { Test-Ours (Join-Path $Dir 'chrome\userChrome.css') }

# While running, Firefox keeps <profile>\parent.lock open with no sharing. A
# crash can leave the file behind, so check whether it can be opened.
function Test-InUse([string]$Dir) {
  $lock = Join-Path $Dir 'parent.lock'
  if (-not (Test-Path -LiteralPath $lock -PathType Leaf)) { return $false }
  try { [IO.File]::Open($lock, 'Open', 'Read', 'None').Dispose(); $false } catch { $true }
}

# Is chrome\ empty or only holding files we wrote?
function Test-ChromeClean([string]$Dir) {
  $chrome = Join-Path $Dir 'chrome'
  if (-not (Test-Path -LiteralPath $chrome -PathType Container)) { return $true }
  foreach ($f in Get-ChildItem -LiteralPath $chrome -Force) {
    if ($f.Name -notin 'userChrome.css', 'userContent.css' -or -not (Test-Ours $f.FullName)) { return $false }
  }
  $true
}

function Write-ProfileNotes($p) {
  $notes = @()
  if ($p.Default) { $notes += , @('default', '') }
  if (Test-InUse $p.Path) { $notes += , @('in use', '') }
  if (Test-Installed $p.Path) { $notes += , @('installed', 'Green') }
  elseif (-not (Test-ChromeClean $p.Path)) { $notes += , @('has other chrome\ files', 'Yellow') }
  for ($i = 0; $i -lt $notes.Count; $i++) {
    if ($i -gt 0) { Write-Part ', ' }
    Write-Part $notes[$i][0] $notes[$i][1]
  }
}

function Test-LabelHasRoot([string]$Label) {
  foreach ($inst in $Installs) {
    if ($inst.Label -eq $Label -and (Test-Path -LiteralPath $inst.Root -PathType Container)) { return $true }
  }
  $false
}

function Show-Installs {
  Say 'Firefox installs'
  foreach ($inst in $Installs) {
    if (Test-Path -LiteralPath $inst.Root -PathType Container) {
      $count = @($Profiles | Where-Object { $_.Path.StartsWith("$($inst.Root)$Sep", 'OrdinalIgnoreCase') }).Count
      $note = "$count profile$(if ($count -ne 1) { 's' })"
      if (-not $inst.Installed) { $note += ', app not found' }
    } elseif ($inst.Installed -and -not (Test-LabelHasRoot $inst.Label)) {
      $note = 'no profiles yet, start it once'
    } else {
      continue
    }
    Write-Part ('  {0,-22} {1}  ' -f $inst.Label, (Get-Tilde $inst.Root))
    Write-Part "($note)" DarkGray
    Write-Host
  }
  Say
}

function Show-Profiles {
  Say 'Profiles'
  for ($i = 0; $i -lt $Profiles.Count; $i++) {
    $p = $Profiles[$i]
    Write-Part ('  {0,2})' -f ($i + 1)) Cyan
    Write-Part (' {0,-20} ' -f $p.Name)
    Write-Part ('{0,-20} ' -f $p.Label) DarkGray
    Write-ProfileNotes $p
    Write-Host
    Write-Part "       $(Get-Tilde $p.Path)" DarkGray
    Write-Host
  }
  Say
}

# ------------------------------------------------------------------ selection --

function Test-CanPrompt { -not [Console]::IsInputRedirected }

# Returns indexes into $Profiles.
function Read-Selection {
  $total = $Profiles.Count
  while ($true) {
    Write-Part 'Select profiles (e.g. 1 3, 2-4, a = all, q = quit) [a]: '
    $answer = Read-Host
    $answer = if ($null -eq $answer) { 'q' } else { $answer.Trim() }
    if ($answer -in '', 'a', 'all') { return 0..($total - 1) }
    if ($answer -in 'q', 'quit') { Say 'Nothing changed.'; exit 0 }

    $selected = New-Object System.Collections.Generic.List[int]
    $valid = $true
    foreach ($tok in $answer -split '[,\s]+') {
      if ($tok -match '^(\d{1,6})-(\d{1,6})$') {
        $a = [int]$Matches[1]; $b = [int]$Matches[2]
        if ($a -ge 1 -and $b -le $total -and $a -le $b) { $range = $a..$b } else { $valid = $false; continue }
      } elseif ($tok -match '^\d{1,6}$' -and [int]$tok -ge 1 -and [int]$tok -le $total) {
        $range = @([int]$tok)
      } else {
        $valid = $false; continue
      }
      foreach ($n in $range) { if (-not $selected.Contains($n - 1)) { $selected.Add($n - 1) } }
    }
    if ($valid -and $selected.Count -gt 0) { return $selected.ToArray() }
    Write-Warning "Enter numbers between 1 and $total, ranges like 2-4, or a for all."
  }
}

function Confirm-Continue([string]$Question) {
  if ($Yes -or -not (Test-CanPrompt)) { return }
  Write-Part "$Question [Y/n] "
  $answer = Read-Host
  if ($answer -match '^[nN]') { Say 'Nothing changed.'; exit 1 }
}

# ------------------------------------------------------------- applying files --

$Utf8 = New-Object System.Text.UTF8Encoding $false

function Get-BackupDir([string]$Dir) { Join-Path $BackupRoot "$(Split-Path $Dir -Leaf)-$Stamp" }

function Get-Rendered([string]$File) {
  "$Marker`n" + [IO.File]::ReadAllText((Join-Path $SrcDir $File)).Replace('@RADIUS@', $Radius)
}

# Move-Item can't move a folder to another drive, e.g. a -ProfileDir on D:.
function Move-Dir([string]$From, [string]$To) {
  try {
    Move-Item -LiteralPath $From -Destination $To
  } catch {
    Copy-Item -LiteralPath $From -Destination $To -Recurse
    Remove-Item -LiteralPath $From -Recurse -Force
  }
}

# userChrome/userContent are ignored unless this pref is true. user.js is
# applied on every start, so this survives Firefox resetting prefs.
function Enable-Pref([string]$Dir) {
  $userjs = Join-Path $Dir 'user.js'
  $lines = @()
  if (Test-Path -LiteralPath $userjs -PathType Leaf) {
    $lines = @([IO.File]::ReadAllLines($userjs))
    if (@($lines -match "^\s*user_pref\(`"$([regex]::Escape($PrefName))`",\s*true\)").Count) { return }
    $backup = Get-BackupDir $Dir
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    Copy-Item -LiteralPath $userjs -Destination (Join-Path $backup 'user.js')
  }
  $kept = @($lines | Where-Object { -not $_.Contains("`"$PrefName`"") })
  [IO.File]::WriteAllText($userjs, (($kept + $PrefLine) -join "`n") + "`n", $Utf8)
}

function Disable-Pref([string]$Dir) {
  $userjs = Join-Path $Dir 'user.js'
  if (-not (Test-Path -LiteralPath $userjs -PathType Leaf)) { return }
  $lines = @([IO.File]::ReadAllLines($userjs))
  $kept = @($lines | Where-Object { -not $_.Contains($PrefLine) })
  if ($kept.Count -eq $lines.Count) { return }
  if (@($kept | Where-Object { $_.Trim() }).Count) {
    [IO.File]::WriteAllText($userjs, ($kept -join "`n") + "`n", $Utf8)
  } else {
    Remove-Item -LiteralPath $userjs -Force
  }
}

function Install-Into([string]$Dir) {
  $chrome = Join-Path $Dir 'chrome'
  if (-not (Test-ChromeClean $Dir)) {
    $backup = Get-BackupDir $Dir
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    Move-Dir $chrome (Join-Path $backup 'chrome')
    Say "    old chrome\ moved to $(Get-Tilde (Join-Path $backup 'chrome'))"
  }
  New-Item -ItemType Directory -Force -Path $chrome | Out-Null
  [IO.File]::WriteAllText((Join-Path $chrome 'userChrome.css'), (Get-Rendered 'userChrome.css'), $Utf8)
  $content = Join-Path $chrome 'userContent.css'
  if ($NoContent) {
    if (Test-Path -LiteralPath $content) { Remove-Item -LiteralPath $content -Force }
  } else {
    [IO.File]::WriteAllText($content, (Get-Rendered 'userContent.css'), $Utf8)
  }
  Enable-Pref $Dir
}

function Uninstall-From([string]$Dir) {
  $chrome = Join-Path $Dir 'chrome'
  foreach ($f in 'userChrome.css', 'userContent.css') {
    $file = Join-Path $chrome $f
    if (Test-Ours $file) { Remove-Item -LiteralPath $file -Force }
  }
  if ((Test-Path -LiteralPath $chrome -PathType Container) -and -not (Get-ChildItem -LiteralPath $chrome -Force)) {
    Remove-Item -LiteralPath $chrome
  }
  Disable-Pref $Dir
  $latest = Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name.StartsWith("$(Split-Path $Dir -Leaf)-") -and (Test-Path -LiteralPath (Join-Path $_.FullName 'chrome')) } |
    Sort-Object Name | Select-Object -Last 1
  if ($latest) { Say "    your previous chrome\ is saved at $(Get-Tilde (Join-Path $latest.FullName 'chrome'))" }
}

# ----------------------------------------------------------------------- main --

Find-Installs
Find-Profiles

if ($Mode -eq 'list') {
  Show-Installs
  if ($Profiles.Count -gt 0) { Show-Profiles } else { Say 'No profiles found.' }
  exit 0
}

$Selected = @()
if ($ProfileDir) {
  foreach ($arg in $ProfileDir) {
    if (-not (Test-Path -LiteralPath $arg -PathType Container)) { Die "profile directory not found: $arg" }
    $dir = Resolve-Dir $arg
    Add-Profile 'custom' (Split-Path $dir -Leaf) $dir $false
    for ($i = 0; $i -lt $Profiles.Count; $i++) {
      if ($Profiles[$i].Path -eq $dir -and $Selected -notcontains $i) { $Selected += $i }
    }
  }
} else {
  if ($Profiles.Count -eq 0) {
    Die 'no Firefox profiles found. Start Firefox once, or pass -ProfileDir DIR (see about:support -> Profile Folder).'
  }
  Show-Installs
  Show-Profiles
  if ($All) {
    $Selected = 0..($Profiles.Count - 1)
  } elseif (Test-CanPrompt) {
    $Selected = @(Read-Selection)
  } else {
    Die 'no terminal to ask which profiles to use; pass -All or -ProfileDir DIR.'
  }
}

Say
if ($Mode -eq 'install') {
  Say "Applying radius $Radius to $(@($Selected).Count) profile(s):"
} else {
  Say "Removing $Name from $(@($Selected).Count) profile(s):"
}
$needsBackup = $false
foreach ($i in $Selected) {
  Write-Part "  $($Profiles[$i].Name) "
  Write-Part "($($Profiles[$i].Label))" DarkGray
  Write-Host
  if (-not (Test-ChromeClean $Profiles[$i].Path)) { $needsBackup = $true }
}
if ($Mode -eq 'install' -and $needsBackup) {
  Write-Warning "Existing chrome\ folders will be replaced. Their contents are moved to $(Get-Tilde $BackupRoot)."
}
Confirm-Continue 'Continue?'
Say

$restart = New-Object System.Collections.Generic.List[string]
foreach ($i in $Selected) {
  $p = $Profiles[$i]
  if ($Mode -eq 'install') { Install-Into $p.Path } else { Uninstall-From $p.Path }
  Ok $p.Name "($(Get-Tilde $p.Path))"
  if (-not $restart.Contains($p.Label)) { $restart.Add($p.Label) }
}

Say
Say "Done. Quit and restart: $($restart -join ', ')"
