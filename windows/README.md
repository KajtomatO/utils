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
code-server-connect.cmd [options]
.\code-server-connect.ps1 [options]
```

The `.cmd` launcher runs the script with `-ExecutionPolicy Bypass`, so it also
works from `cmd`, the Run dialog or a double-click.

| Option | What it does |
| --- | --- |
| `-CurrentWindow` | Add the tabs to the current window instead of opening a new one |
| `-Filter <pattern>[,<pattern>…]` | Only sessions whose name matches. Without wildcards it matches anywhere in the name: `hem-js` → `*hem-js*` |
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
