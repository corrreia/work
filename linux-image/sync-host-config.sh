#!/bin/bash
# Snapshot this host's Omarchy terminal setup into the work-linux image.
# Re-run after changing your host config, then: ./work.sh linux rebuild
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
rootfs="$here/rootfs"
skel="$rootfs/usr/share/work-linux/home"
omarchy_path="${OMARCHY_PATH:-/usr/share/omarchy}"

[ -d "$omarchy_path/default/bash" ] || { echo "No Omarchy install found at $omarchy_path" >&2; exit 1; }

# Omarchy's bash rc chain: envs, aliases, functions, prompt/zoxide/fzf init, inputrc
rm -rf "$rootfs/usr/share/omarchy/default/bash"
mkdir -p "$rootfs/usr/share/omarchy/default"
cp -rL "$omarchy_path/default/bash" "$rootfs/usr/share/omarchy/default/bash"

# User-level terminal configs. -L resolves the nvim theme symlink, which points
# at the current Omarchy theme and would dangle inside the container.
mkdir -p "$skel/.config"
cp -L ~/.config/starship.toml "$skel/.config/starship.toml"
for dir in nvim lazygit btop; do
  rm -rf "${skel:?}/.config/$dir"
  [ -d ~/.config/"$dir" ] && cp -rL ~/.config/"$dir" "$skel/.config/$dir"
done
rm -rf "$skel/.config/nvim/.git"

# git config is maintained in the repo instead: the host one carries personal
# identity, 1Password signing and gh credential helpers that don't belong here.
echo "Synced Omarchy terminal config into $rootfs"
