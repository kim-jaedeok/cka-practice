#!/usr/bin/env bash
set -euo pipefail

install -d -o root -g root -m 0755 /run/sshd
ssh-keygen -A
/usr/sbin/sshd -t

exec /usr/sbin/sshd -D -e
