# 시험 전용 문제 은행과 연습 문제 보강 설계안 (초안)

이 설계안은 두 트랙으로 나뉜다. 두 트랙 모두 CKA (Certified Kubernetes Administrator) 준비에
필요한 만큼만 만든다. CKA 기준으로 과한 항목은 줄이거나 연기했고, 그 근거는 5절에 모았다.

- **트랙 A: 시험 전용 문제 은행.** 모의고사를 연습 문제와 겹치지 않는 별도 은행에서
  출제한다. 시험 문제는 이 저장소의 `exam/bank/` 아래에 평문으로 두고, 감독형 SSH runner로만
  실행한다. 한 번 노출된 form은 다시 blind run으로 세지 않는다.
- **트랙 B: 연습 문제 네트워크 보강.** GPU 인프라 엔지니어링의 기초가 되는 네트워크 개념 중
  CKA 범위 안의 것을 먼저 연습 문제로 보강한다. CKA 범위 밖의 GPU 네트워크 주제는 CKA 이후로
  연기한다.

두 트랙은 서로 기다리지 않는다.

**구현 상태 (2026-11-06)**

| 항목 | 상태 |
|---|---|
| A-W0 | 완료. `cmd_question`은 `RUNNING`·`SEALED`·`COLLECTED`·`GRADED`에서만 본문을 출력한다. `tests/ssh-runner-faults.sh`에 회귀 테스트를 추가했다. |
| 트랙 B N1~N6 | 완료. v1.37 공유 클러스터에서 문제마다 selftest(setup 비만점 → near-miss 부분 점수 → solve 만점)를 통과했다. |
| 저장 위치 결정 | 확정(2026-11-05). 사용자가 저장소 평문 저장을 결정했다(A-D1). |
| A-W1 | 완료(2026-11-05). `exam/bank/README.md`, `exam_bank_qdir_of`, 공용 ID 규칙(`CKA_PRACTICE_ID_RE`·`CKA_EXAM_BANK_ID_RE`)과 schema·supervisor·웹 UI 정렬, `tests/test_exam_bank.py`와 `tests/contract-test.sh`의 격리 검사. |
| A-W2 | 완료(2026-11-06). `cka exam-ssh prepare --form NAME [--allow-seen]`, form 검증(17문항·5/4/3/3/2·호환성·shared-kind), 노출 ledger, 은행 문제의 `answer_files`, `result.json`(도메인별 점수·blind·`readinessPass`). `tests/ssh-runner-faults.sh` 23~26. |
| A-W3 | 완료(2026-11-06). form A 17문제, API만으로 푸는 문제. 문제별 selftest 통과. |
| A-W5 | 완료(2026-11-06). form B 17문제, Helm 문제와 node 파일시스템 문제 포함. 문제별 selftest 통과, form A+B 은행 selftest 34/34. |
| 감독형 SSH live gate | 통과(2026-11-06). v1.37.0에서 `tests/ssh-supervised-live-test.sh` 17문항 104/104, deadline `TIMEOUT`, guard 재시작, 정리. curriculum 상태는 `practice-ready-live-complete`. |
| A-W6 | 완료(2026-11-06). `exam/readiness-policy.yaml` v2: blind run 2회, 서로 다른 시험 은행 form, 외부 simulator 유지. 준비도 판정은 `result.json`의 `readinessPass`. |
| A-W4 | 완료(2026-11-06). target image에 Helm v3.22.1 추가. node 파일시스템은 `kubectl debug node … -- chroot /host`로 접근(control-plane etcdctl·static Pod manifest, worker kubelet 설정·crictl, TTY 진입을 v1.37 공유 클러스터에서 확인). kubelet 정지·kubeadm 재구성 문제는 이 방법으로 풀 수 없어 연습 셀에만 둔다. |

트랙 B 문제 ID: N1 `sn-11`, N2 `sn-12`, N3 `ts-16`, N4 `sn-13`, N5 `ts-17`, N6 `sn-14`.

## 1. 목표와 문제

| ID | 내용 |
|---|---|
| G1 | 모의고사가 처음 보는 문제로 준비도를 측정한다. |
| G2 | 연습 문제 은행은 도메인 비율 대신 역량 커버리지만 기준으로 삼는다. |
| G3 | GPU 인프라 엔지니어링의 기초 네트워크 개념을 연습 문제로 확실하게 익힌다. |
| P1 | 연습 문제 모의고사(`cka exam`)는 연습 문제(설계 시점 53개, 트랙 B 이후 59개)의 부분집합이다. 본문·setup·채점이 연습과 같다. → G1을 막는다. |
| P2 | 이 저장소는 GitHub에서 PUBLIC이다. 평문 시험 문제를 commit하면 누구나 본다. 사용자는 이 점을 받아들이고 평문 저장을 결정했다(2026-11-05). → G1을 약하게 한다. |
| P3 | 한 번 본 시험 문제를 다시 출제하면 blind가 아니다. → G1을 막는다. |
| P5 | 현재 네트워크 연습 문제는 Service·DNS·Policy·Ingress·Gateway 같은 API 수준에 모여 있다. node 안의 data path와 CNI 구성을 직접 관찰하는 문제가 없다. → G3을 막는다. |

## 2. 트랙 A: 시험 전용 문제 은행

### A-D1. 저장 위치 (사용자 결정 2026-11-05)

시험 문제는 이 저장소의 `exam/bank/<domain>/ex-<domain 약어>-NN/`에 평문으로 둔다.
private 저장소, 암호화, 노출 경로 차단은 하지 않는다. 개인 학습용이므로 다음 규칙만 둔다.

- 사용자는 아직 풀지 않은 form의 `exam/bank/` 파일과 그 diff를 열지 않는다.
- Claude는 `exam/bank/` 변경의 commit message와 대화 요약에 문제 본문이나 정답을 쓰지 않는다.
  문제 ID, 도메인, 검증 결과만 쓴다.
- form을 한 번 푼 뒤에는 그 form의 `answer.md`를 읽어도 된다.

### A-D2. 실행 경로 (G1)

시험 form은 `cka exam-ssh`로만 실행한다. 기본 `cka exam`과 연습 명령은 시험 문제를
다루지 않는다.

| 이유 | 근거 |
|---|---|
| target에 저장소·grader·Docker socket을 mount하지 않는다. | [exam/ssh/README.md](../exam/ssh/README.md) "보안·복구 경계" |
| systemd timer가 deadline을 강제하고, 초과 run은 `TIMEOUT`이다. | 같은 문서 "실행 순서" |
| 공식 시험의 지정-host 흐름과 같다. | [CKA·CKAD 중요 지침](https://docs.linuxfoundation.org/tc-docs/certification/tips-cka-and-ckad) |

### A-D3. 시험 문제 resolver (P1 해결 → G1)

시험 문제는 공용 `qdir_of`에 fallback을 넣어 찾지 않는다. `qdir_of`는 연습 명령도 쓰기
때문이다([cka](../cka) 293·312행). 대신 `exam/bank/`만 읽는 시험 전용 resolver를 둔다.

- resolver는 문제 디렉터리, schema, form manifest, 제출 파일 목록, cleanup을 `exam/bank/`에서
  찾는다.
- 현재 이 항목들은 연습 은행에 묶여 있다.
  - ID 정규식: [question.schema.json](../exam/question.schema.json) 11행,
    [planner.sh](../exam/planner.sh) 38행은 `^(st|wl|sn|ca|ts)-[0-9]{2}$`만 허용한다.
    반면 supervisor의 `QUESTION_ID_RE`는 일반 slug를 허용한다. 계층마다 규칙이 다르다.
  - `lib/common.sh`의 `domain_of`, 정리 함수, 작업 디렉터리 함수
  - [exam/ssh/gated-form.sh](../exam/ssh/gated-form.sh)의 catalog와 제출 파일 목록
  - 각 문제 `setup.sh`의 상대 경로 `lib` source
- 시험 문제 ID는 `ex-<domain 약어>-NN` 형식이다. 예: `ex-ts-01`. resolver와 supervisor는 같은
  정규식을 쓴다.
- `cka list`, `cka start`, `cka solution`, 웹 UI는 시험 ID를 나열하거나 실행하지 않는다. 계약
  검사로 이를 고정한다.

### A-D4. form 구성 (G1, G2)

form 하나는 17문항이다. 공식 시험은 15~20개 과제이고, 현재 모의고사도 17문항이다.

| 도메인 | 공식 비중 | 17 × 비중 | form당 문항 |
|---|---:|---:|---:|
| Troubleshooting | 30% | 5.1 | 5 |
| Cluster Architecture, Installation & Configuration | 25% | 4.25 | 4 |
| Services & Networking | 20% | 3.4 | 3 |
| Workloads & Scheduling | 15% | 2.55 | 3 |
| Storage | 10% | 1.7 | 2 |

출처: [CKA 페이지](https://training.linuxfoundation.org/certification/certified-kubernetes-administrator-cka/)
(비중), [중요 지침](https://docs.linuxfoundation.org/tc-docs/certification/tips-cka-and-ckad)
(15~20개 과제). 반올림 방식은 이 프로젝트의 선택이다.

- 시험 form은 A와 B 두 개만 만든다. 세 번째 처음 보는 시험은 등록 상품에 포함된 Killer.sh
  simulator가 맡는다. CKA 페이지는 simulator 2회를 제공한다고 밝힌다.
- 고정 form에도 기존 planner의 호환성 검사(mutex, breaks↔breaks, breaks↔requires)를 그대로
  적용한다([planner.sh](../exam/planner.sh)). setup 순서는 manifest에 명시한다.
- form manifest에는 문제 ID, 도메인, 배점, setup 순서만 둔다.
- 연습 문제 은행은 도메인 비율 조건을 없앤다. 27개 역량이 모두 `covered`라는 조건은 남긴다.

### A-D5. 노출 기록 (P3 해결 → G1)

- form 상태는 `AVAILABLE`과 `EXPOSED` 두 가지다.
- runner는 문제 본문을 처음 출력하기 전에 연습 저장소 밖의 ledger에 `EXPOSED`를 기록한다.
  예: `~/.local/state/cka-practice/exam-bank/ledger`.
- 현재 `cmd_question`([supervised-exam.sh](../exam/supervised-exam.sh) 714행)은 run 상태를 검사하지
  않아 `start` 전에도 본문을 출력한다. 이 결함은 A-W0에서 먼저 고친다.
- run이 `INVALID`, `TIMEOUT`, crash로 끝나도 본문이 나갔으면 `EXPOSED`로 둔다.
- `EXPOSED` form을 다시 시작하려면 `--allow-seen`이 필요하다. 그 run은 blind가 아니라고 기록한다.

### A-D6. 노출 경로 차단 (제거)

평문 저장 결정(A-D1)으로 이 항목은 하지 않는다. 문제 파일 자체가 저장소에 있으므로 로그·웹
터미널·대화 기록을 따로 막아도 효과가 없다.

### A-D7. 작성과 검증 (G1)

- 시험 문제는 별도 Claude 세션이 작성한다. 사용자는 그 세션의 대화를 읽지 않는다. 그 세션은
  A-D1의 commit message 규칙을 따른다.
- 문제마다 다음을 검증한다.
  1. `setup.sh` 직후 채점이 만점이 아니다.
  2. `solve.sh` 뒤 채점이 만점이다.
  3. 요구사항 하나를 어긴 오답 표본 1개가 해당 항목에서 감점된다.
  4. 풀이 방법이 여러 가지인 문제는 대안 풀이 1개도 만점이다.
  5. metadata 배점과 채점 배점의 합이 같다.
- form 단위로 `cka exam-ssh` 실제 경로(prepare→start→seal→collect→grade)를 한 번 통과한다.
  이 검증 run은 별도 state와 ledger를 쓴다.
- 검증 출력은 문제 ID와 통과 여부만 보인다.

### A-D8. 결과 기록과 준비 기준 (G1)

- 현재 SSH 결과는 총점과 66% 판정만 저장한다([supervised-exam.sh](../exam/supervised-exam.sh)
  795~820행). 그래서 도메인별 65% 기준을 판정할 수 없다.
- 결과에 문제별·도메인별 점수와 blind 여부를 추가한다.
- [docs/readiness-policy.md](readiness-policy.md)의 blind run 정의를 바꾼다.
  - 현재: 유효한 모의고사 run 3회.
  - 변경: 시험 form A·B를 각각 처음 푼 run 2회. 점수 기준(총점 80%, 도메인별 65%, 초과 시간
    0초)은 유지한다. 외부 simulator 통과 조건(현재 4번)도 그대로 둔다.
- form에 node 수준 문제가 없으면 그 결과는 "부분 범위 진단"으로 표시한다(A-W4).

### A-W. 작업 순서

| 작업 | 내용 | 해결 대상 | 선행 조건 |
|---|---|---|---|
| A-W0 | 현재 SSH runner의 `cmd_question`이 `RUNNING` 상태에서만 본문을 출력하게 고친다 | A-D5 | 없음 |
| A-W1 | `exam/bank/` 디렉터리, 시험 resolver, ID 정규식 통일, 연습 명령·웹 UI가 시험 ID를 다루지 않는 계약 검사 | A-D1, A-D3 | 없음 |
| A-W2 | form manifest, 노출 ledger, 결과의 도메인별 점수 | A-D4, A-D5, A-D8 | A-W1 |
| A-W3 | form A 작성과 A-D7 검증 | A-D4, A-D7 | A-W2 |
| A-W4 | etcd snapshot, kubelet 장애, kubeadm upgrade 같은 node 수준 대표 문제와 Helm 문제를 SSH runner에서 실행할 수 있게 확장 | 8절 한계 1 | A-W1 |
| A-W5 | form B 작성. A-W4가 끝났으면 node 수준 문제를 포함한다 | A-D4 | A-W3 |
| A-W6 | readiness 정책·문서 갱신 | A-D8 | A-W5, 6절 결정 |

## 3. 트랙 B: 연습 문제 네트워크 보강 (P5 해결 → G3)

### B-1. 현재 범위

| 영역 | 현재 연습 문제 |
|---|---|
| Service 종류·endpoint | `sn-01` ClusterIP, `sn-02` NodePort, `sn-09` LoadBalancer, `sn-07`·`ts-03` endpoint 없음 |
| DNS | `sn-06` 조회, `sn-08` CoreDNS 설정, `ts-06` CoreDNS 장애 |
| NetworkPolicy | `sn-03`, `sn-10` |
| L7 진입점 | `sn-04` Ingress, `ts-11` Ingress 404, `sn-05` Gateway API |
| node·CNI 장애 | `ts-14` containerd·CNI 복구, `ts-15` Service·kube-proxy·CNI 진단 |

빈 곳은 다음과 같다. Pod 패킷이 node 안에서 어디로 가는지, CNI 설정이 어디에 있는지,
Service가 어떤 규칙으로 backend에 전달되는지를 직접 관찰하는 문제가 없다.

### B-2. CKA 범위 문제 (먼저 만든다)

CKA 공식 역량 "Understand connectivity between Pods", "Troubleshoot services and networking",
"Understand extension interfaces (CNI, CSI, CRI, etc.)", "Understand and use CoreDNS",
"Use ClusterIP, NodePort, LoadBalancer service types and endpoints"에 해당한다
([CKA 페이지](https://training.linuxfoundation.org/certification/certified-kubernetes-administrator-cka/)).
모두 공유 클러스터에서 풀 수 있게 만든다. 새 셀 profile은 만들지 않는다.

CKA는 명령줄에서 여러 과제를 푸는 performance-based 시험이다
([CKA 페이지](https://training.linuxfoundation.org/certification/certified-kubernetes-administrator-cka/)).
그래서 문제는 "관찰하고 보고하라"가 아니라 "설정하거나 고쳐서 상태를 만들라"는 과제로 쓴다.
결과를 파일에 저장하게 할 때는 출력 하나만 요구한다. 이 형식은 기존 `sn-08`에도 있다.
개념 설명은 문제가 아니라 `answer.md`에 넣는다.

| ID | 개념 | 과제 | 채점 | 공식 근거 |
|---|---|---|---|---|
| N1 | Pod 네트워크 모델과 node 안 경로 | 지정한 Pod로 가는 route를 node에서 찾아 지정 파일에 저장한다. | 파일 내용이 그 node의 실제 route와 같다. | [Services, Load Balancing, and Networking](https://kubernetes.io/docs/concepts/services-networking/), [Cluster Networking](https://kubernetes.io/docs/concepts/cluster-administration/networking/) |
| N2 | CNI 설정과 plugin 위치 | node의 CNI 설정(`/etc/cni/net.d`)에서 사용 중인 IPAM plugin 이름을 찾아 지정 파일에 저장한다. 장애 복구는 기존 `ts-14`가 다룬다. | 파일 내용이 설정 파일의 IPAM type과 같다. | [Network Plugins](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/) |
| N3 | Service와 EndpointSlice | Service 요청이 실패한다. 원인은 Pod readiness 실패로 EndpointSlice의 endpoint가 not ready인 것이다. 원인을 찾아 고친다. 기존 문제의 원인(`sn-07` targetPort, `ts-03` selector, `ts-15` kube-proxy·CNI)과 겹치지 않는다. | EndpointSlice에 ready endpoint가 있고, 실제 HTTP 요청이 성공한다. | [Virtual IPs and Service Proxies](https://kubernetes.io/docs/reference/networking/virtual-ips/), [Debug Services](https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/) |
| N4 | headless Service와 Pod DNS | StatefulSet과 headless Service를 만든다. 지정 Pod의 DNS 이름을 지정 파일에 저장한다. 분산 job이 서로를 찾는 방식의 기초다. | 리소스가 요구대로 있고, Pod별 DNS 이름이 실제로 풀린다. | [DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/) |
| N5 | hostNetwork Pod | port 충돌로 `Pending`인 `hostNetwork: true` Pod를 Running으로 만든다. 다른 workload는 바꾸지 않는다. | Pod가 Running이고, node의 network namespace에서 지정 port가 응답한다. | [Pod API: hostNetwork](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/) |
| N6 | source IP와 `externalTrafficPolicy` | client의 원래 source IP가 보존되도록 지정 Service를 설정한다. | `externalTrafficPolicy`가 `Local`이고, 응답에 담긴 client IP가 Pod 밖 client의 IP와 같다. | [Using Source IP](https://kubernetes.io/docs/tutorials/services/source-ip/) |

- ID는 기존 규칙을 따른다. 개념 문제는 `sn-11`부터, 장애 진단은 `ts-16`부터 붙인다.
- 각 문제는 기존 연습 문제와 같은 파일 묶음을 갖는다. `answer.md`에는 개념 설명과 공식 문서
  링크를 넣는다.
- N1·N2는 node shell이 필요하다. 기존 `ssh <node>` 래퍼로 접속한다.
- N6의 채점은 클러스터 밖 client의 IP가 Pod까지 보존되어야 성립한다. 2026-11-04 v1.37 공유
  클러스터에서 실험했다. lab host에서 NodePort로 요청하면 `Cluster`일 때 Pod는 node IP를 보고,
  `Local`일 때 host IP를 그대로 본다. local endpoint가 없는 node에서는 응답이 없었다. 그래서
  N6는 LoadBalancer 대신 NodePort와 host의 `curl`로 채점한다.

### B-3. CKA 이후로 연기하는 GPU 네트워크 확장

다음 주제는 GPU 인프라의 기초이지만 CKA 공식 역량 목록에 없다. CKA 준비 시간을 빼앗지 않게
CKA 응시 뒤에 다시 검토한다.

| ID | 개념 | 연기 이유 | 공식 근거 |
|---|---|---|---|
| X1 | 다중 network interface (Multus, `NetworkAttachmentDefinition`) | CKA 범위 밖이다. kind에서 Multus와 macvlan이 동작하는지도 아직 확인하지 않았다(미확인). | [Multus CNI](https://github.com/k8snetworkplumbingwg/multus-cni) |
| X2 | 통신 interface 선택 (NCCL의 `NCCL_SOCKET_IFNAME`) | CKA 범위 밖이다. X1이 먼저 필요하다. | [NCCL 환경 변수](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/env.html) |
| X3 | GPU 클러스터 보조 네트워크 구성 (NVIDIA Network Operator, SR-IOV, IPoIB) | CKA 범위 밖이다. 실제 NIC가 필요해 실습 환경에서 재현할 수 없다고 판단한다. | [NVIDIA Network Operator v26.7.0](https://docs.nvidia.com/networking/display/kubernetes2670/index.html) |
| X4 | MTU 불일치 같은 overlay 장애 | 공식 출처를 아직 확인하지 않았다(출처 미확인). | — |

### B-W. 작업 순서

| 작업 | 내용 | 해결 대상 | 선행 조건 |
|---|---|---|---|
| B-W1 | N3·N4·N5 작성(API 과제, 공유 클러스터) | G3 | 없음 |
| B-W2 | N1·N2 작성(node shell, 공유 클러스터) | G3 | 없음 |
| B-W3 | kind에서 source IP 보존 실험 후 N6 작성 | G3 | 없음 |
| B-W4 | curriculum registry와 테스트에 새 문제 반영 | G2 | B-W1~B-W3 |

## 4. 두 트랙의 관계

- 트랙 B의 연습 문제는 `questions/`에, 트랙 A의 시험 문제는 `exam/bank/`에 둔다. 두 디렉터리를
  섞지 않는다.
- 시험 form을 만들 때 트랙 B 문제를 그대로 쓰지 않는다. 같은 개념을 다른 상황으로 바꾼
  새 문제를 쓴다.

## 5. CKA 기준 범위 점검

판정 기준은 "CKA 공식 역량 목록에 있는가"와 "CKA 합격 판단에 필요한가"다. 판정 자체는
이 프로젝트의 판단이다.

| ID | 항목 | 판정 | 조치 |
|---|---|---|---|
| A-0 | private 저장소·암호화 archive·노출 경로 차단(A-D6) | 제거 | 사용자 결정(2026-11-05). 개인 학습용이므로 저장소 평문과 "열지 않는다" 규칙으로 충분하다. |
| A-1 | 운영자·후보자 OS 계정 분리 | 제거 | 개인 학습에는 "열지 않는다" 규칙으로 충분하다. Colima·웹 UI 운영 비용만 는다. |
| A-2 | 시험 form 4개(A·B·C + 예비 D, 68문항) | 축소 | form A·B(34문항)만 만든다. 세 번째 처음 보는 시험은 Killer.sh가 맡는다. |
| A-3 | ledger의 `RESERVED` 상태, 은행 lock, fsync, private 저장소 이중 기록 | 축소 | 사용자 한 명이 순서대로 쓰므로 `AVAILABLE`/`EXPOSED` 두 상태와 "출력 전 기록"만 둔다. |
| A-4 | grader 검증의 모든 오답 조합과 풀이 순서 변경 검사 | 축소 | 오답 표본 1개와 대안 풀이 1개만 검증한다. |
| A-5 | 결과에 은행 revision, form hash, 정책 버전 기록 | 제거 | 도메인별 점수와 blind 여부만 남긴다. 둘은 준비 기준 판정에 필요하다. |
| A-6 | 도메인별 배점 ±5%p 제약 | 제거 | 문항 수 5/4/3/3/2로 충분하다. |
| A-7 | shell history·임시 파일 노출 차단 | 제거 | 우발적 노출 가능성이 낮다. |
| A-8 | node 수준·Helm 문제 실행 확장(A-W4) | 유지 | etcd snapshot, kubeadm upgrade, kubelet 장애, Helm 설치는 CKA 공식 역량이다. 없으면 시험 form이 30%+25% 도메인을 약하게 측정한다. |
| A-9 | SSH runner의 `cka-use-context` 단계를 실제 시험 흐름으로 바꾸는 작업 | 제거 | 문제 풀이 능력과 관계없는 절차 차이다. 8절 한계 6에 적고 runner는 바꾸지 않는다. |
| B-1 | Multus·NCCL·Network Operator·MTU (X1~X4) | 연기 | CKA 공식 역량 목록에 없다. CKA 응시 뒤 다시 검토한다. |
| B-2 | kube-proxy mode 전환용 일회용 셀 | 제거 | 공유 클러스터에서 현재 mode의 규칙만 관찰한다(N3). |
| B-3 | CNI 설정 장애 복구 문제 | 축소 | 기존 `ts-14`와 겹친다. N2는 값 하나를 찾아 저장하는 과제로 둔다. |
| B-4 | 새 셀 profile `network-cell` | 제거 | N1~N6은 공유 클러스터에서 풀 수 있게 만든다. |

## 6. 결정 요청

남은 결정은 없다. 저장 위치, 작성자·열람 규칙, 정답 공개 시점은 A-D1로 정해졌다. 준비 기준
변경(A-D8)은 사용자가 "전체 다 해"로 권장안 진행을 지시해 2026-11-06에 적용했다(A-W6).

## 7. 바로 할 수 있는 일

A-W0~A-W6과 B-W1~B-W4가 모두 끝났다(1절 앞의 구현 상태 참조). 다음 일은 사용자가 form A와
form B를 `cka exam-ssh prepare --form A`·`--form B`로 blind 상태에서 푸는 것이다.

## 8. 한계와 위험

1. **node 수준 문제의 범위(트랙 A).** A-W4로 Helm과 `kubectl debug node`를 쓰는 문제는 시험
   form에 넣을 수 있다. 그러나 kubelet이 멈춘 node에는 debug Pod를 띄울 수 없고, kubeadm
   재구성은 공유 클러스터에서 할 수 없다. 그래서 시험 form은 이 두 영역(Troubleshooting의 node
   장애, Cluster Architecture의 kubeadm lifecycle)을 측정하지 못한다. 이 영역은 연습 셀
   (`ts-05`, `ts-14`, `ca-06`, `ca-11`, `ca-12`)과 Killer.sh로 확인한다.
2. **같은 작성자.** 시험 문제도 Claude가 만든다. 문제 표현과 난이도가 실제 시험과 다를 수
   있다. 외부 검증으로 Killer.sh simulator가 계속 필요하다.
3. **"열지 않는다" 규칙에만 의존한다.** 시험 문제는 public 저장소에 평문으로 있다. 사용자와
   다른 누구든 언제든 볼 수 있다. blind 여부는 사용자가 규칙을 지키는지에 달려 있다.
4. **실행 host.** `cka exam-ssh`는 systemd user manager와 login linger를 요구한다. Colima
   Ubuntu VM에서 이 runner를 실행한 기록은 아직 없다(미확인).
5. **GPU 네트워크는 기초까지만.** 트랙 B는 CKA 범위의 Kubernetes 네트워크 기초만 다룬다.
   RDMA·InfiniBand·SR-IOV 같은 GPU 전용 네트워크는 다루지 않는다.
6. **문항 진입 절차의 차이(트랙 A).** 공식 지침은 문항마다 `ssh <nodename>`으로 지정 host에
   접속하게 안내한다([중요 지침](https://docs.linuxfoundation.org/tc-docs/certification/tips-cka-and-ckad)).
   현재 SSH runner는 그 뒤에 이 저장소만의 `cka-use-context <qid>`를 한 번 더 요구한다. 시험
   문제 본문은 이 명령을 문항 안내 줄에 적고, 풀이 자체는 이 명령에 기대지 않게 쓴다.
