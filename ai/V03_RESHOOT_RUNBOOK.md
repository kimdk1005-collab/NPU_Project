# B 최종 v03 재촬영 Runbook

> 상태: **강화 재촬영·추가 학습·최종 v03 패키징 완료**
>
> 이전 55.47% ZIP은 폐기 대상이며, 최종 정본은 `results/b_deliver_v03.zip`이다.

## 원칙

- 기존 `ai/dataset_samples_target`, `ai/no_target_samples`와 현재 v03 초안 산출물은 삭제하지 않는다.
- 기존 촬영본은 보존하고 새 강화 촬영본은
  `ai/dataset_samples_target_v03_strict`에만 저장한다. 무표적 v03은 기존
  `ai/no_target_samples_v03`을 우선 재사용하되 최종 SCORE 분리도가 나쁘면 추가 촬영한다.
- 한 `session_id`는 하나의 `train`, `validation`, `test` 역할만 가진다.
- Validation/Test Session은 Train 촬영이 끝난 뒤 카메라 또는 촬영판을 다시 설치해 독립적으로 촬영한다.
- 표적 Sample은 `Target Positive Pixel >= 4`, `Target Event Pixel >= 8`,
  `Target/Active Event Ratio >= 0.10`, 전체 활성 픽셀 `8~1200`,
  `Positive Energy Argmax == Label Cell`을 모두 만족해야 저장된다.
  손은 나와도 되지만 손 Event가 표적보다 강한 프레임은 자동 폐기한다.
- 모든 새 NPZ에는 Session metadata가, `audit/`에는 원본+검출 Mask JPEG가 함께 저장된다.
- 재촬영 전 v03 산출물은 `archive/v03_pre_reshoot_20260825/`에 보관했다.
  현재 `results/b_deliver_v03.zip`은 강화 재촬영·추가 학습 후 다시 만든 최종 통합 후보이다.
- 외장 카메라 `/dev/video2`는 제조사 기본 제어값을 사용하며 수집기가 노출·밝기·화이트밸런스·채도·초점을 강제로 보정하지 않는다. `--lock-v03-camera-controls`는 별도 실험에서만 명시적으로 사용한다.
- 파란 라벨 검출은 제조사 기본 화면에서 검증한 HSV `H=88~118`, `S>=120`,
  `V>=100`을 사용한다. 강화 촬영에서는 면적을 `700~2500 px²`로 제한한다.
  촬영 전에 라벨의 시인성과 손·그림자 오검출 여부를 Preview로 확인한다.

## 목표 수량

### 표적 있음

| 순서 | Session ID | Split | 조건 | 목표 |
|---:|---|---|---|---:|
| 1 | `strict_train_a` | train | 손 노출 최소, 기준 조명·배경 | Cell당 6, 총 384 |
| 2 | `strict_train_b` | train | 손이 보이는 실제 시연 움직임 | Cell당 6, 총 384 |
| 3 | `strict_train_c` | train | 반대 손/이동 방향과 배경 변화 | Cell당 6, 총 384 |
| 4 | `strict_validation` | validation | 카메라/촬영판 재설치 후 독립 촬영 | Cell당 4, 총 256 |
| 5 | `strict_test` | test | 다시 재설치하거나 다른 시간대에 독립 촬영 | Cell당 4, 총 256 |

합계는 고품질 표적 Sample 1,664개다. Train/Validation/Test는 각각
1,152/256/256개다. Sample 수보다 독립 Train Session 다양성과 신호 Gate를 우선한다.

### 무표적

| Session ID | Split | 장면 | 목표 |
|---|---|---|---:|
| `nt_train_quiet` | train | 표적 제거, 정지 장면 | 50 |
| `nt_train_motion` | train | 손·비표적 물체·배경 움직임 | 200 |
| `nt_validation_quiet` | validation | 독립 정지 장면 | 25 |
| `nt_validation_motion` | validation | 독립 비표적 움직임 | 75 |
| `nt_test_quiet` | test | 독립 정지 장면 | 25 |
| `nt_test_motion` | test | 독립 비표적 움직임 | 75 |

무표적 합계는 450개다. 파란 표적 또는 검출 Mask에 잡히는 유사 파란 물체는 화면에서 제거한다.

## 1단계 — 카메라 장치 확인

```bash
v4l2-ctl --list-devices
ls -l /dev/video*
```

장치 번호를 확인한 뒤 아래 `<N>`을 실제 번호로 바꾼다.

```bash
.venv/bin/python ai/dataset.py --mode camera --device <N>
```

확인 항목:

- 실제 사용할 카메라 영상인지
- 해상도가 `640x480`, FPS가 `30`으로 표시되는지
- 영상이 좌우 반전되지 않았는지
- 카메라와 촬영판이 흔들리지 않는지

## 2단계 — 표적 검출과 Event 정렬 Pilot

아래 Pilot은 `/tmp`만 사용한다. 창에서 `s`를 누르지 말고 표적을 움직여 본 뒤 `q`로 종료한다.

```bash
.venv/bin/python ai/dataset.py \
  --mode collect \
  --device <N> \
  --output-dir /tmp/event_camera_v03_strict_pilot \
  --session-id pilot_target \
  --capture-split train \
  --samples-per-cell 1 --threshold 8 \
  --min-active-pixels 8 --max-active-pixels 1200 \
  --min-target-positive-pixels 4 --min-target-event-pixels 8 \
  --min-target-event-ratio 0.10 --require-target-positive-argmax \
  --target-min-area 700 --target-max-area 2500 \
  --environment-note "pilot only"
```

확인 항목:

- 파란 마커 중앙에 녹색 십자가가 안정적으로 표시된다.
- `Target Marker Mask`에는 마커만 흰색으로 표시된다.
- 파란 라벨의 `AREA`가 대체로 `700~2500` 안에서 유지되도록 거리와 각도를 고정한다.
- 마커를 한 Cell에서 다음 Cell로 움직일 때 `TGT_POS>=4`, `TGT_EVT>=8`,
  `RATIO>=0.10`, `POS_TOP=YES`가 반복해서 나온다.
- 마커가 검출되지 않거나 배경까지 Mask에 잡히면 본 촬영을 시작하지 않는다.

## 3단계 — 표적 Session 촬영

마커는 화면 밖 또는 이전 Cell에서 목표 Cell 안으로 일정한 속도로 넣는다. 한 위치에
멈춰 있는 동안에는 Event가 없으므로 저장되지 않는 것이 정상이다. 손은 보여도 되지만
파란 라벨을 가리지 말고 물체의 뒤나 가장자리를 잡는다. 카메라와 물체 거리를 Session
중간에 바꾸지 않는다.

아래 공통 옵션을 모든 표적 Session에 사용한다.

```text
--output-dir ai/dataset_samples_target_v03_strict
--threshold 8 --min-active-pixels 8 --max-active-pixels 1200
--min-target-positive-pixels 4 --min-target-event-pixels 8
--min-target-event-ratio 0.10 --require-target-positive-argmax
--target-min-area 700 --target-max-area 2500 --save-cooldown-frames 4
```

Session은 위 표 순서대로 촬영한다. Train 세 Session은 Cell당 6개,
Validation/Test는 Cell당 4개다. 각 실행에는 해당 Session ID, Split,
환경 설명과 위 공통 옵션을 함께 넣는다.

각 Session 직후 검사한다.

```bash
.venv/bin/python ai/dataset.py --mode dataset-check \
  --output-dir ai/dataset_samples_target_v03_strict \
  --session-id strict_train_a --capture-split train --samples-per-cell 6 \
  --min-active-pixels 8 --max-active-pixels 1200 \
  --min-target-positive-pixels 4 --min-target-event-pixels 8 \
  --min-target-event-ratio 0.10 --require-target-positive-argmax
```

다른 Session도 `session-id`, `capture-split`, `samples-per-cell`을 표에 맞게 바꿔 반복한다.

## 4단계 — 무표적 Session 촬영

정지 장면은 `min=0`, 느린 저장 간격을 사용한다.

```bash
.venv/bin/python ai/dataset.py --mode collect-no-target --device <N> --auto-save \
  --session-id nt_train_quiet --capture-split train --max-samples 50 \
  --min-active-pixels 0 --max-active-pixels 40 --save-cooldown-frames 15 \
  --environment-note "표적 없음, 정지 장면"
```

움직임 장면은 손, 케이블, 비표적 물체, 배경 움직임을 다양하게 만든다.

```bash
.venv/bin/python ai/dataset.py --mode collect-no-target --device <N> --auto-save \
  --session-id nt_train_motion --capture-split train --max-samples 200 \
  --min-active-pixels 5 --max-active-pixels 1800 --save-cooldown-frames 5 \
  --environment-note "표적 없음, 손과 비표적 물체 움직임"
```

Validation/Test의 quiet/motion Session도 위 표의 ID, Split, 목표 수로 반복한다.

각 Session 직후 같은 품질 범위로 검사한다.

```bash
.venv/bin/python ai/dataset.py --mode no-target-check \
  --session-id nt_train_motion --capture-split train \
  --min-active-pixels 5 --max-active-pixels 1800
```

## 5단계 — 사람이 확인할 Audit

각 Session에서 시작·중간·끝과 화면 모서리 Cell을 포함해 최소 20장의 `audit/*.jpg`를 연다.

- 왼쪽 원본에서 실제 표적 중심과 Label 위치가 일치하는지 확인한다.
- 오른쪽 Mask가 표적만 흰색으로 분리하는지 확인한다.
- 무표적 Audit에 실제 표적이 들어오지 않았는지 확인한다.
- 잘못된 Sample이 하나라도 있으면 임의로 학습에 포함하지 않고 해당 Session을 재촬영한다.

## 6단계 — 최종 학습 전 Gate

다음 조건을 전부 통과한 뒤에만 final v03 학습을 시작한다.

- 표적 1,664개와 무표적 450개가 모두 형식 검증을 통과한다.
- Train/Validation/Test 각각 64개 Cell이 비어 있지 않다.
- 모든 표적 Sample이 `Target Positive >= 4`, `Target Event >= 8`,
  `Target/Active >= 0.10`, 활성 픽셀 `8~1200`, Positive Argmax 일치를 만족한다.
- 모든 Sample이 `v03_reshoot_1` Session metadata와 Audit JPEG를 가진다.
- Validation/Test Session ID가 Train Session ID와 겹치지 않는다.
- Audit 육안 검수가 끝났다.

그 뒤 `ai/train.py`의 기본 `session` Split으로 학습하고, INT8 평가·SCORE_TH 보정·Golden/Test Vector·Handoff·ZIP을 전부 다시 생성한다.

## 완료 결과

- 표적: 1,664장 — Train 1,152 / Validation 256 / Test 256
- 무표적: 450장 — Train 250 / Validation 100 / Test 100
- Dataset 형식 오류·품질 범위 이탈: 0장
- 표적/무표적 Validation·Test는 Train과 다른 촬영 Session으로 격리
- 최종 FP32 Test Cell Accuracy: 0.9844, Mean MAE: 0.219 px
- 최종 INT8 Test Cell Accuracy: 0.9766, Mean MAE: 0.359 px
- 이전 보류본 INT8 0.5547 대비 +0.4219 (+42.19 percentage points)
- 후보 선택에는 Validation만 사용했고 Test는 최종 후보에 한 번만 평가
- Weight Layout OIHW, Q24 Requant, case00~02 Conv1~4 Integer Golden bit-exact 검증 PASS
- `model_v03` / `weight_v03` / `golden_v03` / `testvec_v03` Version Lock 및 ZIP checksum 검증 PASS
- 최종 ZIP SHA-256: `2a73ff6a810cd8b44b599440ee85cefbd9e6028dc528a9f364f4af9887c75b90`

`SCORE_TH`는 held-out Validation에서 완전 분리되지 않았다. 규격 기본값 `0`은 유지하되
무표적 FPR이 높다는 측정 결과와 후보 임계값은 `results/model_v03_score_th_calibration_report.md`와
`handoff/B_MODEL_HANDOFF.md` §8에 명시했다. A/C 승인 없이 임계값이나 인터페이스를 임의로
동결하지 않는다.
