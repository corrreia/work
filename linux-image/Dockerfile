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
