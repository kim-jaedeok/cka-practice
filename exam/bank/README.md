# 시험 전용 문제 은행

이 디렉터리는 모의고사 전용 문제를 둔다. 연습 문제(`questions/`)와 겹치지 않는 문제로
처음 보는 문제에 대한 준비도를 측정하기 위해서다. 설계와 결정 근거는
[docs/exam-bank-design.md](../../docs/exam-bank-design.md) 트랙 A에 있다.

## 열람 규칙

문제 파일은 이 공개 저장소에 평문으로 있다(2026-11-05 결정). 그래서 blind 여부는 다음 규칙에
달려 있다.

- 아직 풀지 않은 form의 문제 파일과 그 diff를 열지 않는다.
- 이 디렉터리를 바꾸는 commit message와 작업 요약에는 문제 본문이나 정답을 쓰지 않는다.
  문제 ID, 도메인, 검증 결과만 쓴다.
- form을 한 번 푼 뒤에는 그 form의 `answer.md`를 읽어도 된다.

## 구조

```text
exam/bank/
  forms/<NAME>.tsv                 고정 form 하나 (NAME은 대문자 한 글자, 예: A)
  <domain>/ex-<domain 약어>-NN/   문제 하나. 연습 문제와 같은 파일 구성
    meta.yaml  question.md  setup.sh  grade.sh  solve.sh  answer.md
    [teardown.sh] [near-miss.sh] [alternative.sh]
```

form 파일의 각 줄은 `id|setup_priority|mutex|breaks|requires`다. 줄 순서가 화면 표시 순서다.
runner는 다음을 검사하고, 하나라도 어기면 준비를 거부한다.

- 서로 다른 문제 17개, 모두 `environment: shared-kind`
- 도메인별 문항 수 Troubleshooting 5, Cluster Architecture 4, Services & Networking 3,
  Workloads & Scheduling 3, Storage 2
- `exam/planner.sh`와 같은 호환성 규칙(mutex, breaks↔breaks, breaks↔requires)

제출 파일은 각 문제의 `meta.yaml` `answer_files`에 적는다.

## 실행과 노출 기록

```bash
cka exam-ssh prepare --form A
cka exam-ssh start
```

- `start`는 후보자 접근을 열기 전에 form을 `~/.local/state/cka-practice/exam-bank/ledger.tsv`에
  `EXPOSED`로 기록한다. run이 실패해도 기록은 남는다.
- 노출된 form은 `--allow-seen` 없이 다시 준비할 수 없다. `--allow-seen` run은 blind가 아니다.
- `grade`는 run 디렉터리의 `result.json`에 문제별·도메인별 점수, blind 여부, 준비도 판정
  (`readinessPass`)을 남긴다. 준비도 판정은 blind form, 시험 PASS, `exam/readiness-policy.yaml`의
  총점·도메인 기준을 모두 요구한다.

- `<domain>`은 `storage`, `workloads-scheduling`, `services-networking`,
  `cluster-architecture`, `troubleshooting` 중 하나다.
- 문제 ID는 `ex-(st|wl|sn|ca|ts)-NN` 형식이다. 예: `ex-ts-01`. 연습 문제 ID
  `(st|wl|sn|ca|ts)-NN`과 겹치지 않는다.
- 문제 스크립트는 `lib/`를 `source "$(dirname "${BASH_SOURCE[0]}")/../../../../lib/common.sh"`처럼
  한 단계 더 깊은 상대 경로로 불러온다.

## 문제를 찾는 경로

- 감독형 시험 runner만 `exam_bank_qdir_of`([lib/common.sh](../../lib/common.sh))로 이 디렉터리의
  문제를 찾는다.
- 연습 명령(`cka list`, `cka start`, `cka solution` 등)과 웹 UI는 `questions/`만 읽는다. 시험 은행
  ID를 주면 거부한다. `tests/test_exam_bank.py`와 `tests/contract-test.sh`가 이 격리를 검사한다.
- 연습 catalog(`exam/forms/question-catalog.tsv`), curriculum registry, SSH 연습 허용 목록에는 시험
  은행 ID를 넣지 않는다.
