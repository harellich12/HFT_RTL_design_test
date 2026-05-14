## 6. ARCHITECTURAL RATIONALE — FOR AGENT CONTEXT

This section is not a constraint. It exists so the agent understands *why* the constraints exist and does not optimize them away.

**Why no OS?** A Linux kernel interrupt round-trip is 5–50 µs. The entire target latency budget for this engine is under 1 µs wire-to-wire. The OS is not slow — it is irrelevant.

**Why no AXI?** AXI-Stream adds handshake latency even in back-to-back transfers. `TREADY` assertion requires combinational paths from slave to master that cross module boundaries. At 156.25 MHz, a single unnecessary handshake cycle costs 6.4 ns — roughly 1% of the total latency budget.

**Why fixed offsets?** Variable-length header parsing requires either a state machine (variable latency) or a CAM (area-expensive, multi-cycle). The market data feeds this engine targets (ITCH, OUCH, FAST) use fixed-format messages at fixed UDP payload offsets. Treat this as a protocol constraint, not a simplification.

**Why cut-through?** The full inbound Ethernet frame is ~100–200 bytes at a 64-byte minimum. At 10 Gbps, receiving the full frame before processing it adds 80–160 ns. Cut-through eliminates that wait entirely.

**The kill path is the most important path.** A false `risk_pass` is a trading halt. A late `risk_kill` is a regulatory violation. The kill path must be verified with higher coverage priority than the pass path.