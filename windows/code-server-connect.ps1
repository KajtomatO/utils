<#
.SYNOPSIS
    code-server-connect — open a Windows Terminal tab for every tmux session on the code server.

.DESCRIPTION
    Lists the sessions with `tm` on the server, then opens one tab per session, named after it,
    that attaches with `tm a` and reconnects whenever the connection ends.

.PARAMETER CurrentWindow
    Add the tabs to the current Windows Terminal window instead of opening a new one.

.PARAMETER Filter
    Only open sessions whose name matches one of these patterns. A pattern without wildcards
    matches anywhere in the name (hem-js -> *hem-js*). Comma-separated lists are accepted too.

.PARAMETER Server
    Host to ssh to (through WSL).

.PARAMETER ReconnectDelay
    Seconds a tab waits before re-attaching after its connection ends.

.EXAMPLE
    .\code-server-connect.ps1
.EXAMPLE
    .\code-server-connect.ps1 -CurrentWindow -Filter hem-js
#>
[CmdletBinding()]
param(
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

if (-not (Get-Command wt -ErrorAction SilentlyContinue)) {
    Fail 'Windows Terminal (wt.exe) not found. Install it from the Microsoft Store or winget: winget install Microsoft.WindowsTerminal'
}

# --- 1. List sessions -------------------------------------------------------
# WSL hands the raw command line to its shell. The double quotes PowerShell adds around an
# argument with spaces are stripped there, so ~ is not expanded in WSL and reaches the server.
# Extra quotes inside the string would survive all the way to the remote shell — don't add any.
Write-Host "Listing tmux sessions on $Server..."
$output = & wsl ssh -t $Server "~/.local/bin/tm ls"
if ($LASTEXITCODE -ne 0) {
    Fail "listing sessions failed (ssh exit code $LASTEXITCODE)"
}

$ansi = "$([char]27)\[[0-9;?]*[A-Za-z]"
$sessions = foreach ($line in $output) {
    $clean = ($line -replace $ansi, '') -replace "`r", ''
    # ID  NAME  WINDOWS  STATUS  CREATED — the header, "no tmux sessions" and ssh noise don't match
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

# --- 2. Build one wt call with a tab per session -----------------------------
# One call keeps the tabs in order and in a single window. Each tab's loop goes in as
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

$wtArgs = @('-w', $(if ($CurrentWindow) { '0' } else { 'new' }))
$first = $true
foreach ($session in $sessions) {
    if (-not $first) { $wtArgs += ';' }
    $first = $false
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes((New-TabScript $session.Name)))
    $wtArgs += 'new-tab', '--title', $session.Name, '--suppressApplicationTitle',
               'powershell', '-NoProfile', '-EncodedCommand', $encoded
}

$where = if ($CurrentWindow) { 'the current window' } else { 'a new window' }
Write-Host "Opening $($sessions.Count) tab(s) in ${where}:"
foreach ($session in $sessions) {
    Write-Host ("  {0,-3} {1,-20} {2}" -f $session.Id, $session.Name, $session.Status)
}

& wt @wtArgs
