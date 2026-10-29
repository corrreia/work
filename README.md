# work

A corporate remote-work environment in Docker: a Check Point SSL VPN, a Windows 11 VM, and an Arch Linux container. Both guests share the VPN container's network namespace, so their traffic goes through the corporate tunnel. Only RFC 1918 ranges route through the VPN; the rest of your traffic goes direct over your home connection.

## Quickstart

Run these four commands in order, from the repo root:

```bash
./work.sh doctor    # check prerequisites (Docker, KVM, tun, tools)
./work.sh setup     # create .env (asks you a few questions)
./work.sh up        # build and start the containers
./work.sh connect   # bring up the VPN (prompts for 2FA)
```

Then open a guest:

```bash
./work.sh windows rdp    # Windows over RDP (full experience)
./work.sh windows web    # Windows in a browser (quick access)
./work.sh linux shell    # Arch Linux shell
```

## What you provide

`./work.sh setup` asks for these and writes them to `.env`:

- `USERNAME`: the login for both guests.
- `VPN_SERVER`: the VPN gateway IP. From your IT admin. See the note below; it is an IP, not the portal hostname.
- `VPN_PASSWORD`: your corporate credential. It rotates on the company schedule (~45 days). When it does, edit that one line in `.env` and reconnect.
- `CORPORATE_DNS`: the internal DNS server both guests use while the VPN is up. From your IT admin.

Optional:

- `VPN_EXTRA_ROUTES`: extra public ranges to send through the tunnel, comma-separated. Corporate GitHub is IP-allowlisted to company egress, so its ranges go here or git is blocked from both guests.
- `VPN_TEST_HOST`: an internal-only hostname for `./work.sh test`.

Setup generates a random `VM_PASSWORD` for the guest accounts and stores it in `.env`. It is separate from `VPN_PASSWORD` on purpose, so rotating the corporate credential never touches your guest login, and it does not rotate. Read it from `.env` if you ever log in to Windows directly.

Nothing company-specific lives in the repo. It all goes in `.env`, which is gitignored.

If you need internal root CAs in the Linux container, drop `.crt`, `.cer`, or `.pem` files into `./certificates/` before starting it. The same directory is served to Windows under the shared folder as `\\172.30.0.1\Data\certificates`.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  work-vpn container (snx-rs)                    │
│                                                 │
│  eth0 ──────── home internet                    │
│  snx-tun ───── corporate VPN (SSL)              │
│  docker ────── internal bridge (172.30.0.0/24)  │
│                     │                           │
│              ┌──────┴──────┐                    │
│              │ work-windows│                    │
│              │ (Win 11 VM) │                    │
│              └─────────────┘                    │
└─────────────────────────────────────────────────┘

Corporate traffic (10/8, 172.16/12, 192.168/16) → snx-tun → VPN
Internet traffic (everything else)              → eth0    → home
DNS (all queries)                               → corporate DNS
```

## Commands

```
Setup:
  ./work.sh setup               Create .env interactively (first run)
  ./work.sh doctor              Check prerequisites (Docker, KVM, tun, tools)

VPN:
  ./work.sh connect [--debug]   Connect VPN (prompts for 2FA)
  ./work.sh disconnect          Disconnect VPN
  ./work.sh reconnect [--debug] Disconnect + reconnect

Environment:
  ./work.sh up                  Start all containers
  ./work.sh down                Stop all containers
  ./work.sh status              Show VPN + VM status
  ./work.sh test [host]         Check internal DNS + reachability from both guests
  ./work.sh logs [vpn|windows|linux]  Tail container logs

Windows VM:
  ./work.sh windows start       Start the VM
  ./work.sh windows stop        Graceful shutdown
  ./work.sh windows restart     Stop + start
  ./work.sh windows rdp         Open RDP session (FreeRDP 3)
  ./work.sh windows web         Open web viewer in browser
  ./work.sh windows logs        Tail container logs

Linux:
  ./work.sh linux shell         Open interactive shell (alias: ssh)
  ./work.sh linux start|stop|restart   Control the Arch container
  ./work.sh linux rebuild       Re-snapshot host Omarchy config and rebuild the image
  ./work.sh linux logs          Tail container logs
```

## How it works

- **VPN**: [snx-rs](https://github.com/ancwrd1/snx-rs) runs in a Docker container in SSL tunnel mode. IPSec does not work with this server because of SCV/compliance checks. The image is pinned by digest (6.2.4); newer releases have changed routing and forwarding defaults before, so bump it deliberately and re-test both guests.
- **Windows VM**: [dockurr/windows](https://github.com/dockur/windows) runs a Windows 11 QEMU VM that shares the VPN container's network namespace.
- **Linux**: an Arch container set up like an Omarchy terminal shares the same namespace, opens a shell through `docker exec`, and points its resolver at corporate DNS while the VPN is up.
- **Split tunnel**: the server pushes full-tunnel routes, but `no-routing = true` ignores them. Only private subnets route through the VPN via `add-routes`. Internet goes direct.
- **Forwarding**: `allow-forwarding = true` is required. Otherwise snx-rs disables forwarding on `snx-tun` and drops every reply headed for the Windows VM. The Linux container is unaffected, since it shares the VPN namespace.
- **Local subnets**: snx-rs checks its own routing table (18000) before `main`, where the `172.16.0.0/12` route covers the Docker network and the VM bridge. `work.sh` adds `ip rule`s that send those back to `main`, so guests can start before or after the VPN connects.
- **NAT and DNS**: iptables masquerade on both `snx-tun` and `eth0`. Windows DNS is redirected to corporate DNS while the tunnel is up and the redirect is removed when snx-rs exits. Linux DNS is pointed at corporate DNS while up and switched back on `disconnect` or `status`.
- **RDP**: `./work.sh windows rdp` uses FreeRDP 3 (`xfreerdp3`, or `xfreerdp` where the distro names it that) with dynamic resolution, AVC444 graphics, clipboard, sound, mic, and Hyprland scale detection.
- **Shared folder**: `./shared/` is mounted into both guests as a common exchange folder. Certificates placed in `./certificates/` are mounted into the Linux container and imported into its trust store on startup.

## Guest shared folder access

Windows exposes the shared folder over Samba at `\\172.30.0.1\Data`. Linux sees the same files at `/shared` and `~/Shared`.

To import internal CAs in Windows, run this in an elevated PowerShell inside the VM:

```powershell
PowerShell -ExecutionPolicy Bypass -File \\172.30.0.1\Data\certificates\import-certs.ps1
```

## Post-install, one time inside Windows

The shared-folder desktop shortcut uses `host.lan`, which corporate DNS cannot resolve. Add a hosts entry in an elevated PowerShell to fix it:

```powershell
Add-Content C:\Windows\System32\drivers\etc\hosts "172.30.0.1 host.lan"
```

The `Shared` desktop shortcut then works. You can also map it as a drive with `net use Z: \\172.30.0.1\Data /persistent:yes`.

## Linux terminal environment

The Linux image mirrors the Omarchy terminal: the same bash rc chain (aliases, `cd`→zoxide, fzf, inputrc), starship prompt, LazyVim, lazygit, btop, eza, bat, ripgrep, fd, mise, gh, and tmux. Ghostty and Kitty terminfo are installed and `TERM` is passed through, so colours and keys behave as on the host.

- `linux-image/rootfs/` is a snapshot of the host's `/usr/share/omarchy/default/bash` and `~/.config/{starship.toml,nvim,lazygit,btop}`, taken by `linux-image/sync-host-config.sh`. `./work.sh linux rebuild` re-takes it and rebuilds.
- On startup the configs are seeded into the home directory, but only the items that are missing. Anything you edit or delete stays that way. Delete an item to get the fresh copy.
- The git config ships without host identity or signing. Set your work identity once with `git config --global user.name/user.email`.
- Tools in `~/.local/bin`, `~/.opencode/bin`, `~/.pi/agent/bin`, `~/.bun/bin`, and `~/.cargo/bin` are on `PATH`.

## Requirements

- Docker and Docker Compose
- KVM (`/dev/kvm`)
- `xfreerdp3` (package: `freerdp`) for RDP
- `jq` for Hyprland scale detection

## Notes

- The VPN gateway IP is not discoverable via DNS. The portal hostname resolves to a different gateway via MEP (Multiple Entry Point), which snx-rs does not support. Get the correct gateway IP from your IT admin or Check Point client logs.
- `ignore-server-cert = true` is required because we connect by IP, which causes a TLS hostname mismatch.
- `snx-rs.conf` is read from the host at connect time and handed to the container with the credentials in a root-only file, so edits apply on the next `connect`.
- `VM_NET_DEV: "eth0"` must be set so dockurr uses the right interface. Otherwise it picks up `snx-tun` and fails.
- A macOS VM (via dockurr/macos) was part of this setup before. It was removed: the install is too cumbersome (manual steps, Apple ID) and QEMU performance was too slow for daily work.
</content>
</invoke>
