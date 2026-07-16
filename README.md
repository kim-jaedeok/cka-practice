# cka-practice — CKA 시험 로컬 연습 환경

killer.sh 스타일의 CKA(Certified Kubernetes Administrator) 연습 시스템.
실제 클러스터(kind)에 문제 상황을 자동 구성하고, 영어 지문(실전 형식)으로 풀이한 뒤,
클러스터 상태 기반으로 **자동 채점**(부분 점수)받는다.

- 문제 40개 (공식 도메인 비중 반영: Troubleshooting 12 / Cluster Architecture 10 / Networking 8 / Workloads 6 / Storage 4)
- 문제별 정답지 + 한국어 해설 (`answer.md`)
- 모의고사 모드: 17문제 샘플링 + 2시간 타이머 + 성적표(66% 합격 판정)
- 시험 정보: [docs/exam-overview.md](docs/exam-overview.md) · 채점 방식: [docs/grading-policy.md](docs/grading-policy.md)

## 요구사항

- Windows + WSL2 (Ubuntu) — **모든 명령은 WSL 안에서 실행**
- WSL 안에 docker(실행 중), kind, kubectl (helm은 셋업이 자동 설치)
- 여유 메모리 ~4GB (kind 3노드 + 애드온)

## 시작하기

```bash
# WSL에서
cd /mnt/c/Users/<you>/Desktop/cka-practice

# 1회: 클러스터 + 애드온 (Calico, metrics-server, ingress-nginx, Gateway API CRD) 설치
./cka cluster up

# 편의: PATH에 등록 (선택)
echo "alias cka='$(pwd)/cka'" >> ~/.bashrc && source ~/.bashrc
```

> WSL은 유휴 시 VM을 내릴 수 있어 클러스터 컨테이너가 재부팅될 수 있습니다.
> 연습 중에는 WSL 터미널을 하나 열어두세요. 재부팅 후엔 1~2분 내로 자동 복구되며,
> `cka` 명령이 알아서 API 기동을 기다립니다. control-plane 컨테이너가 안 뜨면
> `docker start cka-control-plane`.

## 문제 풀이 흐름

```bash
cka list                  # 40문제 목록 + 진행 상태
cka start ts-03           # 문제 환경 구성 + 영어 지문 표시
# ... kubectl로 직접 풀이 ...
cka grade ts-03           # 자동 채점: 기준별 ✓/✗ + 부분 점수
cka solution ts-03        # 정답지 + 한국어 해설
cka reset ts-03           # 환경 초기화 후 재도전
```

파일 제출형 문제(로그 추출 등)의 답안 파일은 `~/cka/<문제id>/`에 저장한다.

## 모의고사 (실전 리허설)

```bash
cka exam                  # 17문제 샘플링 + 일괄 환경 구성 + 2시간 타이머 시작
cka exam status           # 남은 시간 · 문제 목록
cka exam question 3       # 3번 문제 지문
cka exam finish           # 채점 → 성적표 (총점/도메인별/합격 판정)
cka exam abort            # 중단
```

## 구조

```
cka                        # CLI
cluster/                   # kind 클러스터 + 애드온 셋업
lib/                       # 공통 함수 + 채점 러너 (criterion 기반)
questions/<domain>/<id>/   # question.md(영어 지문) setup.sh(환경 구성)
                           # grade.sh(채점 기준) answer.md(정답+한국어 해설)
                           # solve.sh(모범답안 자동 적용) [teardown.sh]
exam/mock-exam.sh          # 모의고사
tests/selftest.sh          # 전 문제 정합성 검증 (setup→solve→만점 확인)
docs/                      # 시험 개요 · 채점 정책
```

## 유지보수

```bash
tests/selftest.sh --only st-01      # 특정 문제의 setup/solve/grade 정합성 검증
tests/selftest.sh --domain storage  # 도메인 단위 검증
./cka cluster reset                 # 클러스터 완전 재생성
./cka cluster down                  # 클러스터 삭제
```

## 실제 시험과의 차이

노드 접속은 `ssh` 대신 `docker exec -it <노드> bash`, etcdctl은 etcd Pod 안에서
실행(명령 동일), 클러스터 버전 업그레이드는 절차 검증형으로 변형.
자세한 비교는 [docs/exam-overview.md](docs/exam-overview.md#이-연습-환경과-실제-시험의-차이) 참고.
