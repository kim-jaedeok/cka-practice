# ca-06 정답지 — Prepare a worker node upgrade (kubeadm)

## 모범 답안

```bash
# 1. 노드 비우기
kubectl drain cka-worker2 --ignore-daemonsets --delete-emptydir-data

# 2. 업그레이드 명령 시퀀스 작성
mkdir -p ~/cka/ca-06
cat > ~/cka/ca-06/upgrade-commands.txt <<'EOF'
apt-get update
apt-mark unhold kubeadm
apt-get install -y kubeadm=1.36.1-1.1
apt-mark hold kubeadm
kubeadm upgrade node
apt-mark unhold kubelet kubectl
apt-get install -y kubelet=1.36.1-1.1 kubectl=1.36.1-1.1
apt-mark hold kubelet kubectl
systemctl daemon-reload
systemctl restart kubelet
kubectl uncordon cka-worker2
EOF
```

## 해설 (한국어) — 실전 워커 노드 업그레이드 전체 절차

실제 시험/운영에서는 다음 순서로 진행한다 (모든 노드 작업은 `ssh <node>` 후 root로):

1. **(운영머신) drain**: `kubectl drain <node> --ignore-daemonsets`
2. **(노드) kubeadm 업그레이드**: hold 해제 → 목표 버전 설치 → 다시 hold
   - 패키지를 hold하는 이유: 무의도 자동 업그레이드로 버전 skew가 생기는 것을 방지
3. **(노드) `kubeadm upgrade node`**: 워커 노드의 kubelet 설정을 새 버전에 맞게 갱신
   (control plane에서는 첫 노드만 `kubeadm upgrade apply v1.36.1`, 이후 노드는 `upgrade node`)
4. **(노드) kubelet/kubectl 업그레이드 후 재시작**: `systemctl daemon-reload && systemctl restart kubelet`
5. **(운영머신) uncordon**: `kubectl uncordon <node>` → `kubectl get nodes`로 새 버전 확인

**버전 규칙**: kubelet은 kube-apiserver보다 최대 3 minor 낮을 수 있지만, kubeadm은
업그레이드 대상 버전과 같아야 한다. 한 번에 1 minor씩만 업그레이드 가능.

이 연습 환경(kind)의 노드는 컨테이너라 apt가 없어 실제 패키지 업그레이드는
수행할 수 없다 — 그래서 drain 상태와 명령 시퀀스 파일만 채점한다.

- 공식 문서 참조 경로: **Tasks → Administer a Cluster → Upgrading kubeadm clusters**.

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 1 | cka-worker2 cordoned | jsonpath |
| 1 | drain 완료 | ownerReferences 검사 |
| 1 | kubeadm=1.36.1-1.1 설치 명령 | 파일 grep |
| 1 | kubeadm upgrade node | 파일 grep |
| 1 | kubelet 설치 + restart | 파일 grep |
| 1 | uncordon 포함 | 파일 grep |
