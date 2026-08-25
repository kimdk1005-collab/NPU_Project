# 팀 협업 가이드

이 문서는 A·B·C 전원이 동일하게 적용하는 Git·검증·인계 규칙이다.

## 브랜치와 병합 흐름

```text
main          검증 완료 통합 기준점
integration   역할별 기능을 모아 전체 검증하는 브랜치

feature/a-*   A 작업
feature/b-*   B 작업
feature/c-*   C 작업
docs/*        공통 문서 정리
chore/*       저장소 구조·도구·관리 작업
```

기본 흐름:

```text
feature/* → 역할별 단위 Test → PR(integration)
integration → 전체 통합 Test·Timing → PR(main)
```

`main`과 `integration`에 직접 커밋하지 않는다. 긴급 수정도 기능 브랜치와 PR을 사용한다.
두 브랜치는 삭제하지 않는 장기 브랜치이며 강제 Push와 삭제를 GitHub 보호 규칙으로 막는다.
병합 후 자동 삭제는 `feature/*`, `docs/*`, `chore/*` 같은 단기 브랜치에만 적용한다.

### `integration` 유지 확인

`integration → main` PR을 병합한 뒤 저장소 관리자는 `integration`이 남아 있는지 확인한다.

```bash
git fetch origin --prune
git branch -r
```

만약 운영 실수로 삭제됐다면 최신 `main`에서 즉시 복구하고 보호 규칙을 다시 확인한다.

```bash
git push origin origin/main:refs/heads/integration
```

복구 명령은 저장소 관리자만 수행한다. 일반 작업자는 삭제된 브랜치를 임의의 과거
Commit에서 만들지 않는다.

## 작업 시작

```bash
git fetch origin --prune
git switch integration
git pull --ff-only

# 역할에 맞는 예시 하나를 선택한다.
git switch -c feature/a-npu-<topic>
git switch -c feature/b-model-<topic>
git switch -c feature/c-event-control-<topic>
```

작업 중 `integration` 변경을 다시 받을 때는 팀이 합의한 방식으로 rebase한다.

```bash
git fetch origin
git rebase origin/integration
```

rebase 전에 자신의 변경을 커밋하고, 다른 사람의 파일이나 생성물을 임의로 삭제하지 않는다.

## 파일 소유권

| 역할 | 기본 소유 경로 |
|---|---|
| A | `rtl/npu/`, `rtl/integration/`, `tb/npu/`, `sw/` |
| B | `ai/`, `weights/`, `test_vectors/`, `golden_outputs/`, `results/model/` |
| C | `rtl/event/`, `rtl/control/`, `tb/event/`, `tb/control/` |

공유 파일은 관련 역할의 확인 없이 인터페이스를 바꾸지 않는다.

- `docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md`
- `docs/interface_contract.md`
- `docs/change_log.md`
- `docs/integration_manifest.md`
- `rtl/integration/top_system.v`
- `constraints/`

다른 역할의 오류를 발견하면 먼저 Issue/PR 설명에 근거를 남기고, 소유자와 수정 범위를
합의한다. 단순 포맷 수정도 동작·수치 계약에 영향을 주는지 확인한다.

## Commit 규칙

한 Commit에는 가능한 한 한 종류의 변경만 넣는다.

```text
[A][NPU] Add INT8 requant module
[A][SW] Add AXI status polling
[B][MODEL] Export quantized weights
[B][GOLDEN] Add conv2 reference vectors
[C][EVENT] Add polarity accumulator
[C][CTRL] Add servo dead-zone logic
[INT] Connect event tensor to NPU
[DOCS] Update approved interface status
[TEAM][STRUCTURE] Add shared workspace template
```

`final`, `update`, `fix everything`처럼 변경 범위를 알 수 없는 메시지는 사용하지 않는다.

## PR 작성과 리뷰

PR은 `.github/PULL_REQUEST_TEMPLATE.md`의 항목을 채운다.

필수 내용:

1. 담당 역할과 변경 목적
2. 수정한 소유 경로와 공유 파일
3. 실행한 명령, PASS 수와 실패 여부
4. Interface/Model/Weight/Golden 버전 변화
5. Change Request 또는 승인 필요 여부
6. 아직 수행하지 못한 실물·통합 검증과 블로커

`Repository Policy / repository-structure` 검사는 필수다. 이 검사는 역할별 기본 경로,
Markdown 상대 링크, `docs/` 구버전 사본과 생성 가능한 빌드 산출물의 추적 여부를 확인한다.

공유 인터페이스나 `constraints/`를 변경한 PR은 영향받는 역할 전원의 확인을 받은 뒤
병합한다. PR 작성자가 자신의 단위 검증 결과를 먼저 확인하고, 리뷰어는 계약·경로·재현성을
확인한다.

## 역할별 병합 Gate

### A

- `tb/npu/`의 관련 RTL TB PASS
- B Golden과 bit-exact 비교 결과 기록
- AXI/Top 변경 시 C 포트 및 START 단일 소유권 확인
- 합성·implementation 수행 시 Timing/DRC와 대상 부품 기록

### B

- Dataset/Model/Quantization 버전 고정
- 공식 Vector·Golden 생성 명령, seed, checksum 기록
- FP32↔INT8 차이와 Accuracy 결과 기록
- `handoff/B_MODEL_HANDOFF.md` 갱신

### C

- 변경 영향 범위의 `tb/event/`, `tb/control/` PASS
- Fail-closed, E-stop, Limit, 재무장 경로 유지 확인
- 실물 결과와 시뮬레이션 결과를 구분해 기록
- `handoff/C_EVENT_CONTROL_HANDOFF.md` 갱신

### Integration

- `docs/integration_manifest.md`의 조합 버전 일치
- B Golden ↔ A NPU 비교 PASS
- C Event Tensor ↔ A NPU 입력 비교 PASS
- A Target ↔ C Tracking/Interlock 연결 PASS
- 전체 시스템 Timing/DRC 및 보드 안전 Gate 확인

## 진행상황 공유 형식

각 역할은 일일 공유나 PR 업데이트에 같은 형식을 사용한다.

```text
[역할 / 날짜]
- 완료:
- 검증: 실행 명령 / PASS 수
- 변경된 계약·버전: 없음 또는 문서/CR 번호
- 블로커·승인 요청:
- 다음 작업:
```

팀 전체 현황은 `docs/PROJECT_STATUS.md`, 산출물 조합은 `docs/integration_manifest.md`,
세부 인계는 역할별 Handoff 문서에 반영한다.

## 저장소에 올리지 않는 파일

- Vivado/Vitis 생성물: `.runs/`, `.cache/`, `.Xil/`, `xsim.dir/`, GUI 프로젝트 사본
- 로그, 파형, 재생성 가능한 Bitstream/XSA/ELF
- Python 가상환경, cache, 임시 Dataset 사본
- 개인 토큰, 비밀번호, 장치 인증정보

필요한 결과는 원본 바이너리 대신 버전, 생성 명령, 크기, checksum과 판정값을 Handoff와
Manifest에 기록한다.
