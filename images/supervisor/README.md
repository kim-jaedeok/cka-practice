# Host service packaging

Supervisor는 Docker socket을 mount한 container image로 실행하지 않는다. 이 디렉터리는 WSL
host systemd packaging만 제공한다. candidate container와 신뢰 경계를 명확히 분리하고,
systemd가 없는 host에서는 `exam/ssh/session.sh start`가 fail-closed한다.

`cka-ssh-supervisor-recover.service`는 host boot 뒤 active-run 상태를 운영자가 확인하도록 하는
보조 unit이다. 시험 중 핵심 경로는 `session.sh`가 만든 다음 두 transient unit이다.

- `cka-ssh-deadline-<run>-<nonce>.timer`: 독립된 authoritative deadline
- `cka-ssh-guard-<run>-<nonce>.service`: `Restart=on-failure` watcher

영구 unit 설치 경로와 state root는 배포 시스템이 결정해야 하며 repository에서 자동 설치하지
않는다.
