# ex-st-02 정답지 — Give each Pod its own provisioned scratch volume

## 모범 답안

```bash
kubectl -n render-farm edit deploy renderer
```

```yaml
      volumes:
        - name: scratch
          ephemeral:
            volumeClaimTemplate:
              spec:
                storageClassName: standard
                accessModes: ["ReadWriteOnce"]
                resources:
                  requests:
                    storage: 256Mi
```

```bash
kubectl -n render-farm rollout status deploy/renderer
kubectl -n render-farm get pvc
#   renderer-xxxxx-aaaaa-scratch   Bound   ...   standard
#   renderer-xxxxx-bbbbb-scratch   Bound   ...   standard
kubectl -n render-farm get pvc -o jsonpath='{.items[0].metadata.ownerReferences[0].kind}'   # Pod
```

## 해설

- **generic ephemeral volume**: Pod spec 안의 `ephemeral.volumeClaimTemplate`으로
  control plane이 Pod마다 PVC를 만든다. 이름은 `<Pod 이름>-<volume 이름>`이다.
- **수명**: PVC의 owner가 Pod이므로 Pod가 지워지면 garbage collector가 PVC를 지운다.
  StorageClass의 reclaim policy가 `Delete`면 PV도 지워진다.
- **StatefulSet `volumeClaimTemplates`와의 차이**: StatefulSet의 PVC는 Pod가 지워져도
  남아 같은 이름의 새 Pod가 다시 쓴다. 이 문제는 Pod와 함께 사라지는 임시 공간이므로
  generic ephemeral volume이 맞다.
- `standard`는 `WaitForFirstConsumer`이므로 Pod가 node에 배치된 뒤 volume이 생긴다.

공식 문서:
[Ephemeral Volumes — Generic ephemeral volumes](https://kubernetes.io/docs/concepts/storage/ephemeral-volumes/#generic-ephemeral-volumes) ·
[Storage Classes — Volume binding mode](https://kubernetes.io/docs/concepts/storage/storage-classes/#volume-binding-mode)

## 채점 기준 (6점)

| 배점 | 검증 항목 |
|---|---|
| 2 | `scratch`가 generic ephemeral volume이고 `worker`의 `/scratch`에 mount |
| 1 | claim template: `standard`, RWO, 256Mi |
| 1 | 2개 replica Ready로 rollout 완료 |
| 2 | Ready Pod마다 owner가 그 Pod인 Bound PVC `<pod>-scratch`, 다른 PVC 없음 |
