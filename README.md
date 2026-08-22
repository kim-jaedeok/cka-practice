# cka-practice — Certified Kubernetes Administrator (CKA) 로컬 연습 환경

CKA 수행형 시험을 준비하기 위한 로컬 연습 시스템.
[kind (Kubernetes IN Docker)](https://kind.sigs.k8s.io/) 로컬 클러스터에 문제 상황을 자동 구성하고, 영어 지문으로 풀이한 뒤
클러스터 상태 기반 자동 채점과 모의고사를 실행한다.

- 문제 52개 (Cluster Architecture 13 / Workloads 8 / Services & Networking 10 / Storage 6 / Troubleshooting 15)
- 문제별 정답지 + 한국어 해설 (`answer.md`)
- 모의고사 모드: seed 기반의 catalog상 호환 가능한 17문항 form + 2시간 타이머 + 성적표
- 공식 v1.35 역량과 로컬 커버리지를 추적하는 [`curriculum/cka-v1.35.yaml`](curriculum/cka-v1.35.yaml)
- 시험 정보: [docs/exam-overview.md](docs/exam-overview.md) · 채점 방식: [docs/grading-policy.md](docs/grading-policy.md) · 준비 완료 기준: [docs/readiness-policy.md](docs/readiness-policy.md)

> 이 환경의 문제를 모두 풀거나 로컬 모의고사를 통과하는 것만으로 CKA 합격이 보장되지는 않는다.
> 현재 공식 CKA는 Kubernetes v1.35 기반의 2시간 수행형 시험이며 합격선은 66%다.
> 공식 정보: [CKA 시험 페이지](https://training.linuxfoundation.org/certification/certified-kubernetes-administrator-cka/) ·
> [Linux Foundation FAQ](https://docs.linuxfoundation.org/tc-docs/certification/faq-cka-ckad-cks)

## 요구사항

- Windows + WSL2 (Windows Subsystem for Linux 2, Ubuntu) — **모든 명령은 WSL 안에서 실행**
- WSL 안에 Docker(실행 중), kind, kubectl (`helm`은 셋업이 자동 설치)
- 공유 3노드 kind 클러스터와 일회용 셀을 실행할 수 있는 호스트 자원

클러스터 의존성은 [`cluster/versions.lock.yaml`](cluster/versions.lock.yaml)에 고정되어 있다.
셋업은 kind 버전과 기존 노드 이미지가 lock과 다르면 자동으로 덮어쓰지 않고 실패한다.
lock에 기록된 각 프로젝트의 공식 릴리스:
[kind v0.31.0](https://github.com/kubernetes-sigs/kind/releases/tag/v0.31.0),
[etcd v3.6.6](https://github.com/etcd-io/etcd/releases/tag/v3.6.6),
[Calico v3.32.1](https://github.com/projectcalico/calico/releases/tag/v3.32.1),
[metrics-server v0.9.0](https://github.com/kubernetes-sigs/metrics-server/releases/tag/v0.9.0),
[ingress-nginx controller-v1.15.1](https://github.com/kubernetes/ingress-nginx/releases/tag/controller-v1.15.1),
[Gateway API (Application Programming Interface) v1.6.0](https://github.com/kubernetes-sigs/gateway-api/releases/tag/v1.6.0),
[Cloud Provider KIND v0.11.1](https://github.com/kubernetes-sigs/cloud-provider-kind/releases/tag/v0.11.1),
[Helm v3.21.4](https://github.com/helm/helm/releases/tag/v3.21.4).

`ca-06`, `ca-09`, `ca-13`, `sn-05`, `st-06`은 시험 중 네트워크를 사용하지 않도록
공식 패키지·manifest·image를 checksum과 digest로 고정한 로컬 cache를 요구한다. 인터넷이
되는 신뢰할 수 있는 준비 단계에서 한 번 실행한다. 현재 고정 bundle은 `linux/amd64`용이다.

```bash
bash cluster/cells/kubeadm/cache-packages.sh
bash cluster/controllers/cache-assets.sh
bash cluster/csi/cache-images.sh
```

일회용 셀을 만들기 전에는 workspace가 놓인 host filesystem의 가용 공간을 확인한다.
10 GiB 미만이면 생성 전에 중단한다. 10 GiB는 Kubernetes나 Docker의 공식 요구사항이 아닌
이 프로젝트의 보수적인 안전 기준이다. 공간 부족 위험을 직접 감수할 때만
`CKA_CELL_ALLOW_LOW_HOST_SPACE=1 ./cka start <id>`로 명시적으로 우회할 수 있다.
정리 과정은 전역 `volume prune`을 사용하지 않고 manifest에 봉인된 anonymous volume의
정확한 identity·mount destination·inspect fingerprint와 attachment 부재를 다시 검증한 뒤
그 volume만 삭제한다. 구현과 계약은 [`lib/cell.sh`](lib/cell.sh)와
[`tests/kubeadm-cell-contract-test.sh`](tests/kubeadm-cell-contract-test.sh)에 있다.

## 시작하기

```bash
# WSL에서
cd /mnt/c/Users/<you>/Desktop/cka-practice

# 1회: 클러스터 + 애드온 설치: Calico, metrics-server, ingress-nginx,
# Gateway API Custom Resource Definition (CRD), Cloud Provider KIND
./cka cluster up

# 편의: PATH에 등록 (선택)
echo "alias cka='$(pwd)/cka'" >> ~/.bashrc && source ~/.bashrc
```

> WSL은 유휴 상태나 재시작 후 클러스터 컨테이너가 중지될 수 있습니다.
> 연습 중에는 WSL 터미널을 하나 열어두세요. 재시작 뒤에는
> `./cka cluster up`을 실행하세요. 이 명령은 기존 세 노드의 전체 ID와 소유권을
> 확인한 뒤 `worker → control-plane → worker2` 순서로 복구하며, 일반 채점 경로는
> 클러스터 상태를 변경하지 않습니다.

## 문제 풀이 흐름

```bash
cka list                  # 52문제 목록 + 진행 상태
cka start ts-03           # 문제 환경 구성 + 영어 지문 표시
# ... kubectl로 직접 풀이 ...
cka grade ts-03           # 자동 채점: 기준별 ✓/✗ + 부분 점수
cka solution ts-03        # 정답지 + 한국어 해설
cka reset ts-03           # 환경 초기화 후 재도전
```

파일 제출형 문제(로그 추출 등)의 답안 파일은 `~/cka/<문제id>/`에 저장한다.

### 노드 접속 — SSH (Secure Shell) 모양의 래퍼

kind 노드에는 `sshd`가 없기 때문에 기본 개별 연습의 `bin/ssh` 래퍼가 명령을
`docker exec` 또는 선택된 일회용 셀의 shell로 변환한다. 공식 시험에서는 모든 과제를
지정 호스트에 SSH로 접속해 수행한다:
[Linux Foundation 공식 중요 지침](https://docs.linuxfoundation.org/tc-docs/certification/tips-cka-and-ckad).

```bash
ssh cka-worker                        # 노드 셸 진입
ssh cka-control-plane systemctl status kubelet   # 원격 명령 1회 실행
ssh worker2                           # 접두사 생략 가능 (= cka-worker2)
```

일회용 문제를 `cka start`하면 해당 셀이 active cell로 선택된다. `ca-06`, `ca-11`,
`ca-12`에서는 `ssh cp1`, `ssh cp2`, `ssh worker1` 같은 별칭이 검증된 container identifier에
연결된다. controller·storage 문제에서는 지문에 지정된 `ssh operator-admin`,
`ssh gateway-admin`, `ssh st06-admin`이 그 셀의 전용 kubeconfig가 설정된 shell을 연다.
`cka cleanup <id>`가 셀과 선택 정보를 함께 정리한다.

- `./cka cluster up`(또는 `./cka cluster doctor`)이 `~/.bashrc`에 PATH 한 줄을
  등록한다 — **등록 후 새로 연 셸부터** 적용된다. `cka web` 터미널은 즉시 적용.
- 공유 클러스터나 검증된 active cell의 별칭이 아닌 호스트는 원래의 `ssh`로 위임되므로,
  평소 쓰던 SSH 접속에는 영향이 없다.

실제 `base → cka-target` 공개키 SSH를 쓰는 감독형 모드는 아래 `cka exam-ssh`에서
별도로 제공한다. 기본 개별 연습·`cka exam`과 달리 후보자 container에 Docker socket,
저장소, grader를 노출하지 않는다.

## 웹 UI (User Interface) 스플릿 뷰 (지문이 안 가려지게)

터미널 하나로 풀면 명령을 칠수록 지문이 위로 밀려 가려진다. 웹 UI는
**왼쪽 = 문제 지문·버튼, 오른쪽 = 실제 터미널**로 화면을 나눠 이 문제를 해결한다.

```bash
cka web                   # http://localhost:7681 (기본 포트)
cka web 8090              # 포트 지정 (터미널은 자동으로 8091)
```

- 최초 실행 시 터미널 서버(ttyd) 정적 바이너리를 `~/.local/bin`에 자동 설치한다.
- Windows 기본 브라우저가 자동으로 열린다 (안 열리면 위 URL (Uniform Resource Locator)에 직접 접속).
- 왼쪽에서 문제를 고르고 **Start / Grade / Solution / Reset** 버튼으로 조작하며,
  오른쪽 터미널은 지금과 똑같은 실제 bash 셸(`cka`가 PATH에 등록됨)이라 kubectl로 직접 푼다.
- 「모의고사」 탭에서 17문제 타이머 세션도 웹에서 진행할 수 있다.
- 두 포트 모두 `127.0.0.1`에만 바인딩된다(외부 노출 없음). 종료는 `Ctrl-C`.

## 모의고사 (실전 리허설)

```bash
cka exam                  # 17문제 샘플링 + 일괄 환경 구성 + 2시간 타이머 시작
cka exam status           # 남은 시간 · 문제 목록
cka exam question 3       # 3번 문제 지문
cka exam finish           # 채점 → 성적표 (총점/도메인별/합격 판정)
cka exam abort            # 중단
```

- 동일한 `--seed`는 동일한 catalog에서 같은 form을 만든다. planner는 도메인 할당량과
  문제 간 mutex/breaks/requires 조건을 검사하고 setup 순서를 별도로 계산한다. node drain과
  단독 Pod처럼 풀이 순서에 따라 서로 손상되는 조합도 제외한다.
- node Ready/schedulable, scheduler, static Pod 잔존, 핵심 addon baseline과 모든 setup,
  전체 grader preflight가 성공해야 시간이 시작된다. 준비 실패는 점수가 아니라
  `INVALID`로 보관된다.
- 상태는 `PREPARING → RUNNING → SEALED → GRADING → ARCHIVED`로 전이하며,
  준비 또는 채점 인프라 오류는 `INVALID`로 분리한다.
- 제한시간이 지난 run은 점수가 66% 이상이어도 합격 처리하지 않는다. 다만 현재 구현은
  다음 `cka exam status/question/finish` 호출 때 deadline을 확인해 봉인하며, 이미 열려 있는
  raw 터미널 프로세스를 강제로 종료하지는 않는다.
- 52문제 중 40문제가 공유 모의고사 후보이다. `ts-05`, `ts-12`~`ts-15`는 공유 상태를
  손상시킬 수 있고, `ca-06`, `ca-09`, `ca-11`~`ca-13`, `sn-05`, `st-06`은 각자
  독립된 일회용 셀을 요구하므로 공유 form에서 제외한다. 이 12문제는 개별 연습 전용이다.

### 감독형 지정-host SSH 모의고사 (opt-in)

`cka exam-ssh`는 실제 `sshd`가 있는 `base → cka-target` 경로와 host-side 자동 감독기를
연결한다. 공유 클러스터에서 Kubernetes API (Application Programming Interface)만으로
풀 수 있는 34문항을 허용 목록으로 사용하고, 그중 호환 가능한 17문항 form을 만든다.

```bash
bash exam/ssh/build.sh                  # base·target image 1회 빌드
cka exam-ssh preflight --install-linger # 필요할 때만 1회 권한 설정
cka exam-ssh prepare --seed rehearsal-1
cka exam-ssh start
cka exam-ssh enter                      # base 진입 후: ssh cka-target
cka exam-ssh question 1
cka exam-ssh seal
cka exam-ssh collect
cka exam-ssh grade
cka exam-ssh cleanup
```

- 이 모드는 PID (Process Identifier) 1이 systemd이고 persistent user manager와 login
  linger가 동작할 때만
  시작한다. `preflight`가 실패하면 감독 없는 timer로 대체하지 않는다. `--install-linger`는
  `sudo loginctl enable-linger`가 필요한 명시적 1회 단계다.
- systemd timer와 재시작 가능한 guard가 제한시간에 base와 target을 중지한다. 유효한
  seal proof가 있어야 허용된 답안 파일 회수와 host grader 호출이 가능하다.
- deadline으로 봉인된 run은 점수가 66% 이상이어도 `TIMEOUT`, 즉 비통과다.
- node shell, etcd, kubeadm, static Pod, Helm 또는 일회용 셀이 필요한 문제는 34문항
  허용 목록에 포함하지 않는다. 자세한 경계는 [`exam/ssh/README.md`](exam/ssh/README.md)를
  따른다.

66%는 공식 합격선이지만 로컬 준비 완료 기준은 더 보수적으로
[`exam/readiness-policy.yaml`](exam/readiness-policy.yaml)에 분리되어 있다. 적용 방법과
필수 live suite 현황은 [`docs/readiness-policy.md`](docs/readiness-policy.md)에 기록한다.
이 정책은 공식 합격 예측이 아니라 프로젝트 자체 점검 기준이다.

## 구조

```
cka                        # CLI (Command-Line Interface, web 서브커맨드 포함)
bin/ssh                    # `ssh <노드>` 명령 모양 래퍼 (docker exec으로 변환)
web/                       # 웹 스플릿 뷰 (server.py 백엔드 + index.html + serve.sh)
cluster/                   # kind 클러스터 + 애드온 셋업
cluster/cells/             # kubeadm·controller·CSI (Container Storage Interface) 일회용 셀
cluster/controllers/       # cert-manager·Envoy Gateway 고정 asset cache
cluster/csi/               # CSI host-path driver 고정 manifest·image cache
cluster/versions.lock.yaml # 클러스터·애드온·도구 버전 lock
lib/                       # 공통 함수 + 채점 러너 (criterion 기반)
questions/<domain>/<id>/   # question.md(영어 지문) setup.sh(환경 구성)
                           # grade.sh(채점 기준) answer.md(정답+한국어 해설)
                           # solve.sh(모범답안 자동 적용) [teardown.sh]
exam/mock-exam.sh          # 모의고사
exam/planner.sh            # seed 기반 호환 form 생성·검증
exam/forms/                # 문제 호환성 catalog
exam/ssh/                  # 실제 base→target SSH + systemd 감독기
exam/supervised-exam.sh    # 34문항 허용 목록 기반 감독형 runner
images/base, images/target # 지정-host 컨테이너 이미지
tests/selftest.sh          # 전 문제 정합성 검증 (setup→solve→만점 확인)
tests/contract-test.sh     # runner·grader 계약 검증
curriculum/                # 공식 v1.35 역량별 로컬 커버리지
docs/                      # 시험 개요 · 채점·준비 완료 정책
```

## 유지보수

```bash
tests/selftest.sh --only st-01      # 특정 문제의 setup/solve/grade 정합성 검증
tests/selftest.sh --domain storage  # 공유 문제의 도메인 단위 검증
tests/selftest.sh --include-disposable # 52문제 전체(고비용 셀·asset 필요)
tests/selftest.sh --contract-only   # 클러스터 없이 계약 검증만 실행
./cka cluster reset                 # 클러스터 완전 재생성
./cka cluster down                  # 클러스터 삭제
```

현재 cluster-free 정적·계약 검사와 네 필수 Docker live suite가 모두 통과했다.
검증 범위는 `ca-12` blank-node kubeadm bootstrap, `ca-11` 3-control-plane
stacked-etcd failover, `ca-06` N-1→N worker upgrade, `ca-09`·`ca-13` cert-manager,
`sn-05` Envoy Gateway, `st-06` CSI (Container Storage Interface) data path와 clean host의
실제 17문항 감독형 SSH gate다. 2026-08-23 clean Ubuntu 24.04 WSL2 (Windows Subsystem
for Linux 2)에서 마지막 suite까지 통과했으므로 저장소 구현 검증 상태는
`practice-ready-live-complete`다. 이는 공식 CKA 합격 보장이나 개인의 “준비 종료” 선언이
아니다. 별도의 학습 기준과 정확한 명령·결과는
[`docs/readiness-policy.md`](docs/readiness-policy.md)에 있다.

## 실제 시험과의 차이

기본 `cka start`·`cka exam`의 노드 접속은 `ssh <노드>` 모양을 `docker exec` 또는
active-cell shell로 변환한다. 별도 opt-in `cka exam-ssh`만 실제 `base → cka-target`
SSH와 systemd deadline 감독을 사용한다. 모든 환경은 한 호스트의 container에서 실행되므로
물리 failure domain이나 공식 시험 플랫폼의 보안 경계까지 재현하지는 않는다.

기존 `sn-09`의 LoadBalancer와 `sn-10`의 NetworkPolicy 데이터 경로에 더해 다음을 실제
리소스와 결과로 채점하도록 구현했다.

- `ca-06`: 고정된 공식 `.deb` package로 worker를 Kubernetes N-1에서 N으로 upgrade
- `ca-11`: load balancer 뒤 3-control-plane stacked-etcd HA (High Availability) 구성과
  control-plane failover
- `ca-12`: cluster state가 없는 host에서 `kubeadm init`·`join`과 Pod network 구성
- `ca-09`, `ca-13`: cert-manager의 실제 Certificate reconcile과 operator 설치
- `sn-05`: Envoy Gateway가 처리하는 HTTP (Hypertext Transfer Protocol) route
- `st-06`: CSI driver 등록, dynamic provisioning,
  attachment와 volume data

구현 기준은 Kubernetes의
[kubeadm cluster 생성](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/),
[kubeadm HA topology](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/),
[kubeadm Linux node upgrade](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/upgrading-linux-nodes/),
[Operator pattern](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/),
[Gateway API HTTP routing](https://gateway-api.sigs.k8s.io/guides/user-guides/http-routing/),
[CSI 배포](https://kubernetes-csi.github.io/docs/deploying.html) 공식 문서다.

2026-08-22 기준으로 위 일회용 셀 경로는 canonical solution, 실제 상태·데이터 경로 채점과
cleanup까지 live로 통과했다. `st-06`은 기준 답안과 nodeSelector를 생략한 의미상 동등한
대안 모두 10/10을 받았다. 2026-08-23에는 별도 clean Ubuntu 24.04 WSL2에서
[`tests/ssh-supervised-live-test.sh`](tests/ssh-supervised-live-test.sh)의 실제 17문항 form을
104/104 상태로 만든 뒤 무개입 deadline이 `TIMEOUT` 비통과를 강제하는지 확인했다. guard
process kill·restart, 실제 base→target 공개키 SSH, collect·grade와 exact cleanup도
통과했으며, 종료 후 KIND (Kubernetes IN Docker) cluster, 감독형 SSH object, kind node,
`kind` network와 Docker volume은 모두 0개였다. 보조
[`tests/ssh-supervisor-docker-smoke.sh`](tests/ssh-supervisor-docker-smoke.sh)와
[`tests/ssh-runner-docker-smoke.sh`](tests/ssh-runner-docker-smoke.sh)도 통과했다.

공유 클러스터의 종합 장애 문제 `ts-13`, `ts-14`, `ts-15`도 각각 setup 직후 0/8에서
solution 적용 후 8/8로 실제 채점됐고, 각 cleanup 뒤 세 node가 모두 Ready로 복귀했다.
이 결과는 저장소의 구현·live gate 완료를 뜻하지만 개인별 blind run과 외부 공식
simulator를 대신하지 않는다.
자세한 비교는 [docs/exam-overview.md](docs/exam-overview.md#이-연습-환경과-실제-시험의-차이) 참고.
