#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

failures=0

report_failure() {
    printf 'ERROR: %s\n' "$1" >&2
    failures=$((failures + 1))
}

required_paths=(
    README.md
    CONTRIBUTING.md
    .github/PULL_REQUEST_TEMPLATE.md
    docs/00_DOCUMENT_INDEX.md
    docs/TEAM_COMMON_AI_INTEGRATION_SPEC.md
    docs/TEAM_ROLE_PLAN.md
    docs/NPU_DEVELOPMENT_PLAN.md
    docs/interface_contract.md
    docs/PROJECT_STATUS.md
    docs/integration_manifest.md
    rtl/npu/README.md
    rtl/integration/README.md
    tb/npu/README.md
    sw/README.md
    ai/README.md
    weights/README.md
    test_vectors/README.md
    golden_outputs/README.md
    results/model/README.md
    rtl/event/README.md
    rtl/control/README.md
    tb/event/README.md
    tb/control/README.md
    handoff/README.md
    handoff/B_MODEL_HANDOFF.md
    handoff/C_EVENT_CONTROL_HANDOFF.md
)

for required_path in "${required_paths[@]}"; do
    if [[ ! -f "$required_path" ]]; then
        report_failure "required repository path is missing: $required_path"
    fi
done

while IFS=: read -r markdown_file markdown_line markdown_link; do
    link_target="${markdown_link##*(}"
    link_target="${link_target%)}"
    link_target="${link_target%%#*}"

    case "$link_target" in
        http://*|https://*|mailto:*|"")
            continue
            ;;
    esac

    resolved_path="$(dirname "$markdown_file")/$link_target"
    if [[ ! -e "$resolved_path" ]]; then
        report_failure "broken Markdown link at $markdown_file:$markdown_line -> $link_target"
    fi
done < <(
    rg -n -o '\[[^]]+\]\([^)]+\)' \
        README.md CONTRIBUTING.md .github docs handoff rtl tb sw ai weights \
        test_vectors golden_outputs results
)

while IFS= read -r duplicate_candidate; do
    [[ -z "$duplicate_candidate" ]] && continue
    report_failure "versioned or duplicate canonical document is tracked: $duplicate_candidate"
done < <(
    git ls-files docs \
        | rg '(_v[0-9]+|\([0-9]+\)|(^|/)_README_DO_NOT_EDIT|\.txt$)' \
        || true
)

while IFS= read -r generated_file; do
    [[ -z "$generated_file" ]] && continue
    report_failure "generated build artifact is tracked: $generated_file"
done < <(
    git ls-files \
        | rg '(\.(bit|xsa|elf|jou|log|wdb|pb)$|(^|/)(xsim\.dir|\.Xil|[^/]+\.runs|[^/]+\.cache)/)' \
        || true
)

if (( failures > 0 )); then
    printf 'Repository policy check failed: %d issue(s)\n' "$failures" >&2
    exit 1
fi

printf 'Repository policy check passed: required paths, Markdown links, canonical docs, artifacts\n'
