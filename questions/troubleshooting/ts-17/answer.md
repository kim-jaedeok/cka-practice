# ts-17 정답지 — hostNetwork Pod is Pending because of a host port conflict

## 진단 과정

```bash
kubectl -n node-agents get pods -o wide
#   metrics-exporter   0/1   Pending

kubectl -n node-agents describe pod metrics-exporter
#   0/3 nodes are available: 1 node(s) didn't have free ports for the requested pod ports, ...

kubectl -n node-agents get pod legacy-agent \
  -o jsonpath='{.spec.hostNetwork} {.spec.containers[0].ports}'
#   true [{"containerPort":9180,"hostPort":9180,"protocol":"TCP"}]
```

`legacy-agent`와 `metrics-exporter`는 둘 다 `cka-worker`에서 `hostNetwork: true`로 port
9180을 쓰려고 한다. scheduler는 같은 node에서 host port가 겹치는 Pod를 배치하지 않는다.

## 모범 답안

Pod spec의 container port와 command는 실행 중에 바꿀 수 없다. 그래서 Pod를 다시 만든다.

```bash
kubectl -n node-agents get pod metrics-exporter -o yaml > exporter.yaml
# exporter.yaml 수정:
#   command 안의 httpd -p 9180  → -p 9181
#   ports[0].containerPort 9180 → 9181
#   readinessProbe.tcpSocket.port 9180 → 9181
#   status, metadata.uid 등 서버가 채운 필드는 지운다
kubectl replace --force -f exporter.yaml
kubectl -n node-agents wait --for=condition=Ready pod/metrics-exporter

# 확인: node IP에서 두 port가 각각 응답한다
NODE_IP=$(kubectl get node cka-worker -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
kubectl run tmp --image=busybox:1.36 --rm -it --restart=Never -- \
  sh -c "wget -qO- http://$NODE_IP:9181; wget -qO- http://$NODE_IP:9180"
```

containerPort만 9181로 바꾸고 프로세스가 여전히 9180을 쓰면, Pod는 배치되지만 port 9180이
이미 사용 중이라 시작하지 못한다.

## 해설 (한국어)

- **`hostNetwork: true`** Pod는 별도 network namespace 없이 node의 network namespace를 쓴다.
  그래서 container가 연 port는 곧 node의 port다.
- `hostNetwork: true`일 때 container port는 같은 번호의 host port로 취급된다. 공식 Pod API는
  hostNetwork Pod의 `hostPort`가 `containerPort`와 같아야 한다고 설명한다. 그래서 같은 node에
  같은 port를 쓰는 hostNetwork Pod를 두 개 둘 수 없다.
- **GPU 인프라와의 관계**: node 단위 agent(모니터링 exporter, device 관련 daemon 등)는
  hostNetwork나 hostPort로 node의 port를 직접 여는 경우가 있다. 이때 port 충돌은 Pod가
  Pending으로 멈추는 흔한 원인이다.

공식 문서:
[Pod API: hostNetwork, ports](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/) ·
[Kubernetes Scheduler](https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/)

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 1 | `legacy-agent`가 원래 Pod이고 Ready | setup 때 저장한 UID 비교 |
| 2 | `metrics-exporter`가 `cka-worker`에서 hostNetwork로 Ready | Pod spec·status |
| 1 | `metrics-exporter`가 containerPort 9181을 선언 | Pod spec |
| 2 | node IP의 9181은 exporter, 9180은 legacy를 응답 | 상주 채점 Pod의 wget |
