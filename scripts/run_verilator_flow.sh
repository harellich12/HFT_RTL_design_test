#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

verilator_bin="${VERILATOR:-verilator}"
# Verilator 5.048 can hit an internal thread-pool shutdown failure during
# --binary builds at high -j values. Keep smoke builds deterministic by default;
# override with JOBS=N when the local toolchain is known to be stable.
jobs="${JOBS:-1}"
build_root="${BUILD_ROOT:-/tmp/hft_verilator_flow_${USER:-user}}"

usage() {
    cat <<'USAGE'
Usage: scripts/run_verilator_flow.sh [lint|test|all|clean]

Targets:
  lint   Lint RTL, smoke testbenches, and assertion binds.
  test   Build and run all available smoke testbenches with Verilator.
  all    Run lint, then build and run smoke tests.
  clean  Remove Verilator build output.

Environment:
  VERILATOR=/path/to/verilator   Override Verilator executable.
  JOBS=N                         Parallel make jobs used by Verilator builds; defaults to 1.
  BUILD_ROOT=/tmp/path            Verilator build dir; must not contain spaces.
USAGE
}

need_tool() {
    local tool_name="$1"

    if ! command -v "$tool_name" >/dev/null 2>&1; then
        echo "error: required tool '$tool_name' not found in PATH" >&2
        echo "hint: on Ubuntu/WSL, try: sudo apt update && sudo apt install -y make g++ verilator" >&2
        exit 127
    fi
}

check_build_root() {
    case "$build_root" in
        *" "*)
            echo "error: BUILD_ROOT contains spaces: '$build_root'" >&2
            echo "hint: use a path such as /tmp/hft_verilator_flow" >&2
            exit 2
            ;;
    esac
}

run_cmd() {
    echo
    echo "+ $*"
    "$@"
}

lint_rtl() {
    run_cmd "$verilator_bin" --lint-only --timing --assert --top-module mac_shim \
        rtl/mac_shim.sv \
        rtl/mac_shim_assertions.sv

    run_cmd "$verilator_bin" --lint-only --timing --assert --top-module hdr_stripper \
        rtl/hdr_stripper.sv \
        rtl/hdr_stripper_assertions.sv

    run_cmd "$verilator_bin" --lint-only --timing --assert --top-module field_aligner \
        rtl/field_aligner.sv \
        rtl/field_aligner_assertions.sv

    run_cmd "$verilator_bin" --lint-only --timing --assert --top-module sym_id_mapper \
        rtl/sym_id_mapper.sv \
        rtl/sym_id_mapper_assertions.sv

    run_cmd "$verilator_bin" --lint-only --timing --assert --top-module risk_gate \
        rtl/risk_gate.sv \
        rtl/risk_gate_assertions.sv

    run_cmd "$verilator_bin" --lint-only --timing --assert --top-module pkt_formatter \
        rtl/pkt_formatter.sv \
        rtl/pkt_formatter_assertions.sv

    run_cmd "$verilator_bin" --lint-only --timing --assert --top-module hft_engine \
        rtl/hft_engine.sv \
        rtl/mac_shim.sv \
        rtl/mac_shim_assertions.sv \
        rtl/hdr_stripper.sv \
        rtl/hdr_stripper_assertions.sv \
        rtl/field_aligner.sv \
        rtl/field_aligner_assertions.sv \
        rtl/sym_id_mapper.sv \
        rtl/sym_id_mapper_assertions.sv \
        rtl/risk_gate.sv \
        rtl/risk_gate_assertions.sv \
        rtl/pkt_formatter.sv \
        rtl/pkt_formatter_assertions.sv
}

lint_tests() {
    run_cmd "$verilator_bin" --lint-only --timing --assert --top-module tb_mac_shim -Irtl \
        tb/tb_mac_shim.sv \
        rtl/mac_shim.sv \
        rtl/mac_shim_assertions.sv

    run_cmd "$verilator_bin" --lint-only --timing --assert --top-module tb_hdr_stripper -Irtl \
        tb/tb_hdr_stripper.sv \
        rtl/hdr_stripper.sv \
        rtl/hdr_stripper_assertions.sv

    run_cmd "$verilator_bin" --lint-only --timing --assert --top-module tb_field_aligner -Irtl \
        tb/tb_field_aligner.sv \
        rtl/field_aligner.sv \
        rtl/field_aligner_assertions.sv

    run_cmd "$verilator_bin" --lint-only --timing --assert --top-module tb_sym_id_mapper -Irtl \
        tb/tb_sym_id_mapper.sv \
        rtl/sym_id_mapper.sv \
        rtl/sym_id_mapper_assertions.sv

    run_cmd "$verilator_bin" --lint-only --timing --assert --top-module tb_risk_gate -Irtl \
        tb/tb_risk_gate.sv \
        rtl/risk_gate.sv \
        rtl/risk_gate_assertions.sv

    run_cmd "$verilator_bin" --lint-only --timing --assert --top-module tb_pkt_formatter -Irtl \
        tb/tb_pkt_formatter.sv \
        rtl/pkt_formatter.sv \
        rtl/pkt_formatter_assertions.sv

    run_cmd "$verilator_bin" --lint-only --timing --assert --top-module tb_hft_engine -Irtl \
        tb/tb_hft_engine.sv \
        rtl/hft_engine.sv \
        rtl/mac_shim.sv \
        rtl/mac_shim_assertions.sv \
        rtl/hdr_stripper.sv \
        rtl/hdr_stripper_assertions.sv \
        rtl/field_aligner.sv \
        rtl/field_aligner_assertions.sv \
        rtl/sym_id_mapper.sv \
        rtl/sym_id_mapper_assertions.sv \
        rtl/risk_gate.sv \
        rtl/risk_gate_assertions.sv \
        rtl/pkt_formatter.sv \
        rtl/pkt_formatter_assertions.sv
}

build_and_run_test() {
    local top_module="$1"
    local module_build_dir="${build_root}/${top_module}"
    shift

    mkdir -p "$module_build_dir"

    run_cmd "$verilator_bin" --binary --timing --trace --Mdir "$module_build_dir" \
        --top-module "$top_module" -Irtl -j "$jobs" "$@"

    run_cmd "${module_build_dir}/V${top_module}"
}

run_tests() {
    mkdir -p "${build_root}/tb_mac_shim"

    run_cmd "$verilator_bin" --binary --timing --assert --trace --Mdir "${build_root}/tb_mac_shim" \
        --top-module tb_mac_shim -Irtl -j "$jobs" \
        tb/tb_mac_shim.sv \
        rtl/mac_shim.sv \
        rtl/mac_shim_assertions.sv

    run_cmd "${build_root}/tb_mac_shim/Vtb_mac_shim"

    mkdir -p "${build_root}/tb_hdr_stripper"

    run_cmd "$verilator_bin" --binary --timing --assert --trace --Mdir "${build_root}/tb_hdr_stripper" \
        --top-module tb_hdr_stripper -Irtl -j "$jobs" \
        tb/tb_hdr_stripper.sv \
        rtl/hdr_stripper.sv \
        rtl/hdr_stripper_assertions.sv

    run_cmd "${build_root}/tb_hdr_stripper/Vtb_hdr_stripper"

    mkdir -p "${build_root}/tb_field_aligner"

    run_cmd "$verilator_bin" --binary --timing --assert --trace --Mdir "${build_root}/tb_field_aligner" \
        --top-module tb_field_aligner -Irtl -j "$jobs" \
        tb/tb_field_aligner.sv \
        rtl/field_aligner.sv \
        rtl/field_aligner_assertions.sv

    run_cmd "${build_root}/tb_field_aligner/Vtb_field_aligner"

    mkdir -p "${build_root}/tb_sym_id_mapper"

    run_cmd "$verilator_bin" --binary --timing --assert --trace --Mdir "${build_root}/tb_sym_id_mapper" \
        --top-module tb_sym_id_mapper -Irtl -j "$jobs" \
        tb/tb_sym_id_mapper.sv \
        rtl/sym_id_mapper.sv \
        rtl/sym_id_mapper_assertions.sv

    run_cmd "${build_root}/tb_sym_id_mapper/Vtb_sym_id_mapper"

    mkdir -p "${build_root}/tb_risk_gate"

    run_cmd "$verilator_bin" --binary --timing --assert --trace --Mdir "${build_root}/tb_risk_gate" \
        --top-module tb_risk_gate -Irtl -j "$jobs" \
        tb/tb_risk_gate.sv \
        rtl/risk_gate.sv \
        rtl/risk_gate_assertions.sv

    run_cmd "${build_root}/tb_risk_gate/Vtb_risk_gate"

    mkdir -p "${build_root}/tb_pkt_formatter"

    run_cmd "$verilator_bin" --binary --timing --assert --trace --Mdir "${build_root}/tb_pkt_formatter" \
        --top-module tb_pkt_formatter -Irtl -j "$jobs" \
        tb/tb_pkt_formatter.sv \
        rtl/pkt_formatter.sv \
        rtl/pkt_formatter_assertions.sv

    run_cmd "${build_root}/tb_pkt_formatter/Vtb_pkt_formatter"

    mkdir -p "${build_root}/tb_hft_engine"

    run_cmd "$verilator_bin" --binary --timing --assert --trace --Mdir "${build_root}/tb_hft_engine" \
        --top-module tb_hft_engine -Irtl -j "$jobs" \
        tb/tb_hft_engine.sv \
        rtl/hft_engine.sv \
        rtl/mac_shim.sv \
        rtl/mac_shim_assertions.sv \
        rtl/hdr_stripper.sv \
        rtl/hdr_stripper_assertions.sv \
        rtl/field_aligner.sv \
        rtl/field_aligner_assertions.sv \
        rtl/sym_id_mapper.sv \
        rtl/sym_id_mapper_assertions.sv \
        rtl/risk_gate.sv \
        rtl/risk_gate_assertions.sv \
        rtl/pkt_formatter.sv \
        rtl/pkt_formatter_assertions.sv

    run_cmd "${build_root}/tb_hft_engine/Vtb_hft_engine"
}

clean_flow() {
    run_cmd rm -rf obj_dir
    run_cmd rm -rf "$build_root"
}

main() {
    local target="${1:-all}"

    case "$target" in
        lint)
            need_tool "$verilator_bin"
            lint_rtl
            lint_tests
            ;;
        test)
            need_tool "$verilator_bin"
            need_tool make
            check_build_root
            mkdir -p "$build_root"
            run_tests
            ;;
        all)
            need_tool "$verilator_bin"
            need_tool make
            check_build_root
            mkdir -p "$build_root"
            lint_rtl
            lint_tests
            run_tests
            ;;
        clean)
            clean_flow
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            echo "error: unknown target '$target'" >&2
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"
