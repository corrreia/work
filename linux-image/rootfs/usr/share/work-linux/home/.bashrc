# If not running interactively, don't do anything (leave this at the top of this file)
[[ $- != *i* ]] && return

# All the default Omarchy aliases and functions, snapshotted from the host
# (don't mess with these directly, just overwrite them here!)
export OMARCHY_PATH=/usr/share/omarchy
source "$OMARCHY_PATH/default/bash/rc"

# Per-user tool installs that live in this home directory
for dir in "$HOME/.opencode/bin" "$HOME/.pi/agent/bin" "$HOME/.bun/bin" "$HOME/.cargo/bin"; do
  [[ -d $dir && ":$PATH:" != *":$dir:"* ]] && PATH="$dir:$PATH"
done
export PATH

# Add your own exports, aliases, and functions here.
