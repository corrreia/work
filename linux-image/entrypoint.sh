#!/bin/bash
set -e

username="${LINUX_USER:-${USERNAME:-work}}"
password="${LINUX_PASSWORD:-${PASSWORD:-work}}"
home_dir="/home/${username}"

if ! id -u "$username" >/dev/null 2>&1; then
  useradd -m -d "$home_dir" -s /bin/bash "$username"
fi

install -d -m 0755 -o "$username" -g "$username" "$home_dir"
echo "$username:$password" | chpasswd

ln -sfn /shared "$home_dir/Shared"
chown -h "$username:$username" "$home_dir/Shared"

# Seed the Omarchy shell and terminal configs into the (bind-mounted) home.
# Whole items only, and never over something already there, so local edits
# and deletions stick across restarts.
skel=/usr/share/work-linux/home
for item in "$skel"/.bashrc "$skel"/.bash_profile "$skel"/.config/*; do
  target="$home_dir/${item#"$skel"/}"
  [ -e "$target" ] || [ -L "$target" ] && continue
  runuser -u "$username" -- mkdir -p "$(dirname "$target")"
  runuser -u "$username" -- cp -r "$item" "$target"
done

printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$username" > "/etc/sudoers.d/${username}"
chmod 0440 "/etc/sudoers.d/${username}"

mkdir -p /run/sshd

# The host's CA files are mounted into p11-kit's anchors directory, the only
# place Arch reads trust anchors from (DER or PEM). Regenerate the bundles in
# /etc/ssl/certs so OpenSSL, curl and git see them too.
if find /etc/ca-certificates/trust-source/anchors -type f | grep -q .; then
  trust extract-compat
fi

cat > /etc/ssh/sshd_config.d/work.conf <<EOF
PasswordAuthentication yes
PermitRootLogin no
UsePAM yes
X11Forwarding no
PrintMotd no
EOF

exec /usr/bin/sshd -D -e
