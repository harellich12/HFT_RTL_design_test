// Bit-accurate C++ reference model of the strategy_core decision function.
//
// Compiled into the Verilator testbench through DPI and compared against the
// RTL on every decision cycle. This file is the golden definition of the
// Stage-1 strategy; any change to rtl/strategy_core.sv decision behavior must
// change here first, and tb_strategy_core must stay green against both.

#include <cstdint>

namespace {

constexpr int32_t kSideBuy  = 0x42;
constexpr int32_t kSideSell = 0x53;

constexpr int32_t kPolicySame      = 0;
constexpr int32_t kPolicyOpposite  = 1;
constexpr int32_t kPolicyFixedBuy  = 2;
constexpr int32_t kPolicyFixedSell = 3;

}  // namespace

extern "C" {

// Decision codes returned to the testbench.
enum StrategyDecision : int32_t {
    kDecisionIdle     = 0,  // no market_valid: no output pulse expected
    kDecisionValid    = 1,  // order_valid with the fields written below
    kDecisionSuppress = 2,  // order_suppress
    kDecisionErr      = 3,  // order_err
};

int32_t strategy_ref_decide(int32_t market_valid,
                            int32_t market_err,
                            int32_t init_active,
                            int32_t msg_type,
                            int32_t cfg_msg_type,
                            int32_t entry_enable,
                            int32_t side_policy,
                            int64_t entry_qty,
                            int32_t market_side,
                            int32_t* order_side,
                            int64_t* order_qty) {
    *order_side = 0;
    *order_qty  = 0;

    if (!market_valid) {
        return kDecisionIdle;
    }
    if (market_err) {
        return kDecisionErr;
    }

    const bool side_known = (market_side == kSideBuy) || (market_side == kSideSell);
    const bool needs_side =
        (side_policy == kPolicySame) || (side_policy == kPolicyOpposite);

    const bool tradeable = !init_active
                        && (msg_type == cfg_msg_type)
                        && entry_enable
                        && (!needs_side || side_known);

    if (!tradeable) {
        return kDecisionSuppress;
    }

    switch (side_policy) {
        case kPolicySame:      *order_side = market_side; break;
        case kPolicyOpposite:  *order_side = (market_side == kSideBuy) ? kSideSell
                                                                       : kSideBuy; break;
        case kPolicyFixedBuy:  *order_side = kSideBuy; break;
        case kPolicyFixedSell: *order_side = kSideSell; break;
        default:               *order_side = kSideBuy; break;
    }
    *order_qty = entry_qty;
    return kDecisionValid;
}

}  // extern "C"
