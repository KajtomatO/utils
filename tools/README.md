# tools

Standalone command-line helpers. Each one is a single self-contained executable
with no build step; [`install.sh`](#install) puts them on your `PATH`.

Currently: [`tm`](#tm), [`gls`](#gls).

## Install

```
./install.sh
```

installs every tool as a symlink in `~/.local/bin`. Run it again whenever you
like: it reports each tool and touches only what needs changing.

```
$ ./install.sh
tm   up to date     /home/you/.local/bin/tm -> /home/you/repo/tools/tm
gls  installed      /home/you/.local/bin/gls -> /home/you/repo/tools/gls
```

| Option | What it does |
| --- | --- |
| `--copy` | Install standalone copies instead of symlinks |
| `--system` | Install into `/usr/local/bin`, using `sudo` for the writes if needed |
| `--dir DIR` | Install into `DIR` |
| `--check` | Report only and change nothing; exit `1` unless everything is installed and up to date |
| `-h`, `--help` | Show usage |

The two modes differ in what "out of date" means:

- A **symlink** always runs the file in this folder, so edits here are live at
  once. It is out of date only when it is missing, dangling or points somewhere
  else.
- A **copy** is a snapshot. It is compared byte for byte with the file in this
  folder and replaced when they differ, so edits here go live when you re-run
  `install.sh --copy`.

Running with the other mode converts what is installed. With `--system`, prefer
`--copy`: a symlink into your home folder only works for users who can read it.

Each tool is reported as `up to date`, `installed`, `updated` or `skipped`.
`skipped` means a file with that name is in the way and is not this tool — a
different program called `tm`, say. It is never overwritten; remove it yourself
if you want the tool installed there. The exit status is then `1`.

Afterwards `install.sh` notes anything that would stop the tools from working:
the target directory missing from your `PATH`, another `tm` or `gls` earlier on
the `PATH` that would run instead, or a command a tool needs that is not
installed.

To add a tool, drop it in this folder with `# name — description` as its second
line (that header is how `install.sh` recognizes its own tools) and add the
name to `TOOLS` at the top of `install.sh`.

## tm

A small wrapper around the tmux commands you actually type all day: list
sessions, attach to one, make one, close them.

### Requirements

- `bash` 4.4 or newer, and `tmux`
- `jq`, but only for `tm claude`
- `column` is used to align `tm ls` output when present, and skipped when not

### Commands

| Command | What it does |
| --- | --- |
| `tm` | Same as `tm ls` |
| `tm ls` | List sessions with their ids |
| `tm a <id\|name>` | Attach to a session |
| `tm new [name]` | Create a session, named or auto-named |
| `tm kill <id\|name>…` | Close one or more sessions |
| `tm kill-all [-y]` | Close every session and stop the tmux server |
| `tm claude` | Configure tmux and Claude Code to work well together |
| `tm help` | Show usage |

`a`, `kill` and `kill-all` also answer to `attach`, `k`/`close` and
`ka`/`killall`.

Inside tmux, `tm a` switches the current client instead of nesting an attach,
and `tm new` creates the session detached and then switches to it — both of
which plain `tmux attach` refuses to do from within a session.

### Session ids

`tm ls` numbers sessions from 1:

```
$ tm ls
ID  NAME      WINDOWS  STATUS    CREATED
1   0         1w       detached  Thu Aug  6 11:54:13 2026
2   encedo-c  1w       attached  Thu Aug  6 12:22:38 2026
```

Those ids are **positions in that list**, not tmux's own session ids, so they
shift as sessions come and go. Run `tm ls` before acting on one. Anywhere an id
is accepted you can also give:

- `$3` — a raw tmux session id, passed through to tmux untouched
- `=name` — an exact session name, skipping tmux's prefix matching
- `name` — an exact session name

Numeric session names are worth a note, because tmux hands them out by default:
a bare number is read as an id first, and only falls back to a name when there
is no session at that position. Above, `tm a 1` attaches to the session *named*
`0`, since that is the one listed under id 1. Use `=0` when you mean the name.

`tm kill` resolves all of its arguments before killing anything, so ids do not
shift out from under a list — `tm kill 1 2` closes the two sessions you saw in
`tm ls`, not the first one and then whatever slid into second place. Unknown
targets are reported and the rest still run; the exit status is non-zero if any
target failed.

`tm kill-all` asks before stopping the server. Pass `-y` to skip the prompt; with
no terminal to prompt on it refuses unless `-y` is given, so it is safe in a
script that inherited a stray stdin.

### tm claude

Applies the settings that make Claude Code behave inside tmux, in two files:

- `~/.tmux.conf` — `extended-keys` (so modified keys such as Shift+Enter arrive
  intact), `terminal-features xterm*:extkeys`, `allow-passthrough`, and `mouse`
- `~/.claude/settings.json` — `env.CLAUDE_CODE_TMUX_TRUECOLOR=1` and
  `env.CLAUDE_CODE_NO_FLICKER=1`

It is idempotent: it adds only the lines that are missing, and reports that
everything is already configured when nothing needs doing. Before changing
either file it writes a timestamped `.bak` copy next to it. Existing keys in
`settings.json` are preserved, and if that file is not valid JSON, `tm` refuses
to touch it rather than risk clobbering it.

Afterwards it reloads `~/.tmux.conf` in the running server if there is one. The
environment variables only reach a Claude Code session that starts after this,
so restart any that are already running.

## gls

`ls` for a folder full of git repos: one line per folder, colored by whether
the repo in it needs your attention.

### Requirements

- `bash` 4.4 or newer, and `git`
- `timeout` (coreutils) caps each fetch at 30 seconds when present

### Usage

```
gls [options] [path]
```

Reports on every folder directly under `path`, or under the current directory
when no path is given.

| Option | What it does |
| --- | --- |
| `-l`, `--long` | One column per check, to see *why* a name has its color |
| `-r`, `--recursive` | Find repos at any depth |
| `-n`, `--no-fetch` | Don't contact the remotes; judge from the last fetch |
| `-a`, `--all` | Include hidden (dot) folders |
| `-h`, `--help` | Show usage |

Short flags combine: `gls -nl ~/repo`.

### The short list

```
$ gls ~/repo
agent-work-template      review-2026-10-04
debug-usb
encedo-hem-c-api+        development
encedo-hem-python-api*+  development
hem-api-tester           main
open-mercato+            main
```

Each line is the folder name and, for a repo, its current branch (a detached
HEAD shows as `(detached abc1234)`). The color of the name is the verdict:

| Color | Meaning |
| --- | --- |
| green | Nothing to do |
| yellow | A remote branch other than the upstream has commits on top of the current commit |
| red | Uncommitted changes, staged changes, branch not pushed, branch behind its upstream, a local branch has commits on top of the current commit, or the fetch failed |
| gray | Not a git repo |

and the suffix adds detail:

- `*` — uncommitted or staged changes
- `+` — untracked files. These never change the color: a repo with only
  untracked files stays green.

A name that is red and ~~struck through~~ is a repo whose [fetch](#fetching)
failed: everything else on its line comes from the last successful fetch.

Colors and strikethrough are used only when stdout is a terminal and `NO_COLOR`
is unset. Piped output is plain text, so use `-l` there.

### The long table

```
$ gls -l ~/repo
NAME                     BRANCH             DIRTY  STAGED  UNTRACKED  PUSHED  AHEAD
agent-work-template      review-2026-10-04  no     no      0          yes     no
debug-usb                -                  -      -       -          -       -
encedo-hem-c-api+        development        no     no      1          NO +2   no
encedo-hem-python-api*+  development        YES    no      1          yes     no
hem-api-tester           main               no     no      0          yes     no
open-mercato+            main               no     no      1          yes     remote 55
```

| Column | Values |
| --- | --- |
| `DIRTY` | `YES` when tracked files are modified, deleted or in conflict |
| `STAGED` | `YES` when the index holds changes |
| `UNTRACKED` | Number of untracked entries, counted the way `git status` lists them: a new directory counts once, ignored files not at all |
| `PUSHED` | `yes`; `NO +N` — N commits are not on the upstream; `NO gone` — the upstream branch was deleted; `NO` — no upstream and the commit is on no remote branch |
| `AHEAD` | `no`; `upstream -N` — N commits to pull; `local N` / `remote N` — N branches have commits on top of the current commit |

Two rules are worth spelling out:

- **Pushed without an upstream.** A branch with no upstream (or a detached
  HEAD) still counts as pushed when its commit already exists on some remote
  branch — a fresh branch with no commits of its own has nothing to lose. A
  repo with no remote at all is never pushed.
- **Ahead.** A branch is "ahead" only when it contains the current commit plus
  newer ones; a branch that has diverged from it does not count. Being behind
  the upstream or behind a *local* branch is red. Being behind some *other*
  remote branch — a colleague's feature branch, a dependabot PR — is yellow, and
  only when nothing else is wrong.

A repo with no commits yet shows `-` for `PUSHED` and `AHEAD`.

### Fetching

Unless you pass `-n`, `gls` first runs `git fetch --all` in every repo, eight
at a time, so the verdicts reflect the remotes as they are now. It does not
prune.

Those fetches never prompt: with several sharing one terminal, a passphrase or
host-key question could not be answered sanely. SSH runs in batch mode, so a
key that needs a passphrase must already be loaded in `ssh-agent`.

A repo whose fetch fails or exceeds its timeout turns red, whatever its other
checks say, and its name is struck through. The other columns still show what
it last fetched. It is also named on stderr after the report, which is the only
sign of it in piped output —

```
gls: fetch failed, showing last-fetched state: encedo_firmware
```

Run `git fetch` in that repo by hand to see the reason.

### Recursive mode

`gls -r` walks down from `path` and lists the repos it finds, by relative path.
Folders that are not repos are not listed. It stops at each repo root, so
submodules and repos nested inside a repo are not reported, and it stays out of
`node_modules` and symlinked folders.

### Exit status

`0` whenever the report was produced, whatever the colors; `1` for a bad path
or option.
