module srm_dex_v1::srmV1 {
    use std::type_name::{Self, TypeName};
    use sui::balance::{Self, Balance, Supply};
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::math;
    use std::ascii;
    use sui::table::{Self, Table};
    use sui::tx_context::sender;
    use sui::clock::Clock;

    /* === errors === */

    /// The input amount is zero.
    const EZeroInput: u64 = 0;
    /// Pool pair coin types must be ordered alphabetically (`A` < `B`) and mustn't be equal.
    const EInvalidPair: u64 = 1;
    /// Pool for this pair already exists.
    const EPoolAlreadyExists: u64 = 2;
    /// The pool balance differs from the acceptable.
    const EExcessiveSlippage: u64 = 3;
    /// There's no liquidity in the pool.
    const ENoLiquidity: u64 = 4;
    /// Fee exceeds maximum fee amount
    const EInvalidFee: u64 = 5;

    /* === constants === */

    const BASIS_POINTS: u64 = 10_000;
    const SWAP_FEE: u64 = 10;

    /* === Max Fees === */

    const MAX_LP_BUILDER_FEE: u64 = 300; // 3%
    const MAX_BURN_FEE: u64 = 200; // 2%
    const MAX_DEV_ROYALTY_FEE: u64 = 100; // 1%
    const MAX_REWARDS_FEE: u64 = 500; // 5%

    /* === Distribution Thresholds === */

    const DEV_ROYALTY_FEE_THRESHOLD: u64 = 10_000_000_000; // 10 SUI in MIST
    const BURN_THRESHOLD: u64 = 10_000_000_000; // 10 SUI in MIST
    const SWAP_THRESHOLD: u64 = 1_000_000_000; // 1 SUI in MIST

    /* === math === */

    /// Calculates (a * b) / c. Errors if result doesn't fit into u64.
    fun muldiv(a: u64, b: u64, c: u64): u64 {
        ((((a as u128) * (b as u128)) / (c as u128)) as u64)
    }

    /// Calculates ceil_div((a * b), c). Errors if result doesn't fit into u64.
    fun ceil_muldiv(a: u64, b: u64, c: u64): u64 {
        (ceil_div_u128((a as u128) * (b as u128), (c as u128)) as u64)
    }

    /// Calculates sqrt(a * b).
    fun mulsqrt(a: u64, b: u64): u64 {
        (math::sqrt_u128((a as u128) * (b as u128)) as u64)
    }

    /// Calculates ceil(a / b).
    fun ceil_div_u128(a: u128, b: u128): u128 {
        if (a == 0) 0 else (a - 1) / b + 1
    }

    fun get_timestamp(clock: &sui::clock::Clock): u64 {
        sui::clock::timestamp_ms(clock)
    }

    /* === events === */

    public struct PoolCreated has copy, drop {
        pool_id: ID,
        a: TypeName,
        b: TypeName,
        init_a: u64,
        init_b: u64,
        lp_minted: u64,

        // Fee settings
        lp_builder_fee: u64,
        burn_fee: u64,
        dev_royalty_fee: u64,
        rewards_fee: u64,

        // Developer wallet
        dev_wallet: address,
    }

    public struct LiquidityAdded has copy, drop {
        pool_id: ID,
        a: TypeName,
        b: TypeName,
        amountin_a: u64,
        amountin_b: u64,
        lp_minted: u64,
    }

    public struct LiquidityRemoved has copy, drop {
        pool_id: ID,
        a: TypeName,
        b: TypeName,
        amountout_a: u64,
        amountout_b: u64,
        lp_burnt: u64,
    }

    public struct Swapped has copy, drop {
    pool_id: ID,
    wallet: address,
    tokenin: TypeName,
    amountin: u64,
    tokenout: TypeName,
    amountout: u64,
    timestamp: u64
}

    /* === Rewards Distribution === */

    /// Distributes accumulated dev royalty fees to the developer wallet.
    public fun distribute_dev_royalty_fee<A, B>(pool: &mut Pool<A, B>, ctx: &mut TxContext) {
        let dev_balance = balance::value(&pool.dev_balance_a);

        if (dev_balance >= DEV_ROYALTY_FEE_THRESHOLD) {
            let dev_wallet = pool.dev_wallet;
            let dev_funds = balance::split(&mut pool.dev_balance_a, dev_balance);

        transfer::public_transfer(coin::from_balance(dev_funds, ctx), dev_wallet);
        }
    }

    /// Burns accumulated fees by swapping `burn_balance_a` for `balance_b` and burning `balance_b`.
public fun distribute_burn_fee<A, B>(pool: &mut Pool<A, B>, ctx: &mut TxContext) {
    let burn_balance_a = balance::value(&pool.burn_balance_a);

    if (burn_balance_a >= BURN_THRESHOLD) {
        // Step 1: Calculate swap result using `calc_burn_swap_out_b`
        let (amount_out_b, swap_fee_amount) = calc_burn_swap_out_b(
            burn_balance_a,
            balance::value(&pool.balance_a),
            balance::value(&pool.balance_b)
        );

        // Step 2: Perform swap
        // Move CoinA from `burn_balance_a`
        let mut burn_funds_a = balance::split(&mut pool.burn_balance_a, burn_balance_a);
        
        // Store swap fee in `swap_balance_a`
        balance::join(&mut pool.swap_balance_a, balance::split(&mut burn_funds_a, swap_fee_amount));
        
        // Deposit remaining CoinA into `balance_a`
        balance::join(&mut pool.balance_a, burn_funds_a);

        // Step 3: Withdraw CoinB and store it in `burn_balance_b`
        let burn_funds_b = balance::split(&mut pool.balance_b, amount_out_b);
        balance::join(&mut pool.burn_balance_b, burn_funds_b);

        // 🔥 CoinB is now permanently locked in `burn_balance_b`
    }
}


    /// Burns accumulated fees by sending them to the zero address.
    public fun distribute_swap_fee<A, B>(pool: &mut Pool<A, B>, ctx: &mut TxContext) {
        let swap_balance = balance::value(&pool.swap_balance_a);

        if (swap_balance >= SWAP_THRESHOLD) {
            let swap_funds: Balance<A> = balance::split(&mut pool.swap_balance_a, swap_balance);
            let admin_address: address = @0xa4704c71a56fbdfb854ef938b87cd7d38c075f51dd3221d4c228a4ede9c6c0c2; // add admin address
        
        transfer::public_transfer(coin::from_balance<A>(swap_funds, ctx), admin_address);
        }
    }

    /* === LP witness === */

    public struct LP<phantom A, phantom B> has drop {}

    /* === Pool === */

    public struct Pool<phantom A, phantom B> has key {
        id: UID,
        balance_a: Balance<A>,
        balance_b: Balance<B>,
        lp_supply: Supply<LP<A, B>>,
        lp_builder_fee: u64,
        burn_fee: u64,
        dev_royalty_fee: u64,
        rewards_fee: u64,
        swap_balance_a: Balance<A>,
        burn_balance_a: Balance<A>,
        burn_balance_b: Balance<B>,
        dev_balance_a: Balance<A>,
        reward_balance_a: Balance<A>,
        dev_wallet: address
    }

    public fun pool_balances<A, B>(pool: &Pool<A, B>): (u64, u64, u64) {
        (
            balance::value(&pool.balance_a),
            balance::value(&pool.balance_b),
            balance::supply_value(&pool.lp_supply)
        )
    }

    public fun get_pool_fees<A, B>(pool: &Pool<A, B>): (u64, u64, u64, u64) {
        (pool.lp_builder_fee, pool.burn_fee, pool.dev_royalty_fee, pool.rewards_fee)
    }

    /// Returns all pool data in a structured format for UI consumption.
public fun get_pool_info<A, B>(pool: &Pool<A, B>): (
    u64, u64, u64,    // Balances: Token A, Token B, LP supply
    u64, u64, u64, u64, // Fees: LP builder, burn, dev royalty, rewards
    u64, u64, u64, u64, u64, // Fee balances: Swap, burn A, burn B, dev, rewards
    address // Developer wallet
) {
    (
        balance::value(&pool.balance_a),
        balance::value(&pool.balance_b),
        balance::supply_value(&pool.lp_supply),

        pool.lp_builder_fee,
        pool.burn_fee,
        pool.dev_royalty_fee,
        pool.rewards_fee,

        balance::value(&pool.swap_balance_a),
        balance::value(&pool.burn_balance_a),
        balance::value(&pool.burn_balance_b),
        balance::value(&pool.dev_balance_a),
        balance::value(&pool.reward_balance_a),

        pool.dev_wallet // ✅ Added dev wallet address
    )
}

    /* === Factory === */

    public struct Factory has key {
        id: UID,
        table: Table<PoolItem, bool>,
    }

    public struct PoolItem has copy, drop, store  {
        a: TypeName,
        b: TypeName
    }

    fun add_pool<A, B>(factory: &mut Factory) {
        let a = type_name::get<A>();
        let b = type_name::get<B>();
        assert!(cmp_type_names(&a, &b) == 0, EInvalidPair);

        let item = PoolItem{ a, b };
        assert!(table::contains(&factory.table, item) == false, EPoolAlreadyExists);

        table::add(&mut factory.table, item, true)
    }

    // returns: 0 if a < b; 1 if a == b; 2 if a > b
    public fun cmp_type_names(a: &TypeName, b: &TypeName): u8 {
        let bytes_a = ascii::as_bytes(type_name::borrow_string(a));
        let bytes_b = ascii::as_bytes(type_name::borrow_string(b));

        let len_a = vector::length(bytes_a);
        let len_b = vector::length(bytes_b);

        let mut i = 0;
        let n = math::min(len_a, len_b);
        while (i < n) {
            let a = *vector::borrow(bytes_a, i);
            let b = *vector::borrow(bytes_b, i);

            if (a < b) {
                return 0
            };
            if (a > b) {
                return 2
            };
            i = i + 1;
        };

        if (len_a == len_b) {
            1
        } else if (len_a < len_b) {
            0
        } else {
            2
        }
    }

    /* === main logic === */

    fun init(ctx: &mut TxContext) {
        let factory = Factory { 
            id: object::new(ctx),
            table: table::new(ctx),
        };
        transfer::share_object(factory);
    }

    public fun create_pool<A, B>(
        factory: &mut Factory,
        init_a: Balance<A>,
        init_b: Balance<B>,
        lp_builder_fee: u64,
        burn_fee: u64,
        dev_royalty_fee: u64,
        rewards_fee: u64,
        dev_wallet: address,
        ctx: &mut TxContext
    ): Balance<LP<A, B>> {
        assert!(balance::value(&init_a) > 0 && balance::value(&init_b) > 0, EZeroInput);

        // Ensure fees do not exceed maximum values
        assert!(lp_builder_fee <= MAX_LP_BUILDER_FEE, EInvalidFee);
        assert!(burn_fee <= MAX_BURN_FEE, EInvalidFee);
        assert!(dev_royalty_fee <= MAX_DEV_ROYALTY_FEE, EInvalidFee);
        assert!(rewards_fee <= MAX_REWARDS_FEE, EInvalidFee);

        add_pool<A, B>(factory);

    // Create pool
    let mut pool = Pool<A, B> {
        id: object::new(ctx),
        balance_a: init_a,
        balance_b: init_b,
        lp_supply: balance::create_supply(LP<A, B> {}),

        // User-specified fees
        lp_builder_fee,
        burn_fee,
        dev_royalty_fee,
        rewards_fee,

        // Initialize fee balances
        swap_balance_a: balance::zero(),
        burn_balance_a: balance::zero(),
        burn_balance_b: balance::zero(),
        dev_balance_a: balance::zero(),
        reward_balance_a: balance::zero(),

        // User-specified dev wallet
        dev_wallet
    };

        // Mint initial LP tokens
        let lp_amount = mulsqrt(balance::value(&pool.balance_a), balance::value(&pool.balance_b));
        let lp_balance = balance::increase_supply(&mut pool.lp_supply, lp_amount);

        // Emit event
        event::emit(PoolCreated {
        pool_id: object::id(&pool),
        a: type_name::get<A>(),
        b: type_name::get<B>(),
        init_a: balance::value(&pool.balance_a),
        init_b: balance::value(&pool.balance_b),
        lp_minted: lp_amount,

        // Include fee settings in the event
        lp_builder_fee,
        burn_fee,
        dev_royalty_fee,
        rewards_fee,

        // Include developer wallet address
        dev_wallet,
    });

        // Share the pool object
        transfer::share_object(pool);

        lp_balance
    }

    public fun add_liquidity<A, B>(pool: &mut Pool<A, B>, mut input_a: Balance<A>, mut input_b: Balance<B>, min_lp_out: u64): (Balance<A>, Balance<B>, Balance<LP<A, B>>) {
        assert!(balance::value(&input_a) > 0 && balance::value(&input_b) > 0, EZeroInput);

        // calculate the deposit amounts
        let input_a_mul_pool_b: u128 = (balance::value(&input_a) as u128) * (balance::value(&pool.balance_b) as u128);
        let input_b_mul_pool_a: u128 = (balance::value(&input_b) as u128) * (balance::value(&pool.balance_a) as u128);

        let deposit_a: u64;
        let deposit_b: u64;
        let lp_to_issue: u64;
        if (input_a_mul_pool_b > input_b_mul_pool_a) { // input_a / pool_a > input_b / pool_b
            deposit_b = balance::value(&input_b);
            // pool_a * deposit_b / pool_b
            deposit_a = (ceil_div_u128(
                input_b_mul_pool_a,
                (balance::value(&pool.balance_b) as u128),
            ) as u64);
            // deposit_b / pool_b * lp_supply
            lp_to_issue = muldiv(
                deposit_b,
                balance::supply_value(&pool.lp_supply),
                balance::value(&pool.balance_b)
            );
        } else if (input_a_mul_pool_b < input_b_mul_pool_a) { // input_a / pool_a < input_b / pool_b
            deposit_a = balance::value(&input_a);
            // pool_b * deposit_a / pool_a
            deposit_b = (ceil_div_u128(
                input_a_mul_pool_b,
                (balance::value(&pool.balance_a) as u128),
            ) as u64);
            // deposit_a / pool_a * lp_supply
            lp_to_issue = muldiv(
                deposit_a,
                balance::supply_value(&pool.lp_supply),
                balance::value(&pool.balance_a)
            );
        } else {
            deposit_a = balance::value(&input_a);
            deposit_b = balance::value(&input_b);
            if (balance::supply_value(&pool.lp_supply) == 0) {
                // in this case both pool balances are 0 and lp supply is 0
                lp_to_issue = mulsqrt(deposit_a, deposit_b);
            } else {
                // the ratio of input a and b matches the ratio of pool balances
                lp_to_issue = muldiv(
                    deposit_a,
                    balance::supply_value(&pool.lp_supply),
                    balance::value(&pool.balance_a)
                );
            }
        };

        // deposit amounts into pool 
        balance::join(
            &mut pool.balance_a,
            balance::split(&mut input_a, deposit_a)
        );
        balance::join(
            &mut pool.balance_b,
            balance::split(&mut input_b, deposit_b)
        );

        // mint lp coin
        assert!(lp_to_issue >= min_lp_out, EExcessiveSlippage);
        let lp = balance::increase_supply(&mut pool.lp_supply, lp_to_issue);

        event::emit(LiquidityAdded {
            pool_id: object::id(pool),
            a: type_name::get<A>(),
            b: type_name::get<B>(),
            amountin_a: deposit_a,
            amountin_b: deposit_b,
            lp_minted: lp_to_issue,
        });

        // return
        (input_a, input_b, lp)
    }

    public fun remove_liquidity<A, B>(pool: &mut Pool<A, B>, lp_in: Balance<LP<A, B>>, min_a_out: u64, min_b_out: u64): (Balance<A>, Balance<B>) {
        assert!(balance::value(&lp_in) > 0, EZeroInput);

        // calculate output amounts
        let lp_in_amount = balance::value(&lp_in);
        let pool_a_amount = balance::value(&pool.balance_a);
        let pool_b_amount = balance::value(&pool.balance_b);
        let lp_supply = balance::supply_value(&pool.lp_supply);

        let a_out = muldiv(lp_in_amount, pool_a_amount, lp_supply);
        let b_out = muldiv(lp_in_amount, pool_b_amount, lp_supply);
        assert!(a_out >= min_a_out, EExcessiveSlippage);
        assert!(b_out >= min_b_out, EExcessiveSlippage);

        // burn lp tokens
        balance::decrease_supply(&mut pool.lp_supply, lp_in);

        event::emit(LiquidityRemoved {
            pool_id: object::id(pool),
            a: type_name::get<A>(),
            b: type_name::get<B>(),
            amountout_a: a_out,
            amountout_b: b_out,
            lp_burnt: lp_in_amount,
        });

        // return amounts
        (
            balance::split(&mut pool.balance_a, a_out),
            balance::split(&mut pool.balance_b, b_out)
        )
    }

    public fun swap_a_for_b<A, B>(
    pool: &mut Pool<A, B>, 
    input: Balance<A>, 
    min_out: u64,
    clock: &Clock,
    ctx: &mut TxContext
): Balance<B> {
    assert!(balance::value(&input) > 0, EZeroInput);
    assert!(balance::value(&pool.balance_a) > 0 && balance::value(&pool.balance_b) > 0, ENoLiquidity);

    let input_amount = balance::value(&input);
    let pool_a_amount = balance::value(&pool.balance_a);
    let pool_b_amount = balance::value(&pool.balance_b);

    // Retrieve fees from pool (excluding swap_fee since it's a constant)
    let (lp_builder_fee, burn_fee, dev_royalty_fee, rewards_fee) = get_pool_fees(pool);

    // Calculate swap result
    let (
        final_out_b, 
        lp_in_fee, 
        lp_out_fee, 
        swap_fee_amount, 
        burn_fee_amount, 
        dev_fee_amount, 
        reward_fee_amount
    ) = calc_swap_out_b(
        input_amount, pool_a_amount, pool_b_amount, 
        lp_builder_fee, burn_fee, dev_royalty_fee, rewards_fee
    );

    assert!(final_out_b >= min_out, EExcessiveSlippage);

    // Deposit input into pool
    balance::join(&mut pool.balance_a, input);

    // Distribute fees into respective balances
    if (swap_fee_amount != 0) {
    balance::join(&mut pool.swap_balance_a, balance::split(&mut pool.balance_a, swap_fee_amount));
    };
    if (burn_fee_amount != 0) {
    balance::join(&mut pool.burn_balance_a, balance::split(&mut pool.balance_a, burn_fee_amount));
    };
    if (dev_fee_amount != 0) {
    balance::join(&mut pool.dev_balance_a, balance::split(&mut pool.balance_a, dev_fee_amount));
    };
    if (reward_fee_amount != 0) {
    balance::join(&mut pool.reward_balance_a, balance::split(&mut pool.balance_a, reward_fee_amount));
    };

    // **Distribute accumulated fees after processing the swap**
    distribute_dev_royalty_fee(pool, ctx);
    distribute_burn_fee(pool, ctx);
    distribute_swap_fee(pool, ctx);

    let user_wallet = sender(ctx);
    let timestamp = get_timestamp(clock);

    event::emit(Swapped {
        pool_id: object::id(pool),
        wallet: user_wallet, 
        tokenin: type_name::get<A>(),
        amountin: input_amount,
        tokenout: type_name::get<B>(),
        amountout: final_out_b,
        timestamp: timestamp
    });

    // Return the final output balance
    balance::split(&mut pool.balance_b, final_out_b)
}

    public fun swap_b_for_a<A, B>(
    pool: &mut Pool<A, B>, 
    input: Balance<B>, 
    min_out: u64,
    clock: &Clock,
    ctx: &mut TxContext
): Balance<A> {
    assert!(balance::value(&input) > 0, EZeroInput);
    assert!(balance::value(&pool.balance_a) > 0 && balance::value(&pool.balance_b) > 0, ENoLiquidity);

    let input_amount = balance::value(&input);
    let pool_b_amount = balance::value(&pool.balance_b);
    let pool_a_amount = balance::value(&pool.balance_a);

    // Retrieve fees from pool
    let (lp_builder_fee, burn_fee, dev_royalty_fee, rewards_fee) = get_pool_fees(pool);

    // Calculate swap result
    let (
        final_out_a, 
        lp_in_fee, 
        lp_out_fee, 
        swap_fee_amount, 
        burn_fee_amount, 
        dev_fee_amount, 
        reward_fee_amount
    ) = calc_swap_out_a(
        input_amount, pool_b_amount, pool_a_amount, 
        lp_builder_fee, burn_fee, dev_royalty_fee, rewards_fee
    );

    assert!(final_out_a >= min_out, EExcessiveSlippage);

    balance::join(&mut pool.balance_b, input);

    // **Now correctly distributing swap fees**
    if (swap_fee_amount != 0) {
    balance::join(&mut pool.swap_balance_a, balance::split(&mut pool.balance_a, swap_fee_amount));
    };
    if (burn_fee_amount != 0) {
    balance::join(&mut pool.burn_balance_a, balance::split(&mut pool.balance_a, burn_fee_amount));
    };
    if (dev_fee_amount != 0) {
    balance::join(&mut pool.dev_balance_a, balance::split(&mut pool.balance_a, dev_fee_amount));
    };
    if (reward_fee_amount != 0) {
    balance::join(&mut pool.reward_balance_a, balance::split(&mut pool.balance_a, reward_fee_amount));
    };

    // **Distribute accumulated fees after processing the swap**
    distribute_dev_royalty_fee(pool, ctx);
    distribute_burn_fee(pool, ctx);
    distribute_swap_fee(pool, ctx);

    let user_wallet = sender(ctx);        
    let timestamp = get_timestamp(clock); 

    event::emit(Swapped {
        pool_id: object::id(pool),
        wallet: user_wallet,
        tokenin: type_name::get<B>(),
        amountin: input_amount,
        tokenout: type_name::get<A>(),
        amountout: final_out_a,
        timestamp: timestamp
    });

    balance::split(&mut pool.balance_a, final_out_a)
}

    fun calc_swap_out_a(
    input_amount_b: u64, 
    pool_balance_b: u64, 
    pool_balance_a: u64, 
    lp_builder_fee: u64,
    burn_fee: u64,
    dev_royalty_fee: u64,
    rewards_fee: u64
): (u64, u64, u64, u64, u64, u64, u64) { // Now returns 7 values instead of 8
    // Step 1: Apply 50% of LP builder fee on `input_amount_b`
    let lp_builder_fee_amount_in = ceil_muldiv(input_amount_b, lp_builder_fee, 2 * BASIS_POINTS);
    let adjusted_amount_in_b = input_amount_b - lp_builder_fee_amount_in;

    // Step 2: Calculate `amount_out_a` based on adjusted input
    let amount_out_a = muldiv(adjusted_amount_in_b, pool_balance_a, pool_balance_b + adjusted_amount_in_b);

    // Step 3: Calculate swap fee based on SWAP_FEE constant
    let swap_fee_amount = ceil_muldiv(amount_out_a, SWAP_FEE, BASIS_POINTS);

    // Step 4: Apply burn fee, dev royalty fee, and rewards fee to `amount_out_a`
    let burn_fee_amount = ceil_muldiv(amount_out_a, burn_fee, BASIS_POINTS);
    let dev_fee_amount = ceil_muldiv(amount_out_a, dev_royalty_fee, BASIS_POINTS);
    let reward_fee_amount = ceil_muldiv(amount_out_a, rewards_fee, BASIS_POINTS);

    // Step 5: Apply 50% of LP builder fee on `amount_out_a`
    let lp_builder_fee_amount_out = ceil_muldiv(amount_out_a, lp_builder_fee, 2 * BASIS_POINTS);
    
    // Step 6: Calculate final amount out after deducting fees
    let final_amount_out_a = amount_out_a 
        - swap_fee_amount
        - burn_fee_amount 
        - dev_fee_amount 
        - reward_fee_amount 
        - lp_builder_fee_amount_out;

    // Returns:
    // 1. Final amount of token A received by user
    // 2. LP builder fee taken from token B
    // 3. LP builder fee taken from token A
    // 4. Swap fee taken from token A
    // 5. Burn fee taken from token A
    // 6. Developer fee taken from token A
    // 7. Rewards fee taken from token A
    (final_amount_out_a, lp_builder_fee_amount_in, lp_builder_fee_amount_out, swap_fee_amount, burn_fee_amount, dev_fee_amount, reward_fee_amount)
}

    fun calc_swap_out_b(
    input_amount_a: u64, 
    pool_balance_a: u64, 
    pool_balance_b: u64, 
    lp_builder_fee: u64,
    burn_fee: u64,
    dev_royalty_fee: u64,
    rewards_fee: u64
): (u64, u64, u64, u64, u64, u64, u64) { // Now returns 7 values instead of 8
    // Step 1: Calculate all fees on `input_amount_a`
    let swap_fee_amount = ceil_muldiv(input_amount_a, SWAP_FEE, BASIS_POINTS);
    let burn_fee_amount = ceil_muldiv(input_amount_a, burn_fee, BASIS_POINTS);
    let dev_fee_amount = ceil_muldiv(input_amount_a, dev_royalty_fee, BASIS_POINTS);
    let reward_fee_amount = ceil_muldiv(input_amount_a, rewards_fee, BASIS_POINTS);
    let lp_builder_fee_amount_in = ceil_muldiv(input_amount_a, lp_builder_fee, 2 * BASIS_POINTS);

    // Step 2: Adjust `input_amount_a` after deducting fees
    let adjusted_amount_in_a = input_amount_a 
        - swap_fee_amount 
        - burn_fee_amount 
        - dev_fee_amount 
        - reward_fee_amount 
        - lp_builder_fee_amount_in;

    // Step 3: Calculate `amount_out_b` from adjusted input
    let amount_out_b = muldiv(adjusted_amount_in_a, pool_balance_b, pool_balance_a + adjusted_amount_in_a);

    // Step 4: Apply 50% of LP Builder Fee on output
    let lp_builder_fee_amount_out = ceil_muldiv(amount_out_b, lp_builder_fee, 2 * BASIS_POINTS);
    let final_amount_out_b = amount_out_b - lp_builder_fee_amount_out;

    // Returns:
    // 1. Final amount of token B received by user
    // 2. LP builder fee taken from token A
    // 3. LP builder fee taken from token B
    // 4. Swap fee taken from token A
    // 5. Burn fee taken from token A
    // 6. Developer fee taken from token A
    // 7. Rewards fee taken from token A
    (final_amount_out_b, lp_builder_fee_amount_in, lp_builder_fee_amount_out, swap_fee_amount, burn_fee_amount, dev_fee_amount, reward_fee_amount)
}

fun calc_burn_swap_out_b(
    input_amount_a: u64, 
    pool_balance_a: u64, 
    pool_balance_b: u64, 
): (u64, u64) {
    // Step 1: Calculate all fees on `input_amount_a`
    let swap_fee_amount = ceil_muldiv(input_amount_a, SWAP_FEE, BASIS_POINTS);
    
    // Step 2: Adjust `input_amount_a` after deducting fees
    let adjusted_amount_in_a = input_amount_a - swap_fee_amount;

    // Step 3: Calculate `amount_out_b` from adjusted input
    let amount_out_b = muldiv(adjusted_amount_in_a, pool_balance_b, pool_balance_a + adjusted_amount_in_a);

    // Returns:
    // 1. Final amount of token B
    // 2. Swap fee taken from token A
    (amount_out_b, swap_fee_amount)
}

    /* === with coin === */

    fun destroy_zero_or_transfer_balance<T>(balance: Balance<T>, recipient: address, ctx: &mut TxContext) {
        if (balance::value(&balance) == 0) {
            balance::destroy_zero(balance);
        } else {
            transfer::public_transfer(coin::from_balance(balance, ctx), recipient);
        };
    }

    /// Create a pool using only a **specified amount** from the provided coin objects.
    public fun create_pool_with_coins<A, B>(
        factory: &mut Factory,
        mut init_a: Coin<A>,
        amount_a: u64,
        mut init_b: Coin<B>,
        amount_b: u64,
        lp_builder_fee: u64,
        burn_fee: u64,
        dev_royalty_fee: u64,
        rewards_fee: u64,
        dev_wallet: address,
        ctx: &mut TxContext
    ): (Coin<A>, Coin<B>, Coin<LP<A, B>>) { // ✅ Return remaining balances
    // ✅ Split coins into specified amounts
    let used_a = coin::split(&mut init_a, amount_a, ctx);
    let used_b = coin::split(&mut init_b, amount_b, ctx);


        let lp_balance = create_pool(
            factory,
            coin::into_balance(used_a), // ✅ Use the split amount
        coin::into_balance(used_b), // ✅ Use the split amount
            lp_builder_fee,
            burn_fee,
            dev_royalty_fee,
            rewards_fee,
            dev_wallet,
            ctx
        );

        // ✅ Return the remaining coin balances to the user
        (init_a, init_b, coin::from_balance(lp_balance, ctx))
    }

    public entry fun create_pool_with_coins_and_transfer_lp_to_sender<A, B>(
        factory: &mut Factory,
        mut init_a: Coin<A>,
        amount_a: u64,
        mut init_b: Coin<B>,
        amount_b: u64,
        lp_builder_fee: u64,
        burn_fee: u64,
        dev_royalty_fee: u64,
        rewards_fee: u64,
        dev_wallet: address,
        ctx: &mut TxContext
    ) {

        // ✅ Split coins into specified amounts
    let used_a = coin::split(&mut init_a, amount_a, ctx);
    let used_b = coin::split(&mut init_b, amount_b, ctx);


        let lp_balance = create_pool(
            factory,
            coin::into_balance(used_a), // ✅ Use the split amount
        coin::into_balance(used_b), // ✅ Use the split amount
            lp_builder_fee,
            burn_fee,
            dev_royalty_fee,
            rewards_fee,
            dev_wallet,
            ctx
        );
        let sender_addr = sender(ctx);


    // ✅ Return remaining balances to sender
    let remaining_a = coin::into_balance(init_a);
let remaining_b = coin::into_balance(init_b);
destroy_zero_or_transfer_balance(remaining_a, sender_addr, ctx);
destroy_zero_or_transfer_balance(remaining_b, sender_addr, ctx);


    // ✅ Transfer LP tokens to sender
    transfer::public_transfer(coin::from_balance(lp_balance, ctx), sender_addr);
    }

    public fun add_liquidity_with_coins<A, B>(pool: &mut Pool<A, B>, input_a: Coin<A>, input_b: Coin<B>, min_lp_out: u64, ctx: &mut TxContext): (Coin<A>, Coin<B>, Coin<LP<A, B>>) {
        let (remaining_a, remaining_b, lp) = add_liquidity(pool, coin::into_balance(input_a), coin::into_balance(input_b), min_lp_out);

        (
            coin::from_balance(remaining_a, ctx),
            coin::from_balance(remaining_b, ctx),
            coin::from_balance(lp, ctx),
        )
    }

    public entry fun add_liquidity_with_coins_and_transfer_to_sender<A, B>(pool: &mut Pool<A, B>, input_a: Coin<A>, input_b: Coin<B>, min_lp_out: u64, ctx: &mut TxContext) {
        let (remaining_a, remaining_b, lp) = add_liquidity(pool, coin::into_balance(input_a), coin::into_balance(input_b), min_lp_out);
        let sender = sender(ctx);
        destroy_zero_or_transfer_balance(remaining_a, sender, ctx);
        destroy_zero_or_transfer_balance(remaining_b, sender, ctx);
        destroy_zero_or_transfer_balance(lp, sender, ctx);
    }

    public fun remove_liquidity_with_coins<A, B>(pool: &mut Pool<A, B>, lp_in: Coin<LP<A, B>>, min_a_out: u64, min_b_out: u64, ctx: &mut TxContext): (Coin<A>, Coin<B>) {
        let (a_out, b_out) = remove_liquidity(pool, coin::into_balance(lp_in), min_a_out, min_b_out);

        (
            coin::from_balance(a_out, ctx),
            coin::from_balance(b_out, ctx),
        )
    }

    public entry fun remove_liquidity_with_coins_and_transfer_to_sender<A, B>(pool: &mut Pool<A, B>, lp_in: Coin<LP<A, B>>, min_a_out: u64, min_b_out: u64, ctx: &mut TxContext) {
        let (a_out, b_out) = remove_liquidity(pool, coin::into_balance(lp_in), min_a_out, min_b_out);
        let sender = sender(ctx);
        destroy_zero_or_transfer_balance(a_out, sender, ctx);
        destroy_zero_or_transfer_balance(b_out, sender, ctx);
    }

    public fun swap_a_for_b_with_coin<A, B>(
    pool: &mut Pool<A, B>, 
    input: Coin<A>, 
    min_out: u64, 
    clock: &Clock,
    ctx: &mut TxContext
): Coin<B> {
    let b_out = swap_a_for_b(pool, coin::into_balance(input), min_out, clock, ctx);

    coin::from_balance(b_out, ctx)
}

    public entry fun swap_a_for_b_with_coin_and_transfer_to_sender<A, B>(
    pool: &mut Pool<A, B>, 
    input: Coin<A>, 
    min_out: u64, 
    clock: &Clock,
    ctx: &mut TxContext
) {
    let b_out = swap_a_for_b(pool, coin::into_balance(input), min_out, clock, ctx);
    transfer::public_transfer(coin::from_balance(b_out, ctx), sender(ctx));
}

    public fun swap_b_for_a_with_coin<A, B>(
    pool: &mut Pool<A, B>, 
    input: Coin<B>, 
    min_out: u64, 
    clock: &Clock,
    ctx: &mut TxContext
): Coin<A> {
    let a_out = swap_b_for_a(pool, coin::into_balance(input), min_out, clock, ctx);

    coin::from_balance(a_out, ctx)
}


    public entry fun swap_b_for_a_with_coin_and_transfer_to_sender<A, B>(
    pool: &mut Pool<A, B>, 
    input: Coin<B>, 
    min_out: u64, 
    clock: &Clock,
    ctx: &mut TxContext
) {
    let a_out = swap_b_for_a(pool, coin::into_balance(input), min_out, clock, ctx);
    transfer::public_transfer(coin::from_balance(a_out, ctx), sender(ctx));
}


}