# B 역할 — Integer Golden Output

> 소유: B · A RTL의 bit-exact 판정 기준

공식 Test Vector에 대응하는 Layer별 Tensor, Heatmap, Argmax 좌표와 Score를 둔다.
출력 파일은 입력·Weight 버전과 일대일로 추적 가능해야 하며, 반올림·포화·Tie-Break
규칙을 `docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md`와 동일하게 유지한다.
