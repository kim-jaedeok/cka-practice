# ca-10 정답지 — Create a static Pod

## 모범 답안

```bash
# 노드 접속
ssh cka-worker

# 매니페스트 작성
cat > /etc/kubernetes/manifests/static-web.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: static-web
spec:
  containers:
    - name: web
      image: nginx:1.29
      ports:
        - containerPort: 80
YAML
exit

# kubelet이 자동으로 감지해 Pod를 띄운다 (수 초 ~ 수십 초)
kubectl get pod static-web-cka-worker    # Running
```

## 해설 (한국어)

- **static Pod**는 API 서버가 아니라 **kubelet이 직접** 관리한다. kubelet이
  `staticPodPath`(kubeadm 기본: `/etc/kubernetes/manifests`) 디렉토리를 감시하다가
  YAML이 생기면 Pod를 띄우고, 파일을 지우면 Pod를 제거한다.
- API 서버에는 **mirror Pod**가 `<pod이름>-<노드이름>` 형식으로 나타난다
  (그래서 `static-web-cka-worker`). mirror Pod는 읽기 전용 — `kubectl delete`해도
  kubelet이 다시 만든다. 삭제하려면 **매니페스트 파일을 지워야** 한다.
- control plane 컴포넌트(kube-apiserver, etcd, scheduler, controller-manager)가
  모두 이 방식으로 뜬다 — ts-12(컨트롤플레인 장애) 문제와 연결되는 핵심 개념.
- staticPodPath 확인법: 노드의 `/var/lib/kubelet/config.yaml`에서 `staticPodPath` 필드.
- 공식 문서 참조 경로: **Tasks → Configure Pods and Containers → Create static Pods**.

## 채점 기준 (6점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | 노드에 매니페스트 파일 존재 | 노드 파일시스템 grep |
| 2 | mirror Pod Running | phase 확인 |
| 1 | 이미지 nginx:1.29 | jsonpath |
| 1 | ownerReference가 Node (static pod 증명) | jsonpath |
