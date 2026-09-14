# wl-09 정답지 — Secret 파일 마운트와 프로그램 경로 설정

## 모범 답안

기존 Deployment의 Pod 템플릿에 Secret 볼륨과 마운트를 추가하고,
nginx 실행 인자로 설정 파일 경로를 지정한다.

```bash
kubectl -n file-config patch deployment config-web --type=strategic -p '{
  "spec": {"template": {"spec": {
    "volumes": [{"name": "app-config", "secret": {"secretName": "web-config"}}],
    "containers": [{
      "name": "web",
      "command": ["nginx"],
      "args": ["-c", "/etc/app/server.conf", "-g", "daemon off;"],
      "volumeMounts": [{"name": "app-config", "mountPath": "/etc/app", "readOnly": true}]
    }]
  }}}
}'
kubectl -n file-config rollout status deployment/config-web
kubectl -n file-config exec deployment/config-web -c web -- cat /etc/app/server.conf
kubectl -n cka-system exec deployment/grader-client -- \
  wget -qO- http://config-web.file-config.svc.cluster.local:8080
```

마지막 명령의 예상 응답은 `secret-file-ready`이다.

## 연결 구조

`web-config`의 `server.conf` 키 → `volumes[].secret.secretName` → 같은 이름의
`volumeMounts[]` → `/etc/app/server.conf` → nginx의 `-c` 인자 순으로 연결된다.

Secret을 볼륨으로 연결하면 각 키를 파일로 제공할 수 있다. 프로그램이 해당
파일을 사용하도록 설정하는 일은 별도다.
[Kubernetes 공식 문서](https://kubernetes.io/docs/concepts/configuration/secret/#using-secrets-as-files-from-a-pod)

nginx의 `-c`는 설정 파일 경로를 지정하고, `-g 'daemon off;'`는 전역 지시문을
전달한다. 문제에서는 설정 파일 내용을 제공하므로 nginx 문법을 새로 작성할
필요가 없다. 파일을 마운트하기만 하고 `-c`를 빠뜨리면 기본 설정으로 실행된다.
[nginx 실행 옵션](https://nginx.org/en/docs/switches.html)

이 Secret은 파일 연결을 연습하기 위한 설정 데이터다. 인증서 발급과 클라이언트
신뢰 설정은 이 문제의 요구사항이 아니다.

## 채점 기준

| 점수 | 확인 항목 |
|---|---|
| 2 | 실제 Secret과 마운트의 연결, 읽기 전용, 컨테이너 내 파일 내용 |
| 2 | 지정한 이미지와 설정 경로를 사용하는 실행 명령 |
| 1 | 1개 replica 롤아웃 완료 |
| 1 | Service의 실제 응답 |

볼륨 이름은 자유이며 `command`와 `args`를 나누는 방식도 자유다.
