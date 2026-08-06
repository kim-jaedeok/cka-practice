# ca-04 정답지 — Restore an etcd snapshot (drill)

## 모범 답안

```bash
ssh cka-control-plane

etcdutl snapshot restore /var/lib/etcd/snapshot-restore-src.db \
  --data-dir /var/lib/etcd/restore-drill

# 구조 확인
ls -R /var/lib/etcd/restore-drill/member
```

## 대체 방식 (etcd Pod exec)

노드의 etcdutl이 유실됐다면 (`cka cluster doctor`로 복구 가능) etcd Pod 안에서
같은 명령을 실행해도 된다.

```bash
kubectl -n kube-system exec etcd-cka-control-plane -- etcdutl \
  snapshot restore /var/lib/etcd/snapshot-restore-src.db \
  --data-dir /var/lib/etcd/restore-drill
```

## 해설 (한국어)

- `etcdutl snapshot restore`는 **오프라인 파일 작업**이다 — 서버 연결이나 인증서가
  필요 없고, 스냅샷을 새 데이터 디렉토리 구조(member/snap, member/wal)로 풀어낸다.
  `--data-dir`가 이미 존재하고 비어있지 않으면 실패한다.
- **실전에서 전체 복원 절차** (이 드릴의 다음 단계, 시험에도 출제됨):
  1. `etcdutl snapshot restore <snap> --data-dir /var/lib/etcd-from-backup`
  2. `/etc/kubernetes/manifests/etcd.yaml`의 hostPath volume(`etcd-data`)을
     새 디렉토리(`/var/lib/etcd-from-backup`)로 수정
  3. static pod가 자동 재시작되며 복원된 데이터로 etcd가 뜬다
     (kube-apiserver도 잠시 재시작됨 — 1~2분 대기)
  4. `kubectl get nodes` 등으로 클러스터 상태 확인
- 이 문제는 running 클러스터를 유지해야 하므로 **2~4단계를 수행하면 안 된다** —
  요구사항의 금지 조건을 정확히 읽는 것도 채점 대상이다.
- 공식 문서 참조 경로: **Tasks → Administer a Cluster → Operating etcd clusters
  → Restoring an etcd cluster**.

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 3 | member/snap, member/wal 구조 생성 | 노드 파일시스템 확인 |
| 1 | member/snap/db 파일 존재 | 노드 파일시스템 확인 |
| 1 | 소스 스냅샷 보존 | 파일 존재 확인 |
| 1 | 클러스터 무중단 (etcd 정상) | etcd Pod Ready |
