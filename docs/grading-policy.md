# 로컬 채점 정책 (Grading Policy)

이 문서는 cka-practice의 grader와 모의고사 판정 규칙을 정의한다. 이는 CKA (Certified
Kubernetes Administrator)의 비공개 공식 채점 구현을 설명하는 문서가 아니다. 공식적으로
확인되는 합격선은 66%이며 근거는
[Linux Foundation FAQ](https://docs.linuxfoundation.org/tc-docs/certification/faq-cka-ckad-cks)다.

## 원칙

1. **결과 기반**: 실행한 명령 자체가 아니라 클러스터 리소스 또는 제출 파일의 최종 상태를
   검사한다.
2. **criterion별 부분 점수**: 문제 요구사항을 독립 criterion으로 나누고 각 항목의 배점을
   더한다.
3. **스펙과 실제 동작을 함께 검사**: 가능한 문제는 필드 비교 외에 HTTP (Hypertext Transfer
   Protocol), DNS (Domain Name System), 권한, Pod readiness 등을 실제로 확인한다.
4. **정확한 관계 검사**: 배열 값은 exact token으로, 연관 필드는 같은 배열 원소의 tuple로
   비교해 substring 또는 서로 다른 원소 조합의 오탐을 줄인다.
5. **후보자 오답과 인프라 장애 분리**: `PASS`, `FAIL`, `INVALID`의 세 상태를 사용한다.
6. **채점 중 자동 복구 금지**: grader는 누락된 애드온이나 클러스터를 복구하지 않는다.
   복구가 필요한 상태는 후보자의 0점과 섞지 않고 `INVALID`로 처리한다.

구현 기준은 [`lib/grader.sh`](../lib/grader.sh), 계약 검증은
[`tests/contract-test.sh`](../tests/contract-test.sh)에 있다.

## 세 가지 결과

| 결과 | 의미 | 문제 상태 기록 |
|---|---|---|
| `PASS` | 모든 criterion을 만족해 만점을 얻음 | `graded:<earned>/<max>` |
| `FAIL` | grader는 정상 실행됐지만 하나 이상의 criterion을 만족하지 못함 | `graded:<earned>/<max>` |
| `INVALID` | API (Application Programming Interface), `kubectl`, 공용 grader client 등 채점 인프라가 유효하지 않음 | `invalid:<reason>` |

`INVALID`는 0점 답안이 아니다. 개별 채점에서는 원인을 고친 뒤 다시 채점하고, 모의고사
final grading 중 하나라도 유효한 수치 결과를 만들지 못하면 run 전체를 `INVALID`로 판정한다.
감독형 `cka exam-ssh`는 deadline seal이 확인된 유효 점수에 별도 verdict `TIMEOUT`을 사용하며,
이는 항상 비통과다.

## 검증 helper

| 검증 유형 | helper | 예 |
|---|---|---|
| 리소스 존재 | `res_exists` | PV (PersistentVolume), PVC (PersistentVolumeClaim), Role 존재 |
| 스칼라 필드 | `jp_eq`, `jp_contains` | 이미지, replica, probe 값 |
| 배열·관계 | `jp_array_has`, `jp_array_count`, `jp_relation_has` | exact token, 같은 원소의 field tuple |
| 워크로드 상태 | `deploy_ready`, `pod_running`, `pod_ready` | Ready replica, Pod phase/condition |
| Service 연결성 | `svc_has_endpoints`, `http_ok`, `http_body_contains` | ready EndpointSlice, 응답 본문 |
| NetworkPolicy | `http_ok_from`, `http_denied_from` | 허용 요청 성공, 차단 요청의 network timeout |
| Ingress | `ingress_ok` | Host header와 path로 실제 요청 |
| DNS | `dns_resolves`, `dns_baseline_from` | 명령 성공과 기대 주소, 채점 인프라 baseline |
| RBAC (Role-Based Access Control) | `can_i`, `cannot_i` | `kubectl auth can-i --as ...` |
| 제출 파일 | `file_exists`, `file_exact_command_output`, `file_exact_nonblank_command_output` | 전체 stdout 또는 비어 있지 않은 행의 정확한 결과 |
| 노드 상태 | `node_ready`, `node_schedulable`, `node_drained`, `node_exec` | Ready, cordon/drain, 노드 내부 상태 |

RBAC 검사처럼 약어가 포함된 세부 동작은 Kubernetes 공식 문서의
리소스 의미를 따른다:
[Kubernetes Authorization](https://kubernetes.io/docs/reference/access-authn-authz/authorization/),
[JSONPath 지원](https://kubernetes.io/docs/reference/kubectl/jsonpath/).

### negative HTTP 판정

`http_denied*`는 단순히 명령이 실패했다고 통과시키지 않는다. source Pod와 grader client가
실행 가능하고, DNS baseline과 대상 Service endpoint가 정상인지를 먼저 확인한 뒤
network timeout, unreachable, no route와 같은 네트워크 차단 결과만 성공으로 인정한다.
따라서 오타, 존재하지 않는 Service, connection refused, `kubectl exec` 실패를
NetworkPolicy 정답으로 오인하지 않는다.

`sn-10`은 `namespaceSelector`와 `podSelector`가 같은 peer에 있을 때 두 selector의 교집합을
정확히 검사하고, 허용·차단 ingress와 egress를 실제 요청으로 확인한다. 이 결합 의미는
[Kubernetes NetworkPolicy 공식 문서](https://kubernetes.io/docs/concepts/services-networking/network-policies/)를
기준으로 한다.

`sn-09`는 Service spec과 EndpointSlice만 보지 않는다. setup이 준비한 독립 sentinel로
Cloud Provider KIND와 LoadBalancer 데이터 경로의 건강 상태를 먼저 확인하며, 후보 Service에
외부 주소가 할당되고 그 주소의 HTTP (Hypertext Transfer Protocol) 응답이 기대 workload에
도달해야 점수를 준다. provider 또는 sentinel 자체가 깨진 경우 후보자의 0점과 섞지 않고
`INVALID`로 처리한다. 로컬 구현체의 공식 사용법은
[kind LoadBalancer 문서](https://kind.sigs.k8s.io/docs/user/loadbalancer/)에서 확인할 수 있다.

DNS 제출 문제는 resolver가 출력한 서버 주소만 보고 성공으로 판정하지 않는다. 명령이
성공하고 기대 Service 주소가 응답에 포함되어야 한다. BusyBox `nslookup`처럼 버전에 따라
빈 줄 위치만 달라질 수 있는 출력은 비어 있지 않은 모든 행의 내용과 순서를 정확히
비교한다.

Gateway API route는 `parentRefs`의 listener와 port, backend namespace/weight, Gateway의
`allowedRoutes` kind 및 namespace 정책까지 함께 검사한다. etcd restore 문제는 복원
디렉터리 모양만 보지 않는다. setup source의 SHA-256 (Secure Hash Algorithm 256-bit)과
revision/key 수를 보존하고, grader 전용 기준 복원본과 후보 복원본을 각각 기동한다. 이때
기동한 process가 probe port를 실제 소유하는지도 확인한 뒤 endpoint health와
KV (Key-Value) hash/revision을 비교한다.

일회용 문제의 grader는 공유 `kind-cka` context를 거부하고, immutable cell manifest가
가리키는 context만 사용한다. `ca-06`은 실제 package version·hold·kubelet version과 기존
resource identity를, `ca-11`은 control-plane/etcd membership과 failover 증거를,
`ca-12`는 kubeadm bootstrap 및 cross-node Service 요청을 검사한다. `ca-09`·`ca-13`은
cert-manager의 현재 `observedGeneration`, owner reference와 생성된
TLS (Transport Layer Security) Secret을 검사한다.
`sn-05`는 Envoy Gateway status뿐 아니라 독립 probe의 HTTP 응답을, `st-06`은
CSI (Container Storage Interface) driver/CSINode 등록, dynamic PV
(PersistentVolume) 관계와 실제 mount data를 검사한다. 개념 기준은 Kubernetes의
[Operator pattern](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/),
[Gateway API HTTP routing](https://gateway-api.sigs.k8s.io/guides/user-guides/http-routing/),
[CSI 배포](https://kubernetes-csi.github.io/docs/deploying.html) 공식 문서다.

일회용 셀 생성은 grader 실행 이전에 workspace host filesystem의 가용 공간을 확인하며,
10 GiB 미만이면 기본적으로 거부한다. 이는 공식 시험 또는 Kubernetes 요구사항이 아니라
이 프로젝트의 안전 정책이다. `CKA_CELL_ALLOW_LOW_HOST_SPACE=1`은 위험을 이해한 사용자의
명시적 우회이며 grader 점수나 readiness 증거를 완화하지 않는다. cleanup은 manifest에
봉인된 anonymous volume의 이름·mount destination·inspect fingerprint와 attachment를
검증한 뒤 정확히 그 generation만 삭제하며, 전역 volume prune은 실행하지 않는다.
구현 계약은 [`lib/cell.sh`](../lib/cell.sh)와
[`tests/kubeadm-cell-contract-test.sh`](../tests/kubeadm-cell-contract-test.sh)에 있다.

## 개별 문제 점수

- 문제별 만점은 `meta.yaml`의 `points`다.
- `cka grade <id>`는 criterion별 성공/실패, 획득 점수와 만점을 출력한다.
- 개별 학습에서는 상태를 수정한 뒤 반복 채점할 수 있다.
- `grade_init`은 읽기 전용 API 상태만 확인한다. 클러스터 복구는 명시적으로
  `cka cluster doctor` 또는 `cka cluster up`에서 수행한다.

## 모의고사 시작과 preflight

17문항 form은 [`exam/planner.sh`](../exam/planner.sh)가 seed와
[`exam/forms/question-catalog.tsv`](../exam/forms/question-catalog.tsv)의 compatibility
metadata를 사용해 만든다. 동일 catalog와 seed는 같은 form을 만든다. domain quota,
mutex, `breaks`와 `requires`, 문제별 enable 상태를 검사하며 setup priority로 환경 구성
순서를 정한다. 전체 52문제 중 `ts-05`, `ts-12`~`ts-15`, `ca-06`, `ca-09`,
`ca-11`~`ca-13`, `sn-05`, `st-06`은 공유 모의고사에서 비활성화하고 나머지 40문제를
후보로 사용한다. 앞의 troubleshooting 문제는 공유 상태를 손상시킬 수 있고, 뒤의 7문제는
각각 독립된 일회용 셀을 요구한다.

runner는 `PREPARING`에서 다음 절차를 모두 끝낸 뒤에만 `RUNNING`과 timer를 시작한다.

1. lock 버전, worker Ready/schedulable/taint, scheduler, 잔여 static Pod, 핵심 addon baseline 검사
2. 호환 가능한 17문항 form 생성 및 재검증
3. setup priority 순서로 17개 `setup.sh` 실행
4. 모든 `grade.sh` preflight
5. 각 결과가 `graded:<earned>/<max>` 형식인지 확인
6. grader 만점이 `meta.yaml`과 같은지, setup 직후 이미 만점은 아닌지 확인

어느 단계든 실패하면 알려진 setup을 역순 정리하고 run을 `INVALID`로 보관한다. 준비에
걸린 시간은 120분에 포함하지 않는다. teardown과 공통 resource cleanup은 개별 timeout과
run당 10분의 총 cleanup 상한을 적용하며, 완료되지 않으면 점수를 `INVALID`로 남긴다.

## 모의고사 종료 판정

정상 제출은 답안을 `SEALED`로 바꾼 뒤 `GRADING`에서 17개 문제를 다시 채점한다.

| 조건 | 최종 결과 |
|---|---|
| grader 오류 또는 유효하지 않은 점수 | `INVALID` |
| 제한시간 초과 | `FAIL` (점수가 66% 이상이어도 동일) |
| 유효·시간 내·66% 이상 | `PASS` |
| 유효·시간 내·66% 미만 | `FAIL` |

공식 CKA 합격선 66%는
[Linux Foundation FAQ](https://docs.linuxfoundation.org/tc-docs/certification/faq-cka-ckad-cks)와
같지만, 이 로컬 점수는 공식 시험 합격을 예측하거나 보장하지 않는다. 보수적인 로컬 준비
완료 조건은 [`exam/readiness-policy.yaml`](../exam/readiness-policy.yaml)에 별도로 정의된다.

결과는 `.state/exam-results/`에 timestamp가 붙은 text 파일로 저장하며 seed, 점수,
timeout 여부, 문항별 결과를 포함한다. 제출 파일이 있으면 별도 디렉터리에 복사한다.

## 시간·잠금 경계

- 기본 `cka exam` runner는 `status`, `question`, `finish` 호출 시 deadline을 확인하고 시간이
  지났으면 `SEALED`로 전환한다.
- timeout run은 언제 채점하더라도 `PASS`가 될 수 없다.
- 기본 runner는 120분 시점에 이미 열린 raw terminal process를 강제로 종료하지 않는다.
- `PREPARING`, `RUNNING`, `SEALED`, `GRADING` 동안 CLI (Command-Line Interface)와 웹은 `start`, `grade`,
  `solution`, `reset`, 클러스터 변경을 막는다.
- 이 잠금은 애플리케이션 수준 보호다. 별도 운영체제 사용자, 저장소 answer 파일,
  직접 실행한 script까지 격리하는 보안 sandbox는 아니다.
- 별도 opt-in [`cka exam-ssh`](../exam/ssh/)는 34개 Kubernetes API-safe shared 문제에서
  17개 form을 만들고, 실제 base→target SSH (Secure Shell)와 systemd timer·guard를 사용한다. systemd user
  manager와 login linger를 검증하지 못하면 시작하지 않으며 감독 없는 fallback은 없다.
- 감독형 runner는 immutable seal proof가 있어야 허용 답안 수집과 host grader를 호출한다.
  deadline seal은 점수와 관계없이 `TIMEOUT`으로 비통과 처리한다. systemd transient unit의
  공식 동작은 [`systemd-run`](https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html)을
  기준으로 한다.

## 알려진 실습 한계

- 실측 검증은 비동기 Kubernetes 상태에 의존하므로, 개별 학습에서는 rollout이 끝난 뒤
  다시 채점해야 할 수 있다. grader 기반 인프라가 없으면 점수 대신 `INVALID`다.
- `ts-05`와 `ts-12`는 worker kubelet 또는 scheduler 장애가 공유 form 전체에 영향을 줄
  수 있어 개별 연습 전용이다. `ts-13`~`ts-15`도 control plane, CRI (Container Runtime
  Interface), CNI (Container Network Interface), kube-proxy를 손상시키는 종합 장애라
  같은 이유로 개별 연습 전용이다.
- `ca-06`, `ca-09`, `ca-11`~`ca-13`, `sn-05`, `st-06`은 공유 form과 격리된 일회용
  cell을 사용하므로 개별 연습 전용이다. package·controller·CSI image cache가 없거나
  checksum/digest가 다르면 setup을 중단한다.
- HA (High Availability) cell은 한 host 위의 container topology다. kubeadm과
  stacked-etcd quorum·API failover는
  연습하지만 production failure domain을 재현하지 않는다. Kubernetes 공식 HA topology는
  [kubeadm HA 문서](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/)를
  기준으로 한다.
- cluster-free 정적·계약 검사와 `ca-06`, `ca-09`, `ca-11`~`ca-13`, `sn-05`, `st-06`의
  Docker live gate가 통과했다. 실제 kubeadm lifecycle·failover, controller reconcile,
  Gateway·CSI data path를 채점했고 모든 일회용 resource의 exact cleanup도 통과했다.
- user systemd preflight와 보조
  [`tests/ssh-supervisor-docker-smoke.sh`](../tests/ssh-supervisor-docker-smoke.sh),
  [`tests/ssh-runner-docker-smoke.sh`](../tests/ssh-runner-docker-smoke.sh)가 통과했다.
  2026-08-23 clean Ubuntu 24.04 WSL2 (Windows Subsystem for Linux 2)의 실제 17문항
  unattended gate도 104/104 채점 가능 상태, deadline `TIMEOUT`, guard kill·restart, 실제
  base→target SSH, collect·grade와 exact cleanup을 모두 검증했다. 종료 후 관련 KIND
  (Kubernetes IN Docker) cluster·container·network·volume은 0개였다. 따라서 저장소 구현
  상태는 `practice-ready-live-complete`이며 개인 학습 준비 기준은
  [`readiness-policy.md`](readiness-policy.md)를 따른다.
