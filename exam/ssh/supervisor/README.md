# SSH 시험 감독기 계약

이 디렉터리는 기존 수동 `start.sh`/`seal.sh`와 독립적인 host-side 감독기다. 자동 모드는
`exam/ssh/session.sh`만 공개 진입점으로 사용하며 systemd가 없으면 시작 자체를 거부한다.
Docker socket은 WSL (Windows Subsystem for Linux) host의 supervisor와 systemd service만
사용한다. base와 target에는 socket, 저장소, grader 코드·비밀을 mount하지 않는다.
자동 모드는 persistent per-user systemd manager만 사용하며 login lingering을 요구한다.
필요한 경우 `session.sh preflight --install-linger`가 `sudo loginctl enable-linger`를 명시적으로
실행한다. 이 일회성 단계가 실패하면 비감독 process로 대체하지 않는다.

## 안정된 CLI 계약

```text
session.sh preflight [--install-linger]
session.sh start --run-id ID --duration-seconds N [--answer QUESTION:FILE ...]
                 [--input-manifest PATH --external-network-id FULL_ID]
session.sh seal --run-id ID [--reason manual|operator]
session.sh status --run-id ID
session.sh recover --run-id ID
session.sh collect --run-id ID --destination NEW_ABSOLUTE_PATH
session.sh authorize-grade --run-id ID
session.sh candidate-entry --run-id ID
session.sh cleanup --run-id ID
```

runner는 `start`가 성공한 뒤에만 base 진입 정보를 노출한다. 종료 시에는 `seal`, `collect`,
`authorize-grade` 순서로 호출한다. `authorize-grade`의 exit code가 0이 아니면 host grader를
호출해서는 안 된다. 이 계약은 점수와 별개이며 seal proof가 없거나 invalid이면 항상 닫힌다.
deadline으로 봉인된 run은 진단 채점은 가능하지만 authorization에 immutable `seal_reason`과
deadline provenance가 포함되며 runner verdict는 점수와 무관하게 `TIMEOUT`이다.

## 자동 form 입력과 cluster network

`cka exam-ssh` runner는 main catalog 중 `environment: shared-kind`이고 SSH allowlist에 있는
API (Application Programming Interface) 문항만 선택한다. node shell, etcd, kubeadm,
static Pod, 실제 operator/Gateway/CSI disposable cell 문항은 이 경로로 들어오지 않는다.

- form의 17개 question ID, active question, 각 question의 internal kubeconfig와 work root를
  create-once input manifest로 고정한다.
- supervisor는 symlink/hardlink/path traversal과 bounded-copy 한도를 검사하고 source를 snapshot한
  뒤, stopped target에 tar stream으로 복사한다. host bind mount는 만들지 않는다.
- target은 exact 64자리 KIND network ID에 연결된다. ID·name·driver·internal flag·label digest와
  target/base의 exact attachment set은 guard, activation, seal, collection, candidate entry에서
  다시 확인한다. create-before-start 단계에서는 `HostConfig.NetworkMode`와 attachment name으로
  선언 연결을 검증하고, 실행 단계에서는 `NetworkSettings.Networks[].NetworkID`와 run network의
  active endpoint가 실행 중인 exact manifest ID 집합과 같은지도 검증한다. 외부 KIND network는
  supervisor의 삭제 대상에 포함되지 않는다.
- target start 후 checksum을 확인하고 나서야 base를 시작하므로 input tamper나 activation race는
  candidate access 전에 run을 INVALID로 만든다.

## 불변 상태와 복구

- 상태 root는 supervisor 사용자 소유의 mode `0700` native Linux filesystem이어야 한다.
  DrvFS, 9p, CIFS, NFS 계열은 거부한다.
- `manifest.json`, `objects.json`과 각 SHA-256 (Secure Hash Algorithm 256-bit) digest는
  `O_EXCL`로 한 번만 생성하고 mode `0400`으로 봉인한다.
- manifest에는 create가 반환한 64자리 network/container ID와 `sha256:` image ID가 들어간다.
  생성 이후의 start/stop/inspect/remove는 이름을 사용하지 않는다.
- 전이는 kernel `flock`으로 직렬화한다. deadline seal은 별도의 per-run lock을 사용하므로
  일반 상태 명령이 느려도 target → base 중지 경로를 기다리지 않는다.
- systemd의 calendar timer가 authoritative deadline을 실행한다. restartable guard는 두 번째
  경로이며, 재시작 시 기한이 지났거나 Linux boot ID가 바뀌었으면 즉시 봉인한다.
- manifest가 손상되면 독립 objects ledger로 exact ID만 중지하고 run은 영구 INVALID가 된다.
  ownership label 또는 cross-run nonce가 다르면 해당 객체를 건드리지 않고 fail-closed한다.

## 수집 경계

`start --answer QUESTION:FILE`로 manifest에 들어간 파일만 중지된 target에서 회수한다.
symlink, hardlink, device, path traversal, 8 MiB 초과 파일, 전체 32 MiB 초과는 거부한다.
수집 대상 디렉터리는 새 절대 경로여야 한다. valid seal proof가 없으면 수집과 grade authorization
둘 다 실행되지 않는다.

## 장애 주입 검사

Docker/Kubernetes 없이 실행:

```bash
bash tests/ssh-supervisor-faults.sh
```

실제 Docker smoke는 명시적으로 opt-in한다. 첫 검사는 공유 `kind-cka` network나 cluster에
연결하지 않는 감독기 격리 검사이고, 두 번째 검사는 기존 KIND cluster를 변경하지 않은 채
internal kubeconfig 입력, 지정 host SSH hop, API data path, 회수·채점 gate·exact cleanup 전체를 검사한다.

```bash
CKA_SSH_SUPERVISOR_DOCKER_SMOKE=1 bash tests/ssh-supervisor-docker-smoke.sh
CKA_SSH_RUNNER_DOCKER_SMOKE=1 bash tests/ssh-runner-docker-smoke.sh
```

공식 동작 근거:

- Docker는 container rename을 지원하므로 이름은 immutable identity가 아니다:
  <https://docs.docker.com/reference/cli/docker/container/rename/>
- `docker container stop`은 timeout 뒤 강제 종료를 수행한다:
  <https://docs.docker.com/reference/cli/docker/container/stop/>
- `systemd-run`은 transient service와 timer를 만든다:
  <https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html>
- `Restart=on-failure`, `RestartPreventExitStatus=`와 start-rate limit의 공식 동작:
  <https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html>
- Docker Engine container inspect의 per-network `NetworkSettings.Networks` 계약:
  <https://docs.docker.com/reference/api/engine/version-history/#v122-api-changes>
- `docker network inspect`는 network의 상세 runtime 정보를 반환한다:
  <https://docs.docker.com/reference/cli/docker/network/inspect/>
- Bash login shell은 종료할 때 `~/.bash_logout`을 실행하므로, supervisor의 비대화형
  provisioning은 image의 logout hook이 성공한 명령의 종료 상태를 바꾸지 않도록 non-login
  `bash -c`만 사용한다:
  <https://www.gnu.org/software/bash/manual/html_node/Bash-Startup-Files.html>
- `flock(2)` 잠금은 열린 file description에 연결된다:
  <https://man7.org/linux/man-pages/man2/flock.2.html>
