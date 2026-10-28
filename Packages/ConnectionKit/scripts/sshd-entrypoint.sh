#!/bin/bash
# Test-only OpenSSH servers, three auth policies on three ports:
#   2222  publickey or password
#   2223  AuthenticationMethods publickey,password (both on one connection)
#   2224  keyboard-interactive only (PAM)
#   2226  root by public key only (the account cpuser has no login shell)
# PUBLIC_KEY: authorized_keys content for users dockyard and root.
set -e
printf '%s\n' "$PUBLIC_KEY" > /etc/ssh/authorized_keys/dockyard
chmod 644 /etc/ssh/authorized_keys/dockyard
printf '%s\n' "$PUBLIC_KEY" > /etc/ssh/authorized_keys/root
chmod 644 /etc/ssh/authorized_keys/root

common='UsePAM yes
PermitRootLogin no
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
AuthorizedKeysFile /etc/ssh/authorized_keys/%u
Subsystem sftp /usr/lib/openssh/sftp-server
LogLevel VERBOSE'

cat > /etc/ssh/sshd_2222.conf <<EOF
Port 2222
PasswordAuthentication yes
KbdInteractiveAuthentication no
$common
EOF
cat > /etc/ssh/sshd_2223.conf <<EOF
Port 2223
AuthenticationMethods publickey,password
PasswordAuthentication yes
KbdInteractiveAuthentication no
$common
EOF
cat > /etc/ssh/sshd_2224.conf <<EOF
Port 2224
PasswordAuthentication no
PubkeyAuthentication no
KbdInteractiveAuthentication yes
AuthenticationMethods keyboard-interactive
$common
EOF

# The first PermitRootLogin wins, so this overrides the one in $common.
cat > /etc/ssh/sshd_2226.conf <<EOF
Port 2226
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
$common
EOF

for port in 2222 2223 2224 2226; do /usr/sbin/sshd -f /etc/ssh/sshd_$port.conf -E /var/log/sshd_$port.log; done
exec tail -F /var/log/sshd_2222.log
