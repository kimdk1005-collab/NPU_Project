// NPU 공통 정의 -- docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md v1.2 기준
`ifndef NPU_DEFS_VH
`define NPU_DEFS_VH

`define NPU_NPE          8      // PE 개수 = 병렬 출력 채널 수 (spec 18)
`define NPU_SHIFT        24     // requantize right shift (spec 9.4)
`define NPU_ACT_DEPTH    8192   // 64*64*2 = 최대 activation 버퍼 크기
`define NPU_ACT_AW       13
`define NPU_WROM_DEPTH   770    // 뱅크당 weight 개수 (18+144+576+32)
`define NPU_WROM_AW      10

// $readmemh 경로: 시뮬/합성 모두 build/ 를 작업 디렉토리로 가정
`ifndef NPU_WEIGHT_DIR
  `define NPU_WEIGHT_DIR "../weights/"
`endif
`ifndef NPU_TV_DIR
  `define NPU_TV_DIR "../test_vectors/case00/"
`endif

`endif
