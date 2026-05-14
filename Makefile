SHELL := /bin/bash

.PHONY: all lint test clean help

all:
	@bash scripts/run_verilator_flow.sh all

lint:
	@bash scripts/run_verilator_flow.sh lint

test:
	@bash scripts/run_verilator_flow.sh test

clean:
	@bash scripts/run_verilator_flow.sh clean

help:
	@bash scripts/run_verilator_flow.sh help
