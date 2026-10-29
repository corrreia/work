# AGENTS.md

Guide for any agent (or colleague) working in this repo. This is a corporate remote
work environment: a Check Point SSL VPN, a Windows 11 VM, and an Arch Linux container,
all in Docker. The guests share the VPN container's network namespace so their traffic
can go through the corporate tunnel. `README.md` is the human walkthrough; this file is
the short list of things the code does not make obvious.

## First setup

Run these, in order, from the repo root:

```bash
./work.sh doctor   # check prerequisites (Docker, KVM, /dev/net/tun, tools, repo integrity)
./work.sh setup    # create .env interactively; asks what comes from IT
./work.sh up       # build and start the containers
./work.sh connect  # bring up the VPN (prompts for 2FA)
```

Do not configure anything by hand that `doctor` or `setup` already cover. If a step
fails, fix the cause `doctor` names rather than working around it.

## Invariants (do not break these)

- **snx-rs is pinned by digest** in `docker-compose.yml`. Releases have changed routing
  and forwarding defaults before. Bump deliberately and re-test `connect` plus both
  guests (`./work.sh test <internal-host>`).
- **`allow-forwarding = true`** in `snx-rs.conf` is mandatory. Without it snx-rs disables
  forwarding on `snx-tun` and silently drops every reply headed for the Windows VM.
- **Split tunnel by route.** Only RFC 1918 ranges plus `VPN_EXTRA_ROUTES` go through the
  tunnel; everything else goes direct over the home connection. Corporate GitHub is
  IP-allowlisted to company egress addresses, so its ranges must be in `VPN_EXTRA_ROUTES`
  or git is blocked from both guests. This is not optional for anyone doing GitHub work.
- **`linux-image/rootfs/` must be committed.** The Dockerfile does `COPY linux-image/rootfs/ /`,
  so a clone without it fails the build. It is a generated snapshot (see below) but the
  snapshot itself is tracked.
- **Never commit secrets.** `.env`, `linux/`, `shared/*`, and `certificates/` are
  gitignored and stay that way. The VPN password lives only in `.env` (mode 0600).
- **`VM_PASSWORD` and `VPN_PASSWORD` are separate on purpose.** `VM_PASSWORD` is the local
  guest login and never rotates; `VPN_PASSWORD` is the corporate credential and rotates
  (~45d). On rotation, edit one line in `.env` and reconnect.

## Where things live

- `work.sh` is the single entry point (setup, doctor, VPN, both guests). Its helpers are
  `die/info/success/warn` and the color vars; match them.
- `snx-rs.conf` is the VPN tunnel config, read at `connect` time.
- `docker-compose.yml` defines the three services; the guests use `network_mode: service:vpn`.
- `linux-image/` builds the Arch container. `rootfs/` is a snapshot of the host's Omarchy
  terminal config, taken by `sync-host-config.sh`. These defaults are personal; a colleague
  can keep them or delete items in their home to get fresh copies.
- `linux/`, `windows/`, `shared/`, `certificates/` are runtime data, all gitignored.

## Verifying a change

- `./work.sh doctor` after any change to prerequisites or the build.
- `./work.sh connect` then `./work.sh test <internal-host>` after any routing, DNS, or
  `snx-rs.conf` change. "Inconclusive" is not a pass; confirm both guests reach the host.
- `bash -n work.sh` (and `shellcheck work.sh` if available) after editing the script.
