# ex-ca-05 정답지 — Back up etcd before a cutover

## 모범 답안

```bash
kubectl debug node/cka-control-plane -it --image=busybox:1.36 -- chroot /host bash
# node 안에서
grep -E 'listen-client-urls|trusted-ca-file|cert-file|key-file' /etc/kubernetes/manifests/etcd.yaml
#   --listen-client-urls=https://127.0.0.1:2379,...
#   --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
#   --cert-file=/etc/kubernetes/pki/etcd/server.crt
#   --key-file=/etc/kubernetes/pki/etcd/server.key

mkdir -p /var/lib/etcd-backup
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd-backup/pre-upgrade.db

etcdutl snapshot status /var/lib/etcd-backup/pre-upgrade.db -w table
#   +----------+----------+------------+------------+---------+
#   |   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE | VERSION |
#   ...          ↑ 이 숫자
exit

# 작업 host로 돌아와서
echo <REVISION 값> > ~/cka/ex-ca-05/revision.txt
```

`-w json`을 쓰면 `"revision":<숫자>`로 나온다. `--cert`·`--key`에는 kube-apiserver가 etcd에 접속할
때 쓰는 `/etc/kubernetes/pki/apiserver-etcd-client.crt`·`.key`도 쓸 수 있다. 둘 다 etcd CA가 서명한
클라이언트 인증서다.

## 해설

- **인증서 경로 찾기**: kubeadm 클러스터의 etcd는 static Pod다. manifest의 `--trusted-ca-file`,
  `--cert-file`, `--key-file`이 etcdctl의 `--cacert`, `--cert`, `--key`에 대응한다.
  `kubectl -n kube-system describe pod etcd-cka-control-plane`으로도 같은 값을 볼 수 있다.
- **snapshot save**는 실행 중인 member 하나에서 받는다. endpoint는 하나만 준다.
- **revision**은 snapshot 시점 etcd 저장소의 revision이다. `HASH`, `TOTAL KEYS`와 혼동하지 않는다.
- 상태 확인은 `etcdutl snapshot status`로 한다. 이 클러스터의 `etcdctl` 3.7에는 `snapshot save`만
  있고 `snapshot status`는 없다(`etcdctl snapshot --help`로 확인).
- debug Pod는 작업 뒤에 남는다. `kubectl get pods`로 확인하고 지워도 된다.

공식 문서:
[Operating etcd clusters for Kubernetes: Backing up an etcd cluster](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/#backing-up-an-etcd-cluster) ·
[etcd v3.6: Disaster recovery (snapshot save)](https://etcd.io/docs/v3.6/op-guide/recovery/) ·
[Debugging Kubernetes Nodes With Kubectl](https://kubernetes.io/docs/tasks/debug/debug-cluster/kubectl-node-debug/)

## 채점 기준 (7점)

| 배점 | 검증 항목 |
|---|---|
| 2 | `/var/lib/etcd-backup/pre-upgrade.db`가 `etcdutl snapshot status`로 읽히는 snapshot이다 |
| 2 | snapshot에 setup이 만든 `cutover-plan` 값이 들어 있다 (setup 뒤에 받은 snapshot) |
| 2 | `revision.txt`가 그 snapshot의 revision과 같다 |
| 1 | etcd static Pod manifest가 바뀌지 않았고 etcd가 Ready다 |
