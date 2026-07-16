# ts-12 정답지 — Control plane failure (Pods stay Pending)

## 진단 과정

```bash
# 1. Pending인데 이벤트가 없다? → 스케줄러 의심
kubectl -n sched-check describe pod <pod> | tail -5
#   Events: <none>       ← FailedScheduling 이벤트조차 없음 = 스케줄러가 아예 안 돎

# 2. control plane 컴포넌트 확인
kubectl -n kube-system get pods | grep -E "scheduler|apiserver|controller"
#   kube-scheduler-cka-control-plane   0/1   CrashLoopBackOff (또는 목록에 없음)

kubectl -n kube-system logs kube-scheduler-cka-control-plane 2>&1 | tail -3
# 또는 노드에서 컨테이너 로그 직접 확인

# 3. static pod 매니페스트 검사
docker exec -it cka-control-plane bash      # (실전: ssh)
cat /etc/kubernetes/manifests/kube-scheduler.yaml | head -20
#   command:
#     - kube-schedulerx        ← 오타!
```

## 모범 답안

```bash
# 노드 안에서 매니페스트 수정
vi /etc/kubernetes/manifests/kube-scheduler.yaml
#   - kube-schedulerx  →  - kube-scheduler
exit

# kubelet이 파일 변경을 감지해 static pod를 자동 재생성 (~20초)
kubectl -n kube-system get pods | grep scheduler    # Running 1/1
kubectl -n sched-check get pods                     # Running으로 전환
```

## 해설 (한국어)

- **"Pending + 이벤트 없음"은 스케줄러 장애의 시그니처다.** 리소스 부족이면
  FailedScheduling 이벤트가 남지만, 스케줄러 자체가 죽어 있으면 아무도 Pod를
  노드에 할당하지 않고 이벤트도 없다.
- control plane 컴포넌트(kube-apiserver, kube-scheduler, kube-controller-manager,
  etcd)는 **static Pod**로 실행된다(ca-10 참고). 문제가 생기면
  `/etc/kubernetes/manifests/`의 매니페스트를 직접 조사한다.
- static pod 매니페스트가 깨졌을 때 확인할 곳:
  (1) 매니페스트 YAML 문법/커맨드 오타, (2) kubelet 로그
  `journalctl -u kubelet | grep -i scheduler`, (3) 컨테이너 런타임
  `crictl ps -a | grep scheduler` + `crictl logs <id>`.
- 파일을 저장하면 kubelet이 자동으로 재시작한다 — kubectl로 mirror Pod를
  삭제해도 소용없다(다시 생김). **파일이 진실의 원천**이다.
- apiserver가 깨진 변형 문제에서는 kubectl 자체가 안 되므로 처음부터 노드의
  `crictl`/`journalctl`로 진단해야 한다.

## 채점 기준 (8점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | 매니페스트 오타 수정 | 노드 파일 grep |
| 3 | kube-scheduler Ready | mirror Pod 상태 |
| 3 | sched-test 2/2 Ready | `.status.readyReplicas` |
