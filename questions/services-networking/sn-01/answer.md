# sn-01 정답지 — Expose a Deployment with a ClusterIP Service

## 모범 답안

```bash
kubectl -n world expose deployment europe --name=europe-svc --port=80 --target-port=80
```

또는 YAML로:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: europe-svc
  namespace: world
spec:
  type: ClusterIP          # 생략 시 기본값
  selector:
    app: europe            # Deployment의 pod 라벨과 일치해야 함
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
```

확인:

```bash
kubectl -n world get svc europe-svc
kubectl -n world get endpointslices          # 엔드포인트에 Pod IP 2개
kubectl -n world run tmp --image=busybox:1.36 --rm -it --restart=Never \
  -- wget -qO- http://europe-svc.world.svc.cluster.local
```

## 해설 (한국어)

- `kubectl expose`는 대상 리소스의 **selector를 자동으로 복사**해 주므로 가장 빠르고
  실수가 적다. YAML로 직접 만들 때 가장 흔한 실수가 selector와 pod 라벨 불일치다.
- Service DNS 이름 규칙: `<svc>.<namespace>.svc.cluster.local`.
  같은 네임스페이스에서는 `<svc>`만으로 접근 가능.
- **엔드포인트 확인 습관**: `kubectl get endpointslices -n world` 에서 READY 주소가
  비어 있으면 selector 불일치 또는 Pod not-ready다. Service 문제 디버깅의 출발점.
- `port`는 Service가 노출하는 포트, `targetPort`는 컨테이너 포트다.

## 채점 기준 (5점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | Service 타입/포트 스펙 | jsonpath 비교 |
| 1 | 엔드포인트 존재 | EndpointSlice 조회 |
| 2 | 클러스터 내부 HTTP 실측 | 상주 채점 Pod에서 wget |
