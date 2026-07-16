# sn-03 정답지 — Restrict traffic with NetworkPolicies

## 모범 답안

```yaml
# 1. 네임스페이스 전체 ingress 차단 (default deny)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: secure-apps
spec:
  podSelector: {}            # 빈 selector = 네임스페이스의 모든 Pod
  policyTypes:
    - Ingress
---
# 2. backend → db :80 만 선별 허용
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-backend-to-db
  namespace: secure-apps
spec:
  podSelector:
    matchLabels:
      role: db               # 이 정책이 적용될 대상
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              role: backend  # 허용할 발신자
      ports:
        - protocol: TCP
          port: 80
```

확인:

```bash
kubectl -n secure-apps exec backend -- wget -qO- -T 3 http://db-svc   # 성공
kubectl -n secure-apps exec other   -- wget -qO- -T 3 http://db-svc   # timeout
```

## 해설 (한국어)

- **NetworkPolicy는 additive(허용 목록)** 방식이다: 어떤 Pod가 하나 이상의 정책에
  선택되면, 그 정책들이 허용한 트래픽 **외에는 전부 차단**된다. 그래서
  default-deny + 선별 allow의 2정책 조합이 표준 패턴이다.
- `podSelector: {}`(빈 셀렉터)는 "네임스페이스의 모든 Pod"를 뜻한다.
- `from` 안의 `podSelector`는 **같은 네임스페이스** 안의 Pod만 매칭한다.
  다른 네임스페이스에서의 접근을 허용하려면 `namespaceSelector`를 함께 쓴다.
  (`- podSelector` 와 `- namespaceSelector`를 별개 항목으로 쓰면 OR,
  한 항목에 둘 다 쓰면 AND — 시험 단골 함정)
- NetworkPolicy는 **CNI가 지원해야 실제로 동작**한다. 이 연습 환경은 Calico를
  사용하므로 실측 채점이 가능하다 (kind 기본 CNI kindnet은 미지원).
- 공식 문서 참조 경로: **Concepts → Services, Load Balancing, and Networking →
  Network Policies**.

## 채점 기준 (8점)

| 배점 | 검증 항목 | 검증 방법 |
|---|---|---|
| 2 | default-deny 정책 스펙 | 빈 podSelector + policyTypes |
| 2 | allow 정책 스펙 (대상/발신/포트) | jsonpath 비교 |
| 2 | backend → db 실측 성공 | pod exec wget |
| 2 | other → db 실측 차단 | pod exec wget timeout |
