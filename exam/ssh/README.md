# 감독형 Secure Shell (SSH) 지정-host 모의고사

`cka exam-ssh`는 CKA (Certified Kubernetes Administrator) 공식 환경의 지정-host
흐름을 연습하기 위한 opt-in runner다. 후보자는 작업 도구와 저장소가 없는 `base`에서
시작해 실제 SSH로 `cka-target`에 접속한다. Linux Foundation은 모든 과제를
문항에 지정된 호스트에서 수행하고 완료 후 `exit`로 base에 돌아오며, 작업 도구는 base가
아닌 지정 호스트에 있다고 안내한다.

공식 근거: [Linux Foundation CKA·CKAD (Certified Kubernetes Application Developer) 중요 지침](https://docs.linuxfoundation.org/tc-docs/certification/tips-cka-and-ckad)

## 지원 범위

- 52개 문제 중 `environment: shared-kind`이며 Kubernetes API (Application Programming
  Interface)만으로 풀 수 있는 34개를 허용 목록으로 관리한다. node shell, etcd, kubeadm,
  static Pod, Helm, host 전용 endpoint 또는 일회용 셀이 필요한 문제는 제외한다.
- `prepare`는 허용 목록과 compatibility metadata로 17문항 form을 만들고 모든 setup과
  grader preflight를 끝낸다. 내부 kind kubeconfig와 문제별 작업 파일은 checksum이 포함된
  immutable input manifest로 target에 복사된다.
- target에서는 `cka-use-context <question-id>`로 해당 문제의 kubeconfig를 활성화하고
  `~/cka/<question-id>/`에 제출 파일을 작성한다.
- 봉인 후에는 immutable allowlist에 있는 제출 파일만 회수하고, valid seal proof가 있어야
  host grader를 호출한다.

허용 목록은 [`supported-questions.txt`](supported-questions.txt), 제출 파일은
[`answer-files.tsv`](answer-files.tsv)에 정의한다. 이 모드는 일회용 셀 문제 7개를 포함하지
않으며, 기본 `cka exam`의 40개 공유 후보 pool과도 동일하지 않다.

## 사전 조건

- Linux/WSL (Windows Subsystem for Linux)에서 실행 중인 Docker Engine과 준비된
  `kind-cka` cluster
- PID 1의 systemd, 접근 가능한 persistent per-user systemd manager, login linger
- symlink component가 없고 현재 사용자가 소유한 mode `0700` native-Linux state directory
- 미리 빌드한 base·target image

자동 모드는 이 조건을 모두 fail-closed로 검사한다. systemd를 사용할 수 없으면
`nohup`, `sleep` 또는 foreground watcher로 대체하지 않는다. login linger가 꺼져 있을 때만
아래 명시적 1회 단계가 `sudo loginctl enable-linger`를 실행한다.

```bash
bash exam/ssh/build.sh
cka exam-ssh preflight --install-linger
```

systemd timer/transient service의 공식 동작은
[`systemd-run`](https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html)을
기준으로 한다.

## 실행 순서

```bash
cka exam-ssh preflight
cka exam-ssh prepare --run-id rehearsal01 --seed rehearsal-1
cka exam-ssh start
cka exam-ssh enter

# base container 안에서
ssh cka-target
cka-use-context ts-01
# ... 문제 풀이 ...
exit
exit

cka exam-ssh status
cka exam-ssh seal
cka exam-ssh collect
cka exam-ssh grade
cka exam-ssh cleanup
```

기본 제한시간은 7200초이며 `prepare --duration-seconds N`으로 짧은 시험을 만들 수 있다.
form이 `PREPARED`가 된 뒤 `start`가 systemd timer와 restartable guard를 모두 활성화해야
후보자 진입 정보를 공개한다. timer는 deadline에 base와 target을 중지하고, guard는
process 재시작이나 host boot identifier 변경 뒤에도 overdue run을 봉인한다. deadline seal이
확인된 결과는 점수가 66% 이상이어도 `TIMEOUT`, 즉 비통과다.
manual 또는 operator seal 요청이 lock에 들어오기 전에는 시간이 남아 있었더라도, 정확한
target→base 중지가 끝난 시각이 deadline을 넘으면 supervisor가 provenance를 `deadline`으로
강제한다. 경계 시각의 지연을 수동 제출로 우회할 수 없다.

## 보안·복구 경계

- base와 target은 run 전용 `--internal` network를 사용한다. target만 immutable full ID로
  확인한 기존 kind network에 추가 연결되며, base는 cluster network에 연결되지 않는다.
- base에는 OpenSSH client만 있고 `kubectl`, `sudo`, 저장소가 없다. target에는 문제 풀이
  도구와 `NOPASSWD` sudo가 있지만 Docker socket, 저장소, grader code·secret은 mount하지
  않는다.
- run마다 Ed25519 후보자 key와 target host key를 새로 만든다. nested SSH client와 모든
  forwarding은 기본 image에서 제거·비활성화한다.
- network/container create 결과의 64자리 identifier와 image identifier, cross-run nonce를 create-once
  manifest와 별도 object ledger에 기록한다. start/stop/inspect/remove는 이름을 신뢰하지
  않는다. 상태 전이는 `flock`으로 직렬화한다.
- manifest 손상 시 ledger로 소유권이 입증된 exact ID만 중지하고 run을 영구 `INVALID`로
  만든다. valid seal proof가 없으면 collect·grade authorization은 실패한다.
- 허용 답안 회수는 symlink, hardlink, device, path traversal, 파일당 8 MiB와 전체 32 MiB
  초과를 거부한다.

Docker의 network·중지·복사 동작과 identity 경계는 공식
[internal network](https://docs.docker.com/reference/cli/docker/network/create/#network-internal-mode---internal),
[container stop](https://docs.docker.com/reference/cli/docker/container/stop/),
[container cp](https://docs.docker.com/reference/cli/docker/container/cp/),
[container rename](https://docs.docker.com/reference/cli/docker/container/rename/) 문서를
기준으로 한다. 이 환경은 target에 `sudo`를 허용하는 학습 장치이며, 악의적인 root 사용자를
막는 보안 sandbox라고 주장하지 않는다.

## 검증 상태

Docker/Kubernetes가 필요 없는 supervisor·runner 장애 주입과 계약 검사는 통과했다.

```bash
bash tests/ssh-supervisor-faults.sh
bash tests/ssh-runner-faults.sh
```

실제 Docker lifecycle smoke는 별도 opt-in이다.

```bash
CKA_SSH_SUPERVISOR_DOCKER_SMOKE=1 bash tests/ssh-supervisor-docker-smoke.sh
CKA_SSH_RUNNER_DOCKER_SMOKE=1 bash tests/ssh-runner-docker-smoke.sh
```

준비 종료 판정에 사용하는 필수 end-to-end gate는 실제 `cka exam-ssh` 17문항 경로를
사용한다. 기존 KIND cluster가 하나도 없는 disposable WSL/Linux host에서만 실행하며,
지정-host image를 먼저 `bash exam/ssh/build.sh`로 빌드해야 한다. 이 gate는 run 전용 KIND
cluster/network만 만들고 exact ID와 run label을 다시 확인한 뒤 정리한다. 기존 cluster가
있으면 삭제하지 않고 즉시 거부한다.

```bash
CKA_SSH_SUPERVISED_LIVE=1 bash tests/ssh-supervised-live-test.sh
```

이 필수 gate는 canonical 17문항의 실제 runner prepare/start, base→target→KIND API 경로,
guard 강제 종료 후 systemd 재시작, 수동 seal 없는 짧은 deadline, perfect-score 진단 결과의
`TIMEOUT` non-pass, collect/final grade, supervisor object와 runner active record의 실제 cleanup을
검증한다. setup grader evidence는 candidate input과 분리된 create-once manifest에 묶이고,
final grader에는 같은 bytes가 0400 read-only snapshot으로 전달되며 preflight/final status는
서로 다른 경로를 사용한다.

2026-08-23 persistent user systemd와 login linger를 준비한 clean Ubuntu 24.04 WSL2에서
위 필수 end-to-end gate가 통과했다. 실제 canonical 17문항 form은 104/104였지만 무개입
deadline 뒤 verdict는 `TIMEOUT` 비통과였고, guard 강제 종료 후 systemd 재시작과 실제
base→target 공개키 SSH, collect·final grade, exact cleanup도 모두 통과했다. 종료 후 KIND
cluster, 감독형 SSH object, kind node, `kind` network와 Docker volume은 모두 0개였다.
따라서 저장소 implementation validation은 `practice-ready-live-complete`이며, static fault
contract와 별도 runner smoke는 계속 빠른 보조 회귀 검사로 사용한다. 이 결과는 공식 CKA
합격 보장이나 개인의 학습 준비 완료 판정이 아니다.

## 공급망 고정

| 항목 | 고정 값 | 검증 |
|---|---|---|
| base OS (Operating System) image | `ubuntu:24.04@sha256:33ceb719…987517` | Docker manifest digest |
| kubectl amd64 | `v1.35.0`, `a2e984a1…060989` | 다운로드 후 SHA-256 (Secure Hash Algorithm 256-bit) |
| kubectl arm64 | `v1.35.0`, `58f82f9f…89e25` | 다운로드 후 SHA-256 |
| yq amd64 | `v4.48.2`, `0ffc3532…25bcc` | 다운로드 후 SHA-256 |
| yq arm64 | `v4.48.2`, `3c21630f…cfe45` | 다운로드 후 SHA-256 |

공식 근거:
[kubectl Linux 설치](https://v1-35.docs.kubernetes.io/docs/tasks/tools/install-kubectl-linux/) ·
[yq v4.48.2 release](https://github.com/mikefarah/yq/releases/tag/v4.48.2) ·
[Ubuntu Docker Official Image](https://hub.docker.com/_/ubuntu) ·
[Docker digest pin](https://docs.docker.com/reference/cli/docker/image/pull/#pull-an-image-by-digest-immutable-identifier)

Ubuntu archive에서 설치하는 OpenSSH, sudo, curl, wget, man package의 개별 `.deb` 버전은
snapshot repository로 고정하지 않았다. 따라서 base digest와 standalone binary는
고정되지만, 이후 다시 빌드한 OS package layer가 byte-for-byte 동일하다고 보장하지 않는다.
