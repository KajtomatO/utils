# windows

Helpers for the Windows side of the setup.

## code-server-connect

Opens a Windows Terminal tab for every tmux session on the code server. Each
tab is named after its session, attached with [`tm a`](../tools/README.md#tm),
and reconnects on its own when the connection ends.

### Requirements

- Windows Terminal (`wt.exe`)
- WSL with `ssh`, and key-based login to the server
- [`tm`](../tools/README.md#tm) installed on the server as `~/.local/bin/tm`

### Usage

```
code-server-connect.cmd [connect|create] [options]
.\code-server-connect.ps1 [connect|create] [options]
```

The `.cmd` launcher runs the script with `-ExecutionPolicy Bypass`, so it also
works from `cmd`, the Run dialog or a double-click. `connect` is the default;
[`create`](#create-mode) manages the sessions.

| Option | What it does |
| --- | --- |
| `-CurrentWindow` | Add the tabs to the current window instead of opening a new one |
| `-Filter <pattern>[,<pattern>…]` | `connect` only: sessions whose name matches. Without wildcards it matches anywhere in the name: `hem-js` → `*hem-js*` |
| `-Server <host>` | Server to connect to (default `192.168.0.153`) |
| `-ReconnectDelay <s>` | Seconds to wait before re-attaching (default `5`) |

```
> .\code-server-connect.ps1 -CurrentWindow -Filter hem-js
Listing tmux sessions on 192.168.0.153...
Opening 2 tab(s) in the current window:
  3   hem-js               attached
  4   hem-js-console       attached
```

Tabs open in the order of `tm ls`. In `-CurrentWindow` mode the tab you ran the
script from stays as it is.

### Reconnecting

A tab re-attaches to its session `-ReconnectDelay` seconds after any
disconnect, including a deliberate detach. To stop it, press Ctrl+C during the
countdown or close the tab. While you are attached, Ctrl+C goes to the remote
session.

Tabs attach with `tm a <name>`. `tm` reads a bare number as a position in its
list, so a session with a numeric name such as `0` may attach to the wrong
session — give those sessions a name.

### Create mode

```
code-server-connect create
```

An interactive list of the folders in `~/repo` on the server (dot-folders
skipped). Each folder has a pair of sessions, `<folder>` and
`<folder>-console`, both started in that folder:

```
 Folders in 192.168.0.153:~/repo   (6 sessions)

   [ ] encedo-hem-tool
   [■] hem-sdk-js                   attached
   [◧] open-mercato                 only open-mercato
 * [ ] utils
```

| Box | Meaning |
| --- | --- |
| `[■]` | Both sessions exist |
| `[◧]` | Only one of the two exists. Create adds the missing one |
| `[ ]` | No sessions |

A folder is matched to its sessions by name only. Sessions named any other way
(`hem-c` for `encedo-hem-c-api`, say) show up only in the all-sessions view.
Dots and colons in a folder name become `_` in the session name, since tmux
does not allow them.

| Key | What it does |
| --- | --- |
| ↑ ↓ PgUp PgDn Home End | Move |
| Space | Mark the row (`*`) and move down |
| C | Create the missing sessions for the marked folders, or the one under the cursor |
| K | Kill the sessions of the marked folders, or the one under the cursor. Asks first |
| A | Switch between the folder view and a view of every tmux session, where K kills exactly the sessions you pick |
| R | Reload from the server |
| Q, Esc, Ctrl+C | Quit |

If you created sessions, quitting asks whether to open tabs for them, in a new
window or, with `-CurrentWindow`, the current one.

Killing an attached session drops whoever is attached. A tab opened by this
script then keeps trying to reconnect: close it.
