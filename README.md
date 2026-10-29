# work

Corporate remote work environment running a Check Point SSL VPN, a Windows 11 VM, and a simple Arch Linux container in Docker. The Windows VM and Linux container share the VPN container's network namespace so their traffic goes through the corporate VPN tunnel.

Split-tunnel: only RFC 1918 private subnets route through the VPN. Internet traffic goes direct through your home connection.

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

## Setup

New to this? Run `./work.sh doctor` to check prerequisites, then `./work.sh setup` to
create your `.env` interactively. The steps below are the manual equivalent.

1. Copy `.env.example` to `.env` and fill in your credentials:

```bash
cp .env.example .env
```

You need `USERNAME`, `VM_PASSWORD`, `VPN_SERVER` (gateway IP), `VPN_PASSWORD` and `CORPORATE_DNS` (the internal DNS server both guests use while the VPN is up).

Optional: `VPN_EXTRA_ROUTES` sends extra public ranges through the tunnel, and `VPN_TEST_HOST` is an internal-only hostname that `./work.sh test` resolves and connects to from both guests. Nothing company-specific lives in the repo; it all goes in `.env`.

`VM_PASSWORD` and `VPN_PASSWORD` are deliberately separate. `VM_PASSWORD` is the local
login for the Windows VM and the Linux container — neither is domain-joined, so it never
rotates. `VPN_PASSWORD` is the corporate credential and rotates on your company's schedule
(~every 45 days); when it does, edit that one line in `.env` and reconnect. Nothing else
needs to change.

If you need internal root CAs inside the Linux container, drop `.crt`, `.cer`, or `.pem` files into `./certificates/` before starting it.

The same `./certificates/` directory is also prepared for Windows under the shared folder as `\\172.30.0.1\Data\certificates`.

2. Start everything:

```bash
./work.sh up
```

3. Connect VPN (prompts for 2FA code):

```bash
./work.sh connect
```

4. Open Windows VM:

```bash
./work.sh windows rdp    # RDP (full experience)
./work.sh windows web    # browser viewer (quick access)
```

5. Open Linux shell:

```bash
./work.sh linux shell
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
  ./work.sh windows rdp         Open RDP session (xfreerdp3)
  ./work.sh windows web         Open web viewer in browser
  ./work.sh windows logs        Tail container logs

Linux:
  ./work.sh linux start         Start the Arch container
  ./work.sh linux stop          Stop the Arch container
  ./work.sh linux restart       Stop + start
  ./work.sh linux shell         Open interactive shell (alias: ssh)
  ./work.sh linux rebuild       Re-snapshot host Omarchy config and rebuild the image
  ./work.sh linux logs          Tail container logs
```

## How it works

- **VPN**: [snx-rs](https://github.com/ancwrd1/snx-rs) runs inside a Docker container in SSL tunnel mode. IPSec doesn't work with this server due to SCV/compliance checks.
- **Windows VM**: [dockurr/windows](https://github.com/dockur/windows) runs a Windows 11 QEMU VM sharing the VPN container's network namespace.
- **Linux**: an Arch Linux container set up like an Omarchy terminal shares the VPN container's network namespace, opens a shell through `docker exec`, and switches its resolver to corporate DNS when the VPN is connected.
- **Split tunnel**: Server pushes full-tunnel routes, but `no-routing = true` ignores them. Only private subnets are routed through the VPN via `add-routes`. Internet goes direct.
- **Forwarding**: `allow-forwarding = true` is required. snx-rs otherwise disables forwarding on `snx-tun`, which drops every reply headed for the Windows VM (the Linux container is unaffected, since it shares the VPN network namespace).
- **Local subnets**: snx-rs looks up its own routing table (18000) before `main`, and the `172.16.0.0/12` route there covers the Docker network and the VM bridge (`172.30.0.0/24`). `work.sh` adds `ip rule`s that send those two back to `main`, so guests can be started before or after the VPN connects.
- **NAT**: iptables masquerade on both `snx-tun` (corporate) and `eth0` (internet). Windows DNS is redirected to corporate DNS while the tunnel is up and the redirect is removed when snx-rs exits. Linux DNS is pointed directly at corporate DNS while the VPN is up and switched back on `disconnect` or `status`.
- **RDP**: `xfreerdp3` with dynamic resolution, AVC444 graphics, clipboard, sound/mic, and Hyprland scale detection.
- **Shared folder**: `./shared/` is mounted into Windows and Linux, so it acts as a common exchange folder across all guests.
- **Internal certificates**: files placed in `./certificates/` are mounted into the Linux container and imported into the system trust store on startup.

## Linux terminal environment

The Linux image mirrors the Omarchy terminal: the same bash rc chain (aliases, `cd`→zoxide, fzf, inputrc), starship prompt, LazyVim, lazygit, btop, eza, bat, ripgrep, fd, mise, gh and tmux. Ghostty and Kitty terminfo are installed and `TERM` is passed through, so colours and keys behave as on the host.

- `linux-image/rootfs/` is a snapshot of the host's `/usr/share/omarchy/default/bash` and `~/.config/{starship.toml,nvim,lazygit,btop}`, taken by `linux-image/sync-host-config.sh`. `./work.sh linux rebuild` re-takes it and rebuilds.
- On startup the configs are seeded into the home directory, but only items that are missing. Anything you edit or delete there stays that way; delete an item to get the fresh copy.
- The git config is kept in the repo without host identity or signing. Set your work identity once with `git config --global user.name/user.email`.
- Tools installed into the home directory (`~/.local/bin`, `~/.opencode/bin`, `~/.pi/agent/bin`, `~/.bun/bin`, `~/.cargo/bin`) are on `PATH`.

## Guest shared folder access

Windows exposes the shared folder over Samba at `\\172.30.0.1\Data`.

Linux sees the same files directly at `/shared` and also through `~/Shared`.

If you need to import internal CAs in Windows, run this in an elevated PowerShell inside the VM:

```powershell
PowerShell -ExecutionPolicy Bypass -File \\172.30.0.1\Data\certificates\import-certs.ps1
```

## Post-install (one-time, inside Windows)

The shared folder desktop shortcut uses `host.lan` which corporate DNS can't resolve. Fix it by adding a hosts entry in an elevated PowerShell:

```powershell
Add-Content C:\Windows\System32\drivers\etc\hosts "172.30.0.1 host.lan"
```

The `Shared` shortcut on the desktop will then work. Alternatively, map it as a network drive:

```powershell
net use Z: \\172.30.0.1\Data /persistent:yes
```

## Requirements

- Docker + Docker Compose
- KVM (`/dev/kvm`)
- `xfreerdp3` (package: `freerdp`) for RDP
- `jq` for Hyprland scale detection

## Notes

- The VPN gateway IP is not discoverable via DNS. The portal hostname resolves to a different gateway via MEP (Multiple Entry Point), but snx-rs doesn't support MEP. You need the correct gateway IP from your IT admin or Check Point client logs.
- `ignore-server-cert = true` is required because we connect by IP, causing a TLS hostname mismatch.
- The snx-rs image is pinned by digest (6.2.4). Newer releases have changed routing and forwarding defaults before, so bump it deliberately and re-test both guests.
- `snx-rs.conf` is read from the host at connect time and handed to the container together with the credentials in a root-only file, so edits apply on the next `connect`.
- `VM_NET_DEV: "eth0"` must be set so dockurr uses the right network interface (otherwise it picks up `snx-tun` and fails).
- macOS VM (via dockurr/macos) was previously part of this setup but was removed. The initial setup process is too cumbersome (manual installer steps, Apple ID, etc.) and QEMU performance for macOS is poor — unusably slow for daily work compared to the Windows VM.
