#!/bin/sh
# ForceCommand for the test user splitview: SFTP sees the real file system, shell commands run in a chroot
# (/srv/jail) that has a decoy /home/splitview/victim. Models a server whose shell and SFTP views differ.
case "$SSH_ORIGINAL_COMMAND" in
  */sftp-server*|sftp|internal-sftp) exec /usr/lib/openssh/sftp-server ;;
esac
exec sudo /usr/sbin/chroot --userspec=1003:1003 /srv/jail /bin/sh -c "$SSH_ORIGINAL_COMMAND"
