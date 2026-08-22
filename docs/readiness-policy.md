# Certified Kubernetes Administrator (CKA) 준비 완료 정책

이 문서는 [`exam/readiness-policy.yaml`](../exam/readiness-policy.yaml)의 학습 기준과
[`curriculum/cka-v1.35.yaml`](../curriculum/cka-v1.35.yaml)의 구현 검증 gate를 사람이
실행할 수 있는 형태로 정리한다. Linux Foundation의 공식 합격 판정이나 합격 보장이 아니다.

공식 CKA 합격선은 66%이고, 모든 과제는 문항에 지정된 SSH (Secure Shell) host에서
수행한다. 이 프로젝트의 80%·도메인별 65%·3회 blind run 기준은 공식 기준보다 보수적으로
정한 로컬 정책이다.

공식 근거:
[Linux Foundation FAQ](https://docs.linuxfoundation.org/tc-docs/certification/faq-cka-ckad-cks) ·
[CKA·Certified Kubernetes Application Developer (CKAD) 중요 지침](https://docs.linuxfoundation.org/tc-docs/certification/tips-cka-and-ckad) ·
[CKA 상품 페이지](https://training.linuxfoundation.org/certification/certified-kubernetes-administrator-cka/)

## 현재 implementation validation 상태

저장소 구현 검증 상태는 `practice-ready-live-complete`다. cluster-free 정적·계약·장애
주입 검사가 통과했고, 2026-08-22에는 kubeadm, Operator·Gateway, CSI (Container Storage
Interface)의 모든 열거된 일회용 문제를 실제 Docker 환경에서 검증해 각 실행의 resource
cleanup까지 통과했다. 2026-08-23에는 clean Ubuntu 24.04 WSL2 (Windows Subsystem for
Linux 2)에서 감독형 SSH (Secure Shell) 17문항 end-to-end gate도 통과했다. 이 상태는
저장소의 구현·live 검증 완료를 뜻하며 Linux Foundation의 공식 합격 보장이나 개인의 학습
준비 완료 판정이 아니다.

| curriculum 필수 suite | 범위 | 현재 상태 |
|---|---|---|
| [`tests/kubeadm-live-test.sh`](../tests/kubeadm-live-test.sh) | `ca-12` bootstrap, `ca-11` stacked-etcd HA (High Availability) failover, `ca-06` N-1→N upgrade | 통과: blank init/join, 3-control-plane 구성 후 `cp1` 중지 상태의 API (Application Programming Interface) write·Service path, 실제 v1.34→v1.35 worker upgrade와 각 cleanup |
| [`tests/operator-gateway-live-test.sh`](../tests/operator-gateway-live-test.sh) | `ca-09` reconcile, `ca-13` install, `sn-05` Envoy data path | 통과: cert-manager reconcile, offline operator install, Gateway status·HTTP (Hypertext Transfer Protocol) data path와 각 cleanup |
| [`tests/csi-live-test.sh`](../tests/csi-live-test.sh) | `st-06` CSI registration, provisioning, attachment와 data | 통과: canonical 및 의미상 동등한 대안이 각각 10/10, cleanup 통과 |
| [`tests/ssh-supervised-live-test.sh`](../tests/ssh-supervised-live-test.sh) | clean host의 실제 17문항 runner, base→target→kind (Kubernetes IN Docker), systemd deadline, `TIMEOUT`, collect·grade·cleanup | 통과: 17문항 104/104 상태에서도 무개입 deadline 후 `TIMEOUT`, guard kill·restart, 실제 base→target SSH, collect·grade, exact cleanup; 종료 후 관련 cluster·container·network·volume 0개 |

이 네 파일은 curriculum registry의 `implementationValidation.requiredLiveSuites`와 실제
workspace에 모두 존재하며 네 suite 모두 전체 gate와 cleanup을 통과했다. 앞의 세 suite는
각 suite가 열거한 모든 문제를 개별 `--only`로 검증했다. 문제 하나의 `--only` 실행이나 보조
smoke만으로 다른 문제의 gate까지 통과한 것으로 간주하지 않는다. 고정
kubeadm·controller·CSI cache도 exact 검증과 해당 live import를 통과했다. 추가 회귀
검증에서는 `ts-13`, `ts-14`, `ts-15`가 각각 setup 후 0/8, solution 후 8/8을 받았고 각
cleanup 뒤 공유 cluster의 세 node가 모두 Ready였다.

## 필수 live suite 실행

필수 opt-in 변수를 빼면 kubeadm·CSI·감독형 SSH suite는 `SKIP`과 종료코드 `77`을,
operator/Gateway suite는 오류와 비영(非零) 종료코드를 반환한다. 따라서 실행하지 않은
gate가 종료코드 `0`인 통과로 기록되지 않는다.

### kubeadm

`ca-06`용 공식 package cache를 먼저 준비한다. 전체 suite는 세 문제를 순서대로 실행하며,
host 자원이 부족하면 `--only`로 하나씩 검증할 수 있다.

```bash
bash cluster/cells/kubeadm/cache-packages.sh
CKA_ENABLE_KUBEADM_CELLS=1 CKA_RUN_KUBEADM_LIVE_TESTS=1 \
  bash tests/kubeadm-live-test.sh

# 개별 재검증 예
CKA_ENABLE_KUBEADM_CELLS=1 CKA_RUN_KUBEADM_LIVE_TESTS=1 \
  bash tests/kubeadm-live-test.sh --only ca-11
```

### Operator와 Gateway

controller asset cache는 `sn-05`의 nginx/BusyBox bundle을 재사용하므로, kubeadm
package cache를 먼저 준비한 뒤 세 profile을 각각 실행한다. controller cache는 이
선행 bundle을 네트워크 요청 전에 exact 검증한다.

```bash
bash cluster/cells/kubeadm/cache-packages.sh
bash cluster/controllers/cache-assets.sh
CKA_CONTROLLER_LIVE=1 bash tests/operator-gateway-live-test.sh --only ca-09
CKA_CONTROLLER_LIVE=1 bash tests/operator-gateway-live-test.sh --only ca-13
CKA_CONTROLLER_LIVE=1 bash tests/operator-gateway-live-test.sh --only sn-05
```

### CSI

```bash
bash cluster/csi/cache-images.sh
CKA_CSI_LIVE=1 bash tests/csi-live-test.sh
```

### 감독형 SSH 모의고사

이 gate는 기존 KIND cluster가 하나도 없는 disposable WSL (Windows Subsystem for Linux)
또는 Linux host를 요구한다. 지정-host image를 먼저 빌드하고 persistent user systemd와
login linger를 준비한다. 기존 cluster가 있으면 test가 삭제하지 않고 거부한다.

2026-08-23 별도 clean Ubuntu 24.04 WSL2에서 persistent user systemd와 login linger를
준비해 실제 17문항 전체 gate를 실행했다. form을 104/104 상태로 만든 뒤 개입하지 않아
deadline이 `TIMEOUT`을 강제하는지 확인했고, guard process를 강제로 종료한 뒤 재시작되는
경로도 통과했다. 실제 base→target 공개키 SSH, collect·grade와 exact cleanup도 통과했다.
종료 뒤 KIND cluster, 감독형 SSH container·network, kind node, `kind` network와 Docker
volume은 모두 0개였다. 기존 보호 대상 `kind-cka`는 이 별도 host 검증에 사용하지 않았다.

```bash
bash exam/ssh/build.sh
cka exam-ssh preflight --install-linger
CKA_SSH_SUPERVISED_LIVE=1 bash tests/ssh-supervised-live-test.sh
```

보조 [`tests/ssh-supervisor-docker-smoke.sh`](../tests/ssh-supervisor-docker-smoke.sh)와
[`tests/ssh-runner-docker-smoke.sh`](../tests/ssh-runner-docker-smoke.sh)도 통과했다. 이 smoke는
계속 빠른 회귀 검사용이며 위 17문항 필수 end-to-end gate의 통과 기록을 대체하지 않는다.

## 일회용 셀 host 안전 정책

[`lib/cell.sh`](../lib/cell.sh)는 셀 object 생성 전에 workspace가 있는 host filesystem을
검사하고 가용 공간이 10 GiB 미만이면 중단한다. 10 GiB는 Kubernetes·Docker의 공식
요구사항이 아니라 다중-node 셀 생성 중 host 고갈 가능성을 줄이기 위한 프로젝트 정책이다.
자체 KIND cluster를 만드는 감독형 SSH live gate도 첫 Docker object 생성 전에 같은 검사를
호출한다.
공간 부족 위험을 이해하고 명시적으로 감수할 때만 다음 override를 사용한다.

```bash
CKA_CELL_ALLOW_LOW_HOST_SPACE=1 ./cka start ca-12
```

override는 저장 공간 검사만 우회한다. identity·소유권·cleanup 검사나 readiness 기준을
완화하지 않는다. 셀 manifest는 container·network와 anonymous volume의 정확한 generation,
mount destination, inspect fingerprint를 봉인한다. cleanup은 foreign attachment나
fingerprint drift가 있으면 중단하고, 검증된 volume만 개별 삭제한다. 전역
`docker volume prune`은 사용하지 않는다. 이 동작의 정적·near-miss 계약은
[`tests/kubeadm-cell-contract-test.sh`](../tests/kubeadm-cell-contract-test.sh)가 검사한다.

Docker의 공식 명령 문서도 일반 container 삭제와 anonymous volume 삭제를 별도 동작으로
구분하며, 사용 중인 volume은 삭제할 수 없다고 명시한다:
[container rm](https://docs.docker.com/reference/cli/docker/container/rm/) ·
[volume inspect](https://docs.docker.com/reference/cli/docker/volume/inspect/) ·
[volume rm](https://docs.docker.com/reference/cli/docker/volume/rm/) ·
[container ls volume filter](https://docs.docker.com/reference/cli/docker/container/ls/).

## “준비 종료” 선언 조건

다음을 모두 만족해야 한다.

1. curriculum의 모든 역량이 `covered`이고 위 네 required live suite가 전체 통과한다.
2. 유효한 blind run을 3회 완료하며, 매번 총점 80% 이상·각 도메인 65% 이상·초과시간
   0초를 만족한다. `INVALID`와 overtime run은 횟수에 포함하지 않는다.
3. 실제 지정-host workflow를 사용한다.
4. 등록 상품에 제공되는 외부 공식 simulator를 통과한다.

현재 네 required live suite는 모두 통과해 저장소 구현·live gate는 완료됐다. 다만 개인이
2~4번 조건을 충족했다는 증거는 별도이므로, 이 repository 상태만으로 공식 CKA 합격이나
개인 학습의 “준비 종료”를 선언하지 않는다.
