# ca-03 정답지 — Create an etcd snapshot backup

## 모범 답안

```bash
# 1. 노드에 접속해 스냅샷 생성 (인증서 4종 플래그가 핵심)
ssh cka-control-plane
etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/snapshot-cka.db
exit

# 2. 검증 출력을 작업 머신의 파일로 저장 (원격 실행 결과를 그대로 리다이렉트)
mkdir -p ~/cka/ca-03
ssh cka-control-plane "etcdutl snapshot status /var/lib/etcd/snapshot-cka.db -w table" \
  > ~/cka/ca-03/status.txt
```

## 해설 (한국어)

- **작업 위치가 중요하다.** etcd 백업은 control plane 노드에 `ssh` 로 들어가
  노드의 `etcdctl` 로 수행한다 — 실제 시험과 동일하다. 이 연습 환경도 노드에
  `etcdctl`·`etcdutl` 이 설치돼 있다(`cka cluster up`/`doctor` 가 etcd 이미지에서
  꺼내 `/usr/local/bin` 에 넣어 둔다).
- 스냅샷은 **노드의 파일**로 남고, 제출 파일은 **작업 머신**에 만든다.
  `ssh <node> "<명령>" > 파일` 로 원격 출력만 받아오면 두 곳을 오갈 필요가 없다.
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
