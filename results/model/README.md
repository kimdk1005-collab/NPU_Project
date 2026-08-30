# B 역할 — Model 측정 결과

이 폴더의 `model_v03_*` 파일은 이전 정본의 학습·평가 이력으로 보존한다. 현재 통합 대상은
`model_v04_demo_masked_radius1_x1`이며 승인 성능 요약과 범위 제한은
`../../handoff/B_MODEL_HANDOFF.md`에 기록한다.

v04 원본 per-frame Dataset/평가 묶음은 공개 저장소 범위에 포함되지 않았다. 이 저장소에
없는 결과 파일을 생성된 것처럼 표시하지 않으며, 승인 checkpoint·Weight·Golden의 실제
파일 지문은 `../../golden_outputs/model_v04_demo_manifest.json`을 사용한다.

Vivado/Vitis 바이너리나 로그는 이 폴더에 저장하지 않는다.
