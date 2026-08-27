# C → A 승인 — `D3_FREEZE_REQUEST_A_002` rev.2 §2.13 좌표변환식

> 승인일: 2026-08-27
>
> 승인자/담당: C (Event Camera / Tracking / Servo / Laser)
>
> 대상: `docs/D3_FREEZE_REQUEST_A_002.md` rev.2 §2.13
>
> 상태: **승인·RTL 구현·단위 TB 확인 완료 / 실물 축 방향·FOV·Offset 보정 대기**

## 1. 승인 결론

C는 다음 PT#2 절대 좌표변환식을 승인한다.

```text
theta_pan_target  = theta_pan1  + k_x * (target_x - 32)
theta_tilt_target = theta_tilt1 + k_y * (target_y - 32)

PAN2_CMD  = theta_pan_target  + LASER_OFFSET_PAN
TILT2_CMD = theta_tilt_target + LASER_OFFSET_TILT
```

`theta_pan1`과 `theta_tilt1`은 별도 센서값이나 화면 오차가 아니라, Tracking
Controller가 현재 출력하고 있는 PT#1 Camera PAN/TILT 명령값이다. PT#2를
`error_x/error_y`만으로 계산하는 방식은 채택하지 않는다.

## 2. RTL 대응

구현 위치는 `rtl/control/laser_head_controller.v`다.

| 승인식 항목 | RTL 대응 |
|---|---|
| `target_x/y - 32` | `error_x`, `error_y` |
| `k_x`, `k_y` | `PAN_ERR_NUM/DEN`, `TILT_ERR_NUM/DEN` 및 축 반전 parameter |
| `theta_pan1/tilt1` | `camera_pan_pos`, `camera_tilt_pos` |
| `LASER_OFFSET_*` | 정적 `*_OFFSET_POS` 또는 signed runtime `LASER_CAL` |
| 최종 PT#2 명령 | `laser_pan_target`, `laser_tilt_target` 등록 후 Frame 기반 Slew |

새 NPU 결과의 `target_update && target_valid` 시점에 PT#1 자세, 화면 잔차,
Offset을 더한 절대 목표를 등록한다. 그 뒤 `SAFE_LIMIT2` clamp와 Slew를 적용하며,
PT#2 실제 명령이 목표에 도달하기 전에는 `aim_ready`를 열지 않는다.

## 3. 검증 근거

`tb/control/tb_laser_head_controller.v`에서 다음을 자동 판정한다.

- PT#1 자세 `140/120`과 잔차 `+12/-12`를 더해 PT#2 목표 `152/108` 생성
- 분수 Scale, 축 반전, 정적 Offset 적용
- signed runtime `LASER_CAL` 우선 적용
- `SAFE_LIMIT2` 최종 clamp
- `target_valid=0`일 때 위치 Hold와 `aim_ready=0`

`tb/control/tb_dual_head_control.v`에서도 PT#1 Tracking 출력 자세를 포함한 PT#2
절대 목표와 4축 통합 동작을 재검증한다. 2026-08-27 전체 C 회귀 결과는
자동판정 13 TB **341 PASS, errors=0**이다.

## 4. 승인과 별개로 남은 실물 보정

식과 RTL 구조는 승인했지만 `k_x/k_y`의 최종 크기·부호, Servo 축 방향,
`LASER_OFFSET_PAN/TILT`는 실물 측정값이 아니다. Camera/Laser FOV, 두 헤드
baseline, 고정 시연 거리에서 중앙+네 모서리를 측정한 뒤 확정한다. 측정 전에는
정적 기본값과 LED/dummy-load 검증까지만 사용한다.
