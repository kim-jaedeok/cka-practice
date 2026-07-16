# sn-02 정답지 — Expose an application via NodePort

## 모범 답안

`nodePort` 번호가 지정된 문제는 YAML로 작성하는 것이 안전하다
(`kubectl expose`는 nodePort 번호를 지정할 수 없음):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: asia-svc
  namespace: world
spec:
  type: NodePort
  selector:
    app: asia
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30080
      protocol: TCP
```

확인:

```bash
kubectl -n world get svc asia-svc
NODE_IP=$(kubectl get node cka-worker -o jsonpath='{.status.addresses[0].address}')
kubectl -n world run tmp --image=busybox:1.36 --rm -it --restart=Never \
  -- wget -qO- http://$NODE_IP:30080
```

## 해설 (한국어)

- **NodePort**는 모든 노드의 동일 포트(기본 범위 30000-32767)에서 서비스를 노출한다.
  Pod가 없는 노드로 들어온 요청도 kube-proxy가 올바른 Pod로 전달한다.
- 빠른 방법: `kubectl expose deployment asia --name=asia-svc --port=80 --type=NodePort`
  후 `kubectl edit`으로 nodePort를 30080으로 수정하는 2단계도 가능하다.
- NodePort 범위를 벗어난 번호를 지정하면 API 서버가 거부한다.
- 시험에서 "reachable on every node"라는 표현이 나오면 NodePort를 떠올릴 것.
  LoadBalancer는 클라우드 LB가 필요하므로 이 환경(kind)에서는 pending이 된다.

## 채점 기준 (5점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | NodePort 30080 / 포트 스펙 | jsonpath 비교 |
| 1 | 엔드포인트 존재 | EndpointSlice 조회 |
| 2 | 노드IP:30080 HTTP 실측 | 상주 채점 Pod에서 wget |
