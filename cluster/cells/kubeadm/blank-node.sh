#!/usr/bin/env bash
# Runs INSIDE a recorded disposable kind node.  The host-side caller verifies
# the immutable container ID and ownership before feeding this script to it.
set -euo pipefail

run_id="${1:-}"
qid="${2:-}"
role="${3:-}"
load_balancer_host="${4:-}"
load_balancer_ip="${5:-}"
ownership=/opt/cka-cell/ownership

[[ "$run_id" =~ ^[0-9a-f]{32}$ ]]
[[ "$qid" =~ ^(st|wl|sn|ca|ts)-[0-9]{2}$ ]]
[[ "$role" =~ ^(cp[123]|worker[123])$ ]]
if [ -n "$load_balancer_host" ] || [ -n "$load_balancer_ip" ]; then
  [ -n "$load_balancer_host" ] && [ -n "$load_balancer_ip" ]
  [ "$qid" = ca-11 ]
  [[ "$role" =~ ^cp[23]$ ]]
  [[ "$load_balancer_host" =~ ^cka-cell-ca-11-[0-9a-f]{12}-external-load-balancer$ ]]
  IFS=. read -r ip1 ip2 ip3 ip4 ip_extra <<< "$load_balancer_ip"
  [ -z "${ip_extra:-}" ]
  for octet in "$ip1" "$ip2" "$ip3" "$ip4"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] && [ "$octet" -le 255 ]
  done
fi
[ -f "$ownership" ] && [ ! -L "$ownership" ]
[ "$(sed -n '1p' "$ownership")" = "$run_id" ]
[ "$(sed -n '2p' "$ownership")" = "$qid" ]
[ "$(sed -n '3p' "$ownership")" = "$role" ]
[ -d /kind ] && [ -x /usr/bin/kubeadm ]

# kubeadm reset is explicitly best-effort.  Kubernetes documents that it does
# not clean CNI configuration or kube-proxy's network rules, so this disposable
# node scrub performs those bounded, explicit follow-up operations.
# https://v1-35.docs.kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-reset/
timeout --foreground 150s kubeadm reset --force --cleanup-tmp-dir
systemctl stop kubelet

for path in \
  /etc/kubernetes \
  /var/lib/etcd \
  /var/lib/kubelet \
  /etc/cni/net.d \
  /var/lib/cni; do
  case "$path" in
    /etc/kubernetes|/var/lib/etcd|/var/lib/kubelet|/etc/cni/net.d|/var/lib/cni) ;;
    *) exit 1 ;;
  esac
  [ ! -L "$path" ] || exit 1
  if [ -d "$path" ]; then
    find "$path" -xdev -mindepth 1 -delete
  fi
done

for table in filter nat mangle; do
  iptables -t "$table" -F || true
  iptables -t "$table" -X || true
done
if command -v ip6tables >/dev/null 2>&1; then
  for table in filter nat mangle; do
    ip6tables -t "$table" -F || true
    ip6tables -t "$table" -X || true
  done
fi
command -v ipvsadm >/dev/null 2>&1 && ipvsadm --clear || true
for link in cni0 flannel.1 tunl0 vxlan.calico; do
  ip link show "$link" >/dev/null 2>&1 && ip link delete "$link" || true
done

# Flushing the disposable node's NAT table also removes Docker's embedded DNS
# redirect.  Preserve only the HA load-balancer name that kubeadm generated;
# all other node state stays blank.  The trusted caller obtained this address
# from the run-owned Docker network before the scrub.
if [ -n "$load_balancer_host" ]; then
  [ -f /etc/hosts ] && [ ! -L /etc/hosts ]
  printf '%s\t%s\n' "$load_balancer_ip" "$load_balancer_host" >> /etc/hosts
  [ "$(getent ahostsv4 "$load_balancer_host" | awk 'NR == 1 {print $1}')" = "$load_balancer_ip" ]
fi

if [ -d /root/.kube ]; then
  [ ! -L /root/.kube ] || exit 1
  rm -f -- /root/.kube/config
fi

mkdir -p /etc/kubernetes /var/lib/kubelet /etc/cni/net.d /var/lib/cni
chmod 0700 /etc/kubernetes /var/lib/kubelet

# Docker Desktop/WSL can expose the host swap device inside privileged KIND
# nodes. Disabling that device here would affect the whole WSL VM, so scope the
# exception to this disposable kubelet. kubeadm's systemd drop-in reads
# KUBELET_EXTRA_ARGS from /etc/default/kubelet.
install -d -m 0755 /etc/default
printf '%s\n' 'KUBELET_EXTRA_ARGS=--fail-swap-on=false' > /etc/default/kubelet
chmod 0600 /etc/default/kubelet

! test -e /etc/kubernetes/admin.conf
! test -e /etc/kubernetes/kubelet.conf
! find /etc/kubernetes/manifests -mindepth 1 -print -quit 2>/dev/null | grep -q .
! test -e /var/lib/etcd/member
! test -e /var/lib/kubelet/kubeadm-flags.env
! find /etc/cni/net.d -mindepth 1 -print -quit | grep -q .
[ "$(systemctl is-active kubelet 2>/dev/null || true)" != active ]
