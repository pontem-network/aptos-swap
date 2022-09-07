/// The current module contains pre-deplopyed scripts for LiquidSwap.
module liquidswap::scripts {
    use std::signer;

    use aptos_framework::coin;

    use liquidswap::router;
    use liquidswap::liquidity_pool::LP;

    /// Register a new liquidity pool for `X`/`Y` pair.
    /// * `curve_type` - curve type: 1 = stable (like Solidly), 2 = uncorrelated (like Uniswap).
    public entry fun register_pool<X, Y>(account: &signer, curve_type: u8) {
        router::register_pool<X, Y>(account, curve_type);
    }

    /// Register a new liquidity pool `X`/`Y` and immediately add liquidity.
    /// * `curve_type` - curve type: 1 = stable (like Solidly), 2 = uncorrelated (like Uniswap).
    /// * `coin_x_val` - amount of coin `X` to add as liquidity.
    /// * `coin_x_val_min` - minimum amount of coin `X` to add as liquidity (slippage).
    /// * `coin_y_val` - minimum amount of coin `Y` to add as liquidity.
    /// * `coin_y_val_min` - minimum amount of coin `Y` to add as liquidity (slippage).
    public entry fun register_pool_and_add_liquidity<X, Y>(
        account: &signer,
        curve_type: u8,
        coin_x_val: u64,
        coin_x_val_min: u64,
        coin_y_val: u64,
        coin_y_val_min: u64,
    ) {
        let acc_addr = signer::address_of(account);
        router::register_pool<X, Y>(account, curve_type);

        add_liquidity<X, Y>(
            account,
            acc_addr,
            coin_x_val,
            coin_x_val_min,
            coin_y_val,
            coin_y_val_min,
        );
    }

    /// Add new liquidity into pool `X`/`Y` and get liquidity coin `LP`.
    /// * `pool_addr` - address of account registered pool.
    /// * `coin_x_val` - amount of coin `X` to add as liquidity.
    /// * `coin_x_val_min` - minimum amount of coin `X` to add as liquidity (slippage).
    /// * `coin_y_val` - minimum amount of coin `Y` to add as liquidity.
    /// * `coin_y_val_min` - minimum amount of coin `Y` to add as liquidity (slippage).
    public entry fun add_liquidity<X, Y>(
        account: &signer,
        pool_addr: address,
        coin_x_val: u64,
        coin_x_val_min: u64,
        coin_y_val: u64,
        coin_y_val_min: u64,
    ) {
        let coin_x = coin::withdraw<X>(account, coin_x_val);
        let coin_y = coin::withdraw<Y>(account, coin_y_val);

        let (coin_x_remainder, coin_y_remainder, lp_coins) =
            router::add_liquidity<X, Y>(
                pool_addr,
                coin_x,
                coin_x_val_min,
                coin_y,
                coin_y_val_min,
            );

        let account_addr = signer::address_of(account);

        if (!coin::is_account_registered<LP<X, Y>>(account_addr)) {
            coin::register<LP<X, Y>>(account);
        };

        coin::deposit(account_addr, coin_x_remainder);
        coin::deposit(account_addr, coin_y_remainder);
        coin::deposit(account_addr, lp_coins);
    }

    /// Remove (burn) liquidity coins `LP` from account, get `X` and`Y` coins back.
    /// * `pool_addr` - address of account registered pool.
    /// * `lp_val` - amount of `LP` coins to burn.
    /// * `min_x_out_val` - minimum amount of X coins to get.
    /// * `min_y_out_val` - minimum amount of Y coins to get.
    public entry fun remove_liquidity<X, Y>(
        account: &signer,
        pool_addr: address,
        lp_val: u64,
        min_x_out_val: u64,
        min_y_out_val: u64,
    ) {
        let lp_coins = coin::withdraw<LP<X, Y>>(account, lp_val);

        let (coin_x, coin_y) = router::remove_liquidity<X, Y>(
            pool_addr,
            lp_coins,
            min_x_out_val,
            min_y_out_val,
        );

        let account_addr = signer::address_of(account);
        coin::deposit(account_addr, coin_x);
        coin::deposit(account_addr, coin_y);
    }

    /// Swap exact coin `X` for at least minimum coin `Y`.
    /// * `pool_addr` - address of account registered pool.
    /// * `coin_val` - amount of coins `X` to swap.
    /// * `coin_out_min_val` - minimum expected amount of coins `Y` to get.
    public entry fun swap<X, Y>(
        account: &signer,
        pool_addr: address,
        coin_val: u64,
        coin_out_min_val: u64,
    ) {
        let coin_x = coin::withdraw<X>(account, coin_val);

        let coin_y = router::swap_exact_coin_for_coin<X, Y>(
            pool_addr,
            coin_x,
            coin_out_min_val,
        );

        let account_addr = signer::address_of(account);
        coin::deposit(account_addr, coin_y);
    }

    /// Swap maximum coin `X` for exact coin `Y`.
    /// * `pool_addr` - address of account registered pool.
    /// * `coin_val_max` - how much of coins `X` can be used to get `Y` coin.
    /// * `coin_out` - how much of coins `Y` should be returned.
    public entry fun swap_into<X, Y>(
        account: &signer,
        pool_addr: address,
        coin_val_max: u64,
        coin_out: u64,
    ) {
        let coin_x = coin::withdraw<X>(account, coin_val_max);

        let (coin_x, coin_y) = router::swap_coin_for_exact_coin<X, Y>(
            pool_addr,
            coin_x,
            coin_out,
        );

        let account_addr = signer::address_of(account);
        coin::deposit(account_addr, coin_x);
        coin::deposit(account_addr, coin_y);
    }
}
