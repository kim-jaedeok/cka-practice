# CKA 시험 개요 및 출제 경향 (2026, Kubernetes v1.35 기준)

> 조사 출처: Linux Foundation 공식 시험 페이지, CNCF 공식 커리큘럼(`CKA_Curriculum_v1.35.pdf`),
> killer.sh·커뮤니티 후기. 조사일: 2026-07-16.

## 시험 형식

| 항목 | 내용 |
|---|---|
| 방식 | 온라인 원격 감독(PSI), 수행형(performance-based) 실기 |
| 시간 | 2시간 |
| 문항 | 15~20개 과제 (문항별 배점 상이, 부분 점수 인정) |
| 합격선 | 66% |
| 환경 | 원격 데스크톱의 터미널에서 복수 클러스터를 컨텍스트 전환하며 작업 |
| 허용 자료 | kubernetes.io/docs, kubernetes.io/blog, helm.sh/docs (별도 탭) |
| 기반 버전 | Kubernetes v1.35 (마이너 릴리스 후 4~8주 내 갱신) |
| 유효 기간 | 인증 후 2년 |

- 각 문제 상단에 `kubectl config use-context <cluster>` 전환 명령이 주어진다.
- 일부 문제는 특정 노드에 `ssh <node>`로 접속해 작업한다 (kubelet, etcd, static pod 등).
- 채점은 시험 종료 후 **클러스터의 최종 상태**를 검사하는 방식 — 과정이 아니라 결과를 본다.

## 도메인별 비중 (공식)

| 도메인 | 비중 | 이 뱅크의 문제 |
|---|---|---|
| Troubleshooting | **30%** | ts-01 ~ ts-12 (12문제) |
| Cluster Architecture, Installation & Configuration | 25% | ca-01 ~ ca-10 (10문제) |
| Services & Networking | 20% | sn-01 ~ sn-08 (8문제) |
| Workloads & Scheduling | 15% | wl-01 ~ wl-06 (6문제) |
| Storage | 10% | st-01 ~ st-04 (4문제) |

## 공식 세부 역량 → 문제 매핑

### Troubleshooting (30%)
- Troubleshoot clusters and nodes → ts-05(kubelet/NotReady)
- Troubleshoot cluster components → ts-06(CoreDNS), ts-12(kube-scheduler)
- Monitor cluster and application resource usage → ts-08(kubectl top)
- Manage and evaluate container output streams → ts-07(로그 추출)
- Troubleshoot services and networking → ts-03(selector), ts-11(Ingress)
- (애플리케이션 장애 일반) → ts-01(이미지), ts-02(CrashLoop), ts-04(리소스), ts-09(PVC), ts-10(RBAC)

### Cluster Architecture, Installation & Configuration (25%)
- Manage role based access control (RBAC) → ca-01, ca-02
- Manage the lifecycle of Kubernetes clusters → ca-03(etcd backup), ca-04(etcd restore), ca-05(drain), ca-06(업그레이드 절차)
- Use Helm and Kustomize to install cluster components → ca-07, ca-08
- Understand CRDs, install and configure operators → ca-09
- (static pod / control plane 구조) → ca-10
- Prepare underlying infrastructure / HA control plane → 이 랩(kind)에서 재현 불가, ca-06 해설에 이론 수록

### Services & Networking (20%)
- Use ClusterIP, NodePort, LoadBalancer service types and endpoints → sn-01, sn-02, sn-07
- Define and enforce Network Policies → sn-03
- Know how to use Ingress controllers and Ingress resources → sn-04
- Use the Gateway API to manage Ingress traffic → sn-05
- Understand and use CoreDNS → sn-06, sn-08

### Workloads & Scheduling (15%)
- Application deployments and rolling updates/rollbacks → wl-01
- (사이드카 패턴) → wl-02 (native sidecar, 최신 출제 경향)
- Configure workload autoscaling → wl-03 (HPA)
- Primitives for robust, self-healing deployments → wl-04 (probes)
- Configure Pod admission and scheduling → wl-05 (nodeSelector/taint/toleration)
- Use ConfigMaps and Secrets to configure applications → wl-06 (+PriorityClass)

### Storage (10%)
- Manage persistent volumes and persistent volume claims → st-01, st-04
- Implement storage classes and dynamic volume provisioning → st-02
- Configure volume types, access modes and reclaim policies → st-01, st-03(확장)

## 2025-02 대개편 이후 출제 경향 (현행)

- **Gateway API**가 신규 편입 — Gateway/HTTPRoute 리소스 작성 (sn-05)
- **Helm/Kustomize** 실사용 문제 (ca-07, ca-08)
- **CRD/Operator** 관련 조회·CR 생성 (ca-09)
- **native sidecar**(initContainer + restartPolicy: Always)가 사이드카 표준 패턴 (wl-02)
- kubeadm 설치 자체보다 **업그레이드·백업 등 lifecycle 관리** 중심 (ca-03~06)
- Troubleshooting 비중 30%로 최대 — 진단 루틴(describe → events → logs)을 몸에 익힐 것

## 시험 전략

1. **시간 관리**: 문항당 평균 6~7분. 막히면 플래그해두고 넘어간다 (부분 점수 존재).
2. **컨텍스트 전환 필수**: 문제마다 지정된 컨텍스트 명령을 그대로 복사해 실행하는 습관.
3. **명령형 우선**: `kubectl create/run/expose ... --dry-run=client -o yaml`로 골격 생성 후 수정.
4. **검증 습관**: 리소스 생성 후 반드시 상태 확인 (`rollout status`, `get endpointslices`, `auth can-i`).
5. **문서 활용**: kubernetes.io/docs 검색을 빠르게 — 자주 쓰는 페이지의 검색 키워드를 외운다.
6. **금지 조건 준수**: "Do not delete/modify X" 위반 시 0점 처리될 수 있다.

## 이 연습 환경과 실제 시험의 차이

| 항목 | 실제 시험 | 이 연습 환경 |
|---|---|---|
| 클러스터 | 여러 개(문제별 전환) | kind 단일 클러스터 `kind-cka` |
| 노드 접속 | `ssh <node>` | `docker exec -it <node> bash` |
| etcdctl | 노드에 설치됨 | etcd Pod 안에서 실행 (명령 동일) |
| 클러스터 업그레이드 | 실제 kubeadm/apt 수행 | 절차 검증형 변형 (ca-06) |
| LoadBalancer | 클라우드 환경에 따라 | 미지원 (NodePort/Ingress로 대체) |
| 채점 | 종료 후 일괄 | `cka grade <id>` 즉시 채점 |
