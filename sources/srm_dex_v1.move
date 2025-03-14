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
    /// Caller is not authorized to perform this action.
    const EUnauthorized: u64 = 6;
    // Invalid Despost Amount Create Liquidity
    const EInvalidDepositAmount: u64 = 7;
    // Not Enough Rewards to Distrbute
    const ENotEnoughRewards: u64 = 8;
    // NSF
    const EInsufficientFunds: u64 = 9;

    /* === constants === */

    const BASIS_POINTS: u64 = 10_000;

    /* === Max Fees === */

    const MAX_LP_BUILDER_FEE: u64 = 300; // 3%
    const MAX_BURN_FEE: u64 = 500; // 5%
    const MAX_CREATOR_ROYALTY_FEE: u64 = 100; // 1%
    const MAX_REWARDS_FEE: u64 = 500; // 5%
    const MAX_SWAP_FEE: u64 = 100; // 1%

    /* === Distribution Thresholds === */

    const CREATOR_ROYALTY_FEE_THRESHOLD: u64 = 250_000_000; // 0.25 SUI in MIST
    const BURN_THRESHOLD: u64 = 1_000_000_000; // 1 SUI in MIST
    const SWAP_THRESHOLD: u64 = 250_000_000; // 0.25 SUI in MIST

    /* === math === */

    const U64_MAX: u128 = 18_446_744_073_709_551_615;

    /// Calculates (a * b) / c. Errors if result doesn't fit into u64.
    fun muldiv(a: u64, b: u64, c: u64): u64 {
        assert!(c > 0, EZeroInput); // Prevent division by zero
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

    #[allow(deprecated_usage)]
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
        locked_lp_balance: u64,

        // Fee settings
        lp_builder_fee: u64,
        burn_fee: u64,
        creator_royalty_fee: u64,
        rewards_fee: u64,

        // Pool Creator Royalty Wallet
        creator_royalty_wallet: address,
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

    /// Event emitted when a user deposits LP tokens into the pool.
    public struct LPLocked has copy, drop, store {
        pool_id: ID,
        amount: u64,
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

    public struct CreatorRoyaltyFeeDistributed has copy, drop {
        pool_id: ID,
        creator_royalty_wallet: address,
        amount: u64,
        timestamp: u64
    }

    public struct BuyBackandBurn has copy, drop {
        pool_id: ID,
        amount_a_burnt: u64,
        amount_b_received: u64,
        timestamp: u64
    }

    public struct RewardsProcessing has copy, drop {
        pool_id: ID,
        recipient: address,
        amount: u64
    }

    public struct RewardsDeposited has copy, drop {
        pool_id: ID,
        amount: u64
    }

    /* === Admin === */

    /// Config struct to store swap fee and admin addresses
    public struct Config has key {
        id: UID,
        swap_fee: u64,
        swap_fee_wallet: address,
        admin: address,
        rewards_manager: address
    }

    public fun get_swap_fee(config: &Config): u64 {
        config.swap_fee
    }

    public fun get_swap_fee_wallet(config: &Config): address {
        config.swap_fee_wallet
    }

    public fun get_admin(config: &Config): address {
        config.admin
    }

    public entry fun update_swap_fee(config: &mut Config, new_fee: u64, ctx: &mut TxContext) {
        let caller = sender(ctx);
        assert!(caller == config.admin, EUnauthorized); // Only admin can update
        assert!(new_fee <= MAX_SWAP_FEE, EInvalidFee);

        config.swap_fee = new_fee;
    }

    public entry fun update_swap_fee_wallet(config: &mut Config, new_wallet: address, ctx: &mut TxContext) {
        let caller = sender(ctx);
        assert!(caller == config.admin, EUnauthorized); // Only admin can update
        config.swap_fee_wallet = new_wallet;
    }

    public entry fun update_admin(config: &mut Config, new_admin: address, ctx: &mut TxContext) {
        let caller = sender(ctx);
        assert!(caller == config.admin, EUnauthorized); // Only admin can update
        config.admin = new_admin;
    }

    public entry fun update_rewards_manager(config: &mut Config, new_manager: address, ctx: &mut TxContext) {
        let caller = sender(ctx);
        assert!(caller == config.admin, EUnauthorized); // Only admin can update
        config.rewards_manager = new_manager;
    }
    
    /* === Rewards Distribution === */

    public entry fun withdraw_rewards<A, B>(
        pool: &mut Pool<A, B>, 
        config: &Config, 
        amount: u64, 
        ctx: &mut TxContext
    ) {
        let caller = sender(ctx);
        assert!(caller == config.rewards_manager, EUnauthorized);

        let available_rewards = balance::value(&pool.reward_balance_a);
        assert!(amount > 0 && amount <= available_rewards, ENotEnoughRewards);

        let rewards = balance::split(&mut pool.reward_balance_a, amount);

        destroy_zero_or_transfer_balance(rewards, config.rewards_manager, ctx);

        event::emit(RewardsProcessing {
            pool_id: object::id(pool),
            recipient: config.rewards_manager,
            amount: amount
        });
    }

    public entry fun deposit_rewards_to_pool<A, B>(
        pool: &mut Pool<A, B>, 
        config: &Config, 
        mut rewards_coin: Coin<A>,
        amount: u64, 
        ctx: &mut TxContext
    ) {
        let sender = sender(ctx);
        assert!(sender == config.rewards_manager || sender == config.admin, EUnauthorized); // Allow both admin and rewards_manager
        assert!(coin::value(&rewards_coin) >= amount, EInsufficientFunds);

        let deposit_coin = coin::split(&mut rewards_coin, amount, ctx);

        let rewards_balance = coin::into_balance(deposit_coin);
        balance::join(&mut pool.reward_balance_a, rewards_balance);

        event::emit(RewardsDeposited {
            pool_id: object::id(pool),
            amount: balance::value(&pool.reward_balance_a),
        });

        destroy_zero_or_transfer_balance(coin::into_balance(rewards_coin), sender, ctx);
    }

    /// Distributes accumulated pool creator royalty fees to the creator royalty wallet.
    public fun distribute_creator_royalty_fee<A, B>(pool: &mut Pool<A, B>, clock: &Clock, ctx: &mut TxContext) {
        let dev_balance = balance::value(&pool.creator_balance_a);

        if (dev_balance >= CREATOR_ROYALTY_FEE_THRESHOLD) {
            let creator_royalty_wallet = pool.creator_royalty_wallet;
            let dev_funds = balance::split(&mut pool.creator_balance_a, dev_balance);

            transfer::public_transfer(coin::from_balance(dev_funds, ctx), creator_royalty_wallet);

            event::emit(CreatorRoyaltyFeeDistributed {
                pool_id: object::id(pool),
                creator_royalty_wallet: creator_royalty_wallet,
                amount: dev_balance,
                timestamp: get_timestamp(clock)
            });
        }
    }

    /// Allows the creator royalty wallet to withdraw all accumulated creator royalties.
    public entry fun withdraw_creator_royalty_fees<A, B>(
        pool: &mut Pool<A, B>, 
        ctx: &mut TxContext
    ) {
        let sender = sender(ctx);
        assert!(sender == pool.creator_royalty_wallet, EUnauthorized); // Only the creator royalty wallet can withdraw
        assert!(balance::value(&pool.creator_balance_a) > 0, EInsufficientFunds); // Ensure there are funds to withdraw

        let full_amount = balance::value(&pool.creator_balance_a);
        let withdrawn_balance = balance::split(&mut pool.creator_balance_a, full_amount);

        destroy_zero_or_transfer_balance(withdrawn_balance, sender, ctx);
    }
    
    #[allow(unused_variable)]
    /// Burns accumulated fees by swapping `burn_balance_a` for `balance_b` and locking `balance_b` in the pool struct.
    public fun distribute_burn_fee<A, B>(pool: &mut Pool<A, B>, clock: &Clock, config: &Config, ctx: &mut TxContext) {
        let burn_balance_a = balance::value(&pool.burn_balance_a);

        if (burn_balance_a >= BURN_THRESHOLD) {
            let (amount_out_b, swap_fee_amount) = calc_burn_swap_out_b(
                burn_balance_a,
                balance::value(&pool.balance_a),
                balance::value(&pool.balance_b),
                config
            );

            let mut burn_funds_a = balance::split(&mut pool.burn_balance_a, burn_balance_a);

            if (swap_fee_amount > 0) {
                balance::join(
                    &mut pool.swap_balance_a, 
                    balance::split(&mut burn_funds_a, swap_fee_amount)
                );
            };

            balance::join(&mut pool.balance_a, burn_funds_a);

            let burn_funds_b = balance::split(&mut pool.balance_b, amount_out_b);
            balance::join(&mut pool.burn_balance_b, burn_funds_b);

            event::emit(BuyBackandBurn {
                pool_id: object::id(pool),
                amount_a_burnt: burn_balance_a,
                amount_b_received: amount_out_b,
                timestamp: get_timestamp(clock) 
            });
        }
    }

    /// Sends swap fees collected to admin
    public fun distribute_swap_fee<A, B>(pool: &mut Pool<A, B>, config: &Config, ctx: &mut TxContext) {
        let swap_balance = balance::value(&pool.swap_balance_a);

        if (swap_balance >= SWAP_THRESHOLD) {
            let swap_funds: Balance<A> = balance::split(&mut pool.swap_balance_a, swap_balance);
            let swap_fee_wallet = config.swap_fee_wallet;
        
        transfer::public_transfer(coin::from_balance<A>(swap_funds, ctx), swap_fee_wallet);
        }
    }

    /// Allows the admin to withdraw all swap fees from the pool.
    public entry fun withdraw_swap_fees<A, B>(
        pool: &mut Pool<A, B>, 
        config: &Config, 
        ctx: &mut TxContext
    ) {
        let sender = sender(ctx);
        assert!(sender == config.admin, EUnauthorized); // Only admin can withdraw fees
        assert!(balance::value(&pool.swap_balance_a) > 0, EInsufficientFunds); // Ensure there are funds to withdraw

        let full_amount = balance::value(&pool.swap_balance_a);
        let withdrawn_balance = balance::split(&mut pool.swap_balance_a, full_amount);

        let swap_fee_wallet = config.swap_fee_wallet;

        destroy_zero_or_transfer_balance(withdrawn_balance, swap_fee_wallet, ctx);
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
        creator_royalty_fee: u64,
        rewards_fee: u64,
        swap_balance_a: Balance<A>,
        burn_balance_a: Balance<A>,
        burn_balance_b: Balance<B>,
        creator_balance_a: Balance<A>,
        reward_balance_a: Balance<A>,
        locked_lp_balance: Balance<LP<A, B>>,
        creator_royalty_wallet: address
    }

    public fun pool_balances<A, B>(pool: &Pool<A, B>): (u64, u64, u64) {
        (
            balance::value(&pool.balance_a),
            balance::value(&pool.balance_b),
            balance::supply_value(&pool.lp_supply)
        )
    }

    public fun get_pool_fees<A, B>(pool: &Pool<A, B>): (u64, u64, u64, u64) {
        (pool.lp_builder_fee, pool.burn_fee, pool.creator_royalty_fee, pool.rewards_fee)
    }

    /// Returns all pool data
    public fun get_pool_info<A, B>(pool: &Pool<A, B>): (
        u64, u64, u64, u64, u64, u64, u64, u64, u64, u64, u64, u64,
        address
    ) {
        (
        balance::value<A>(&pool.balance_a),
        balance::value<B>(&pool.balance_b),
        balance::supply_value<LP<A, B>>(&pool.lp_supply),

        pool.lp_builder_fee,
        pool.burn_fee,
        pool.creator_royalty_fee,
        pool.rewards_fee,

        balance::value<A>(&pool.swap_balance_a),
        balance::value<A>(&pool.burn_balance_a),
        balance::value<B>(&pool.burn_balance_b),
        balance::value<A>(&pool.creator_balance_a),
        balance::value<A>(&pool.reward_balance_a),

        pool.creator_royalty_wallet
        )
    }

    public fun get_pool_id<A, B>(factory: &Factory): ID {
        let a = type_name::get<A>();
        let b = type_name::get<B>();
        assert!(cmp_type_names(&a, &b) == 0, EInvalidPair);

        let item = PoolItem { a, b };
        assert!(table::contains(&factory.pools, item), ENoLiquidity);

        *(table::borrow(&factory.pools, item))
    }

    public fun get_pool<A, B>(pool: &Pool<A, B>): &Pool<A, B> {
        pool
    }

    public fun get_pool_balances<A, B>(pool: &Pool<A, B>): (u64, u64) {
        (balance::value(&pool.balance_a), balance::value(&pool.balance_b))
    }

    /* === Factory === */

    public struct Factory has key {
        id: UID,
        pools: Table<PoolItem, ID>,
    }

    public struct PoolItem has copy, drop, store  {
        a: TypeName,
        b: TypeName
    }

    fun add_pool<A, B>(factory: &mut Factory, pool_id: ID) {
        let a = type_name::get<A>();
        let b = type_name::get<B>();
        assert!(cmp_type_names(&a, &b) == 0, EInvalidPair);

        let item = PoolItem { a, b };
        assert!(table::contains(&factory.pools, item) == false, EPoolAlreadyExists);

        table::add(&mut factory.pools, item, pool_id);
    }

    #[allow(deprecated_usage)]
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
            pools: table::new<PoolItem, ID>(ctx),
        };
        transfer::share_object(factory);

        let deployer = sender(ctx);

        let config = Config {
            id: object::new(ctx),
            swap_fee: 100,
            swap_fee_wallet: deployer,
            admin: deployer,
            rewards_manager: deployer
        };

        transfer::share_object(config);
    }

    public fun create_pool<A, B>(
        factory: &mut Factory,
        init_a: Balance<A>,
        init_b: Balance<B>,
        lp_builder_fee: u64,
        burn_fee: u64,
        creator_royalty_fee: u64,
        rewards_fee: u64,
        creator_royalty_wallet: address,
        ctx: &mut TxContext
    ): Balance<LP<A, B>> {
        assert!(balance::value(&init_a) > 0 && balance::value(&init_b) > 0, EZeroInput);

        // Ensure fees do not exceed maximum values
        assert!(lp_builder_fee <= MAX_LP_BUILDER_FEE, EInvalidFee);
        assert!(burn_fee <= MAX_BURN_FEE, EInvalidFee);
        assert!(creator_royalty_fee <= MAX_CREATOR_ROYALTY_FEE, EInvalidFee);
        assert!(rewards_fee <= MAX_REWARDS_FEE, EInvalidFee);

        // Create pool
        let mut pool = Pool<A, B> {
            id: object::new(ctx),
            balance_a: init_a,
            balance_b: init_b,
            lp_supply: balance::create_supply(LP<A, B> {}),

            // Creator-specified fees
            lp_builder_fee,
            burn_fee,
            creator_royalty_fee,
            rewards_fee,

            // Initialize fee balances
            swap_balance_a: balance::zero(),
            burn_balance_a: balance::zero(),
            burn_balance_b: balance::zero(),
            creator_balance_a: balance::zero(),
            reward_balance_a: balance::zero(),
            locked_lp_balance: balance::zero(),

            // User-specified dev wallet
            creator_royalty_wallet
        };

        let pool_id = object::id(&pool);

        add_pool<A, B>(factory, pool_id);

        // Mint initial LP tokens
        let lp_amount = mulsqrt(balance::value(&pool.balance_a), balance::value(&pool.balance_b));
        let lp_balance = balance::increase_supply(&mut pool.lp_supply, lp_amount);

        // Emit event
        event::emit(PoolCreated {
        pool_id,
        a: type_name::get<A>(),
        b: type_name::get<B>(),
        init_a: balance::value(&pool.balance_a),
        init_b: balance::value(&pool.balance_b),
        lp_minted: lp_amount,
        locked_lp_balance: balance::value(&pool.locked_lp_balance),

        // Include fee settings in the event
        lp_builder_fee,
        burn_fee,
        creator_royalty_fee,
        rewards_fee,

        // Include creator royalty wallet address
        creator_royalty_wallet,
    });

        // Share the pool object
        transfer::share_object(pool);

        lp_balance
    }

    public fun create_pool_and_lock_lp<A, B>(
        factory: &mut Factory,
        init_a: Balance<A>,
        init_b: Balance<B>,
        lp_builder_fee: u64,
        burn_fee: u64,
        creator_royalty_fee: u64,
        rewards_fee: u64,
        creator_royalty_wallet: address,
        ctx: &mut TxContext
    ) {
        assert!(balance::value(&init_a) > 0 && balance::value(&init_b) > 0, EZeroInput);

        // Ensure fees do not exceed maximum values
        assert!(lp_builder_fee <= MAX_LP_BUILDER_FEE, EInvalidFee);
        assert!(burn_fee <= MAX_BURN_FEE, EInvalidFee);
        assert!(creator_royalty_fee <= MAX_CREATOR_ROYALTY_FEE, EInvalidFee);
        assert!(rewards_fee <= MAX_REWARDS_FEE, EInvalidFee);

        // Create pool
        let mut pool = Pool<A, B> {
            id: object::new(ctx),
            balance_a: init_a,
            balance_b: init_b,
            lp_supply: balance::create_supply(LP<A, B> {}),

            // Creator-specified fees
            lp_builder_fee,
            burn_fee,
            creator_royalty_fee,
            rewards_fee,

            // Initialize fee balances
            swap_balance_a: balance::zero(),
            burn_balance_a: balance::zero(),
            burn_balance_b: balance::zero(),
            creator_balance_a: balance::zero(),
            reward_balance_a: balance::zero(),
            locked_lp_balance: balance::zero(),

            // Creator royalty wallet
            creator_royalty_wallet
        };

        let pool_id = object::id(&pool);

        add_pool<A, B>(factory, pool_id);

        // Mint initial LP tokens
        let lp_amount = mulsqrt(balance::value(&pool.balance_a), balance::value(&pool.balance_b));
        let lp_balance = balance::increase_supply(&mut pool.lp_supply, lp_amount);

        balance::join(&mut pool.locked_lp_balance, lp_balance);

        // Emit event
        event::emit(PoolCreated {
        pool_id,
        a: type_name::get<A>(),
        b: type_name::get<B>(),
        init_a: balance::value(&pool.balance_a),
        init_b: balance::value(&pool.balance_b),
        lp_minted: lp_amount,
        locked_lp_balance: balance::value(&pool.locked_lp_balance),

        // Include fee settings in the event
        lp_builder_fee,
        burn_fee,
        creator_royalty_fee,
        rewards_fee,

        // Include creator royalty wallet address
        creator_royalty_wallet,

    });

        // Share the pool object
        transfer::share_object(pool);
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
        assert!(balance::supply_value(&pool.lp_supply) > 0, ENoLiquidity);

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

    #[allow(unused_variable)]
    public fun swap_a_for_b<A, B>(
        pool: &mut Pool<A, B>,
        config: &Config, 
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

        // Retrieve fees from pool and config
        let swap_fee = config.swap_fee;
        let (lp_builder_fee, burn_fee, creator_royalty_fee, rewards_fee) = get_pool_fees(pool);

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
            swap_fee, lp_builder_fee, burn_fee, creator_royalty_fee, rewards_fee
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
            balance::join(&mut pool.creator_balance_a, balance::split(&mut pool.balance_a, dev_fee_amount));
        };
    
        if (reward_fee_amount != 0) {
            balance::join(&mut pool.reward_balance_a, balance::split(&mut pool.balance_a, reward_fee_amount));
        };

        distribute_creator_royalty_fee(pool, clock, ctx);
        distribute_burn_fee(pool, clock, config, ctx);
        distribute_swap_fee(pool, config, ctx);

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

    #[allow(unused_variable)]
    public fun swap_b_for_a<A, B>(
        pool: &mut Pool<A, B>,
        config: &Config, 
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

        // Retrieve fees from pool and config
        let swap_fee = config.swap_fee;
        let (lp_builder_fee, burn_fee, creator_royalty_fee, rewards_fee) = get_pool_fees(pool);

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
            swap_fee, lp_builder_fee, burn_fee, creator_royalty_fee, rewards_fee
        );

        assert!(final_out_a >= min_out, EExcessiveSlippage);

        balance::join(&mut pool.balance_b, input);

        if (swap_fee_amount != 0) {
            balance::join(&mut pool.swap_balance_a, balance::split(&mut pool.balance_a, swap_fee_amount));
        };

        if (burn_fee_amount != 0) {
            balance::join(&mut pool.burn_balance_a, balance::split(&mut pool.balance_a, burn_fee_amount));
        };
    
        if (dev_fee_amount != 0) {
            balance::join(&mut pool.creator_balance_a, balance::split(&mut pool.balance_a, dev_fee_amount));
        };
    
        if (reward_fee_amount != 0) {
            balance::join(&mut pool.reward_balance_a, balance::split(&mut pool.balance_a, reward_fee_amount));
        };

        distribute_creator_royalty_fee(pool, clock, ctx);
        distribute_burn_fee(pool, clock, config, ctx);
        distribute_swap_fee(pool, config, ctx);

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
        swap_fee: u64, 
        lp_builder_fee: u64,
        burn_fee: u64,
        creator_royalty_fee: u64,
        rewards_fee: u64
    ): (u64, u64, u64, u64, u64, u64, u64) { 
        assert!(pool_balance_b > 0 && pool_balance_a > 0, ENoLiquidity); // Prevent division by zero

        // Step 1: Apply 50% of LP builder fee on `input_amount_b`
        let lp_builder_fee_amount_in = if (lp_builder_fee > 0) {
            ceil_muldiv(input_amount_b, lp_builder_fee, 2 * BASIS_POINTS)
        } else { 0 };

        let adjusted_amount_in_b = input_amount_b - lp_builder_fee_amount_in;

        // Step 2: Calculate `amount_out_a` based on adjusted input
        let denominator = pool_balance_b + adjusted_amount_in_b;
        assert!(denominator > 1, EZeroInput); 
        let amount_out_a = muldiv(adjusted_amount_in_b, pool_balance_a, denominator);

        // Step 3: Calculate swap fee based on SWAP_FEE constant
        let swap_fee_amount = if (swap_fee > 0) {
            ceil_muldiv(amount_out_a, swap_fee, BASIS_POINTS)
        } else { 0 };

        // Step 4: Apply burn fee, creator royalty fee, and rewards fee to `amount_out_a`
        let burn_fee_amount = if (burn_fee > 0) {
            ceil_muldiv(amount_out_a, burn_fee, BASIS_POINTS)
        } else { 0 };

        let dev_fee_amount = if (creator_royalty_fee > 0) {
            ceil_muldiv(amount_out_a, creator_royalty_fee, BASIS_POINTS)
        } else { 0 };

        let reward_fee_amount = if (rewards_fee > 0) {
            ceil_muldiv(amount_out_a, rewards_fee, BASIS_POINTS)
        } else { 0 };

        // Step 5: Apply 50% of LP builder fee on `amount_out_a`
        let lp_builder_fee_amount_out = if (lp_builder_fee > 0) {
            ceil_muldiv(amount_out_a, lp_builder_fee, 2 * BASIS_POINTS)
        } else { 0 };
    
        // Step 6: Calculate final amount out after deducting fees
        let final_amount_out_a = amount_out_a 
            - swap_fee_amount
            - burn_fee_amount 
            - dev_fee_amount 
            - reward_fee_amount 
            - lp_builder_fee_amount_out;

        (final_amount_out_a, lp_builder_fee_amount_in, lp_builder_fee_amount_out, swap_fee_amount, burn_fee_amount, dev_fee_amount, reward_fee_amount)
    }

    fun calc_swap_out_b(
        input_amount_a: u64, 
        pool_balance_a: u64, 
        pool_balance_b: u64,
        swap_fee: u64, 
        lp_builder_fee: u64,
        burn_fee: u64,
        creator_royalty_fee: u64,
        rewards_fee: u64
    ): (u64, u64, u64, u64, u64, u64, u64) { 
        assert!(pool_balance_a > 0 && pool_balance_b > 0, EZeroInput);
        
        // Step 1: Calculate all fees on `input_amount_a`
        let swap_fee_amount = if (swap_fee > 0) {
            ceil_muldiv(input_amount_a, swap_fee, BASIS_POINTS)
        } else { 0 };

        let burn_fee_amount = if (burn_fee > 0) {
            ceil_muldiv(input_amount_a, burn_fee, BASIS_POINTS)
        } else { 0 };

        let dev_fee_amount = if (creator_royalty_fee > 0) {
            ceil_muldiv(input_amount_a, creator_royalty_fee, BASIS_POINTS)
        } else { 0 };

        let reward_fee_amount = if (rewards_fee > 0) {
            ceil_muldiv(input_amount_a, rewards_fee, BASIS_POINTS)
        } else { 0 };

        let lp_builder_fee_amount_in = if (lp_builder_fee > 0) {
            ceil_muldiv(input_amount_a, lp_builder_fee, 2 * BASIS_POINTS)
        } else { 0 };

        // Step 2: Adjust `input_amount_a` after deducting fees
        let adjusted_amount_in_a = input_amount_a 
        - swap_fee_amount 
        - burn_fee_amount 
        - dev_fee_amount 
        - reward_fee_amount 
        - lp_builder_fee_amount_in;

        // Step 3: Calculate `amount_out_b` from adjusted input
        let denominator = pool_balance_a + adjusted_amount_in_a;
        assert!(denominator > 1, EZeroInput); 
        let amount_out_b = muldiv(adjusted_amount_in_a, pool_balance_b, denominator);

        // Step 4: Apply 50% of LP Builder Fee on output
        let lp_builder_fee_amount_out = if (lp_builder_fee > 0) {
            ceil_muldiv(amount_out_b, lp_builder_fee, 2 * BASIS_POINTS)
        } else { 0 };

        let final_amount_out_b = amount_out_b - lp_builder_fee_amount_out;

        (final_amount_out_b, lp_builder_fee_amount_in, lp_builder_fee_amount_out, swap_fee_amount, burn_fee_amount, dev_fee_amount, reward_fee_amount)
    }

    fun calc_burn_swap_out_b(
        input_amount_a: u64, 
        pool_balance_a: u64, 
        pool_balance_b: u64,
        config: &Config 
    ): (u64, u64) {
        assert!(pool_balance_a > 0 && pool_balance_b > 0, EZeroInput);
        
        let swap_fee = config.swap_fee;

        // Step 1: Calculate all fees on `input_amount_a`
        let swap_fee_amount = if (swap_fee > 0) {
            ceil_muldiv(input_amount_a, swap_fee, BASIS_POINTS)
        } else { 0 };
    
        // Step 2: Adjust `input_amount_a` after deducting fees
        let adjusted_amount_in_a = input_amount_a - swap_fee_amount;

        // Step 3: Calculate `amount_out_b` from adjusted input
        let denominator = pool_balance_a + adjusted_amount_in_a;
        assert!(denominator > 1, EZeroInput); 
        let amount_out_b = muldiv(adjusted_amount_in_a, pool_balance_b, denominator);

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

    public fun create_pool_with_coins<A, B>(
        factory: &mut Factory,
        mut init_a: Coin<A>,
        amount_a: u64,
        mut init_b: Coin<B>,
        amount_b: u64,
        lp_builder_fee: u64,
        burn_fee: u64,
        creator_royalty_fee: u64,
        rewards_fee: u64,
        creator_royalty_wallet: address,
        ctx: &mut TxContext
    ): (Coin<A>, Coin<B>, Coin<LP<A, B>>) { 
        
        let used_a = coin::split(&mut init_a, amount_a, ctx);
        let used_b = coin::split(&mut init_b, amount_b, ctx);

        let lp_balance = create_pool(
            factory,
            coin::into_balance(used_a), 
        coin::into_balance(used_b), 
            lp_builder_fee,
            burn_fee,
            creator_royalty_fee,
            rewards_fee,
            creator_royalty_wallet,
            ctx
        );

        (init_a, init_b, coin::from_balance(lp_balance, ctx))
    }

    public entry fun create_pool_and_lock_lp_in_pool<A, B>(
        factory: &mut Factory,
        mut init_a: Coin<A>,
        amount_a: u64,
        mut init_b: Coin<B>,
        amount_b: u64,
        lp_builder_fee: u64,
        burn_fee: u64,
        creator_royalty_fee: u64,
        rewards_fee: u64,
        creator_royalty_wallet: address,
        ctx: &mut TxContext
    ) {
    
        assert!(amount_a > 0, EInvalidDepositAmount);
        assert!(amount_b > 0, EInvalidDepositAmount);
        let sender_addr = sender(ctx);

        let used_a = coin::split(&mut init_a, amount_a, ctx);
        let used_b = coin::split(&mut init_b, amount_b, ctx);

        create_pool_and_lock_lp(
            factory,
            coin::into_balance(used_a), 
            coin::into_balance(used_b), 
            lp_builder_fee,
            burn_fee,
            creator_royalty_fee,
            rewards_fee,
            creator_royalty_wallet,
            ctx
        );

        destroy_zero_or_transfer_balance(coin::into_balance(init_a), sender_addr, ctx);
        destroy_zero_or_transfer_balance(coin::into_balance(init_b), sender_addr, ctx);
    }

    public entry fun create_pool_with_coins_and_transfer_lp_to_sender<A, B>(
        factory: &mut Factory,
        mut init_a: Coin<A>,
        amount_a: u64,
        mut init_b: Coin<B>,
        amount_b: u64,
        lp_builder_fee: u64,
        burn_fee: u64,
        creator_royalty_fee: u64,
        rewards_fee: u64,
        creator_royalty_wallet: address,
        ctx: &mut TxContext
    ) {
    
        assert!(amount_a > 0, EInvalidDepositAmount);
        assert!(amount_b > 0, EInvalidDepositAmount);
        let sender_addr = sender(ctx);

        let used_a = coin::split(&mut init_a, amount_a, ctx);
        let used_b = coin::split(&mut init_b, amount_b, ctx);

        let lp_balance = create_pool(
            factory,
            coin::into_balance(used_a), 
            coin::into_balance(used_b),
            lp_builder_fee,
            burn_fee,
            creator_royalty_fee,
            rewards_fee,
            creator_royalty_wallet,
            ctx
        );

        let remaining_a_balance = coin::into_balance(init_a);
        let remaining_b_balance = coin::into_balance(init_b);

        destroy_zero_or_transfer_balance(remaining_a_balance, sender_addr, ctx);
        destroy_zero_or_transfer_balance(remaining_b_balance, sender_addr, ctx);
        destroy_zero_or_transfer_balance(lp_balance, sender_addr, ctx);
    }

    public fun add_liquidity_with_coins<A, B>(pool: &mut Pool<A, B>, input_a: Coin<A>, input_b: Coin<B>, min_lp_out: u64, ctx: &mut TxContext): (Coin<A>, Coin<B>, Coin<LP<A, B>>) {
        let (remaining_a, remaining_b, lp) = add_liquidity(pool, coin::into_balance(input_a), coin::into_balance(input_b), min_lp_out);

        (
            coin::from_balance(remaining_a, ctx),
            coin::from_balance(remaining_b, ctx),
            coin::from_balance(lp, ctx),
        )
    }

    public entry fun add_liquidity_with_coins_and_transfer_to_sender<A, B>(
        pool: &mut Pool<A, B>, 
        mut input_a: Coin<A>, 
        a_amount: u64,  
        mut input_b: Coin<B>, 
        b_amount: u64,  
        min_lp_out: u64, 
        ctx: &mut TxContext
    ) {
        let sender = sender(ctx);

        assert!(a_amount > 0, EInvalidDepositAmount);
        assert!(b_amount > 0, EInvalidDepositAmount);

        let deposit_a = coin::split(&mut input_a, a_amount, ctx);
        let deposit_b = coin::split(&mut input_b, b_amount, ctx);

        let (remaining_a, remaining_b, lp) = add_liquidity(pool, coin::into_balance(deposit_a), coin::into_balance(deposit_b), min_lp_out);

        destroy_zero_or_transfer_balance(lp, sender, ctx);

        let remaining_a_coin = coin::from_balance(remaining_a, ctx);
        let remaining_b_coin = coin::from_balance(remaining_b, ctx);

        destroy_zero_or_transfer_balance(coin::into_balance(input_a), sender, ctx);
        destroy_zero_or_transfer_balance(coin::into_balance(input_b), sender, ctx);
        destroy_zero_or_transfer_balance(coin::into_balance(remaining_a_coin), sender, ctx);
        destroy_zero_or_transfer_balance(coin::into_balance(remaining_b_coin), sender, ctx);
    }

    public fun remove_liquidity_with_coins<A, B>(pool: &mut Pool<A, B>, lp_in: Coin<LP<A, B>>, min_a_out: u64, min_b_out: u64, ctx: &mut TxContext): (Coin<A>, Coin<B>) {
        let (a_out, b_out) = remove_liquidity(pool, coin::into_balance(lp_in), min_a_out, min_b_out);

        (
            coin::from_balance(a_out, ctx),
            coin::from_balance(b_out, ctx),
        )
    }

    public entry fun remove_liquidity_with_coins_and_transfer_to_sender<A, B>(
        pool: &mut Pool<A, B>, 
        mut lp_in: Coin<LP<A, B>>,
        lp_amount: u64,
        min_a_out: u64, 
        min_b_out: u64, 
        ctx: &mut TxContext
    ) {
        assert!(lp_amount > 0, EInvalidDepositAmount);
        let sender = sender(ctx);

        let lp_used = coin::split(&mut lp_in, lp_amount, ctx);

        let (a_out, b_out) = remove_liquidity(pool, coin::into_balance(lp_used), min_a_out, min_b_out);

        destroy_zero_or_transfer_balance(a_out, sender, ctx);
        destroy_zero_or_transfer_balance(b_out, sender, ctx);
        destroy_zero_or_transfer_balance(coin::into_balance(lp_in), sender, ctx);
    }

    public fun swap_a_for_b_with_coins<A, B>(
        pool: &mut Pool<A, B>, 
        config: &Config,
        mut input: Coin<A>, 
        amount_a: u64,
        min_out: u64, 
        clock: &Clock,
        ctx: &mut TxContext
    ): (Coin<A>, Coin<B>) { 
    
        let used_a = coin::split(&mut input, amount_a, ctx);

        let b_out = swap_a_for_b(pool, config, coin::into_balance(used_a), min_out, clock, ctx);

        (input, coin::from_balance(b_out, ctx))
    }

    /// Allows users to deposit a specific amount of LP tokens into the pool's locked LP balance.
    public entry fun deposit_lp_tokens<A, B>(
        pool: &mut Pool<A, B>,
        mut lp_tokens: Coin<LP<A, B>>, // User's LP coin object
        amount: u64, // Amount to deposit
        ctx: &mut TxContext
    ) {
        assert!(amount > 0, EZeroInput); // Ensure deposit amount is greater than zero
        assert!(coin::value(&lp_tokens) >= amount, EInsufficientFunds); // Ensure sufficient LP balance

        let deposit_coin = coin::split(&mut lp_tokens, amount, ctx); // Split the deposit amount
        let deposit_balance = coin::into_balance(deposit_coin); // Convert to balance

        balance::join(&mut pool.locked_lp_balance, deposit_balance); // Deposit into locked balance

        event::emit(LPLocked {
            pool_id: object::id(pool),
            amount, // Emit only the deposited amount
        });

        // Return the remaining LP tokens to the user
        let sender = sender(ctx);
        destroy_zero_or_transfer_balance(coin::into_balance(lp_tokens), sender, ctx);
    }

    public entry fun swap_a_for_b_with_coins_and_transfer_to_sender<A, B>(
        pool: &mut Pool<A, B>, 
        config: &Config,
        mut input: Coin<A>, 
        amount_a: u64,
        min_out: u64, 
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(amount_a > 0, EZeroInput);
        let used_a = coin::split(&mut input, amount_a, ctx);
        let b_out = swap_a_for_b(pool, config, coin::into_balance(used_a), min_out, clock, ctx);
        let sender = sender(ctx);

        destroy_zero_or_transfer_balance(coin::into_balance(input), sender, ctx);
        destroy_zero_or_transfer_balance(b_out, sender, ctx);
    }

    public fun swap_b_for_a_with_coins<A, B>(
        pool: &mut Pool<A, B>, 
        config: &Config,
        mut input: Coin<B>, 
        amount_b: u64,
        min_out: u64, 
        clock: &Clock,
        ctx: &mut TxContext
    ): (Coin<B>, Coin<A>) { 

        let used_b = coin::split(&mut input, amount_b, ctx);
        let a_out = swap_b_for_a(pool, config, coin::into_balance(used_b), min_out, clock, ctx);

        (input, coin::from_balance(a_out, ctx))
    }

    public entry fun swap_b_for_a_with_coins_and_transfer_to_sender<A, B>(
        pool: &mut Pool<A, B>, 
        config: &Config,
        mut input: Coin<B>, 
        amount_b: u64,
        min_out: u64, 
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(amount_b > 0, EZeroInput);
    
        let used_b = coin::split(&mut input, amount_b, ctx);
        let a_out = swap_b_for_a(pool, config, coin::into_balance(used_b), min_out, clock, ctx);
        let sender = sender(ctx);

        destroy_zero_or_transfer_balance(coin::into_balance(input), sender, ctx);
        destroy_zero_or_transfer_balance(a_out, sender, ctx);
    }

}