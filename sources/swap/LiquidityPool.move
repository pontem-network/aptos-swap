/// Liquidity pool.
module AptosSwap::LiquidityPool {
    use Std::Signer;
    use Std::ASCII::String;
    use Std::BCS;
    use Std::Compare;
    use CoreFramework::Timestamp;
    use AptosSwap::Token::{Self, Token};
    use AptosSwap::SafeMath;
    use AptosSwap::FixedPoint128;
    use Std::U256::{U256, Self};

    // Constants.
    /// LP token default decimals.
    const LP_TOKEN_DECIMALS: u8 = 9;

    /// Minimal liquidity.
    const MINIMAL_LIQUIDITY: u128 = 1000;

    /// Current fee is 0.3%
    const FEE_NUMERATOR: u128 = 3;
    /// It's fee denumenator.
    const FEE_DENUMENATOR: u128 = 1000;

    // Error codes.
    /// When tokens used to create pair have wrong ordering.
    const ERR_WRONG_PAIR_ORDERING: u64 = 101;

    /// When provided LP token already has minted supply.
    const ERR_LP_TOKEN_NON_ZERO_TOTAL: u64 = 102;

    /// When pair already exists on account.
    const ERR_POOL_EXISTS_FOR_PAIR: u64 = 103;

    /// When not enough liquidity minted.
    const ERR_NOT_ENOUGH_LIQUIDITY: u64 = 104;

    /// When both X and Y provided for swap are equal zero.
    const ERR_EMPTY_IN: u64 = 105;

    /// When incorrect INs/OUTs arguments passed during swap and math doesn't work.
    const ERR_INCORRECT_SWAP: u64 = 106;

    /// Incorrect lp token burn values
    const ERR_INCORRECT_BURN_VALUES: u64 = 107;

    const ERR_POOL_DOES_NOT_EXIST: u64 = 108;

    // TODO: events.

    /// Liquidity pool with reserves.
    /// LP token should go outside of this module.
    /// Probably we only need mint capability?
    struct LiquidityPool<phantom X, phantom Y, phantom LP> has key, store {
        token_x_reserve: Token<X>,
        token_y_reserve: Token<Y>,
        last_block_timestamp: u64,
        last_price_x_cumulative: U256,
        last_price_y_cumulative: U256,
        lp_mint_cap: Token::MintCapability<LP>,
        lp_burn_cap: Token::BurnCapability<LP>,
    }

    /// Register liquidity pool (by pairs).
    public fun register<X: store, Y: store, LP>(owner: &signer,
                                                               lp_mint_cap: Token::MintCapability<LP>,
                                                               lp_burn_cap: Token::BurnCapability<LP>) {
        Token::assert_is_token<X>();
        Token::assert_is_token<Y>();
        assert_correct_token_order<X, Y>();

        Token::assert_is_token<LP>();
        
        // TODO: check LP decimals.
        assert!(Token::total_value<LP>() == 0, ERR_LP_TOKEN_NON_ZERO_TOTAL);

        let owner_addr = Signer::address_of(owner);
        assert!(!exists<LiquidityPool<X, Y, LP>>(owner_addr), ERR_POOL_EXISTS_FOR_PAIR);

        let pool = LiquidityPool<X, Y, LP>{
            token_x_reserve: Token::zero<X>(),
            token_y_reserve: Token::zero<Y>(),
            last_block_timestamp: 0,
            last_price_x_cumulative: U256::zero(),
            last_price_y_cumulative: U256::zero(),
            lp_mint_cap,
            lp_burn_cap,
        };
        move_to(owner, pool);
    }

    /// Mint new liquidity.
    public fun add_liquidity<X: store, Y: store, LP>(owner_addr: address, token_x: Token<X>, token_y: Token<Y>): Token<LP>
    acquires LiquidityPool {
        assert!(exists<LiquidityPool<X, Y, LP>>(owner_addr), ERR_POOL_DOES_NOT_EXIST);

        let total_supply: u128 = Token::total_value<LP>();

        let (x_reserve, y_reserve) = get_reserves_size<X, Y, LP>(owner_addr);

        let x_value = Token::value<X>(&token_x);
        let y_value = Token::value<Y>(&token_y);

        let provided_liquidity = if (total_supply == 0) {
            SafeMath::sqrt_u256(SafeMath::mul_u128(x_value, y_value)) - MINIMAL_LIQUIDITY
        } else {
            let x_liquidity = SafeMath::safe_mul_div_u128(x_value, total_supply, x_reserve);
            let y_liquidity = SafeMath::safe_mul_div_u128(y_value, total_supply, y_reserve);

            if (x_liquidity < y_liquidity) {
                x_liquidity
            } else {
                y_liquidity
            }
        };
        assert!(provided_liquidity > 0, ERR_NOT_ENOUGH_LIQUIDITY);

        let pool = borrow_global_mut<LiquidityPool<X, Y, LP>>(owner_addr);
        Token::deposit(&mut pool.token_x_reserve, token_x);
        Token::deposit(&mut pool.token_y_reserve, token_y);

        let lp_tokens = Token::mint<LP>(provided_liquidity, &pool.lp_mint_cap);

        update_oracle<X, Y, LP>(pool, x_reserve, y_reserve);

        lp_tokens
    }

    public fun burn_liquidity<X: store, Y: store, LP>(owner_addr: address, lp_tokens: Token<LP>): (Token<X>, Token<Y>)
    acquires LiquidityPool {
        assert!(exists<LiquidityPool<X, Y, LP>>(owner_addr), ERR_POOL_DOES_NOT_EXIST);

        let burned_lp_value = Token::value(&lp_tokens);
        let pool = borrow_global_mut<LiquidityPool<X, Y, LP>>(owner_addr);

        let lp_tokens_total = Token::total_value<LP>();
        let x_reserve = Token::value(&pool.token_x_reserve);
        let y_reserve = Token::value(&pool.token_y_reserve);

        let x_value = SafeMath::safe_mul_div_u128(burned_lp_value, x_reserve, lp_tokens_total);
        let y_value = SafeMath::safe_mul_div_u128(burned_lp_value, y_reserve, lp_tokens_total);
        assert!(x_value > 0 && y_value > 0, ERR_INCORRECT_BURN_VALUES);

        let x_token = Token::withdraw(&mut pool.token_x_reserve, x_value);
        let y_token = Token::withdraw(&mut pool.token_y_reserve, y_value);

        update_oracle<X, Y, LP>(pool, x_reserve - x_value, y_reserve - y_value);
        Token::burn(lp_tokens, &pool.lp_burn_cap);

        (x_token, y_token)
    }

    /// Swap tokens (can swap both x and y in the same time).
    /// In the most of situation only X or Y tokens argument has value (similar with *_out, only one _out will be non-zero).
    /// Because an user usually exchanges only one token, yet function allow to exchange both tokens.
    /// * x_in - X tokens to swap.
    /// * x_out - exptected amount of X tokens to get out.
    /// * y_in - Y tokens to swap.
    /// * y_out - exptected amount of Y tokens to get out.
    /// Returns - both exchanged X and Y token.
    public fun swap<X: store, Y: store, LP>(owner_addr: address, x_in: Token<X>, x_out: u128, y_in: Token<Y>, y_out: u128): (Token<X>, Token<Y>)
    acquires LiquidityPool {
        assert!(exists<LiquidityPool<X, Y, LP>>(owner_addr), ERR_POOL_DOES_NOT_EXIST);

        let x_in_value = Token::value(&x_in);
        let y_in_value = Token::value(&y_in);

        assert!(x_in_value > 0 || y_in_value > 0, ERR_EMPTY_IN);

        let (x_reserve, y_reserve) = get_reserves_size<X, Y, LP>(owner_addr);
        let pool = borrow_global_mut<LiquidityPool<X, Y, LP>>(owner_addr);

        // Deposit new tokens to liquidity pool.
        Token::deposit(&mut pool.token_x_reserve, x_in);
        Token::deposit(&mut pool.token_y_reserve, y_in);

        // Withdraw expected amount from reserves.
        let x_swapped = Token::withdraw(&mut pool.token_x_reserve, x_out);
        let y_swapped = Token::withdraw(&mut pool.token_y_reserve, y_out);

        // Get new reserves.
        let x_reserve_new = Token::value(&pool.token_x_reserve);
        let y_reserve_new = Token::value(&pool.token_y_reserve);

        // Check we can do swap with provided info.
        let x_adjusted = x_reserve_new * FEE_DENUMENATOR - x_in_value * FEE_NUMERATOR;
        let y_adjusted = y_reserve_new * FEE_DENUMENATOR - y_in_value * FEE_NUMERATOR;
        let cmp_order = SafeMath::safe_compare_mul_u128(x_adjusted, y_adjusted, x_reserve, y_reserve * 1000000);

        assert!((SafeMath::CONST_EQUALS() == cmp_order || SafeMath::CONST_GREATER_THAN() == cmp_order), ERR_INCORRECT_SWAP);

        update_oracle<X, Y, LP>(pool, x_reserve, y_reserve);

        // Return swapped amount.
        (x_swapped, y_swapped)
    }

    /// Update prices.
    fun update_oracle<X: store, Y: store, LP>(pool: &mut LiquidityPool<X, Y, LP>, x_reserve: u128, y_reserve: u128) {
        let last_block_timestamp = pool.last_block_timestamp;

        let block_timestamp = Timestamp::now_seconds() % (1u64 << 32);

        let time_elapsed: u64 = block_timestamp - last_block_timestamp;

        if (time_elapsed > 0 && x_reserve != 0 && y_reserve != 0) {
            // If we are not in the same block.
            // TODO: see if possible rewrite without FixedPoint128 and U256 (yet i'm really not sure, too big numbers).
            // Uniswap is using the following library https://github.com/Uniswap/v2-core/blob/master/contracts/libraries/UQ112x112.sol
            // And doing it so - https://github.com/Uniswap/v2-core/blob/master/contracts/UniswapV2Pair.sol#L77.
            let last_price_x_cumulative = U256::mul(FixedPoint128::to_u256(FixedPoint128::div(FixedPoint128::encode(y_reserve), x_reserve)), U256::from_u64(time_elapsed));
            let last_price_y_cumulative = U256::mul(FixedPoint128::to_u256(FixedPoint128::div(FixedPoint128::encode(x_reserve), y_reserve)), U256::from_u64(time_elapsed));
            pool.last_price_x_cumulative = U256::add(*&pool.last_price_x_cumulative, last_price_x_cumulative);
            pool.last_price_y_cumulative = U256::add(*&pool.last_price_y_cumulative, last_price_y_cumulative);
        };

        pool.last_block_timestamp = block_timestamp;
    }

    public fun assert_correct_token_order<X, Y>() {
        let cmp = compare_token<X, Y>();
        // can only be LESS_THAN, alphabetical order
        assert!(cmp == SafeMath::CONST_LESS_THAN(), ERR_WRONG_PAIR_ORDERING);
    }

    /// Caller should call this function to determine the order of A, B.
    public fun compare_token<X, Y>(): u8 {
        let x_bytes = BCS::to_bytes<String>(&Token::symbol<X>());
        let y_bytes = BCS::to_bytes<String>(&Token::symbol<Y>());
        let ret: u8 = Compare::cmp_bcs_bytes(&x_bytes, &y_bytes);
        ret
    }

    /// Get reserves of a token pair.
    public fun get_reserves_size<X: store, Y: store, LP>(owner_addr: address): (u128, u128)
    acquires LiquidityPool {
        assert_correct_token_order<X, Y>();
        assert!(exists<LiquidityPool<X, Y, LP>>(owner_addr), ERR_POOL_DOES_NOT_EXIST);

        let liquidity_pool = borrow_global<LiquidityPool<X, Y, LP>>(owner_addr);
        let x_reserve = Token::value(&liquidity_pool.token_x_reserve);
        let y_reserve = Token::value(&liquidity_pool.token_y_reserve);

        (x_reserve, y_reserve)
    }

    /// Get current prices.
    public fun get_cumulative_prices<X: store, Y: store, LP>(owner_addr: address): (U256, U256, u64)
    acquires LiquidityPool {
        assert_correct_token_order<X, Y>();
        assert!(exists<LiquidityPool<X, Y, LP>>(owner_addr), ERR_POOL_DOES_NOT_EXIST);

        let liquidity_pool = borrow_global<LiquidityPool<X, Y, LP>>(owner_addr);
        let last_price_x_cumulative = *&liquidity_pool.last_price_x_cumulative;
        let last_price_y_cumulative = *&liquidity_pool.last_price_y_cumulative;
        let last_block_timestamp = liquidity_pool.last_block_timestamp;

        (last_price_x_cumulative, last_price_y_cumulative, last_block_timestamp)
    }

    /// Check if lp exists at address
    public fun lp_exists_at<X: store, Y: store, LP>(owner: address): bool {
        exists<LiquidityPool<X, Y, LP>>(owner)
    }

    /// Get fees numerator, denumerator.
    public fun get_fees_config(): (u128, u128) {
        (FEE_NUMERATOR, FEE_DENUMENATOR)
    }
}
