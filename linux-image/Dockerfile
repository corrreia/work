FROM archlinux:base

# The Omarchy terminal toolset, plus what LazyVim needs to build parsers and
# install language servers, plus network tools for poking at the VPN.
RUN pacman -Syu --noconfirm --needed \
      openssh sudo bash-completion less which procps-ng \
      starship eza fzf zoxide bat ripgrep fd jq tmux btop fastfetch \
      neovim tree-sitter-cli gcc make unzip curl wget \
      git git-delta lazygit github-cli \
      mise nodejs npm python \
      bind iputils \
      ghostty-terminfo kitty-terminfo \
    && pacman -Scc --noconfirm

# Agent tooling: herdr (workspace manager) and pi (pi.dev coding agent), from
# the same aqua sources Omarchy's mise config uses on the host, checksum-checked.
# Installed system-wide, not in the home, which is a bind mount that hides
# anything the image puts there. Latest at build time; rebuild to update.
ENV WORK_TOOLS_DIR=/opt/work-tools
RUN MISE_DATA_DIR="$WORK_TOOLS_DIR" MISE_CACHE_DIR=/tmp/mise-cache \
      mise install aqua:herdrdev/herdr@latest aqua:earendil-works/pi@latest \
    && for bin in herdr pi; do \
         path="$(find "$WORK_TOOLS_DIR/installs" -type f -name "$bin" -perm -u+x | head -n1)"; \
         [ -n "$path" ] || { echo "mise installed no $bin binary" >&2; exit 1; }; \
         ln -sf "$path" "/usr/local/bin/$bin"; \
       done \
    && chmod -R a+rX "$WORK_TOOLS_DIR" \
    && rm -rf /tmp/mise-cache \
    && herdr --version && pi --version

# Snapshot of the host's Omarchy shell defaults and terminal configs
# (refresh with linux-image/sync-host-config.sh), plus container shims.
COPY linux-image/rootfs/ /
COPY linux-image/entrypoint.sh /usr/local/bin/work-linux-entrypoint

RUN chmod +x /usr/local/bin/work-linux-entrypoint \
    && chmod -R a+rX /usr/share/work-linux /usr/share/omarchy \
    && ssh-keygen -A

# C.UTF-8 ships with glibc, so icons and prompt glyphs render without locale-gen.
# SHELL is set because docker exec leaves it empty, and herdr then spawns
# panes with /bin/sh instead of bash. EDITOR is preset so Omarchy's envs
# keeps it instead of its desktop launcher.
ENV LANG=C.UTF-8 \
    SHELL=/bin/bash \
    EDITOR=nvim \
    SUDO_EDITOR=nvim

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/work-linux-entrypoint"]
