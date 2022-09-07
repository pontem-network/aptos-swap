/// LiquidSwap liquidity pool module.
/// Implements mint/burn liquidity, swap of coins.
module liquidswap::liquidity_pool {
    use std::string::String;
    use std::signer;

    use uq64x64::uq64x64;
    use u256::u256;

    use aptos_std::event;

    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp;
    use aptos_framework::account;

    use liquidswap::coin_helper;
    use liquidswap::coin_helper::assert_is_coin;
    use liquidswap::dao_storage;
    use liquidswap::bribe;
    use liquidswap::gauge;
    use liquidswap::math;
    use liquidswap::stable_curve;
    use liquidswap::emergency::assert_no_emergency;

    // Error codes.

    /// When coins used to create pair have wrong ordering.
    const ERR_WRONG_PAIR_ORDERING: u64 = 100;

    /// When pair already exists on account.
    const ERR_POOL_EXISTS_FOR_PAIR: u64 = 101;

    /// When not enough liquidity minted.
    const ERR_NOT_ENOUGH_INITIAL_LIQUIDITY: u64 = 102;

    /// When not enough liquidity minted.
    const ERR_NOT_ENOUGH_LIQUIDITY: u64 = 103;

    /// When both X and Y provided for swap are equal zero.
    const ERR_EMPTY_COIN_IN: u64 = 104;

    /// When incorrect INs/OUTs arguments passed during swap and math doesn't work.
    const ERR_INCORRECT_SWAP: u64 = 105;

    /// Incorrect lp coin burn values
    const ERR_INCORRECT_BURN_VALUES: u64 = 106;

    /// When pool doesn't exists for pair.
    const ERR_POOL_DOES_NOT_EXIST: u64 = 107;

    /// When both X and Y provided for flashloan are equal zero.
    const ERR_EMPTY_COIN_LOAN: u64 = 108;

    /// When pool is locked.
    const ERR_POOL_IS_LOCKED: u64 = 109;

    /// When invalid curve passed as argument.
    const ERR_INVALID_CURVE: u64 = 110;

    // Constants.

    /// Minimal liquidity.
    const MINIMAL_LIQUIDITY: u64 = 1000;

    /// Current fee is 0.3%
    const FEE_MULTIPLIER: u64 = 30;

    /// Denominator to handle decimal points for fees.
    const FEE_SCALE: u64 = 10000;

    // Curve types.

    /// Stable curve (like Solidly).
    const STABLE_CURVE: u8 = 1;

    /// Uncorrelated curve (Uniswap like).
    const UNCORRELATED_CURVE: u8 = 2;

    // Public functions.

    /// Liquidity pool with reserves.
    struct LiquidityPool<phantom X, phantom Y, phantom LP> has key {
        coin_x_reserve: Coin<X>,
        coin_y_reserve: Coin<Y>,
        last_block_timestamp: u64,
        last_price_x_cumulative: u128,
        last_price_y_cumulative: u128,
        lp_mint_cap: coin::MintCapability<LP>,
        lp_burn_cap: coin::BurnCapability<LP>,
        // Scales are pow(10, token_decimals).
        x_scale: u64,
        y_scale: u64,
        curve_type: u8,
        locked: bool,
    }

    /// Flash loan resource
    /// There is no way in Move to pass calldata and make dynamic calls, but a resource can be used for this purpose.
    /// To make the execution into a single transaction, the flash loan function must return a resource
    /// that cannot be copied, cannot be saved, cannot be dropped, or cloned.
    struct Flashloan<phantom X, phantom Y, phantom LP> {
        pool_addr: address,
        x_loan: u64,
        y_loan: u64
    }

    /// Register liquidity pool `X`/`Y`.
    /// Parameters:
    /// * `lp_name` - LP coin name.
    /// * `lp_symbol` - LP coin symbol.
    /// * `curve_type` - pool curve type: 1 = stable, 2 = uncorrelated (uniswap like).
    public fun register<X, Y, LP>(
        owner: &signer,
        lp_name: String,
        lp_symbol: String,
        curve_type: u8
    ) {
        assert_no_emergency();

        assert_is_coin<X>();
        assert_is_coin<Y>();
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);

        let owner_addr = signer::address_of(owner);
        assert!(!exists<LiquidityPool<X, Y, LP>>(owner_addr), ERR_POOL_EXISTS_FOR_PAIR);
        assert!(
            curve_type == STABLE_CURVE || curve_type == UNCORRELATED_CURVE,
            ERR_INVALID_CURVE
        );

        let (lp_burn_cap, lp_freeze_cap, lp_mint_cap) = coin::initialize<LP>(
            owner,
            lp_name,
            lp_symbol,
            6,
            true
        );
        coin::destroy_freeze_cap(lp_freeze_cap);

        let x_scale = 0;
        let y_scale = 0;

        if (curve_type == STABLE_CURVE) {
            x_scale = math::pow_10(coin::decimals<X>());
            y_scale = math::pow_10(coin::decimals<Y>());
        };

        let pool = LiquidityPool<X, Y, LP> {
            coin_x_reserve: coin::zero<X>(),
            coin_y_reserve: coin::zero<Y>(),
            last_block_timestamp: 0,
            last_price_x_cumulative: 0,
            last_price_y_cumulative: 0,
            lp_mint_cap,
            lp_burn_cap,
            x_scale,
            y_scale,
            curve_type,
            locked: false,
        };
        move_to(owner, pool);

        dao_storage::register<X, Y, LP>(owner);
        gauge::register<X, Y, LP>(owner);
        bribe::register<X, Y, LP>(owner);

        let events_store = EventsStore<X, Y, LP> {
            pool_created_handle: account::new_event_handle<PoolCreatedEvent<X, Y, LP>>(owner),
            liquidity_added_handle: account::new_event_handle<LiquidityAddedEvent<X, Y, LP>>(owner),
            liquidity_removed_handle: account::new_event_handle<LiquidityRemovedEvent<X, Y, LP>>(owner),
            swap_handle: account::new_event_handle<SwapEvent<X, Y, LP>>(owner),
            loan_handle: account::new_event_handle<FlashloanEvent<X, Y, LP>>(owner),
            oracle_updated_handle: account::new_event_handle<OracleUpdatedEvent<X, Y, LP>>(owner),
        };
        event::emit_event(
            &mut events_store.pool_created_handle,
            PoolCreatedEvent<X, Y, LP> {},
        );

        move_to(owner, events_store);
    }

    /// Mint new liquidity coins.
    /// * `pool_addr` - pool owner address.
    /// * `coin_x` - coin X to add to liquidity reserves.
    /// * `coin_y` - coin Y to add to liquidity reserves.
    /// Returns LP coins: `Coin<LP>`.
    public fun mint<X, Y, LP>(
        pool_addr: address,
        coin_x: Coin<X>,
        coin_y: Coin<Y>
    ): Coin<LP> acquires LiquidityPool, EventsStore {
        assert_no_emergency();
        assert_pool_locked<X, Y, LP>(pool_addr);

        let lp_coins_total = coin_helper::supply<LP>();

        let (x_reserve_size, y_reserve_size) = get_reserves_size<X, Y, LP>(pool_addr);

        let x_provided_val = coin::value<X>(&coin_x);
        let y_provided_val = coin::value<Y>(&coin_y);

        let provided_liq = if (lp_coins_total == 0) {
            let initial_liq = math::sqrt(math::mul_to_u128(x_provided_val, y_provided_val));
            assert!(initial_liq > MINIMAL_LIQUIDITY, ERR_NOT_ENOUGH_INITIAL_LIQUIDITY);
            initial_liq - MINIMAL_LIQUIDITY
        } else {
            let x_liq = math::mul_div_u128((x_provided_val as u128), lp_coins_total, (x_reserve_size as u128));
            let y_liq = math::mul_div_u128((y_provided_val as u128), lp_coins_total, (y_reserve_size as u128));
            if (x_liq < y_liq) {
                x_liq
            } else {
                y_liq
            }
        };
        assert!(provided_liq > 0, ERR_NOT_ENOUGH_LIQUIDITY);

        let pool = borrow_global_mut<LiquidityPool<X, Y, LP>>(pool_addr);
        coin::merge(&mut pool.coin_x_reserve, coin_x);
        coin::merge(&mut pool.coin_y_reserve, coin_y);

        let lp_coins = coin::mint<LP>(provided_liq, &pool.lp_mint_cap);

        update_oracle<X, Y, LP>(pool, pool_addr, x_reserve_size, y_reserve_size);

        let events_store = borrow_global_mut<EventsStore<X, Y, LP>>(pool_addr);
        event::emit_event(
            &mut events_store.liquidity_added_handle,
            LiquidityAddedEvent<X, Y, LP> {
                added_x_val: x_provided_val,
                added_y_val: y_provided_val,
                lp_tokens_received: provided_liq
            });

        lp_coins
    }

    /// Burn liquidity coins (LP) and get back X and Y coins from reserves.
    /// * `pool_addr` - pool owner address.
    /// * `lp_coins` - LP coins to burn.
    /// Returns both X and Y coins - `(Coin<X>, Coin<Y>)`.
    public fun burn<X, Y, LP>(pool_addr: address, lp_coins: Coin<LP>): (Coin<X>, Coin<Y>)
    acquires LiquidityPool, EventsStore {
        assert_pool_locked<X, Y, LP>(pool_addr);

        let burned_lp_coins_val = coin::value(&lp_coins);

        let pool = borrow_global_mut<LiquidityPool<X, Y, LP>>(pool_addr);

        let lp_coins_total = coin_helper::supply<LP>();
        let x_reserve_val = coin::value(&pool.coin_x_reserve);
        let y_reserve_val = coin::value(&pool.coin_y_reserve);

        // Compute x, y coin values for provided lp_coins value
        let x_to_return_val = math::mul_div_u128((burned_lp_coins_val as u128), (x_reserve_val as u128), lp_coins_total);
        let y_to_return_val = math::mul_div_u128((burned_lp_coins_val as u128), (y_reserve_val as u128), lp_coins_total);
        assert!(x_to_return_val > 0 && y_to_return_val > 0, ERR_INCORRECT_BURN_VALUES);

        // Withdraw those values from reserves
        let x_coin_to_return = coin::extract(&mut pool.coin_x_reserve, x_to_return_val);
        let y_coin_to_return = coin::extract(&mut pool.coin_y_reserve, y_to_return_val);

        update_oracle<X, Y, LP>(pool, pool_addr, x_reserve_val, y_reserve_val);
        coin::burn(lp_coins, &pool.lp_burn_cap);

        let events_store = borrow_global_mut<EventsStore<X, Y, LP>>(pool_addr);
        event::emit_event(
            &mut events_store.liquidity_removed_handle,
            LiquidityRemovedEvent<X, Y, LP> {
                returned_x_val: x_to_return_val,
                returned_y_val: y_to_return_val,
                lp_tokens_burned: burned_lp_coins_val
            });

        (x_coin_to_return, y_coin_to_return)
    }

    /// Swap coins (can swap both x and y in the same time).
    /// In the most of situation only X or Y coin argument has value (similar with *_out, only one _out will be non-zero).
    /// Because an user usually exchanges only one coin, yet function allow to exchange both coin.
    /// * `x_in` - X coins to swap.
    /// * `x_out` - expected amount of X coins to get out.
    /// * `y_in` - Y coins to swap.
    /// * `y_out` - expected amount of Y coins to get out.
    /// Returns both exchanged X and Y coins: `(Coin<X>, Coin<Y>)`.
    public fun swap<X, Y, LP>(
        pool_addr: address,
        x_in: Coin<X>,
        x_out: u64,
        y_in: Coin<Y>,
        y_out: u64
    ): (Coin<X>, Coin<Y>) acquires LiquidityPool, EventsStore {
        assert_no_emergency();
        assert_pool_locked<X, Y, LP>(pool_addr);

        let x_in_val = coin::value(&x_in);
        let y_in_val = coin::value(&y_in);

        assert!(x_in_val > 0 || y_in_val > 0, ERR_EMPTY_COIN_IN);

        let (x_reserve_size, y_reserve_size) = get_reserves_size<X, Y, LP>(pool_addr);
        let pool = borrow_global_mut<LiquidityPool<X, Y, LP>>(pool_addr);

        // Deposit new coins to liquidity pool.
        coin::merge(&mut pool.coin_x_reserve, x_in);
        coin::merge(&mut pool.coin_y_reserve, y_in);

        // Withdraw expected amount from reserves.
        let x_swapped = coin::extract(&mut pool.coin_x_reserve, x_out);
        let y_swapped = coin::extract(&mut pool.coin_y_reserve, y_out);

        // Confirm that lp_value for the pool hasn't been reduced.
        // For that, we compute lp_value with old reserves and lp_value with reserves after swap is done,
        // and make sure lp_value doesn't decrease
        let (x_res_new_after_fee, y_res_new_after_fee) =
            new_reserves_after_fees_scaled(
                coin::value(&pool.coin_x_reserve),
                coin::value(&pool.coin_y_reserve),
                x_in_val,
                y_in_val,
                pool.curve_type
            );
        assert_lp_value_is_increased(
            pool.x_scale,
            pool.y_scale,
            pool.curve_type,
            (x_reserve_size as u128),
            (y_reserve_size as u128),
            (x_res_new_after_fee as u128),
            (y_res_new_after_fee as u128),
        );

        split_third_of_fee_to_dao(pool, pool_addr, x_in_val, y_in_val);
        split_two_thirds_of_fee_to_gauge(pool, pool_addr, x_in_val, y_in_val);

        update_oracle<X, Y, LP>(pool, pool_addr, x_reserve_size, y_reserve_size);

        let events_store = borrow_global_mut<EventsStore<X, Y, LP>>(pool_addr);
        event::emit_event(
            &mut events_store.swap_handle,
            SwapEvent<X, Y, LP> {
                x_in: x_in_val,
                y_in: y_in_val,
                x_out,
                y_out,
            });

        // Return swapped amount.
        (x_swapped, y_swapped)
    }

    /// Get flash loan coins.
    /// In the most of situation only X or Y coin argument has value.
    /// Because an user usually loans only one coin, yet function allow to loans both coin.
    /// * `pool_addr` - pool owner address.
    /// * `x_loan` - expected amount of X coins to loan.
    /// * `y_loan` - expected amount of Y coins to loan.
    /// Returns both loaned X and Y coins: `(Coin<X>, Coin<Y>, Flashloan<X, Y, LP)`.
    public fun flashloan<X, Y, LP>(
        pool_addr: address,
        x_loan: u64,
        y_loan: u64
    ): (Coin<X>, Coin<Y>, Flashloan<X, Y, LP>) acquires LiquidityPool, EventsStore {
        assert_no_emergency();

        assert_pool_locked<X, Y, LP>(pool_addr);
        assert!(x_loan > 0 || y_loan > 0, ERR_EMPTY_COIN_LOAN);

        let pool = borrow_global_mut<LiquidityPool<X, Y, LP>>(pool_addr);

        let reserve_x = coin::value(&pool.coin_x_reserve);
        let reserve_y = coin::value(&pool.coin_y_reserve);

        // Withdraw expected amount from reserves.
        let x_loaned = coin::extract(&mut pool.coin_x_reserve, x_loan);
        let y_loaned = coin::extract(&mut pool.coin_y_reserve, y_loan);

        // The pool will be locked after the loan until payment.
        pool.locked = true;

        let events_store = borrow_global_mut<EventsStore<X, Y, LP>>(pool_addr);
        event::emit_event(
            &mut events_store.loan_handle,
            FlashloanEvent<X, Y, LP> {
                x_loan,
                y_loan,
            });

        update_oracle(pool, pool_addr, reserve_x, reserve_y);

        // Return loaned amount.
        (x_loaned, y_loaned, Flashloan<X, Y, LP> {
            pool_addr,
            x_loan,
            y_loan,
        })
    }

    /// Pay flash loan coins.
    /// In the most of situation only X or Y coin argument has value.
    /// Because an user usually loans only one coin, yet function allow to loans both coin.
    /// * `x_in` - X coins to pay.
    /// * `y_in` - Y coins to pay.
    /// * `loan` - data about flashloan.
    /// Returns both loaned X and Y coins: `(Coin<X>, Coin<Y>, Flashloan<X, Y, LP)`.
    public fun pay_flashloan<X, Y, LP>(
        x_in: Coin<X>,
        y_in: Coin<Y>,
        loan: Flashloan<X, Y, LP>
    ) acquires LiquidityPool {
        assert_no_emergency();

        let Flashloan { pool_addr, x_loan, y_loan } = loan;

        assert!(exists<LiquidityPool<X, Y, LP>>(pool_addr), ERR_POOL_DOES_NOT_EXIST);

        let x_in_val = coin::value(&x_in);
        let y_in_val = coin::value(&y_in);

        assert!(x_in_val > 0 || y_in_val > 0, ERR_EMPTY_COIN_IN);

        let pool = borrow_global_mut<LiquidityPool<X, Y, LP>>(pool_addr);

        let x_reserve_size = coin::value(&pool.coin_x_reserve);
        let y_reserve_size = coin::value(&pool.coin_y_reserve);

        // Reserve sizes before loan out
        x_reserve_size = x_reserve_size + x_loan;
        y_reserve_size = y_reserve_size + y_loan;

        // Deposit new coins to liquidity pool.
        coin::merge(&mut pool.coin_x_reserve, x_in);
        coin::merge(&mut pool.coin_y_reserve, y_in);

        // Confirm that lp_value for the pool hasn't been reduced.
        // For that, we compute lp_value with old reserves and lp_value with reserves after swap is done,
        // and make sure lp_value doesn't decrease
        let (x_res_new_after_fee, y_res_new_after_fee) =
            new_reserves_after_fees_scaled(
                coin::value(&pool.coin_x_reserve),
                coin::value(&pool.coin_y_reserve),
                x_in_val,
                y_in_val,
                pool.curve_type
            );
        assert_lp_value_is_increased(
            pool.x_scale,
            pool.y_scale,
            pool.curve_type,
            (x_reserve_size as u128),
            (y_reserve_size as u128),
            x_res_new_after_fee,
            y_res_new_after_fee,
        );
        // third of all fees goes into DAO
        split_third_of_fee_to_dao(pool, pool_addr, x_in_val, y_in_val);
        // two-thirds of all fees goes into gauge
        split_two_thirds_of_fee_to_gauge(pool, pool_addr, x_in_val, y_in_val);

        // As we are in same block, don't need to update oracle, it's already updated during flashloan initalization.

        // The pool will be unlocked after payment.
        pool.locked = false;
    }

    // Private functions.

    /// Get reserves after fees.
    /// * `x_reserve` - reserve X.
    /// * `y_reserve` - reserve Y.
    /// * `x_in_val` - amount of X coins added to reserves.
    /// * `y_in_val` - amount of Y coins added to reserves.
    /// Returns both X and Y reserves after fees.
    fun new_reserves_after_fees_scaled(
        x_reserve: u64,
        y_reserve: u64,
        x_in_val: u64,
        y_in_val: u64,
        curve_type: u8
    ): (u128, u128) {
        // x_res_after_fee = x_reserve_new - x_in_value * 0.003
        // (all of it scaled to 1000 to be able to achieve this math in integers)
        let x_res_new_after_fee = if (curve_type == UNCORRELATED_CURVE) {
            math::mul_to_u128(x_reserve, FEE_SCALE) - math::mul_to_u128(x_in_val, FEE_MULTIPLIER)
        } else {
            ((x_reserve - math::mul_div(x_in_val, FEE_MULTIPLIER, FEE_SCALE)) as u128)
        };

        let y_res_new_after_fee = if (curve_type == UNCORRELATED_CURVE) {
            math::mul_to_u128(y_reserve, FEE_SCALE) - math::mul_to_u128(y_in_val, FEE_MULTIPLIER)
        } else {
            ((y_reserve - math::mul_div(y_in_val, FEE_MULTIPLIER, FEE_SCALE)) as u128)
        };
        (x_res_new_after_fee, y_res_new_after_fee)
    }

    /// Depositing part of fees to DAO Storage.
    /// * `pool` - pool to extract coins.
    /// * `pool_addr` - address of pool.
    /// * `x_in_val` - how much X coins was deposited to pool.
    /// * `y_in_val` - how much Y coins was deposited to pool.
    fun split_third_of_fee_to_dao<X, Y, LP>(
        pool: &mut LiquidityPool<X, Y, LP>,
        pool_addr: address,
        x_in_val: u64,
        y_in_val: u64
    ) {
        // Split 33% of fee multiplier of provided coins to the DAOStorage
        // x_in_val * (fee / fee_scale), ie. for 0.1% it's (10 / 10000)
        let dao_fee_multiplier = FEE_MULTIPLIER / 3;
        let dao_x_fee_val = math::mul_div(x_in_val, dao_fee_multiplier, FEE_SCALE);
        let dao_y_fee_val = math::mul_div(y_in_val, dao_fee_multiplier, FEE_SCALE);

        let dao_x_in = coin::extract(&mut pool.coin_x_reserve, dao_x_fee_val);
        let dao_y_in = coin::extract(&mut pool.coin_y_reserve, dao_y_fee_val);
        dao_storage::deposit<X, Y, LP>(pool_addr, dao_x_in, dao_y_in);
    }

    /// Depositing part of fees to gauge.
    /// * `pool` - pool to extract coins.
    /// * `pool_addr` - address of pool.
    /// * `x_in_val` - how much X coins was deposited to pool.
    /// * `y_in_val` - how much Y coins was deposited to pool.
    fun split_two_thirds_of_fee_to_gauge<X, Y, LP>(
        pool: &mut LiquidityPool<X, Y, LP>,
        pool_addr: address,
        x_in_val: u64,
        y_in_val: u64
    ) {
        // Split 66% of fee multiplier of provided coins to the gauge
        // x_in_val * (fee / fee_scale), ie. for 0.2% it's (20 / 10000)
        let gauge_fee_multiplier = 2 * FEE_MULTIPLIER / 3;
        let gauge_x_fee_val = math::mul_div(x_in_val, gauge_fee_multiplier, FEE_SCALE);
        let gauge_y_fee_val = math::mul_div(y_in_val, gauge_fee_multiplier, FEE_SCALE);

        let gauge_x_in = coin::extract(&mut pool.coin_x_reserve, gauge_x_fee_val);
        let gauge_y_in = coin::extract(&mut pool.coin_y_reserve, gauge_y_fee_val);
        gauge::deposit_fees<X, Y, LP>(pool_addr, gauge_x_in, gauge_y_in);
    }

    /// Compute and verify LP value after and before swap, in nutshell, _k function.
    /// * `x_scale` - 10 pow by X coin decimals.
    /// * `y_scale` - 10 pow by Y coin decimals.
    /// * `curve_type` - type of curve.
    /// * `x_res` - X reserves before swap.
    /// * `y_res` - Y reserves before swap.
    /// * `x_res_with_fees` - X reserves after swap.
    /// * `y_res_with_fees` - Y reserves after swap.
    /// Aborts if swap can't be done.
    fun assert_lp_value_is_increased(
        x_scale: u64,
        y_scale: u64,
        curve_type: u8,
        x_res: u128,
        y_res: u128,
        x_res_with_fees: u128,
        y_res_with_fees: u128,
    ) {
        if (curve_type == STABLE_CURVE) {
            let lp_value_before_swap = stable_curve::lp_value(x_res, x_scale, y_res, y_scale);
            let lp_value_after_swap_and_fee = stable_curve::lp_value(x_res_with_fees, x_scale, y_res_with_fees, y_scale);

            let cmp = u256::compare(&lp_value_after_swap_and_fee, &lp_value_before_swap);
            assert!(cmp == 2, ERR_INCORRECT_SWAP);
        } else if (curve_type == UNCORRELATED_CURVE) {
            let lp_value_before_swap = x_res * y_res;
            let lp_value_before_swap_u256 = u256::mul(
                u256::from_u128(lp_value_before_swap),
                u256::from_u64(FEE_SCALE * FEE_SCALE)
            );
            let lp_value_after_swap_and_fee = u256::mul(
                u256::from_u128(x_res_with_fees),
                u256::from_u128(y_res_with_fees),
            );

            let cmp = u256::compare(&lp_value_after_swap_and_fee, &lp_value_before_swap_u256);
            assert!(cmp == 2, ERR_INCORRECT_SWAP);
        } else {
            abort ERR_INVALID_CURVE
        };
    }

    /// Update current cumulative prices.
    /// Important: If you want to use the following function take into account prices can be overflowed.
    /// So it's important to use same logic in your math/algo (as Move doesn't allow overflow). See math::overflow_add.
    /// * `pool` - Liquidity pool to update prices.
    /// * `pool_addr` - address of pool to get event emitter.
    /// * `x_reserve` - coin X reserves.
    /// * `y_reserve` - coin Y reserves.
    fun update_oracle<X, Y, LP>(
        pool: &mut LiquidityPool<X, Y, LP>,
        pool_addr: address,
        x_reserve: u64,
        y_reserve: u64
    ) acquires EventsStore {
        let last_block_timestamp = pool.last_block_timestamp;

        let block_timestamp = timestamp::now_seconds();

        let time_elapsed = ((block_timestamp - last_block_timestamp) as u128);

        if (time_elapsed > 0 && x_reserve != 0 && y_reserve != 0) {
            let last_price_x_cumulative = uq64x64::to_u128(uq64x64::fraction(y_reserve, x_reserve)) * time_elapsed;
            let last_price_y_cumulative = uq64x64::to_u128(uq64x64::fraction(x_reserve, y_reserve)) * time_elapsed;

            pool.last_price_x_cumulative = math::overflow_add(pool.last_price_x_cumulative, last_price_x_cumulative);
            pool.last_price_y_cumulative = math::overflow_add(pool.last_price_y_cumulative, last_price_y_cumulative);

            let events_store = borrow_global_mut<EventsStore<X, Y, LP>>(pool_addr);
            event::emit_event(
                &mut events_store.oracle_updated_handle,
                OracleUpdatedEvent<X, Y, LP> {
                    last_price_x_cumulative: pool.last_price_x_cumulative,
                    last_price_y_cumulative: pool.last_price_y_cumulative,
                });
        };

        pool.last_block_timestamp = block_timestamp;
    }

    /// Aborts if pool is locked.
    /// * `pool_addr` - pool owner address.
    fun assert_pool_locked<X, Y, LP>(pool_addr: address) acquires LiquidityPool {
        assert!(is_pool_locked<X, Y, LP>(pool_addr) == false, ERR_POOL_IS_LOCKED);
    }

    // Getters.

    /// Check if pool is locked.
    /// * `pool_addr` - pool owner address.
    public fun is_pool_locked<X, Y, LP>(pool_addr: address): bool acquires LiquidityPool {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        assert!(exists<LiquidityPool<X, Y, LP>>(pool_addr), ERR_POOL_DOES_NOT_EXIST);
        let pool = borrow_global<LiquidityPool<X, Y, LP>>(pool_addr);
        pool.locked
    }

    /// Get reserves of a pool.
    /// * `pool_addr` - pool owner address.
    /// Returns both (X, Y) reserves.
    public fun get_reserves_size<X, Y, LP>(pool_addr: address): (u64, u64)
    acquires LiquidityPool {
        assert_no_emergency();
        assert_pool_locked<X, Y, LP>(pool_addr);

        let liquidity_pool = borrow_global<LiquidityPool<X, Y, LP>>(pool_addr);
        let x_reserve = coin::value(&liquidity_pool.coin_x_reserve);
        let y_reserve = coin::value(&liquidity_pool.coin_y_reserve);

        (x_reserve, y_reserve)
    }

    /// Get current cumulative prices.
    /// Cumulative prices can be overflowed, so take it into account before work with the following function.
    /// It's important to use same logic in your math/algo (as Move doesn't allow overflow).
    /// * `pool_addr` - pool owner address.
    /// Returns (X price, Y price, block_timestamp).
    public fun get_cumulative_prices<X, Y, LP>(pool_addr: address): (u128, u128, u64)
    acquires LiquidityPool {
        assert_no_emergency();
        assert_pool_locked<X, Y, LP>(pool_addr);

        let liquidity_pool = borrow_global<LiquidityPool<X, Y, LP>>(pool_addr);
        let last_price_x_cumulative = *&liquidity_pool.last_price_x_cumulative;
        let last_price_y_cumulative = *&liquidity_pool.last_price_y_cumulative;
        let last_block_timestamp = liquidity_pool.last_block_timestamp;

        (last_price_x_cumulative, last_price_y_cumulative, last_block_timestamp)
    }

    /// Get curve type of the pool.
    /// * `pool_addr` - pool owner address.
    /// Returns 1 = stable or 2 = uncorrelated (uniswap like).
    public fun get_curve_type<X, Y, LP>(pool_addr: address): u8 acquires LiquidityPool {
        assert!(
            coin_helper::is_sorted<X, Y>(),
            ERR_WRONG_PAIR_ORDERING
        );
        assert!(
            exists<LiquidityPool<X, Y, LP>>(pool_addr),
            ERR_POOL_DOES_NOT_EXIST
        );

        borrow_global<LiquidityPool<X, Y, LP>>(pool_addr).curve_type
    }


    /// Get decimals scales (10^X decimals, 10^Y decimals) for stable curve.
    /// For uncorrelated curve would return just zeros.
    /// * `pool_addr` - pool owner address.
    public fun get_decimals_scales<X, Y, LP>(pool_addr: address): (u64, u64) acquires LiquidityPool {
        assert!(
            coin_helper::is_sorted<X, Y>(),
            ERR_WRONG_PAIR_ORDERING
        );
        assert!(
            exists<LiquidityPool<X, Y, LP>>(pool_addr),
            ERR_POOL_DOES_NOT_EXIST
        );

        let pool = borrow_global<LiquidityPool<X, Y, LP>>(pool_addr);
        (pool.x_scale, pool.y_scale)
    }

    /// Check if lp exists at address
    /// * pool_addr - pool owner address.
    /// If pool exists returns true, otherwise false.
    public fun pool_exists_at<X, Y, LP>(pool_addr: address): bool {
        exists<LiquidityPool<X, Y, LP>>(pool_addr)
    }

    /// Get fees numerator, denumerator.
    /// Returns (numerator, denumerator).
    public fun get_fees_config(): (u64, u64) {
        (FEE_MULTIPLIER, FEE_SCALE)
    }

    // Events
    struct EventsStore<phantom X, phantom Y, phantom LP> has key {
        pool_created_handle: event::EventHandle<PoolCreatedEvent<X, Y, LP>>,
        liquidity_added_handle: event::EventHandle<LiquidityAddedEvent<X, Y, LP>>,
        liquidity_removed_handle: event::EventHandle<LiquidityRemovedEvent<X, Y, LP>>,
        swap_handle: event::EventHandle<SwapEvent<X, Y, LP>>,
        loan_handle: event::EventHandle<FlashloanEvent<X, Y, LP>>,
        oracle_updated_handle: event::EventHandle<OracleUpdatedEvent<X, Y, LP>>
    }

    struct PoolCreatedEvent<phantom X, phantom Y, phantom LP> has drop, store {}

    struct LiquidityAddedEvent<phantom X, phantom Y, phantom LP> has drop, store {
        added_x_val: u64,
        added_y_val: u64,
        lp_tokens_received: u64,
    }

    struct LiquidityRemovedEvent<phantom X, phantom Y, phantom LP> has drop, store {
        returned_x_val: u64,
        returned_y_val: u64,
        lp_tokens_burned: u64,
    }

    struct SwapEvent<phantom X, phantom Y, phantom LP> has drop, store {
        x_in: u64,
        x_out: u64,
        y_in: u64,
        y_out: u64,
    }

    struct FlashloanEvent<phantom X, phantom Y, phantom LP> has drop, store {
        x_loan: u64,
        y_loan: u64,
    }

    struct OracleUpdatedEvent<phantom X, phantom Y, phantom LP> has drop, store {
        last_price_x_cumulative: u128,
        last_price_y_cumulative: u128,
    }

    #[test_only]
    public fun compute_and_verify_lp_value_for_test(
        x_scale: u64,
        y_scale: u64,
        curve_type: u8,
        x_res: u128,
        y_res: u128,
        x_res_new: u128,
        y_res_new: u128,
    ) {
        assert_lp_value_is_increased(
            x_scale,
            y_scale,
            curve_type,
            x_res,
            y_res,
            x_res_new,
            y_res_new,
        )
    }

    #[test_only]
    public fun update_cumulative_price_for_test<X, Y, LP>(
        account: &signer,
        last_block_timestamp: u64,
        last_price_x_cumulative: u128,
        last_price_y_cumulative: u128,
        x_reserve: u64,
        y_reserve: u64,
        lp_mint_cap: coin::MintCapability<LP>,
        lp_burn_cap: coin::BurnCapability<LP>,
    ): (u128, u128, u64) acquires EventsStore {
        // just in case
        let addr = signer::address_of(account);
        assert!(addr == @0x12, 0);

        let pool = LiquidityPool<X, Y, LP> {
            coin_x_reserve: coin::zero<X>(),
            coin_y_reserve: coin::zero<Y>(),
            last_block_timestamp,
            last_price_x_cumulative,
            last_price_y_cumulative,
            lp_mint_cap,
            lp_burn_cap,
            x_scale: 0,
            y_scale: 0,
            curve_type: 2,
            locked: false,
        };

        let events_store = EventsStore<X, Y, LP> {
            pool_created_handle: account::new_event_handle<PoolCreatedEvent<X, Y, LP>>(account),
            liquidity_added_handle: account::new_event_handle<LiquidityAddedEvent<X, Y, LP>>(account),
            liquidity_removed_handle: account::new_event_handle<LiquidityRemovedEvent<X, Y, LP>>(account),
            swap_handle: account::new_event_handle<SwapEvent<X, Y, LP>>(account),
            loan_handle: account::new_event_handle<FlashloanEvent<X, Y, LP>>(account),
            oracle_updated_handle: account::new_event_handle<OracleUpdatedEvent<X, Y, LP>>(account),
        };

        move_to(account, events_store);

        update_oracle(
            &mut pool,
            addr,
            x_reserve,
            y_reserve
        );

        let LiquidityPool {
            coin_x_reserve,
            coin_y_reserve,
            last_block_timestamp,
            last_price_x_cumulative,
            last_price_y_cumulative,
            lp_mint_cap,
            lp_burn_cap,
            x_scale: _,
            y_scale: _,
            curve_type: _,
            locked: _,
        } = pool;

        coin::destroy_zero(coin_x_reserve);
        coin::destroy_zero(coin_y_reserve);
        coin::destroy_mint_cap(lp_mint_cap);
        coin::destroy_burn_cap(lp_burn_cap);

        (last_price_x_cumulative, last_price_y_cumulative, last_block_timestamp)
    }
}
