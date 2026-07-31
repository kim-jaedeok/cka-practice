# ca-03 정답지 — Create an etcd snapshot backup

## 모범 답안

```bash
# 1. 스냅샷 생성 (인증서 4종 플래그가 핵심)
kubectl -n kube-system exec etcd-cka-control-plane -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/snapshot-cka.db

# 2. 검증 출력 저장
mkdir -p ~/cka/ca-03
kubectl -n kube-system exec etcd-cka-control-plane -- etcdutl \
  snapshot status /var/lib/etcd/snapshot-cka.db -w table \
  > ~/cka/ca-03/status.txt
```

## 해설 (한국어)

- **실제 시험**에서는 control plane 노드에 `ssh <node>`로 접속해 노드에 설치된
  etcdctl을 직접 실행한다. 이 연습 환경도 `ssh cka-control-plane` 접속은 되지만
  kind 노드 이미지에 etcdctl 바이너리가 없어 etcd Pod 안에서 실행한다 —
  **명령과 플래그는 완전히 동일**하다.
- 인증서 경로는 외우기보다 **찾는 법**을 익힌다:
  `cat /etc/kubernetes/manifests/etcd.yaml | grep -E "cert|key|listen-client"` —
  etcd static pod 매니페스트에 모든 플래그가 적혀 있다.
- 스냅샷 저장은 `etcdctl snapshot save`(서버 연결 필요 → 인증서 필수),
  상태 확인·복원은 **`etcdutl`**(로컬 파일 작업 → 인증서 불필요)로 분리된 것이
  etcd 3.5+의 표준이다. `etcdctl snapshot status`는 deprecated.
- ETCDCTL_API=3 환경변수는 etcd 3.4+에서 기본값이므로 생략 가능하다.
- 공식 문서 참조 경로: **Tasks → Administer a Cluster → Operating etcd clusters
  → Backing up an etcd cluster**.

## 채점 기준 (7점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | 스냅샷 파일 존재(비어있지 않음) | 노드 파일시스템 확인 |
| 3 | 스냅샷 유효성 (etcdutl status 성공) | 채점기가 직접 실행 |
| 2 | status.txt에 검증 출력 저장 | 파일 내용 확인 |
