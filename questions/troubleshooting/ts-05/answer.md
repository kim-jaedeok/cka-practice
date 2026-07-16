# ts-05 정답지 — Node NotReady (kubelet down)

## 진단 과정

```bash
kubectl get nodes
#   cka-worker2   NotReady   <none>   ...

kubectl describe node cka-worker2 | grep -A5 Conditions
#   Ready  Unknown ... Kubelet stopped posting node status.

# 노드 접속 후 kubelet 상태 확인
docker exec -it cka-worker2 bash        # (실전: ssh cka-worker2)
systemctl status kubelet                #   inactive (dead)
journalctl -u kubelet | tail -20        #   이상 로그 없음 → 단순 정지
```

## 모범 답안

```bash
# 노드 안에서
systemctl start kubelet
systemctl enable kubelet     # 재부팅에도 살아나도록
systemctl status kubelet     # active (running)
exit

# 확인 (~30초 내)
kubectl get nodes            # cka-worker2   Ready
```

## 해설 (한국어)

- **NotReady 진단 루틴**: `describe node`의 Conditions에서
  "Kubelet stopped posting node status"가 보이면 kubelet 자체 문제다.
  노드 접속 → `systemctl status kubelet` → 죽어 있으면 start,
  기동 실패하면 `journalctl -u kubelet -f`로 원인(설정 오류, 인증서, swap 등)을 본다.
- kubelet이 기동 실패하는 흔한 원인들: `/var/lib/kubelet/config.yaml` 오타,
  `/etc/kubernetes/kubelet.conf`의 잘못된 API 서버 주소, CA 인증서 경로 오류.
  이 문제는 단순 정지 케이스이지만 실전에서는 이 파일들도 확인 대상이다.
- `enable`을 빼먹으면 "재부팅 후에도 동작해야 한다"는 요구사항을 놓친다 —
  killer.sh/실전 모두 enable 여부를 채점한다.
- 노드가 NotReady여도 그 노드의 Pod는 즉시 죽지 않는다 — 기본 5분(tolerationSeconds)
  후 축출이 시작된다.

## 채점 기준 (7점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | kubelet active | `systemctl is-active` |
| 1 | kubelet enabled | `systemctl is-enabled` |
| 4 | 노드 Ready | node condition |
