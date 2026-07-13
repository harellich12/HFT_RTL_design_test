SHELL := /bin/bash

.PHONY: all lint test waves clean help

all:
	@bash scripts/run_verilator_flow.sh all

lint:
	@bash scripts/run_verilator_flow.sh lint

test:
	@bash scripts/run_verilator_flow.sh test

# Open a smoke waveform in gtkwave. Defaults to the top-level engine; pick a
# leaf block with: make waves MOD=risk_gate
waves:
	@MOD="$(MOD)" bash scripts/run_verilator_flow.sh waves

clean:
	@bash scripts/run_verilator_flow.sh clean

help:
	@bash scripts/run_verilator_flow.sh help
