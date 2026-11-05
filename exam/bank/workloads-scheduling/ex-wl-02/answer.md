# ex-wl-02 정답지 — Combine ConfigMap and Secret keys in one volume

## 모범 답안

```bash
kubectl -n inference edit deploy predictor
```

```yaml
spec:
  template:
    spec:
      volumes:
        - name: bundle
          projected:
            defaultMode: 0440          # YAML 8진수. JSON으로 쓰면 288
            sources:
              - configMap:
                  name: model-config
                  items:
                    - {key: model.yaml, path: config/model.yaml}
              - secret:
                  name: model-registry
                  items:
                    - {key: token, path: auth/token}
      containers:
        - name: server
          volumeMounts:
            - {name: bundle, mountPath: /etc/predictor, readOnly: true}
```

```bash
kubectl -n inference rollout status deploy/predictor
kubectl -n inference exec deploy/predictor -- ls -R /etc/predictor
kubectl -n inference exec deploy/predictor -- stat -L -c %a /etc/predictor/auth/token   # 440
```

다른 정답: `defaultMode` 대신 각 item에 `mode: 0440`을 쓴다.

## 해설

- **projected volume**은 여러 source(ConfigMap, Secret, downwardAPI, serviceAccountToken)를
  한 디렉터리에 모은다. volume 두 개를 같은 경로에 mount할 수는 없다.
- **items**를 쓰면 적은 key만 파일이 된다. items가 없으면 모든 key가 파일이 된다.
- **파일 mode**: item의 `mode`가 있으면 그것을, 없으면 `defaultMode`(기본 0644)를 쓴다.
  파일은 `..data` 아래 실제 파일로 가는 symlink이므로 `stat -L`로 확인한다.
- YAML에서 `0440`은 8진수로 읽힌다. `kubectl get -o yaml`에는 10진수 `288`로 보인다.

공식 문서:
[Projected Volumes](https://kubernetes.io/docs/concepts/storage/projected-volumes/) ·
[Configure a Pod to Use a Projected Volume for Storage](https://kubernetes.io/docs/tasks/configure-pod-container/configure-projected-volume-storage/)

## 채점 기준 (7점)

| 배점 | 검증 항목 |
|---|---|
| 2 | volume `bundle`이 두 key만 지정 경로로 projection |
| 1 | 두 파일의 실제 mode가 0440 (item mode 또는 defaultMode) |
| 1 | container `server`의 `/etc/predictor`에 read-only mount |
| 1 | 1개 replica Ready |
| 2 | 실행 중인 container에서 두 파일만 보이고 내용·mode 440 확인 |
