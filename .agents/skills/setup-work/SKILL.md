---
name: setup-work
description: Use when setting up this corporate work environment on a new machine for the first time, or when ./work.sh up, connect, or a guest fails to start. Walks the setup commands and troubleshoots from the real logs.
---

# Setup work environment

This repo configures everything through `./work.sh`. Your job is to run its setup
commands and help diagnose failures from real output. Do not reimplement the steps.

First read `AGENTS.md` for the invariants. Then:

1. `./work.sh doctor` and fix every required check it reports before going on.
2. If `.env` is missing, `./work.sh setup`. It asks the user for the fields; the VPN
   gateway IP and corporate DNS come from their IT admin.
3. `./work.sh up`, then `./work.sh connect` (the user types the 2FA code, not you).

## Troubleshooting

- **Build fails on `COPY linux-image/rootfs/`**: `rootfs/` was not committed to the repo.
  It must come from whoever shared the repo; it cannot be regenerated without their host.
- **VPN will not connect**: `./work.sh logs vpn`. Check the gateway IP and that
  `VPN_PASSWORD` in `.env` is current (it rotates ~45d).
- **A guest cannot reach internal hosts**: `./work.sh test <internal-host>`. If GitHub
  specifically is blocked, its ranges are missing from `VPN_EXTRA_ROUTES` in `.env`.
- **Windows shared-folder shortcut is dead**: add the `host.lan` hosts entry from the
  README's post-install section inside the VM.

Never edit `.env`, `snx-rs.conf`, or the pinned snx-rs digest to force a connection
without understanding why; see the invariants in `AGENTS.md`.
