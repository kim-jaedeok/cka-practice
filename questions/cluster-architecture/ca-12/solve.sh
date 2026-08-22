#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/cell.sh"

export CKA_CELL_DOCKER_TIMEOUT="${CKA_CELL_KUBEADM_DOCKER_TIMEOUT:-420}"

cell_activate ca-12 kubeadm-bootstrap

cell_exec ca-12 cp1 kubeadm config validate --config /opt/cka/kubeadm-init.yaml
cell_exec ca-12 cp1 kubeadm init --config /opt/cka/kubeadm-init.yaml
cell_exec ca-12 cp1 bash -c '
  set -eu
  install -d -m 0700 /root/.kube
  install -m 0600 /etc/kubernetes/admin.conf /root/.kube/config
  kubectl apply -f /opt/cka/kindnet.yaml
'

join_command="$(cell_exec ca-12 cp1 kubeadm token create --print-join-command)"
read -r -a join_args <<< "$join_command"
[ "${#join_args[@]}" -eq 7 ]
[ "${join_args[0]}" = kubeadm ]
[ "${join_args[1]}" = join ]
[[ "${join_args[2]}" =~ ^[A-Za-z0-9._:-]+$ ]]
[ "${join_args[3]}" = --token ]
[[ "${join_args[4]}" =~ ^[a-z0-9]{6}\.[a-z0-9]{16}$ ]]
[ "${join_args[5]}" = --discovery-token-ca-cert-hash ]
[[ "${join_args[6]}" =~ ^sha256:[0-9a-f]{64}$ ]]
cell_exec ca-12 worker1 "${join_args[@]}"
cell_exec ca-12 worker2 "${join_args[@]}"
cell_exec ca-12 cp1 kubectl wait --for=condition=Ready nodes --all --timeout=300s

cell_exec_stdin ca-12 cp1 kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: bootstrap-check
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bootstrap-web
  namespace: bootstrap-check
  labels:
    app: bootstrap-web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: bootstrap-web
  template:
    metadata:
      labels:
        app: bootstrap-web
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - topologyKey: kubernetes.io/hostname
              labelSelector:
                matchLabels:
                  app: bootstrap-web
      containers:
        - name: web
          image: nginx:1.29
          ports:
            - name: http
              containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: bootstrap-web
  namespace: bootstrap-check
  labels:
    app: bootstrap-web
spec:
  selector:
    app: bootstrap-web
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: v1
kind: Pod
metadata:
  name: network-client
  namespace: bootstrap-check
spec:
  containers:
    - name: client
      image: busybox:1.36
      command: ["sh", "-c", "sleep 86400"]
YAML
cell_exec ca-12 cp1 kubectl -n bootstrap-check rollout status deploy/bootstrap-web --timeout=180s
cell_exec ca-12 cp1 kubectl -n bootstrap-check wait --for=condition=Ready pod/network-client --timeout=180s
