# Certified Kubernetes Administrator (CKA) 시험 개요와 로컬 커버리지 (Kubernetes v1.35)

CKA의 현재 공식 시험 정보와 이 저장소의 범위를
구분해 기록한다. 공식 페이지는 시험 환경이 Kubernetes v1.35이며 최신 마이너 릴리스 후
약 4~8주 안에 갱신된다고 안내한다. 따라서 응시 직전에는 아래 공식 출처를 다시 확인해야 한다.

## 공식 시험 형식

| 항목 | 공식 안내 |
|---|---|
| 방식 | 온라인 원격 감독, 명령줄에서 수행하는 performance-based 과제 |
| 시간 | 2시간 |
| 과제 수 | 15~20개 |
| 합격선 | 66% 이상 |
| 현재 환경 | Kubernetes v1.35 |
| 인증 유효 기간 | 2년 |
| 공식 simulator | 등록 상품에 따라 Killer.sh 2회, 회당 활성화 후 36시간 |

공식 근거:
[Linux Foundation CKA 페이지](https://training.linuxfoundation.org/certification/certified-kubernetes-administrator-cka/) ·
[CKA·Certified Kubernetes Application Developer (CKAD)·Certified Kubernetes Security Specialist (CKS) FAQ](https://docs.linuxfoundation.org/tc-docs/certification/faq-cka-ckad-cks) ·
[CKA·CKAD 중요 지침](https://docs.linuxfoundation.org/tc-docs/certification/tips-cka-and-ckad)

공식 환경에서는 모든 과제를 `base` 호스트가 아니라 각 문항에 지정된 호스트에서
수행한다. 문항의 infobox가 SSH (Secure Shell) 명령 `ssh <nodename>` 접속을 지시하며,
완료 후 `exit`로 base에 돌아온다. base에는 `kubectl` 등의 작업 도구가 설치되어 있지 않다.
[공식 중요 지침](https://docs.linuxfoundation.org/tc-docs/certification/tips-cka-and-ckad)

허용 자료는 시험 VM (Virtual Machine) 안의 브라우저에서 여는 Kubernetes 문서와 블로그,
Helm 문서, CKA용 Gateway API (Application Programming Interface) 문서, 문항별 Quick
Reference 등으로 제한된다. 허용 범위는 변경될 수 있으므로 응시 직전에
[공식 Resources Allowed](https://docs.linuxfoundation.org/tc-docs/certification/certification-resources-allowed)를
확인한다.

## 공식 도메인과 현재 52문제

도메인과 비중은
[공식 CKA 페이지](https://training.linuxfoundation.org/certification/certified-kubernetes-administrator-cka/)에
게시된 v1.35 역량과
[Cloud Native Computing Foundation (CNCF) 공식 v1.35 curriculum](https://github.com/cncf/curriculum/blob/master/CKA_Curriculum_v1.35.pdf)을
기준으로 한다. 문제 수는 로컬 뱅크의 수이며 실제 시험 문항 수나 배점을 뜻하지 않는다.

| 도메인 | 공식 비중 | 로컬 문제 |
|---|---:|---|
| Troubleshooting | 30% | ts-01 ~ ts-15 (15개) |
| Cluster Architecture, Installation & Configuration | 25% | ca-01 ~ ca-13 (13개) |
| Services & Networking | 20% | sn-01 ~ sn-10 (10개) |
| Workloads & Scheduling | 15% | wl-01 ~ wl-08 (8개) |
| Storage | 10% | st-01 ~ st-06 (6개) |

역량별 `covered`/`partial`/`gap` 판정과 문제 매핑의 단일 기준은
[`curriculum/cka-v1.35.yaml`](../curriculum/cka-v1.35.yaml)이다. 문제 수가 많더라도 공식
역량 전체가 `covered`가 아니면 이 저장소만으로 준비가 끝났다고 판단하지 않는다.

### 주요 보강 문제

- `wl-07`: required node affinity와 topology spread constraint를 함께 적용하고 실제 배치를 확인한다.
- `wl-08`: LimitRange와 ResourceQuota admission 제약을 만족하도록 워크로드를 수정한다.
- `st-05`: access mode와 `Retain` reclaim policy를 사용해 보존된 데이터를 새 claim에 재연결한다.
- `sn-09`: Cloud Provider KIND가 주소를 할당한 LoadBalancer Service의 HTTP (Hypertext
  Transfer Protocol) 데이터 경로를 실제로 확인한다.
- `sn-10`: namespace와 Pod selector의 교집합, Domain Name System (DNS) egress, 허용·차단
  HTTP 요청으로 cross-namespace NetworkPolicy를 검증한다.
- `ts-13`: etcd와 kube-apiserver static Pod 장애를 node-local 진단 도구로 복구한다.
- `ts-14`: CRI (Container Runtime Interface)와 CNI (Container Network Interface) 장애로
  NotReady가 된 node를 복구한다.
- `ts-15`: Service selector·kube-proxy·CNI 장애를 한 번에 진단하고 실제 요청으로 확인한다.
- `ca-06`: 고정된 공식 package로 worker를 Kubernetes N-1에서 N으로 실제 upgrade한다.
- `ca-09`: 설치된 cert-manager에 Issuer·Certificate를 작성하고 controller가 만든
  TLS (Transport Layer Security) Secret과 현재 generation의 Ready 상태를 확인한다.
- `ca-11`: load balancer 뒤의 기존 control plane에 두 control plane을 join해
  3-member stacked-etcd HA (High Availability)를 만들고 failover를 확인한다.
- `ca-12`: cluster state가 없는 세 host에서 `kubeadm init`·`join`, network add-on과
  cross-node Service 데이터 경로를 구성한다.
- `ca-13`: CRD (Custom Resource Definition)만 있는 cluster에 고정된 cert-manager
  operator를 설치하고 기존 Certificate의 reconcile 결과를 확인한다.
- `sn-05`: Envoy Gateway의 Gateway·HTTPRoute 상태와 실제 HTTP 데이터 경로를 확인한다.
- `st-06`: CSI (Container Storage Interface) driver 등록부터 dynamic
  PV (PersistentVolume) provisioning, attachment와 volume data까지 확인한다.

종합 장애 문제의 진단·복구 기준은 Kubernetes 공식 문서의
[kubeadm cluster 재구성](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-reconfigure/),
[`crictl` node 디버깅](https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/),
[container runtime](https://kubernetes.io/docs/setup/production-environment/container-runtimes/),
[network plugin](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/),
[Service 디버깅](https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/)을 따른다.
추가 일회용 셀은 Kubernetes의
[kubeadm cluster 생성](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/),
[HA topology](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/),
[Linux node upgrade](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/upgrading-linux-nodes/),
[Operator pattern](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/),
[Gateway API HTTP routing](https://gateway-api.sigs.k8s.io/guides/user-guides/http-routing/),
[CSI 배포](https://kubernetes-csi.github.io/docs/deploying.html)를 구현 기준으로 삼는다.

`wl-07`, `wl-08`, `st-05`, `sn-09`, `sn-10`은 개별 연습과 공유 모의고사 후보에
들어간다. `ts-05`, `ts-12`~`ts-15`는 공유 상태를 손상시킬 수 있고, `ca-06`, `ca-09`,
`ca-11`~`ca-13`, `sn-05`, `st-06`은 각각 일회용 셀을 요구한다. 이 12문제는 공유
모의고사에서 제외하므로 52문제 중 공유 form 후보는 40개다.

LoadBalancer 구현은 Cloud Provider KIND v0.11.1로 고정한다. kind 공식 문서는
Cloud Provider KIND를 사용해 `type: LoadBalancer` Service를 지원하는 방법을 설명한다:
[kind LoadBalancer 공식 문서](https://kind.sigs.k8s.io/docs/user/loadbalancer/) ·
[Cloud Provider KIND v0.11.1 공식 릴리스](https://github.com/kubernetes-sigs/cloud-provider-kind/releases/tag/v0.11.1).
NetworkPolicy의 `namespaceSelector`와 `podSelector`를 같은 peer에 함께 쓰면 두 조건을 모두
만족하는 Pod가 선택된다는 기준은
[Kubernetes NetworkPolicy 공식 문서](https://kubernetes.io/docs/concepts/services-networking/network-policies/)를
따른다.

## 이 저장소의 모의고사

`cka exam start --seed <seed>`는 domain quota를 맞추면서 catalog의
`mutex`/`breaks`/`requires` 조건을 통과하는 17문항 form을 만든다. 동일한 catalog와 seed는
같은 form을 재현한다. 화면 표시 순서와 setup 순서는 별도로 계산하며, node drain과
controller 없는 Pod처럼 풀이 순서에 따라 충돌하는 조합도 배제한다.
`kubectl drain`의 unmanaged Pod 처리 규칙은
[Kubernetes 공식 drain 문서](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_drain/)를
기준으로 한다.

시험 시작 전에는 node/scheduler/addon baseline을 확인하고 17개 setup을 모두 적용한 뒤
각 grader를 preflight한다. baseline·setup 실패, grader 결과 누락, `meta.yaml`과 배점
불일치, setup 직후 이미 만점인 문제는 후보자의 오답으로 계산하지 않고 run 전체를
`INVALID`로 종료한다. 모든 검사가 성공한 시점부터 120분을 센다.

상태 전이는 다음과 같다.

```text
PREPARING → RUNNING → SEALED → GRADING → ARCHIVED
    └→ INVALID                 └→ INVALID
```

제한시간이 지난 run은 최종 점수가 66% 이상이어도 `FAIL`이다. 현재 deadline 봉인은
`cka exam status`, `question`, `finish` 중 다음 호출에서 적용된다. 즉, 열린 raw 터미널을
120분 시점에 운영체제 수준에서 강제로 닫는 hard-stop은 아직 구현되지 않았다. 모의고사
중 CLI (Command-Line Interface)와 웹의 연습/정답/클러스터 변경 버튼은 잠기지만, 별도
운영체제 사용자나 파일시스템 격리는 제공하지 않는다.

별도 opt-in [`cka exam-ssh`](../exam/ssh/) runner는 실제 `sshd`가 있는 target, 작업
도구와 저장소가 없는 base, run별 SSH key·내부 network를 사용한다. Kubernetes API만으로
풀 수 있는 34개 shared-kind 문제를 허용 목록으로 두고, 그중 17개 form의 setup,
불변 kubeconfig·작업 입력, 실제 base→target 접속, 허용 답안 회수와 host grader를 연결한다.

자동 모드는 systemd user manager와 login linger가 확인될 때만 시작한다. systemd timer가
deadline을 실행하고 재시작 가능한 guard가 이를 보조하며, 감독 없는 process fallback은
없다. 유효한 seal proof가 없으면 답안 수집과 채점을 거부한다. deadline으로 봉인된 run은
점수가 66% 이상이어도 `TIMEOUT`으로 비통과다. systemd transient unit 동작은
[`systemd-run` 공식 manual](https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html)을
기준으로 한다.

공식 66%와 별개로 이 프로젝트의 보수적인 준비 완료 조건은
[`exam/readiness-policy.yaml`](../exam/readiness-policy.yaml)에 정의되어 있다. 이는 공식
합격 예측이나 Linux Foundation 정책이 아니다.

## 이 연습 환경과 실제 시험의 차이

| 항목 | 공식 시험 | 이 연습 환경 |
|---|---|---|
| 작업 호스트 | 모든 과제를 지정 SSH 호스트에서 수행 | 기본 runner는 Windows Subsystem for Linux (WSL) 셸과 `bin/ssh` 래퍼 사용; opt-in `cka exam-ssh`는 실제 `base → cka-target` SSH 제공 |
| 격리 | base와 지정 호스트가 분리됨 | 감독형 SSH는 base·target을 분리하지만 `sudo`가 가능한 로컬 학습 장치이며 적대적 우회를 막는 보안 sandbox는 아님 |
| 클러스터 | 문항 infobox의 지정 환경에서 수행 | 공유 `kind-cka`와 문제별 무작위 이름·전용 network의 일회용 kind/kubeadm 셀 |
| 환경 구성 | 제공된 시험 환경 | setup script가 공유 cluster를 변형하거나 별도 셀을 생성 |
| 시간 종료 | 공식 시험 시스템이 통제 | 기본 `cka exam`은 다음 명령에서 봉인; `cka exam-ssh`는 systemd timer가 base·target을 중지하고 timeout을 비통과 처리 |
| 채점 | 공식 자동 채점 후 결과 통지 | 즉시 로컬 criterion 채점, `PASS`/`FAIL`/`INVALID` |
| 정답 접근 | 허용되지 않음 | 기본 모의고사는 저장소 파일 자체를 격리하지 않음; 감독형 target에는 저장소·grader를 mount하지 않음 |
| HA control plane | 공식 역량에 포함 | `ca-11`이 3-control-plane stacked-etcd 구성과 control-plane 중지 후 API write·Service path를 검증 |
| kubeadm lifecycle | 공식 역량에 포함 | `ca-06`이 N-1→N worker upgrade, `ca-12`가 blank host의 init/join을 별도 셀에서 수행 |
| Operator | 공식 역량에 포함 | `ca-09`가 cert-manager configure/reconcile, `ca-13`이 고정 manifest operator 설치를 검증 |
| LoadBalancer | 공식 Service 역량에 포함 | Cloud Provider KIND가 외부 주소를 할당하고 `sn-09`가 실제 HTTP 응답까지 채점 |
| Gateway API | 공식 Services & Networking 역량에 포함 | `sn-05`가 Envoy Gateway의 상태와 실제 HTTP data path를 검증 |
| Storage extension | CSI driver 설치·storage 구성 역량에 포함 | `st-06`이 CSI driver 등록, dynamic provisioning, attachment와 실제 volume data를 검증 |

cluster-free 정적·계약 검사와 `ca-06`, `ca-09`, `ca-11`~`ca-13`, `sn-05`, `st-06`의
Docker live gate가 통과했다. 여기에는 blank kubeadm init/join, 3-control-plane
stacked-etcd failover 중 API write·Service path, 실제 worker upgrade, cert-manager
reconcile·offline install, Envoy Gateway 상태·HTTP data path, CSI provisioning·attachment와
data path 및 각 일회용 resource cleanup이 포함된다. 2026-08-23 clean Ubuntu 24.04 WSL2
(Windows Subsystem for Linux 2)에서 실제 17문항 감독형 SSH gate도 통과했다. 104/104
상태에서 무개입 deadline 후 `TIMEOUT`, guard kill·restart, 실제 base→target SSH와 exact
cleanup을 검증했으며 종료 후 관련 Docker·KIND object는 모두 0개였다. 따라서 저장소의
구현 검증은 `practice-ready-live-complete`지만, 이 상태만으로 개인의 “준비 종료”나 공식
CKA 합격을 선언하지 않는다.

### 일회용 셀의 host 저장 공간과 정리 정책

일회용 셀은 어떤 Docker object도 만들기 전에 workspace가 있는 host filesystem의 가용
공간을 검사한다. 10 GiB 미만이면 생성이 중단된다. 이 수치는 Kubernetes·Docker의 공식
최소 요구량이 아니라 다중-node 셀의 불완전 생성과 host 고갈을 줄이기 위한 프로젝트
안전 정책이다. 위험을 이해하고 공간 부족 상태에서 의도적으로 실행할 때만
`CKA_CELL_ALLOW_LOW_HOST_SPACE=1 ./cka start <id>`를 사용할 수 있다.

셀 manifest는 container·network의 immutable identifier뿐 아니라 각 anonymous volume의
이름, mount destination과 inspect fingerprint를 봉인한다. cleanup은 container 제거 후
동일한 volume generation이고 foreign attachment가 없음을 다시 확인한 것만 삭제한다.
전역 `docker volume prune`이나 이름 pattern 기반 삭제는 사용하지 않는다. 구현은
[`lib/cell.sh`](../lib/cell.sh), 장애·near-miss 계약은
[`tests/kubeadm-cell-contract-test.sh`](../tests/kubeadm-cell-contract-test.sh)에 있다.

## 버전 재현성

[`cluster/versions.lock.yaml`](../cluster/versions.lock.yaml)은 kind와 node image digest,
etcd image, Calico, metrics-server, ingress-nginx, Gateway API, Cloud Provider KIND와
그 proxy image, Helm 버전을 고정한다. 셋업은
kind와 Helm 버전, metrics-server manifest와 Helm archive의 checksum, 기존 kind node 및
etcd image ref, Cloud Provider KIND archive·binary checksum과 proxy image digest를 검사하며
lock과 다르면 명시적 reset 또는 설치 정정을 요구한다.

lock 버전의 공식 릴리스:
[kind v0.31.0](https://github.com/kubernetes-sigs/kind/releases/tag/v0.31.0) ·
[etcd v3.6.6](https://github.com/etcd-io/etcd/releases/tag/v3.6.6) ·
[Calico v3.32.1](https://github.com/projectcalico/calico/releases/tag/v3.32.1) ·
[metrics-server v0.9.0](https://github.com/kubernetes-sigs/metrics-server/releases/tag/v0.9.0) ·
[ingress-nginx controller-v1.15.1](https://github.com/kubernetes/ingress-nginx/releases/tag/controller-v1.15.1) ·
[Gateway API v1.6.0](https://github.com/kubernetes-sigs/gateway-api/releases/tag/v1.6.0) ·
[Cloud Provider KIND v0.11.1](https://github.com/kubernetes-sigs/cloud-provider-kind/releases/tag/v0.11.1) ·
[Helm v3.21.4](https://github.com/helm/helm/releases/tag/v3.21.4)

일회용 문제는 별도 lock을 사용한다. `cluster/cells/kubeadm/packages.lock`은 Kubernetes
v1.34.0·v1.35.0 package를, `cluster/controllers/assets.lock`은 cert-manager v1.21.1,
Gateway API v1.6.1과 Envoy Gateway v1.9.0을, `cluster/csi/assets.lock`은 CSI host-path
driver와 sidecar image를 checksum·platform manifest digest로 고정한다. runtime은 네트워크
download 없이 준비된 cache만 받아들인다. 공식 release 기준은
[cert-manager releases](https://cert-manager.io/docs/releases/),
[Envoy Gateway compatibility matrix](https://gateway.envoyproxy.io/news/releases/matrix/),
[CSI 배포](https://kubernetes-csi.github.io/docs/deploying.html)다.

## 준비 판단

이 저장소는 공식 curriculum에 매핑된 실습 구현을 갖췄지만, 문제를 모두 익혔다는 사실이나
정적 계약 통과만으로 CKA 취득 가능 여부를 단정할 수 없다. 다음 조건을 모두 확인하기 전에는
“이 환경만으로 준비 종료”라고 선언하지 않는다.

1. 충분한 host 저장 공간이 있는 목표 WSL host에서 kubeadm bootstrap·upgrade·HA failover,
   cert-manager reconcile·install, Envoy Gateway HTTP, CSI provisioning·data path의 opt-in
   live 검사를 모두 통과한다. 이 일회용 셀 검사는 2026-08-22에 모두 통과했고 각 cleanup도
   성공했다. `st-06`은 canonical solution과 의미상 동등한 대안이 각각 10/10을 받았다.
2. persistent user systemd와 login linger가 있는 host에서 감독형 SSH runner의 prepare부터
   deadline seal·수집·채점·cleanup까지 실제 lifecycle과 장애 주입 검사를 통과한다. 이
   gate는 2026-08-23 clean Ubuntu 24.04 WSL2에서 통과했다. 실제 17문항 form의 104/104
   결과와 별개로 무개입 deadline이 `TIMEOUT`을 강제했고, guard kill·restart, 실제
   base→target SSH 및 exact cleanup도 통과했다. 종료 후 관련 cluster·container·network와
   volume은 모두 0개였다.
3. [`exam/readiness-policy.yaml`](../exam/readiness-policy.yaml)의 자체 기준대로 유효한 blind
   run 3회를 각각 총점 80% 이상, 각 도메인 65% 이상, 시간 초과 없이 통과한다.
4. 지정-host workflow를 사용하고 외부 공식 simulator를 통과한다.

필수 suite의 정확한 파일명·실행 방법·완료 상태는
[`readiness-policy.md`](readiness-policy.md)에 기록한다. curriculum registry도 같은
네 파일을 [`implementationValidation.requiredLiveSuites`](../curriculum/cka-v1.35.yaml)로
열거한다.

위 80%·65% 기준은 이 프로젝트의 보수적인 학습 gate이며 공식 합격선이나 합격 예측이
아니다. 등록 시 제공되는 공식 Killer.sh simulator를 별도 검증 단계로 사용한다. CKA 상품
페이지는 simulator 2회 제공을 명시한다:
[공식 CKA 페이지](https://training.linuxfoundation.org/certification/certified-kubernetes-administrator-cka/).
