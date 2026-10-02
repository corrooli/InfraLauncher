<p align="center">
  <img src="docs/icon.png" width="128" alt="InfraLauncher icon">
</p>

<h1 align="center">InfraLauncher</h1>

<p align="center">
  A small macOS app for the web UIs and shells that live behind your jump host.<br>
  One click opens the SSH tunnel and then the page.
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000?logo=apple&logoColor=white">
  <img alt="Swift 5" src="https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white">
  <img alt="No Xcode needed" src="https://img.shields.io/badge/Xcode-not%20needed-1f6feb">
  <img alt="License AGPL-3.0" src="https://img.shields.io/badge/license-AGPL--3.0-3fb950">
</p>

---

## Why

If your Proxmox, firewall, NAS or Grafana only answer inside a private network, you probably know this routine:

```sh
ssh -N -L 8006:192.168.1.10:8006 me@jumphost
# new terminal tab, open browser, type localhost:8006, forget which port was which...
```

InfraLauncher keeps those commands in a list. Each row has a switch and a button. The switch starts or stops the tunnel. The button starts it if needed, waits until the ports are really listening, and then opens the URL in your browser. Shell entries open a Terminal window with the SSH session instead.

It's one Swift file, it builds with the Command Line Tools, and it doesn't phone home or need an account. Your list stays on your Mac.

## What it does

- **Tunnel and open in one go.** Click the arrow and the page opens as soon as the forward is up, not before.
- **Knows when a tunnel is actually ready.** It runs `ssh -v` and watches for every `-L` port to report "listening". The dot turns green only then.
- **Clear errors.** Wrong key, host down, DNS failure, port already taken: the row tells you in plain words instead of a dead browser tab.
- **Several forwards per entry.** Put Prometheus and Alertmanager into one entry with two `-L` and two URLs, and both tabs open.
- **Shells too.** Entries without a URL open in Terminal.app, for example `ssh -J jumphost admin@192.168.1.40`.
- **Ask for a value.** Write `<ip>` (or `<host>`, or any `<name>`) in a command and the row gets a small text field for it. Handy for "shell on whatever box I need right now".
- **Checks ports before it starts.** If something else already sits on the local port, you get told up front.
- **Stays alive.** Keepalives are set, so a dead connection shows up as an error instead of hanging forever.
- **Cleans up after itself.** Quit the app or close the window and every tunnel it started goes with it. No orphaned `ssh` processes holding your ports.

## Requirements

- macOS 14 Sonoma or newer
- Apple Silicon (Intel works too, see [below](#intel-macs))
- Xcode Command Line Tools: `xcode-select --install`
- SSH **key** login to your jump host. Tunnels run in the background with `BatchMode=yes`, so there's nowhere to type a password.

## Build and install

```sh
git clone https://github.com/corrooli/InfraLauncher.git
cd InfraLauncher
./build.sh install
```

That compiles the app, draws the icon, signs it ad hoc and copies it to `/Applications`. Run `./build.sh` without `install` if you only want the bundle in `build/`.

Because you build it yourself, Gatekeeper won't complain on first launch.

## Getting started

### 1. Give your jump host a name

The example entries use a host called `jumphost`. The easiest way to make them work is an alias in `~/.ssh/config`:

```ssh-config
Host jumphost
    HostName jump.example.com
    User admin
    IdentityFile ~/.ssh/id_ed25519
```

Now `ssh jumphost` should log you in without asking anything. If your key has a passphrase, load it into the agent once and macOS will remember it:

```sh
ssh-add --apple-use-keychain ~/.ssh/id_ed25519
```

Anything you set up in `~/.ssh/config` (ports, users, `ProxyJump`, other aliases) also works inside InfraLauncher, because it just runs your `ssh`.

### 2. Make the list yours

On first launch you get a handful of examples. Hover a row and click the slider icon, or right click and pick **Edit…**, to change it. The **+** in the toolbar adds a new one.

Every entry has three fields:

| Field   | What goes in                                                                 |
|---------|------------------------------------------------------------------------------|
| Name    | Whatever you want to see in the list                                         |
| Command | The full shell command, usually `ssh -N -L ...`                              |
| Open    | One URL per line. Leave it empty and the entry becomes a Terminal shortcut   |

The editor shows which local ports it found in your command, so you can check before saving.

## Command recipes

**A web UI on a machine the jump host can reach**

```sh
ssh -N -L 8006:192.168.1.10:8006 jumphost
```
Open: `https://localhost:8006`

**Hostnames work too.** They get resolved on the jump host, so internal DNS names are fine even if your Mac can't resolve them:

```sh
ssh -N -L 5001:nas.lan:5001 jumphost
```
Open: `https://localhost:5001`

**Two services, one entry**

```sh
ssh -N -L 9090:192.168.1.20:9090 -L 9093:192.168.1.20:9093 jumphost
```
Open:
```
http://localhost:9090
http://localhost:9093
```

**A service that only listens on 127.0.0.1 of some inner server.** Hop through the jump host with `-J` and forward from the inner box:

```sh
ssh -N -J jumphost -L 8081:127.0.0.1:81 admin@192.168.1.30
```
Open: `http://localhost:8081`

**A shell on a server behind the jump host** (leave Open empty)

```sh
ssh -J jumphost admin@192.168.1.40
```

**A shell on any host, asked each time**

```sh
ssh -J jumphost root@<ip>
```
The row gets an input field. Type the IP and press Enter.

**Not SSH at all.** The command runs through `/bin/sh`, so other long running forwarders work too:

```sh
kubectl port-forward svc/grafana 3000:80 -n monitoring
```
For these the app can't see the ports, so it counts the entry as up once the process has been running for a moment.

> [!TIP]
> Give every entry its own local port. Two entries on `:8006` can't run at the same time, and the app will tell you so.

## Using it

| Action | How |
|---|---|
| Start or stop a tunnel | The switch on the row |
| Connect and open in the browser | The arrow button |
| Open a shell entry | The terminal button |
| Edit, copy the command, delete | Right click a row |
| Stop every tunnel | Toolbar button, or <kbd>⌘</kbd> <kbd>.</kbd> |
| Get the example list back | File menu, **Restore Default Services** |

The dot on the left tells you the state:

- grey: off
- orange, pulsing: connecting
- green: all ports are listening
- red: failed, the reason is right below the name

If you change the command of a running tunnel, it restarts with the new settings when you save.

If a tunnel is up but the target behind it doesn't answer, the row says *Target unreachable* in orange. The SSH part is fine in that case. Check the service itself.

## What happens under the hood

For commands that start with `ssh `, InfraLauncher adds a few options before running them:

| Option | Why |
|---|---|
| `-v` | So it can read "Local forwarding listening on ... port N" and know when each port is ready |
| `-o BatchMode=yes` | Never wait for a password prompt nobody can see |
| `-o StrictHostKeyChecking=accept-new` | New hosts are accepted the first time, changed keys are still refused |
| `-o ExitOnForwardFailure=yes` | Fail loudly if a port can't be bound, instead of running half broken |
| `-o ConnectTimeout=10` | Don't hang on hosts that aren't there |
| `-o ServerAliveInterval=15 -o ServerAliveCountMax=3` | Notice a dead connection within about 45 seconds |

If not all ports report in within 25 seconds, the tunnel is stopped and marked as timed out.

Your list is saved as plain JSON here:

```
~/Library/Application Support/InfraLauncher/services.json
```

You can back it up, sync it, or edit it by hand while the app is closed. Each entry looks like this:

```json
{
  "id" : "6F1C2A4E-3B7D-4C1A-9E0F-2D8B5A7C1E33",
  "name" : "Proxmox",
  "command" : "ssh -N -L 8006:192.168.1.10:8006 jumphost",
  "urls" : [ "https://localhost:8006" ]
}
```

Any unique UUID works for `id`. Delete the file and the app starts over with the examples.

## Troubleshooting

**"Permission denied" in red.** Your key wasn't accepted. Run the command in Terminal and see what SSH says. Often the key just isn't loaded in the agent (`ssh-add -l` to check).

**"Unknown host key".** The host key changed or can't be verified. Connect once in Terminal and sort it out there.

**"Port ... is already in use".** Something else holds that local port. Often it's a tunnel you started by hand earlier. Find it with:

```sh
lsof -nP -iTCP:8006 -sTCP:LISTEN
```

**"Timed out".** SSH connected but not every `-L` port came up. Check for typos in the forward, and that the jump host may forward at all (`AllowTcpForwarding` in its `sshd_config`).

**The browser warns about the certificate.** Expected. Things like Proxmox, DSM or OPNsense have certificates for their real name, not for `localhost`. Accept it once, or add the real name to `/etc/hosts` pointing at `127.0.0.1` and use that in the URL.

## Intel Macs

Change the target in `build.sh` from

```
-target arm64-apple-macos14.0
```

to

```
-target x86_64-apple-macos14.0
```

and build as usual.

## Project layout

```
InfraLauncher.swift   the whole app: model, tunnel handling, SwiftUI views
icon.swift            draws the app icon at build time
build.sh              compiles, bundles, signs, optionally installs
```

No Xcode project, no dependencies, no package manager. Code comments are in German; issues and pull requests in English are welcome.

## License

[GNU AGPL-3.0](LICENSE)
