# sn-11 정답지 — Find the node interface that carries cross-node Pod traffic

## 모범 답안

```bash
# 1. trainer-b의 Pod IP와 node 확인
kubectl -n fabric get pods -o wide
#   trainer-b   ...   192.168.245.x   cka-worker2

# 2. cka-worker에서 그 IP로 가는 route 확인
ssh cka-worker
ip route get 192.168.245.x
#   192.168.245.x via 172.18.0.3 dev tunl0 src 192.168.220.0 ...
ip route
#   192.168.245.0/26 via 172.18.0.3 dev tunl0 proto 80 onlink mtu 1480   ← 다른 node의 Pod 대역
#   192.168.220.3 dev cali2c051ec7880 scope link                         ← 같은 node의 Pod
exit

# 3. interface 이름만 저장
echo tunl0 > ~/cka/sn-11/egress-interface.txt
```

위 출력은 이 저장소의 Calico 설정 기준이다. CNI 설정이 다르면 interface 이름도 다를 수
있으므로, 실제 `ip route get` 결과를 그대로 쓴다.

## 해설 (한국어)

- **Kubernetes network model**: 모든 Pod는 클러스터 안에서 고유한 IP를 받고, NAT 없이 다른
  node의 Pod와 직접 통신한다. 이 모델을 실제로 구현하는 것은 CNI plugin이다.
- 이 클러스터의 Calico는 node마다 Pod IP 블록(`/26`)을 하나씩 나눠 준다.
  - **같은 node의 Pod**: Pod마다 veth 쌍이 생기고, node 쪽 끝이 `cali...` interface다.
    route는 `<Pod IP> dev cali...`이다.
  - **다른 node의 Pod**: 상대 node의 블록 전체로 가는 route가 있다. 이 저장소의 설정에서는
    `tunl0`(IP-in-IP overlay)을 거쳐 상대 node IP로 보낸다.
- `eth0`는 node 자신의 uplink다. Pod 패킷은 overlay interface에서 한 번 감싸진 뒤에
  `eth0`로 나간다. 그래서 "Pod IP로 가는 route의 interface"는 `eth0`가 아니다.
- `mtu 1480`은 IP-in-IP header(20 byte)만큼 MTU가 줄어든 결과다.
- **GPU 인프라와의 관계**: 분산 학습의 node 간 통신이 어느 interface와 경로를 타는지 아는 것이
  성능·장애 분석의 출발점이다. overlay를 쓰면 encapsulation 비용과 MTU 감소가 생긴다.

공식 문서:
[Services, Load Balancing, and Networking (network model)](https://kubernetes.io/docs/concepts/services-networking/) ·
[Cluster Networking](https://kubernetes.io/docs/concepts/cluster-administration/networking/) ·
[Network Plugins](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/)

## 채점 기준 (4점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 1 | 제출 파일 존재 | 파일 크기 |
| 3 | interface가 실제 route와 같음 | 채점 시점에 `cka-worker`에서 `ip route get <trainer-b IP>` 실행 |
