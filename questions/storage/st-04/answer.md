# st-04 정답지 — Mount volumes into an existing Deployment

## 모범 답안

```bash
kubectl -n project-delta edit deploy web-store
```

`spec.template.spec`에 volumes와 volumeMounts를 추가한다:

```yaml
spec:
  template:
    spec:
      containers:
        - name: nginx
          image: nginx:1.29
          volumeMounts:                      # 추가
            - name: store-data
              mountPath: /var/www/data
            - name: tmp-cache
              mountPath: /tmp/cache
      volumes:                               # 추가
        - name: store-data
          persistentVolumeClaim:
            claimName: store-data
        - name: tmp-cache
          emptyDir: {}
```

롤아웃 확인:

```bash
kubectl -n project-delta rollout status deploy/web-store
```

## 해설 (한국어)

- 볼륨 연결은 항상 **2단계**다: (1) `spec.template.spec.volumes`에 볼륨 정의,
  (2) 컨테이너의 `volumeMounts`에서 볼륨 **이름으로** 참조. 한쪽만 쓰면 검증 에러가 난다.
- `emptyDir`는 Pod와 수명을 같이하는 임시 디렉토리로, 노드 로컬 디스크를 쓴다.
  `emptyDir: {}` 처럼 빈 오브젝트로 선언하는 문법에 익숙해질 것.
- Deployment의 pod template을 수정하면 자동으로 **롤링 업데이트**가 발생한다.
  기존 Pod가 종료되고 새 Pod가 뜰 때까지 `rollout status`로 확인하는 습관이 중요하다.
- RWO PVC를 쓰는 Deployment는 replicas를 늘리면 서로 다른 노드에 스케줄될 때
  마운트에 실패할 수 있다 — 이 문제에서 replicas가 1인 이유다.

## 채점 기준 (5점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | PVC 볼륨 + `/var/www/data` 마운트 | jsonpath (claimName, mountPath) |
| 2 | emptyDir `tmp-cache` + `/tmp/cache` 마운트 | jsonpath (volume 정의, mountPath) |
| 1 | 롤아웃 성공 (1/1 Ready) | `.status.readyReplicas` |
