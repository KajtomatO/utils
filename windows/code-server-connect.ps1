<#
.SYNOPSIS
    code-server-connect - open a Windows Terminal tab for every tmux session on the code server,
    or manage the sessions interactively.

.DESCRIPTION
    connect (default): lists the sessions with `tm` on the server, then opens one tab per session,
    named after it, that attaches with `tm a` and reconnects whenever the connection ends.

    create: an interactive list of the folders in ~/repo on the server. Each folder can have a pair
    of sessions, <folder> and <folder>-console, started in that folder. Create and kill them here;
    press A for a view of every tmux session, whatever its name.

.PARAMETER Mode
    connect (default) or create.

.PARAMETER CurrentWindow
    Add the tabs to the current Windows Terminal window instead of opening a new one.

.PARAMETER Filter
    connect mode: only open sessions whose name matches one of these patterns. A pattern without
    wildcards matches anywhere in the name (hem-js -> *hem-js*). Comma-separated lists work too.

.PARAMETER Server
    Host to ssh to (through WSL).

.PARAMETER ReconnectDelay
    Seconds a tab waits before re-attaching after its connection ends.

.EXAMPLE
    .\code-server-connect.ps1
.EXAMPLE
    .\code-server-connect.ps1 -CurrentWindow -Filter hem-js
.EXAMPLE
    .\code-server-connect.ps1 create
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('connect', 'create')]
    [string]$Mode = 'connect',
    [switch]$CurrentWindow,
    [string[]]$Filter,
    [string]$Server = '192.168.0.153',
    [int]$ReconnectDelay = 5
)

$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    Write-Host "code-server-connect: $Message" -ForegroundColor Red
    exit 1
}

function Assert-WindowsTerminal {
    if (-not (Get-Command wt -ErrorAction SilentlyContinue)) {
        Fail 'Windows Terminal (wt.exe) not found. Install it from the Microsoft Store or winget: winget install Microsoft.WindowsTerminal'
    }
}

# --- Tabs ---------------------------------------------------------------------
# One wt call keeps the tabs in order and in a single window. Each tab's loop goes in as
# -EncodedCommand so its quotes and semicolons never reach wt's parser.
function New-TabScript([string]$Name) {
    $n = $Name -replace "'", "''"
    $s = $Server -replace "'", "''"
    @"
`$name = '$n'
`$server = '$s'
while (`$true) {
    wsl ssh -t `$server "~/.local/bin/tm a `$name"
    Write-Host "``n[`$name] disconnected (exit `$LASTEXITCODE). Reconnecting in ${ReconnectDelay}s - Ctrl+C to stop." -ForegroundColor Yellow
    Start-Sleep -Seconds $ReconnectDelay
}
"@
}

function Open-SessionTabs([string[]]$Names) {
    Assert-WindowsTerminal
    $wtArgs = @('-w', $(if ($CurrentWindow) { '0' } else { 'new' }))
    $first = $true
    foreach ($name in $Names) {
        if (-not $first) { $wtArgs += ';' }
        $first = $false
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes((New-TabScript $name)))
        $wtArgs += 'new-tab', '--title', $name, '--suppressApplicationTitle',
                   'powershell', '-NoProfile', '-EncodedCommand', $encoded
    }
    & wt @wtArgs
}

# --- Remote commands (create mode) ----------------------------------------------
# The script travels as base64, which has no characters any of PowerShell, WSL's bash, ssh or
# the remote zsh would interpret, and is run by bash on the server.
function Invoke-Remote([string]$Script) {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Script -replace "`r", '')))
    # Continue, not Stop: with 2>&1, PowerShell 5.1 turns each stderr line of a native command
    # into an error record, which Stop would throw on.
    $ErrorActionPreference = 'Continue'
    $out = @(& wsl ssh -T -o BatchMode=yes -o ConnectTimeout=10 $Server "echo $b64 | base64 -d | bash" 2>&1 |
        ForEach-Object { "$_" -replace "`r", '' })
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $out }
}

function ConvertTo-ShQuote([string]$Value) {
    "'" + ($Value -replace "'", "'\''") + "'"
}

# tmux does not allow . or : in session names
function Get-SessionBase([string]$Folder) {
    $Folder -replace '[.:]', '_'
}

$StateScript = @'
exec 2>&1
printf 'H\t%s\n' "$HOME"
cd ~/repo || exit 3
for d in */; do [ -d "$d" ] && printf 'D\t%s\n' "${d%/}"; done
tmux list-sessions -F $'S\t#{session_name}\t#{session_attached}\t#{session_path}' 2>/dev/null
exit 0
'@

function Get-RemoteState {
    $r = Invoke-Remote $StateScript
    if ($r.ExitCode -ne 0) {
        throw "reading state failed (exit $($r.ExitCode)): $(($r.Lines | Select-Object -First 2) -join ' ')"
    }
    $remoteHome = ''
    $folderNames = New-Object System.Collections.Generic.List[string]
    $sessions = New-Object System.Collections.Generic.List[object]
    foreach ($line in $r.Lines) {
        $f = $line -split "`t", 4
        switch ($f[0]) {
            'H' { $remoteHome = $f[1] }
            'D' { $folderNames.Add($f[1]) }
            'S' {
                if ($f.Count -eq 4) {
                    $sessions.Add([pscustomobject]@{ Key = $f[1]; Name = $f[1]; Attached = ([int]$f[2] -gt 0); Path = $f[3] })
                }
            }
        }
    }
    $byName = @{}
    foreach ($s in $sessions) { $byName[$s.Name] = $s }
    $folders = foreach ($folder in $folderNames) {
        $base = Get-SessionBase $folder
        $names = @($base, "$base-console")
        $existing = @($names | Where-Object { $byName.ContainsKey($_) } | ForEach-Object { $byName[$_] })
        $state = if ($existing.Count -eq 0) { 'none' } elseif ($existing.Count -eq $names.Count) { 'full' } else { 'partial' }
        [pscustomobject]@{ Key = $folder; Folder = $folder; Names = $names; Existing = $existing; State = $state }
    }
    [pscustomobject]@{ Home = $remoteHome; Folders = @($folders); Sessions = $sessions.ToArray() }
}

# $Targets: @{ Folder = ...; Name = ... } pairs. Returns the names created.
function New-RemoteSessions([object[]]$Targets) {
    $lines = @(
        'exec 2>&1'
        'mk() { if tmux has-session -t "=$1" 2>/dev/null; then echo "exists $1"; elif tmux new-session -d -s "$1" -c "$2"; then echo "created $1"; fi; }'
    )
    foreach ($t in $Targets) {
        $lines += 'mk {0} "$HOME/repo/"{1}' -f (ConvertTo-ShQuote $t.Name), (ConvertTo-ShQuote $t.Folder)
    }
    Invoke-Remote ($lines -join "`n")
}

function Remove-RemoteSessions([string[]]$Names) {
    $lines = @(
        'exec 2>&1'
        'rm_session() { if tmux kill-session -t "=$1"; then echo "killed $1"; fi; }'
    )
    foreach ($n in $Names) { $lines += 'rm_session ' + (ConvertTo-ShQuote $n) }
    Invoke-Remote ($lines -join "`n")
}

# --- Create mode TUI --------------------------------------------------------------
$BoxFull    = "[$([char]0x25A0)]"
$BoxPartial = "[$([char]0x25E7)]"
$BoxEmpty   = '[ ]'

# $Segments: hashtables @{ T = text; F = foreground color (optional) }
function Write-Row([int]$Y, [object[]]$Segments, [switch]$Highlight) {
    $width = [Console]::WindowWidth - 1
    [Console]::SetCursorPosition(0, $Y)
    $used = 0
    foreach ($seg in $Segments) {
        $text = [string]$seg.T
        if ($used + $text.Length -gt $width) { $text = $text.Substring(0, [Math]::Max(0, $width - $used)) }
        if (-not $text) { continue }
        $p = @{ NoNewline = $true }
        if ($seg.F) { $p.ForegroundColor = $seg.F } elseif ($Highlight) { $p.ForegroundColor = 'White' }
        if ($Highlight) { $p.BackgroundColor = 'DarkCyan' }
        Write-Host $text @p
        $used += $text.Length
    }
    $pad = ' ' * [Math]::Max(0, $width - $used)
    if ($Highlight) { Write-Host $pad -NoNewline -BackgroundColor DarkCyan } else { Write-Host $pad -NoNewline }
}

function Get-Items {
    if ($ui.View -eq 'folders') { $ui.State.Folders } else { $ui.State.Sessions }
}

function Get-Targets {
    $items = @(Get-Items)
    $marked = @($items | Where-Object { $ui.Marks.Contains($_.Key) })
    if ($marked.Count -gt 0) { return $marked }
    if ($items.Count -gt 0) { return @($items[$ui.Cursor]) }
    @()
}

function Set-Status([string]$Text, [string]$Color = 'Gray') {
    $ui.Status = $Text
    $ui.StatusColor = $Color
}

function Show-Frame {
    $w = [Console]::WindowWidth
    $h = [Console]::WindowHeight
    if ($w -ne $ui.Width -or $h -ne $ui.Height) {
        Clear-Host
        $ui.Width = $w
        $ui.Height = $h
    }
    $items = @(Get-Items)
    $listHeight = [Math]::Max(3, $h - 5)
    if ($ui.Cursor -ge $items.Count) { $ui.Cursor = [Math]::Max(0, $items.Count - 1) }
    if ($ui.Cursor -lt $ui.Top) { $ui.Top = $ui.Cursor }
    if ($ui.Cursor -ge $ui.Top + $listHeight) { $ui.Top = $ui.Cursor - $listHeight + 1 }

    if ($ui.View -eq 'folders') {
        $title = "Folders in ${Server}:~/repo"
        $help = 'Up/Down move  Space mark  C create  K kill  A all sessions  R refresh  Q quit'
    } else {
        $title = "All tmux sessions on $Server"
        $help = 'Up/Down move  Space mark  K kill  A folders  R refresh  Q quit'
    }
    $marks = if ($ui.Marks.Count) { "   $($ui.Marks.Count) marked" } else { '' }
    Write-Row 0 @(@{ T = " $title"; F = 'Cyan' }, @{ T = "   ($($ui.State.Sessions.Count) sessions)$marks"; F = 'DarkGray' })
    Write-Row 1 @()

    for ($row = 0; $row -lt $listHeight; $row++) {
        $i = $ui.Top + $row
        $y = 2 + $row
        if ($i -ge $items.Count) {
            if ($i -eq 0) { Write-Row $y @(@{ T = '   (nothing here)'; F = 'DarkGray' }) } else { Write-Row $y @() }
            continue
        }
        $item = $items[$i]
        $mark = if ($ui.Marks.Contains($item.Key)) { ' * ' } else { '   ' }
        if ($ui.View -eq 'folders') {
            switch ($item.State) {
                'full'    { $box = @{ T = $BoxFull; F = 'Green' } }
                'partial' { $box = @{ T = $BoxPartial; F = 'Yellow' } }
                default   { $box = @{ T = $BoxEmpty; F = 'DarkGray' } }
            }
            $tags = @()
            if ($item.State -eq 'partial') { $tags += "only $($item.Existing[0].Name)" }
            if (@($item.Existing | Where-Object { $_.Attached }).Count) { $tags += 'attached' }
            $tag = if ($tags) { '   ' + ($tags -join ', ') } else { '' }
            Write-Row $y @(@{ T = $mark; F = 'Yellow' }, $box, @{ T = " $($item.Folder)" }, @{ T = $tag; F = 'DarkGray' }) -Highlight:($i -eq $ui.Cursor)
        } else {
            $status = if ($item.Attached) { @{ T = 'attached  '; F = 'Green' } } else { @{ T = 'detached  '; F = 'DarkGray' } }
            $path = $item.Path
            if ($ui.State.Home -and $path.StartsWith($ui.State.Home)) { $path = '~' + $path.Substring($ui.State.Home.Length) }
            Write-Row $y @(@{ T = $mark; F = 'Yellow' }, @{ T = ('{0,-24} ' -f $item.Name) }, $status, @{ T = $path; F = 'DarkGray' }) -Highlight:($i -eq $ui.Cursor)
        }
    }

    Write-Row ($h - 3) @()
    Write-Row ($h - 2) @(@{ T = " $help"; F = 'DarkGray' })
    Write-Row ($h - 1) @(@{ T = " $($ui.Status)"; F = $ui.StatusColor })
}

function Read-Confirm([string]$Question) {
    Set-Status "$Question [y/N]" 'Yellow'
    Show-Frame
    $key = [Console]::ReadKey($true)
    $key.KeyChar -eq 'y' -or $key.KeyChar -eq 'Y'
}

function Update-State {
    Set-Status 'Working...' 'DarkGray'
    Show-Frame
    $ui.State = Get-RemoteState
    $keys = @(Get-Items | ForEach-Object { $_.Key })
    foreach ($k in @($ui.Marks)) { if ($keys -notcontains $k) { [void]$ui.Marks.Remove($k) } }
}

# Turns remote output into a status line; returns the names reported with $Verb.
function Read-ActionResult($Result, [string]$Verb) {
    $done = @($Result.Lines | Where-Object { $_ -like "$Verb *" } | ForEach-Object { $_.Substring($Verb.Length + 1) })
    $other = @($Result.Lines | Where-Object { $_ -notlike "$Verb *" -and $_ -notlike 'exists *' -and $_ })
    if ($other.Count -or $Result.ExitCode -ne 0) {
        Set-Status "$Verb $($done.Count); error: $(($other | Select-Object -First 1)) (exit $($Result.ExitCode))" 'Red'
    } elseif ($done.Count) {
        Set-Status "$Verb $($done -join ', ')" 'Green'
    } else {
        Set-Status 'nothing changed' 'Gray'
    }
    $done
}

function Invoke-Create {
    if ($ui.View -ne 'folders') { Set-Status 'create works in the folder view (press A)' 'Yellow'; return }
    $todo = foreach ($f in Get-Targets) {
        foreach ($n in $f.Names) {
            if (-not @($f.Existing | Where-Object { $_.Name -eq $n }).Count) { @{ Folder = $f.Folder; Name = $n } }
        }
    }
    $todo = @($todo)
    if (-not $todo.Count) { Set-Status 'sessions already exist' 'Gray'; return }
    Set-Status "Creating $(($todo | ForEach-Object { $_.Name }) -join ', ')..." 'DarkGray'
    Show-Frame
    $created = Read-ActionResult (New-RemoteSessions $todo) 'created'
    foreach ($n in $created) { $ui.Created.Add($n) }
    $status = $ui.Status; $color = $ui.StatusColor
    $ui.Marks.Clear()
    Update-State
    Set-Status $status $color
}

function Invoke-Kill {
    if ($ui.View -eq 'folders') {
        $sessions = @(Get-Targets | ForEach-Object { $_.Existing })
    } else {
        $sessions = @(Get-Targets)
    }
    if (-not $sessions.Count) { Set-Status 'no sessions to kill' 'Gray'; return }
    $list = ($sessions | ForEach-Object { if ($_.Attached) { "$($_.Name) (attached)" } else { $_.Name } }) -join ', '
    if (-not (Read-Confirm "Kill $($sessions.Count) session(s): ${list}?")) { Set-Status 'kill cancelled' 'Gray'; return }
    Set-Status 'Killing...' 'DarkGray'
    Show-Frame
    [void](Read-ActionResult (Remove-RemoteSessions @($sessions | ForEach-Object { $_.Name })) 'killed')
    $status = $ui.Status; $color = $ui.StatusColor
    $ui.Marks.Clear()
    Update-State
    Set-Status $status $color
}

function Start-CreateMode {
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        Fail 'create mode needs an interactive terminal'
    }
    $script:ui = @{
        View = 'folders'; Cursor = 0; Top = 0; Width = 0; Height = 0
        Marks = New-Object 'System.Collections.Generic.HashSet[string]'
        Created = New-Object System.Collections.Generic.List[string]
        Status = ''; StatusColor = 'Gray'; State = $null
    }
    $savedEncoding = [Console]::OutputEncoding
    $savedCursor = [Console]::CursorVisible
    $savedCtrlC = [Console]::TreatControlCAsInput
    try {
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        [Console]::CursorVisible = $false
        [Console]::TreatControlCAsInput = $true
        Clear-Host
        $ui.State = [pscustomobject]@{ Home = ''; Folders = @(); Sessions = @() }
        try {
            Update-State
            Set-Status ''
        } catch {
            Set-Status "$_" 'Red'
        }
        while ($true) {
            Show-Frame
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'C' -and ($key.Modifiers -band [ConsoleModifiers]::Control)) { return }
            $count = @(Get-Items).Count
            $page = [Math]::Max(1, [Console]::WindowHeight - 6)
            try {
                switch ($key.Key) {
                    'UpArrow'   { if ($ui.Cursor -gt 0) { $ui.Cursor-- } }
                    'DownArrow' { if ($ui.Cursor -lt $count - 1) { $ui.Cursor++ } }
                    'PageUp'    { $ui.Cursor = [Math]::Max(0, $ui.Cursor - $page) }
                    'PageDown'  { $ui.Cursor = [Math]::Max(0, [Math]::Min($count - 1, $ui.Cursor + $page)) }
                    'Home'      { $ui.Cursor = 0 }
                    'End'       { $ui.Cursor = [Math]::Max(0, $count - 1) }
                    'Spacebar'  {
                        if ($count) {
                            $k = @(Get-Items)[$ui.Cursor].Key
                            if (-not $ui.Marks.Remove($k)) { [void]$ui.Marks.Add($k) }
                            if ($ui.Cursor -lt $count - 1) { $ui.Cursor++ }
                        }
                    }
                    'C'         { Invoke-Create }
                    'K'         { Invoke-Kill }
                    'A'         {
                        $ui.View = if ($ui.View -eq 'folders') { 'sessions' } else { 'folders' }
                        $ui.Marks.Clear(); $ui.Cursor = 0; $ui.Top = 0
                        Set-Status ''
                    }
                    'R'         { Update-State; Set-Status 'refreshed' }
                    'Q'         { return }
                    'Escape'    { return }
                }
            } catch {
                Set-Status "$_" 'Red'
            }
        }
    } finally {
        [Console]::OutputEncoding = $savedEncoding
        [Console]::CursorVisible = $savedCursor
        [Console]::TreatControlCAsInput = $savedCtrlC
        Clear-Host
    }
}

function Complete-CreateMode {
    $names = @($ui.Created | Select-Object -Unique)
    if (-not $names.Count) { return }
    $alive = @($ui.State.Sessions | ForEach-Object { $_.Name })
    $names = @($names | Where-Object { $alive -contains $_ })
    if (-not $names.Count) { return }
    $where = if ($CurrentWindow) { 'the current window' } else { 'a new window' }
    Write-Host "Created this run: $($names -join ', ')"
    Write-Host "Open tabs for $($names.Count) new session(s) in ${where}? [y/N] " -NoNewline
    $key = [Console]::ReadKey($true)
    Write-Host $key.KeyChar
    if ($key.KeyChar -eq 'y' -or $key.KeyChar -eq 'Y') { Open-SessionTabs $names }
}

if ($Mode -eq 'create') {
    Start-CreateMode
    Complete-CreateMode
    exit 0
}

# --- Connect mode -----------------------------------------------------------------
Assert-WindowsTerminal

# WSL hands the raw command line to its shell. The double quotes PowerShell adds around an
# argument with spaces are stripped there, so ~ is not expanded in WSL and reaches the server.
# Extra quotes inside the string would survive all the way to the remote shell - don't add any.
Write-Host "Listing tmux sessions on $Server..."
$output = & wsl ssh -t $Server "~/.local/bin/tm ls"
if ($LASTEXITCODE -ne 0) {
    Fail "listing sessions failed (ssh exit code $LASTEXITCODE)"
}

$ansi = "$([char]27)\[[0-9;?]*[A-Za-z]"
$sessions = foreach ($line in $output) {
    $clean = ($line -replace $ansi, '') -replace "`r", ''
    # ID  NAME  WINDOWS  STATUS  CREATED - the header, "no tmux sessions" and ssh noise don't match
    if ($clean -match '^\s*(\d+)\s+(\S+)\s+\d+w\s+(attached|detached)\b') {
        [pscustomobject]@{ Id = [int]$Matches[1]; Name = $Matches[2]; Status = $Matches[3] }
    }
}
$sessions = @($sessions | Sort-Object Id)
if ($sessions.Count -eq 0) {
    Fail "no tmux sessions found on $Server"
}

if ($Filter) {
    $patterns = @($Filter -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object {
        if ([WildcardPattern]::ContainsWildcardCharacters($_)) { $_ } else { "*$_*" }
    })
    $sessions = @($sessions | Where-Object {
        $name = $_.Name
        @($patterns | Where-Object { $name -like $_ }).Count -gt 0
    })
    if ($sessions.Count -eq 0) {
        Fail "no session matches filter: $($Filter -join ', ')"
    }
}

$where = if ($CurrentWindow) { 'the current window' } else { 'a new window' }
Write-Host "Opening $($sessions.Count) tab(s) in ${where}:"
foreach ($session in $sessions) {
    Write-Host ("  {0,-3} {1,-20} {2}" -f $session.Id, $session.Name, $session.Status)
}

Open-SessionTabs @($sessions | ForEach-Object { $_.Name })
