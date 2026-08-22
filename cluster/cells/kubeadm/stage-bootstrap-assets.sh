#!/usr/bin/env bash
# Runs inside the recorded ca-12 control-plane container. It turns the
# digest-pinned KIND image's internal template into candidate-visible,
# offline kubeadm/CNI inputs without changing the host or shared cluster.
set -euo pipefail

run_id="${1:-}"
qid="${2:-}"
ownership=/opt/cka-cell/ownership

[[ "$run_id" =~ ^[0-9a-f]{32}$ ]]
[ "$qid" = ca-12 ]
[ -f "$ownership" ] && [ ! -L "$ownership" ]
[ "$(sed -n '1p' "$ownership")" = "$run_id" ]
[ "$(sed -n '2p' "$ownership")" = "$qid" ]
[ "$(sed -n '3p' "$ownership")" = cp1 ]

cp_ip="$(hostname -I | awk '{print $1}')"
[[ "$cp_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]

src=/kind/manifests/default-cni.yaml
cni_tmp=/opt/cka/.kindnet.yaml.tmp
cni_dst=/opt/cka/kindnet.yaml
init_tmp=/opt/cka/.kubeadm-init.yaml.tmp
init_dst=/opt/cka/kubeadm-init.yaml
trap 'rm -f -- "$cni_tmp" "$init_tmp"' EXIT

[ -f "$src" ] && [ ! -L "$src" ]
sed 's/{{ \.PodSubnet }}/"10.244.0.0\/16"/g' "$src" \
  | awk -v endpoint="${cp_ip}:6443" '
      { print }
      $0 == "          value: \"10.244.0.0/16\"" {
        print "        - name: CONTROL_PLANE_ENDPOINT"
        print "          value: \"" endpoint "\""
      }
    ' > "$cni_tmp"
grep -Fq 'value: "10.244.0.0/16"' "$cni_tmp"
[ "$(grep -Fc 'name: CONTROL_PLANE_ENDPOINT' "$cni_tmp")" -eq 1 ]
grep -Fq "value: \"${cp_ip}:6443\"" "$cni_tmp"
! grep -Fq '{{' "$cni_tmp"

cat > "$init_tmp" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${cp_ip}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.35.0
apiServer:
  certSANs:
    - 127.0.0.1
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/16
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
cgroupRoot: /kubelet
failSwapOn: false
evictionHard:
  imagefs.available: "0%"
  nodefs.available: "0%"
  nodefs.inodesFree: "0%"
imageGCHighThresholdPercent: 100
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
conntrack:
  maxPerCore: 0
iptables:
  minSyncPeriod: 1s
mode: iptables
EOF

kubeadm config validate --config "$init_tmp"
install -m 0444 "$cni_tmp" "$cni_dst"
install -m 0444 "$init_tmp" "$init_dst"
