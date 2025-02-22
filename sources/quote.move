module srm_dex_v1::quote {

    /* === Constants === */
    const EZeroInput: u64 = 0;      // Input amount is zero
    const ENoLiquidity: u64 = 4;    // No liquidity in the pool
    const BASIS_POINTS: u64 = 10_000;

    const U64_MAX: u128 = 18_446_744_073_709_551_615;

    /* === Math Helper Functions === */

    /// (a * b) / c, ensuring no division by zero and within u64 bounds.
    fun muldiv(a: u64, b: u64, c: u64): u64 {
        assert!(c > 0, EZeroInput);
        let result = ((a as u128) * (b as u128)) / (c as u128);
        assert!(result <= U64_MAX, EZeroInput);
        result as u64
    }

    /// Calculates ceil_div((a * b), c). Errors if result doesn't fit into u64.
    fun ceil_muldiv(a: u64, b: u64, c: u64): u64 {
        assert!(c > 0, EZeroInput); // Prevent division by zero
    
        let product = (a as u128) * (b as u128);
    
        // Ensure the result will not exceed u64 max when divided
        assert!(product / (c as u128) <= U64_MAX, EZeroInput);

        (ceil_div_u128(product, c as u128) as u64)
    }

    /// Calculates ceil(a / b).
    fun ceil_div_u128(a: u128, b: u128): u128 {
        if (a == 0) 0 else (a - 1) / b + 1
    }

    /* === Swap Quote Functions === */

    /// Get swap quote when user inputs `sellAmount`
    public fun get_swap_quote_by_sell(
    sell_amount: u64, 
    is_a_to_b: bool,
    pool_balance_a: u64,
    pool_balance_b: u64,
    swap_fee: u64, 
    lp_builder_fee: u64, 
    burn_fee: u64, 
    dev_royalty_fee: u64, 
    rewards_fee: u64
): (u64, u64, u64, u64, u64, u64, u64) {
    assert!(pool_balance_a > 0 && pool_balance_b > 0, ENoLiquidity);

    if (is_a_to_b) {
        calc_swap_out_b(
            sell_amount, 
            pool_balance_a,
            pool_balance_b,
            swap_fee, 
            lp_builder_fee, 
            burn_fee, 
            dev_royalty_fee, 
            rewards_fee
        )
    } else {
        calc_swap_out_a(
            sell_amount, 
            pool_balance_a,
            pool_balance_b,
            swap_fee, 
            lp_builder_fee, 
            burn_fee, 
            dev_royalty_fee, 
            rewards_fee
        )
    }
}

    /// Get swap quote when user inputs `buyAmount`
public fun get_swap_quote_by_buy(
    buy_amount: u64, 
    is_a_to_b: bool,
    pool_balance_a: u64,
    pool_balance_b: u64,
    swap_fee: u64, 
    lp_builder_fee: u64, 
    burn_fee: u64, 
    dev_royalty_fee: u64, 
    rewards_fee: u64
): (u64, u64, u64, u64, u64, u64, u64) {
    assert!(pool_balance_a > 0 && pool_balance_b > 0, ENoLiquidity);

    if (is_a_to_b) {
        calc_reverse_swap_out_a(
            buy_amount, 
            pool_balance_a,
            pool_balance_b,
            swap_fee, 
            lp_builder_fee, 
            burn_fee, 
            dev_royalty_fee, 
            rewards_fee
        )
    } else {
        calc_reverse_swap_out_b(
            buy_amount, 
            pool_balance_a,
            pool_balance_b,
            swap_fee, 
            lp_builder_fee, 
            burn_fee, 
            dev_royalty_fee, 
            rewards_fee
        )
    }
}

    /* === Swap Calculation Functions === */

    /// Calculate output when selling token B for token A.
    fun calc_swap_out_a(
    input_amount_b: u64,  
    pool_balance_a: u64,
    pool_balance_b: u64,
    swap_fee: u64, 
    lp_builder_fee: u64,
    burn_fee: u64,
    dev_royalty_fee: u64,
    rewards_fee: u64
): (u64, u64, u64, u64, u64, u64, u64) { 
    assert!(pool_balance_b > 0 && pool_balance_a > 0, ENoLiquidity);

    // Step 1: Apply LP Builder Fee (only if lp_builder_fee > 0)
    let lp_builder_fee_amount_in = if (lp_builder_fee > 0) { 
        ceil_muldiv(input_amount_b, lp_builder_fee, 2 * BASIS_POINTS) 
    } else { 0 };

    let adjusted_amount_in_b = input_amount_b - lp_builder_fee_amount_in;

    // Step 2: Compute output before fees
    let amount_out_a = muldiv(adjusted_amount_in_b, pool_balance_a, pool_balance_b + adjusted_amount_in_b);

    // Step 3: Apply output-side fees (only if they are > 0)
    let swap_fee_amount = if (swap_fee > 0) { ceil_muldiv(amount_out_a, swap_fee, BASIS_POINTS) } else { 0 };
    let burn_fee_amount = if (burn_fee > 0) { ceil_muldiv(amount_out_a, burn_fee, BASIS_POINTS) } else { 0 };
    let dev_fee_amount = if (dev_royalty_fee > 0) { ceil_muldiv(amount_out_a, dev_royalty_fee, BASIS_POINTS) } else { 0 };
    let reward_fee_amount = if (rewards_fee > 0) { ceil_muldiv(amount_out_a, rewards_fee, BASIS_POINTS) } else { 0 };
    let lp_builder_fee_amount_out = if (lp_builder_fee > 0) { 
        ceil_muldiv(amount_out_a, lp_builder_fee, 2 * BASIS_POINTS) 
    } else { 0 };

    // Step 4: Compute final amount after all fees
    let final_amount_out_a = amount_out_a 
        - swap_fee_amount 
        - burn_fee_amount 
        - dev_fee_amount 
        - reward_fee_amount 
        - lp_builder_fee_amount_out;

    // Return all computed values
    (
        final_amount_out_a, 
        lp_builder_fee_amount_in, 
        lp_builder_fee_amount_out, 
        swap_fee_amount, 
        burn_fee_amount, 
        dev_fee_amount, 
        reward_fee_amount
    )
}

/// Calculate output when selling token B for token A.
    fun calc_reverse_swap_out_b(
    buy_amount: u64,  
    pool_balance_a: u64,
    pool_balance_b: u64,
    swap_fee: u64, 
    lp_builder_fee: u64,
    burn_fee: u64,
    dev_royalty_fee: u64,
    rewards_fee: u64
): (u64, u64, u64, u64, u64, u64, u64) { 
    assert!(pool_balance_b > 0 && pool_balance_a > 0, ENoLiquidity);

    // ✅ Step 1: Adjust Buy Amount for LP Builder Fee on output
    let lp_builder_fee_amount_out = if (lp_builder_fee > 0) { 
        ceil_muldiv(buy_amount, lp_builder_fee, 2 * BASIS_POINTS) 
    } else { 0 };

    let adjusted_buy_amount = buy_amount + lp_builder_fee_amount_out; // ✅ Ensuring user receives `buy_amount`

    // ✅ Step 2: Compute Required Sell Amount (Corrected Function Call)
    let raw_sell_amount_b = muldiv(adjusted_buy_amount, pool_balance_b, pool_balance_a - adjusted_buy_amount); 

    // ✅ Step 3: Apply Fees to the Sell Side
    let lp_builder_fee_amount_in = if (lp_builder_fee > 0) { 
        ceil_muldiv(raw_sell_amount_b, lp_builder_fee, 2 * BASIS_POINTS) 
    } else { 0 };

    let swap_fee_amount = if (swap_fee > 0) { ceil_muldiv(raw_sell_amount_b, swap_fee, BASIS_POINTS) } else { 0 };
    let burn_fee_amount = if (burn_fee > 0) { ceil_muldiv(raw_sell_amount_b, burn_fee, BASIS_POINTS) } else { 0 };
    let dev_fee_amount = if (dev_royalty_fee > 0) { ceil_muldiv(raw_sell_amount_b, dev_royalty_fee, BASIS_POINTS) } else { 0 };
    let reward_fee_amount = if (rewards_fee > 0) { ceil_muldiv(raw_sell_amount_b, rewards_fee, BASIS_POINTS) } else { 0 };

    // ✅ Step 4: Final Required Sell Amount
    let final_sell_amount_b = raw_sell_amount_b 
        + lp_builder_fee_amount_in 
        + swap_fee_amount 
        + burn_fee_amount 
        + dev_fee_amount 
        + reward_fee_amount;

    // ✅ **EXPLICIT RETURN STATEMENT (Fixes the Error)**
    return (
        final_sell_amount_b, 
        lp_builder_fee_amount_in, 
        lp_builder_fee_amount_out, 
        swap_fee_amount, 
        burn_fee_amount, 
        dev_fee_amount, 
        reward_fee_amount
    )
}

    /// Calculate output when selling token A for token B.
    fun calc_swap_out_b(
    input_amount_a: u64, 
    pool_balance_a: u64, 
    pool_balance_b: u64,
    swap_fee: u64, 
    lp_builder_fee: u64,
    burn_fee: u64,
    dev_royalty_fee: u64,
    rewards_fee: u64
): (u64, u64, u64, u64, u64, u64, u64) { 
    assert!(pool_balance_a > 0 && pool_balance_b > 0, ENoLiquidity);

    // Step 1: Apply LP Builder Fee on input side (only if lp_builder_fee > 0)
    let lp_builder_fee_amount_in = if (lp_builder_fee > 0) { 
        ceil_muldiv(input_amount_a, lp_builder_fee, 2 * BASIS_POINTS) 
    } else { 0 };

    let swap_fee_amount = if (swap_fee > 0) { ceil_muldiv(input_amount_a, swap_fee, BASIS_POINTS) } else { 0 };
    let burn_fee_amount = if (burn_fee > 0) { ceil_muldiv(input_amount_a, burn_fee, BASIS_POINTS) } else { 0 };
    let dev_fee_amount = if (dev_royalty_fee > 0) { ceil_muldiv(input_amount_a, dev_royalty_fee, BASIS_POINTS) } else { 0 };
    let reward_fee_amount = if (rewards_fee > 0) { ceil_muldiv(input_amount_a, rewards_fee, BASIS_POINTS) } else { 0 };

    let adjusted_amount_in_a = input_amount_a - lp_builder_fee_amount_in - swap_fee_amount - burn_fee_amount - dev_fee_amount - reward_fee_amount;

    // Step 2: Compute output before fees
    let amount_out_b = muldiv(adjusted_amount_in_a, pool_balance_b, pool_balance_a + adjusted_amount_in_a);

    // Step 3: Apply output-side fees (only if they are > 0)
    let lp_builder_fee_amount_out = if (lp_builder_fee > 0) { 
        ceil_muldiv(amount_out_b, lp_builder_fee, 2 * BASIS_POINTS) 
    } else { 0 };

    // Step 4: Compute final amount after all fees
    let final_amount_out_b = amount_out_b - lp_builder_fee_amount_out;

    // Return all computed values
    (
        final_amount_out_b, 
        lp_builder_fee_amount_in, 
        lp_builder_fee_amount_out, 
        swap_fee_amount, 
        burn_fee_amount, 
        dev_fee_amount, 
        reward_fee_amount
    )
}

fun calc_reverse_swap_out_a(
    buy_amount: u64,  
    pool_balance_a: u64, 
    pool_balance_b: u64,
    swap_fee: u64, 
    lp_builder_fee: u64,
    burn_fee: u64,
    dev_royalty_fee: u64,
    rewards_fee: u64
): (u64, u64, u64, u64, u64, u64, u64) { 
    assert!(pool_balance_a > 0 && pool_balance_b > 0, ENoLiquidity);

    // ✅ Step 1: Adjust Buy Amount for LP Builder Fee on output
    let lp_builder_fee_amount_out = if (lp_builder_fee > 0) { 
        ceil_muldiv(buy_amount, lp_builder_fee, 2 * BASIS_POINTS) 
    } else { 0 };

    let adjusted_buy_amount = buy_amount + lp_builder_fee_amount_out; // ✅ Ensuring user receives `buy_amount`

    // ✅ Step 2: Compute Required Sell Amount (Corrected Function Call)
    let raw_sell_amount_a = muldiv(adjusted_buy_amount, pool_balance_a, pool_balance_b - adjusted_buy_amount); 

    // ✅ Step 3: Apply Fees to the Sell Side
    let lp_builder_fee_amount_in = if (lp_builder_fee > 0) { 
        ceil_muldiv(raw_sell_amount_a, lp_builder_fee, 2 * BASIS_POINTS) 
    } else { 0 };

    let swap_fee_amount = if (swap_fee > 0) { ceil_muldiv(raw_sell_amount_a, swap_fee, BASIS_POINTS) } else { 0 };
    let burn_fee_amount = if (burn_fee > 0) { ceil_muldiv(raw_sell_amount_a, burn_fee, BASIS_POINTS) } else { 0 };
    let dev_fee_amount = if (dev_royalty_fee > 0) { ceil_muldiv(raw_sell_amount_a, dev_royalty_fee, BASIS_POINTS) } else { 0 };
    let reward_fee_amount = if (rewards_fee > 0) { ceil_muldiv(raw_sell_amount_a, rewards_fee, BASIS_POINTS) } else { 0 };

    // ✅ Step 4: Final Required Sell Amount
    let final_sell_amount_a = raw_sell_amount_a 
        + lp_builder_fee_amount_in 
        + swap_fee_amount 
        + burn_fee_amount 
        + dev_fee_amount 
        + reward_fee_amount;

    // ✅ **EXPLICIT RETURN STATEMENT (Fixes the Error)**
    return (
        final_sell_amount_a, 
        lp_builder_fee_amount_in, 
        lp_builder_fee_amount_out, 
        swap_fee_amount, 
        burn_fee_amount, 
        dev_fee_amount, 
        reward_fee_amount
    )
}

}
