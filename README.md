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

1. Copy `.env.example` to `.env` and fill in your credentials:

```bash
cp .env.example .env
```

You need: `USERNAME`, `PASSWORD` (Windows VM login), `VPN_SERVER` (gateway IP), and `VPN_PASSWORD`.

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
./work.sh linux ssh
```

## Commands

```
VPN:
  ./work.sh connect [--debug]   Connect VPN (prompts for 2FA)
  ./work.sh disconnect          Disconnect VPN
  ./work.sh reconnect [--debug] Disconnect + reconnect

Environment:
  ./work.sh up                  Start all containers
  ./work.sh down                Stop all containers
  ./work.sh status              Show VPN + VM status
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
  ./work.sh linux ssh           Open SSH session
  ./work.sh linux logs          Tail container logs
```

## How it works

- **VPN**: [snx-rs](https://github.com/ancwrd1/snx-rs) runs inside a Docker container in SSL tunnel mode. IPSec doesn't work with this server due to SCV/compliance checks.
- **Windows VM**: [dockurr/windows](https://github.com/dockur/windows) runs a Windows 11 QEMU VM sharing the VPN container's network namespace.
- **Linux**: a small Arch Linux container exposes SSH on port 2222, shares the VPN container's network namespace, and switches its resolver to corporate DNS when the VPN is connected.
- **Split tunnel**: Server pushes full-tunnel routes, but `no-routing = true` ignores them. Only private subnets are routed through the VPN via `add-routes`. Internet goes direct.
- **NAT**: iptables masquerade on both `snx-tun` (corporate) and `eth0` (internet). Linux DNS is pointed directly at corporate DNS while the VPN is up, so internal lookups behave consistently.
- **RDP**: `xfreerdp3` with dynamic resolution, AVC444 graphics, clipboard, sound/mic, and Hyprland scale detection.
- **Shared folder**: `./shared/` is mounted into Windows and Linux, so it acts as a common exchange folder across all guests.

## Guest shared folder access

Windows exposes the shared folder over Samba at `\\172.30.0.1\Data`.

Linux sees the same files directly at `/shared` and also through `~/Shared`.

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
- `VM_NET_DEV: "eth0"` must be set so dockurr uses the right network interface (otherwise it picks up `snx-tun` and fails).
- macOS VM (via dockurr/macos) was previously part of this setup but was removed. The initial setup process is too cumbersome (manual installer steps, Apple ID, etc.) and QEMU performance for macOS is poor — unusably slow for daily work compared to the Windows VM.
