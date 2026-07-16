# 채점 기준 및 방법 (Grading Policy)

이 문서는 문제별 정답지(`answer.md`)를 기준으로 채점이 **어떻게 설계·수행되는지**를 정의한다.

## 원칙

1. **결과 기반 채점**: 실제 CKA와 동일하게, 사용자가 어떤 명령을 쳤는지가 아니라
   **클러스터(또는 제출 파일)의 최종 상태**를 검사한다. 어떤 방법(명령형/선언형/edit)으로
   풀었든 결과가 요구사항을 충족하면 만점이다.
2. **요구사항 = 검증 항목(criterion)**: 각 문제의 요구사항을 독립적인 검증 항목으로
   분해하고 항목별 배점을 부여한다 → **부분 점수**가 자연스럽게 성립한다.
3. **스펙 검증 + 실측 검증의 이중화**: 가능한 문제는 리소스 필드 비교(스펙)에 더해
   실제 동작(HTTP 응답, DNS 응답, 권한 검사)을 확인한다. 스펙만 맞고 동작하지 않는
   답안(예: selector 불일치)은 실측 항목에서 감점된다.
4. **금지 조건 검사**: "Do not modify X" 류의 제약은 별도 항목으로 검증한다.
5. **채점 기준의 코드화**: 모든 기준은 `grade.sh` 안에
   `criterion <배점> "<설명>" "<검증 커맨드>"` 형태로 명문화되어 있어
   채점 근거가 투명하고 재현 가능하다.

## 검증 방법 카탈로그

| 검증 유형 | 헬퍼 (lib/grader.sh) | 예 |
|---|---|---|
| 리소스 존재 | `res_exists` | PV/PVC/Role 존재 |
| 스펙 필드 일치 | `jp_eq`, `jp_contains` (jsonpath) | 이미지·replicas·포트·프로브 파라미터 |
| 워크로드 상태 | `deploy_ready`, `pod_running`, `pod_ready` | N/N Ready |
| 서비스 연결성 | `svc_has_endpoints`, `http_ok`, `http_body_contains` | EndpointSlice, 상주 채점 Pod에서 wget |
| NetworkPolicy 실측 | `http_ok_from`, `http_denied_from` | 허용 경로 성공 + 차단 경로 타임아웃 |
| Ingress 실측 | `ingress_ok` | Host 헤더 curl → 응답 본문 확인 |
| DNS 실측 | `dns_resolves` | 상주 Pod에서 nslookup |
| RBAC 실측 | `can_i`, `cannot_i` | `kubectl auth can-i --as system:serviceaccount:...` |
| 파일 제출물 | `file_exists`, `file_contains` | `~/cka/<id>/` 아래 로그·기록 파일 |
| 노드 상태 | `node_exec`, `node_drained` | kubelet active, drain 완료, 노드 파일 존재 |

## 점수 체계

- 문제별 만점은 `meta.yaml`의 `points` (4~8점, 실제 시험처럼 난이도·작업량 비례).
- `cka grade <id>` 실행 시 항목별 ✓/✗과 획득 점수, 총점, 백분율을 출력한다.
- 채점은 몇 번이든 다시 실행할 수 있다 (실전과 달리 학습 도구이므로).

## 모의고사 채점

- 17문제(도메인 비중 반영: ts 5 / ca 4 / sn 3 / wl 3 / st 2)의 배점 합계를 만점으로,
  획득 합계의 백분율로 환산한다.
- **66% 이상 합격** (실제 기준과 동일).
- 성적표: 문제별 점수, 도메인별 소계(66% 미만 도메인에 ⚠ 취약 표시), 총점·합격 판정.
- 결과는 `.state/exam-results/`에 타임스탬프 파일로 보관된다.

## 채점의 한계 (알려진 것)

- 실측 검증은 클러스터 상태에 의존한다 — Pod가 아직 기동 중이면 잠시 후 다시
  `cka grade` 하면 된다 (감점이 아니라 재채점 가능).
- ts-08(kubectl top)은 metrics-server 수집 주기(15초~1분) 영향을 받는다.
- ca-06(업그레이드)의 명령 파일 검사는 핵심 명령의 포함 여부를 정규식으로 확인한다 —
  순서·옵션의 사소한 차이는 관대하게 처리된다.
- sn-05(Gateway API)는 컨트롤러가 없어 스펙 필드만 검증한다.
