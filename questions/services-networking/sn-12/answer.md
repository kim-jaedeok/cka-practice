# sn-12 정답지 — Identify the CNI configuration and IPAM plugin on a node

## 모범 답안

```bash
ssh cka-worker
ls /etc/cni/net.d/
#   10-calico.conflist  calico-kubeconfig
cat /etc/cni/net.d/10-calico.conflist
#   "plugins": [
#     { "type": "calico", ..., "ipam": { "type": "calico-ipam" }, ... },
#     { "type": "portmap", "capabilities": {"portMappings": true}, ... }
#   ]
ls /opt/cni/bin/
#   calico calico-ipam flannel host-local loopback portmap ptp tuning
exit

echo calico-ipam > ~/cka/sn-12/ipam.txt
```

## 해설 (한국어)

- **CNI 설정 위치**: container runtime은 기본으로 `/etc/cni/net.d`에서 설정을 읽고,
  `/opt/cni/bin`에서 plugin binary를 찾는다.
- **`.conflist`는 plugin chain이다.** `plugins` 배열의 plugin이 순서대로 실행된다. 이 클러스터는
  - `calico`: Pod의 veth를 만들고 route를 설정한다.
  - `portmap`: `hostPort`를 구현한다. `portMappings` capability가 이 기능을 켠다.
- **IPAM (IP Address Management) plugin**은 Pod IP를 실제로 할당한다. 이 클러스터는
  `calico-ipam`을 쓴다. `/opt/cni/bin`에 `host-local` binary가 있어도, 설정이 쓰지 않으면
  사용되지 않는다. binary 목록이 아니라 설정 파일을 봐야 하는 이유다.
- **GPU 인프라와의 관계**: GPU 클러스터의 보조 네트워크(SR-IOV, MacVLAN 등)도 같은 CNI
  plugin과 IPAM 구조 위에서 동작한다. 기본 CNI 설정을 읽을 줄 알아야 그 위에 추가되는
  설정을 이해할 수 있다.

공식 문서:
[Network Plugins](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/) ·
[Cluster Networking](https://kubernetes.io/docs/concepts/cluster-administration/networking/)

## 채점 기준 (4점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 1 | 제출 파일이 있고 node의 CNI 설정이 바뀌지 않음 | setup 때 저장한 checksum 비교 |
| 3 | 값이 CNI 설정의 IPAM type과 같음 | 채점 시점에 `cka-worker`의 설정 파일을 읽어 비교 |
