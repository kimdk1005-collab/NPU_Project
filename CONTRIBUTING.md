# 팀 협업 가이드

## 브랜치

```text
main                       검증된 통합 기준점
integration                팀 기능을 모으는 브랜치
feature/a-npu              A 작업
feature/b-model            B 작업
feature/c-event-control    C 작업
```

직접 `main`에 커밋하지 않는다. 각 기능 브랜치에서 작업하고 Draft Pull Request를
`integration` 대상으로 연다. 전체 통합 검증이 끝난 시점에만 `integration`을
`main`으로 합친다.

## 업데이트 순서

```bash
git fetch origin
git switch feature/c-event-control   # 각자 자신의 브랜치 사용
git rebase origin/integration

# 변경 및 담당 테스트 실행
git add -- <담당 파일만 지정>
git commit -m "[C][EVENT] Add accumulator"
git push -u origin feature/c-event-control
```

Pull Request에는 다음을 적는다.

- 무엇을 구현했는지
- 실행한 테스트와 PASS 수
- 공유 인터페이스 변경 여부
- 남은 블로커 또는 실물 검증 항목

## 진행상황 공유

- 팀 전체 현황: `docs/PROJECT_STATUS.md`
- C 상세 인수인계: `handoff/C_EVENT_CONTROL_HANDOFF.md`
- 일일 작업 근거: 담당 체크리스트 또는 GitHub Issue
- 인터페이스 변경: `docs/CHANGE_REQUEST_*.md` 작성 후 승인

## 커밋 규칙

형식은 `[담당][영역] 명령형 요약`을 사용한다.

```text
[A][NPU] Add INT8 requantizer
[B][MODEL] Export integer golden vectors
[C][CTRL] Add servo dead-zone logic
[INT] Integrate event tensor path
```

## 저장소에 올리지 않는 파일

Vivado/Vitis가 다시 생성할 수 있는 `.runs/`, `.cache/`, `.Xil/`, `xsim.dir/`,
로그, 파형, GUI 프로젝트 사본, 비트스트림은 커밋하지 않는다. 개인 토큰, 비밀번호,
장치 인증정보도 절대 커밋하지 않는다.
