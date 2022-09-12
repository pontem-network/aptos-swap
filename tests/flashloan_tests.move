#[test_only]
module liquidswap::flashloan_tests {
    use std::signer;

    use aptos_framework::coin;

    use liquidswap::emergency;
    use liquidswap::liquidity_pool;
    use liquidswap::router;
    use test_coin_admin::test_coins::{Self, USDT, BTC, USDC};
    use test_pool_owner::test_lp::{Self, LP};

    fun register_pool_with_liquidity(x_val: u64, y_val: u64): (signer, signer) {
        let (coin_admin, pool_owner) = test_lp::setup_coins_and_pool_owner();

        router::register_pool<BTC, USDT, LP>(&pool_owner, 2);

        let pool_owner_addr = signer::address_of(&pool_owner);
        if (x_val != 0 && y_val != 0) {
            let btc_coins = test_coins::mint<BTC>(&coin_admin, x_val);
            let usdt_coins = test_coins::mint<USDT>(&coin_admin, y_val);
            let lp_coins =
                liquidity_pool::mint<BTC, USDT, LP>(pool_owner_addr, btc_coins, usdt_coins);
            coin::register<LP>(&pool_owner);
            coin::deposit<LP>(pool_owner_addr, lp_coins);
        };

        (coin_admin, pool_owner)
    }

    fun register_stable_pool_with_liquidity(x_val: u64, y_val: u64): (signer, signer) {
        let (coin_admin, pool_owner) = test_lp::setup_coins_and_pool_owner();

        router::register_pool<USDC, USDT, LP>(&pool_owner, 1);

        let pool_owner_addr = signer::address_of(&pool_owner);
        if (x_val != 0 && y_val != 0) {
            let usdc_coins = test_coins::mint<USDC>(&coin_admin, x_val);
            let usdt_coins = test_coins::mint<USDT>(&coin_admin, y_val);
            let lp_coins =
                liquidity_pool::mint<USDC, USDT, LP>(pool_owner_addr, usdc_coins, usdt_coins);
            coin::register<LP>(&pool_owner);
            coin::deposit<LP>(pool_owner_addr, lp_coins);
        };

        (coin_admin, pool_owner)
    }

    #[test]
    fun test_flashloan_coins_with_normal_reserves_and_amount() {
        let (coin_admin, pool_owner) = register_pool_with_liquidity(100000000, 28000000000);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<BTC, USDT, LP>(pool_owner_addr, 0, 276404249);
        assert!(coin::value(&usdt_coins) == 276404249, 1);

        let btc_coins_to_exchange = test_coins::mint<BTC>(&coin_admin, 1000000);
        liquidity_pool::pay_flashloan(btc_coins_to_exchange, coin::zero<USDT>(), loan);

        coin::destroy_zero(zero);
        test_coins::burn(&coin_admin, usdt_coins);

        let (x_res, y_res) = liquidity_pool::get_reserves_size<BTC, USDT, LP>(pool_owner_addr);
        assert!(x_res == 100999000, 2);
        assert!(y_res == 27723595751, 3);
    }

    #[test]
    fun test_flashloan_coins_with_normal_reserves_and_min_amount() {
        let (coin_admin, pool_owner) = register_pool_with_liquidity(100999000, 27723595751);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<BTC, USDT, LP>(pool_owner_addr, 0, 270);
        assert!(coin::value(&usdt_coins) == 270, 1);

        let btc_coins_to_exchange = test_coins::mint<BTC>(&coin_admin, 1);
        liquidity_pool::pay_flashloan(btc_coins_to_exchange, coin::zero<USDT>(), loan);

        coin::destroy_zero(zero);
        test_coins::burn(&coin_admin, usdt_coins);

        let (x_res, y_res) = liquidity_pool::get_reserves_size<BTC, USDT, LP>(pool_owner_addr);
        assert!(x_res == 100999001, 2);
        assert!(y_res == 27723595481, 3);
    }

    #[test]
    fun test_flashloan_coins_with_normal_reserves_and_max_amount() {
        let (coin_admin, pool_owner) = register_pool_with_liquidity(100999001, 27723595481);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (btc_coins, usdt_coins, loan) =
            liquidity_pool::flashloan<BTC, USDT, LP>(pool_owner_addr, 100999001, 27723595481);
        assert!(coin::value(&btc_coins) == 100999001, 1);
        assert!(coin::value(&usdt_coins) == 27723595481, 2);

        let btc_coins_to_add = test_coins::mint<BTC>(&coin_admin, 303909);
        let usdt_coins_to_add = test_coins::mint<USDT>(&coin_admin, 83421050);
        coin::merge(&mut btc_coins, btc_coins_to_add);
        coin::merge(&mut usdt_coins, usdt_coins_to_add);
        liquidity_pool::pay_flashloan(btc_coins, usdt_coins, loan);

        let (x_res, y_res) = liquidity_pool::get_reserves_size<BTC, USDT, LP>(pool_owner_addr);
        assert!(x_res == 101201608, 3);
        assert!(y_res == 27779209515, 4);
    }

    #[test]
    fun test_flashloan_coins_with_min_reserves_and_normal_amount() {
        let (coin_admin, pool_owner) = register_pool_with_liquidity(1001, 1001);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<BTC, USDT, LP>(pool_owner_addr, 0, 90);
        assert!(coin::value(&usdt_coins) == 90, 1);

        let btc_coins_to_exchange = test_coins::mint<BTC>(&coin_admin, 100);
        liquidity_pool::pay_flashloan(btc_coins_to_exchange, coin::zero<USDT>(), loan);

        coin::destroy_zero(zero);
        test_coins::burn(&coin_admin, usdt_coins);

        let (x_res, y_res) = liquidity_pool::get_reserves_size<BTC, USDT, LP>(pool_owner_addr);
        assert!(x_res == 1101, 2);
        assert!(y_res == 911, 3);
    }

    #[test]
    fun test_flashloan_coins_with_min_reserves_and_min_amount() {
        let (coin_admin, pool_owner) = register_pool_with_liquidity(1101, 911);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<BTC, USDT, LP>(pool_owner_addr, 0, 1);
        assert!(coin::value(&usdt_coins) == 1, 1);

        let btc_coins_to_exchange = test_coins::mint<BTC>(&coin_admin, 2);
        liquidity_pool::pay_flashloan(btc_coins_to_exchange, coin::zero<USDT>(), loan);

        coin::destroy_zero(zero);
        test_coins::burn(&coin_admin, usdt_coins);

        let (x_res, y_res) = liquidity_pool::get_reserves_size<BTC, USDT, LP>(pool_owner_addr);
        assert!(x_res == 1103, 2);
        assert!(y_res == 910, 3);
    }

    #[test]
    fun test_flashloan_coins_with_min_reserves_and_max_amount() {
        let (coin_admin, pool_owner) = register_pool_with_liquidity(1103, 910);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (btc_coins, usdt_coins, loan) =
            liquidity_pool::flashloan<BTC, USDT, LP>(pool_owner_addr, 1103, 910);
        assert!(coin::value(&btc_coins) == 1103, 1);
        assert!(coin::value(&usdt_coins) == 910, 2);

        let btc_coins_to_add = test_coins::mint<BTC>(&coin_admin, 4);
        let usdt_coins_to_add = test_coins::mint<USDT>(&coin_admin, 3);
        coin::merge(&mut btc_coins, btc_coins_to_add);
        coin::merge(&mut usdt_coins, usdt_coins_to_add);
        liquidity_pool::pay_flashloan(btc_coins, usdt_coins, loan);

        let (x_res, y_res) = liquidity_pool::get_reserves_size<BTC, USDT, LP>(pool_owner_addr);
        assert!(x_res == 1106, 3);
        assert!(y_res == 913, 4);
    }

    #[test]
    fun test_flashloan_coins_with_max_reserves_and_normal_amount() {
        let (coin_admin, pool_owner) = register_pool_with_liquidity(18446744063709551615, 18446744073709551615);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let btc_coins_to_exchange = test_coins::mint<BTC>(&coin_admin, 10000000000);
        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<BTC, USDT, LP>(pool_owner_addr, 0, 9970000000);
        assert!(coin::value(&usdt_coins) == 9970000000, 1);

        liquidity_pool::pay_flashloan(btc_coins_to_exchange, coin::zero<USDT>(), loan);

        coin::destroy_zero(zero);
        test_coins::burn(&coin_admin, usdt_coins);

        let (x_res, y_res) = liquidity_pool::get_reserves_size<BTC, USDT, LP>(pool_owner_addr);
        assert!(x_res == 18446744073699551615, 2);
        assert!(y_res == 18446744063739551615, 3);
    }

    #[test]
    fun test_flashloan_coins_with_max_reserves_and_min_amount() {
        let (coin_admin, pool_owner) = register_pool_with_liquidity(18446744073699551615, 18446744063739551615);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<BTC, USDT, LP>(pool_owner_addr, 0, 1);
        assert!(coin::value(&usdt_coins) == 1, 1);

        let btc_coins_to_exchange = test_coins::mint<BTC>(&coin_admin, 2);
        liquidity_pool::pay_flashloan(btc_coins_to_exchange, coin::zero<USDT>(), loan);

        coin::destroy_zero(zero);
        test_coins::burn(&coin_admin, usdt_coins);

        let (x_res, y_res) = liquidity_pool::get_reserves_size<BTC, USDT, LP>(pool_owner_addr);
        assert!(x_res == 18446744073699551617, 2);
        assert!(y_res == 18446744063739551614, 3);
    }

    #[test]
    fun test_flashloan_coins_from_stable_pool_with_normal_reserves_and_amount() {
        let (coin_admin, pool_owner) = register_stable_pool_with_liquidity(15000000000, 1500000000000);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<USDC, USDT, LP>(pool_owner_addr, 0, 99699999);
        assert!(coin::value(&usdt_coins) == 99699999, 1);

        let usdc_coins_to_exchange = test_coins::mint<USDC>(&coin_admin, 1000000);
        liquidity_pool::pay_flashloan(usdc_coins_to_exchange, coin::zero<USDT>(), loan);

        coin::destroy_zero(zero);
        test_coins::burn(&coin_admin, usdt_coins);

        let (x_res, y_res) = liquidity_pool::get_reserves_size<USDC, USDT, LP>(pool_owner_addr);
        assert!(x_res == 15000999000, 2);
        assert!(y_res == 1499900300001, 3);
    }

    #[test]
    fun test_flashloan_coins_from_stable_pool_with_normal_reserves_and_min_amount() {
        let (coin_admin, pool_owner) = register_stable_pool_with_liquidity(15000999000, 1499900300001);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<USDC, USDT, LP>(pool_owner_addr, 0, 99);
        assert!(coin::value(&usdt_coins) == 99, 1);

        let usdc_coins_to_exchange = test_coins::mint<USDC>(&coin_admin, 1);
        liquidity_pool::pay_flashloan(usdc_coins_to_exchange, coin::zero<USDT>(), loan);

        coin::destroy_zero(zero);
        test_coins::burn(&coin_admin, usdt_coins);

        let (x_res, y_res) = liquidity_pool::get_reserves_size<USDC, USDT, LP>(pool_owner_addr);
        assert!(x_res == 15000999001, 2);
        assert!(y_res == 1499900299902, 3);
    }

    #[test]
    fun test_flashloan_coins_from_stable_pool_with_min_reserves_and_normal_amount() {
        let (coin_admin, pool_owner) = register_stable_pool_with_liquidity(1001, 1001);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<USDC, USDT, LP>(pool_owner_addr, 0, 90);
        assert!(coin::value(&usdt_coins) == 90, 1);

        let usdc_coins_to_exchange = test_coins::mint<USDC>(&coin_admin, 33);
        liquidity_pool::pay_flashloan(usdc_coins_to_exchange, coin::zero<USDT>(), loan);

        coin::destroy_zero(zero);
        test_coins::burn(&coin_admin, usdt_coins);

        let (x_res, y_res) = liquidity_pool::get_reserves_size<USDC, USDT, LP>(pool_owner_addr);
        assert!(x_res == 1034, 2);
        assert!(y_res == 911, 3);
    }

    #[test]
    fun test_flashloan_coins_from_stable_pool_with_min_reserves_and_min_amount() {
        let (coin_admin, pool_owner) = register_stable_pool_with_liquidity(1001, 1001);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<USDC, USDT, LP>(pool_owner_addr, 0, 1);
        assert!(coin::value(&usdt_coins) == 1, 1);

        let usdc_coins_to_exchange = test_coins::mint<USDC>(&coin_admin, 2);
        liquidity_pool::pay_flashloan(usdc_coins_to_exchange, coin::zero<USDT>(), loan);

        coin::destroy_zero(zero);
        test_coins::burn(&coin_admin, usdt_coins);

        let (x_res, y_res) = liquidity_pool::get_reserves_size<USDC, USDT, LP>(pool_owner_addr);
        assert!(x_res == 1003, 2);
        assert!(y_res == 1000, 3);
    }

    #[test]
    fun test_flashloan_coins_from_stable_pool_with_min_reserves_and_max_amount() {
        let (coin_admin, pool_owner) = register_stable_pool_with_liquidity(1001, 1001);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (usdc_coins, usdt_coins, loan) =
            liquidity_pool::flashloan<USDC, USDT, LP>(pool_owner_addr, 1001, 1001);
        assert!(coin::value(&usdc_coins) == 1001, 1);
        assert!(coin::value(&usdt_coins) == 1001, 2);

        let usdc_coins_to_add = test_coins::mint<USDC>(&coin_admin, 4);
        let usdt_coins_to_add = test_coins::mint<USDT>(&coin_admin, 3);
        coin::merge(&mut usdc_coins, usdc_coins_to_add);
        coin::merge(&mut usdt_coins, usdt_coins_to_add);
        liquidity_pool::pay_flashloan(usdc_coins, usdt_coins, loan);

        let (x_res, y_res) = liquidity_pool::get_reserves_size<USDC, USDT, LP>(pool_owner_addr);
        assert!(x_res == 1004, 3);
        assert!(y_res == 1003, 4);
    }

    #[test]
    fun test_flashloan_coins_from_stable_pool_with_big_reserves_and_normal_amount() {
        let (coin_admin, pool_owner) = register_stable_pool_with_liquidity(2930000000000, 293000000000000);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<USDC, USDT, LP>(pool_owner_addr, 0, 996999980359);
        assert!(coin::value(&usdt_coins) == 996999980359, 1);

        let usdc_coins_to_exchange = test_coins::mint<USDC>(&coin_admin, 10000000000);
        liquidity_pool::pay_flashloan(usdc_coins_to_exchange, coin::zero<USDT>(), loan);

        coin::destroy_zero(zero);
        test_coins::burn(&coin_admin, usdt_coins);

        let (x_res, y_res) = liquidity_pool::get_reserves_size<USDC, USDT, LP>(pool_owner_addr);
        assert!(x_res == 2939990000000, 2);
        assert!(y_res == 292003000019641, 3);
    }

    #[test]
    fun test_flashloan_coins_from_stable_pool_with_big_reserves_and_min_amount() {
        let (coin_admin, pool_owner) = register_stable_pool_with_liquidity(2930000000000, 293000000000000);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<USDC, USDT, LP>(pool_owner_addr, 0, 99);
        assert!(coin::value(&usdt_coins) == 99, 1);

        let usdc_coins_to_exchange = test_coins::mint<USDC>(&coin_admin, 1);
        liquidity_pool::pay_flashloan(usdc_coins_to_exchange, coin::zero<USDT>(), loan);

        coin::destroy_zero(zero);
        test_coins::burn(&coin_admin, usdt_coins);

        let (x_res, y_res) = liquidity_pool::get_reserves_size<USDC, USDT, LP>(pool_owner_addr);
        assert!(x_res == 2930000000001, 2);
        assert!(y_res == 292999999999901, 3);
    }

    #[test(emergency_acc = @emergency_admin)]
    #[expected_failure(abort_code = 4001)]
    fun test_fail_if_emergency(emergency_acc: signer) {
        let (_, pool_owner) = register_pool_with_liquidity(100000000, 28000000000);

        let pool_owner_addr = signer::address_of(&pool_owner);

        emergency::pause(&emergency_acc);

        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<BTC, USDT, LP>(pool_owner_addr, 0, 276404249);

        liquidity_pool::pay_flashloan(coin::zero<BTC>(), usdt_coins, loan);

        coin::destroy_zero(zero);
    }

    #[test]
    #[expected_failure(abort_code = 108)]
    fun test_fail_if_flashloan_zero_amount() {
        let (_, pool_owner) = register_pool_with_liquidity(100000000, 28000000000);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<BTC, USDT, LP>(pool_owner_addr, 0, 0);

        liquidity_pool::pay_flashloan(coin::zero<BTC>(), usdt_coins, loan);

        coin::destroy_zero(zero);
    }

    #[test]
    #[expected_failure(abort_code = 105)]
    fun test_fail_if_pay_less_flashloaned_coins() {
        let (coin_admin, pool_owner) = register_pool_with_liquidity(100000000, 28000000000);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<BTC, USDT, LP>(pool_owner_addr, 0, 276404249);

        let btc_coins_to_exchange = test_coins::mint<BTC>(&coin_admin, 999999);
        liquidity_pool::pay_flashloan(btc_coins_to_exchange, coin::zero<USDT>(), loan);

        coin::destroy_zero(zero);
        test_coins::burn(&coin_admin, usdt_coins);
    }

    #[test]
    #[expected_failure(abort_code = 105)]
    fun test_fail_if_pay_equal_flashloaned_coins() {
        let (_, pool_owner) = register_pool_with_liquidity(100000000, 28000000000);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<BTC, USDT, LP>(pool_owner_addr, 0, 280000000);

        liquidity_pool::pay_flashloan(coin::zero<BTC>(), usdt_coins, loan);

        coin::destroy_zero(zero);
    }

    #[test]
    #[expected_failure(abort_code = 65542)]
    fun test_fail_if_flashloan_more_than_reserved() {
        let (_, pool_owner) = register_pool_with_liquidity(100000000, 28000000000);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<BTC, USDT, LP>(pool_owner_addr, 0, 28000000001);

        liquidity_pool::pay_flashloan(coin::zero<BTC>(), usdt_coins, loan);

        coin::destroy_zero(zero);
    }

    #[test]
    #[expected_failure(abort_code = 109)]
    fun test_fail_if_mint_when_pool_is_locked() {
        let (coin_admin, pool_owner) = register_pool_with_liquidity(100000000, 28000000000);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<BTC, USDT, LP>(pool_owner_addr, 0, 280000000);
        assert!(coin::value(&usdt_coins) == 280000000, 1);

        // mint when pool is locked
        let btc_coins_mint = test_coins::mint<BTC>(&coin_admin, 1000000);
        let usdt_coins_mint = test_coins::mint<USDT>(&coin_admin, 280000000);
        let lp_coins_mint =
            liquidity_pool::mint<BTC, USDT, LP>(pool_owner_addr, btc_coins_mint, usdt_coins_mint);
        coin::deposit(pool_owner_addr, lp_coins_mint);

        let btc_coins_to_exchange = test_coins::mint<BTC>(&coin_admin, 2);
        liquidity_pool::pay_flashloan(btc_coins_to_exchange, coin::zero<USDT>(), loan);

        coin::destroy_zero(zero);
        test_coins::burn(&coin_admin, usdt_coins);
    }

    #[test]
    #[expected_failure(abort_code = 109)]
    fun test_fail_if_swap_when_pool_is_locked() {
        let (coin_admin, pool_owner) = register_pool_with_liquidity(100000000, 28000000000);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<BTC, USDT, LP>(pool_owner_addr, 0, 276404249);
        assert!(coin::value(&usdt_coins) == 276404249, 1);

        // swap when pool is locked
        let btc_coins_to_exchange = test_coins::mint<BTC>(&coin_admin, 1000000);
        let (zero_swap, usdt_coins_swap) =
            liquidity_pool::swap<BTC, USDT, LP>(
                pool_owner_addr,
                btc_coins_to_exchange, 0,
                coin::zero<USDT>(), 276404249
            );
        coin::destroy_zero(zero_swap);
        test_coins::burn(&coin_admin, usdt_coins_swap);

        let btc_coins_to_exchange = test_coins::mint<BTC>(&coin_admin, 1000000);
        liquidity_pool::pay_flashloan(btc_coins_to_exchange, coin::zero<USDT>(), loan);

        coin::destroy_zero(zero);
        test_coins::burn(&coin_admin, usdt_coins);
    }

    #[test]
    #[expected_failure(abort_code = 109)]
    fun test_fail_if_burn_when_pool_is_locked() {
        let (coin_admin, pool_owner) = register_pool_with_liquidity(100000000, 28000000000);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<BTC, USDT, LP>(pool_owner_addr, 0, 276404249);
        assert!(coin::value(&usdt_coins) == 276404249, 1);

        // burn when pool is locked
        let lp_coins = coin::withdraw<LP>(&pool_owner, 16733190);
        let (btc_return, usdt_return) =
            liquidity_pool::burn<BTC, USDT, LP>(pool_owner_addr, lp_coins);
        test_coins::burn(&coin_admin, btc_return);
        test_coins::burn(&coin_admin, usdt_return);

        let btc_coins_to_exchange = test_coins::mint<BTC>(&coin_admin, 1000000);
        liquidity_pool::pay_flashloan(btc_coins_to_exchange, coin::zero<USDT>(), loan);

        coin::destroy_zero(zero);
        test_coins::burn(&coin_admin, usdt_coins);
    }

    #[test]
    #[expected_failure(abort_code = 109)]
    fun test_fail_if_flashloan_when_pool_is_locked() {
        let (coin_admin, pool_owner) = register_pool_with_liquidity(100000000, 28000000000);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<BTC, USDT, LP>(pool_owner_addr, 0, 276404249);
        assert!(coin::value(&usdt_coins) == 276404249, 1);

        // flashloan when pool is locked
        let (zero_test, usdt_coins_test, loan_test) =
            liquidity_pool::flashloan<BTC, USDT, LP>(pool_owner_addr, 0, 276404249);
        let btc_coins_to_exchange_test = test_coins::mint<BTC>(&coin_admin, 1000000);
        liquidity_pool::pay_flashloan(btc_coins_to_exchange_test, coin::zero<USDT>(), loan_test);
        coin::destroy_zero(zero_test);
        test_coins::burn(&coin_admin, usdt_coins_test);

        let btc_coins_to_exchange = test_coins::mint<BTC>(&coin_admin, 1000000);
        liquidity_pool::pay_flashloan(btc_coins_to_exchange, coin::zero<USDT>(), loan);

        coin::destroy_zero(zero);
        test_coins::burn(&coin_admin, usdt_coins);
    }

    #[test]
    #[expected_failure(abort_code = 109)]
    fun test_fail_if_get_reserves_when_pool_is_locked() {
        let (coin_admin, pool_owner) = register_pool_with_liquidity(100000000, 28000000000);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<BTC, USDT, LP>(pool_owner_addr, 0, 276404249);
        assert!(coin::value(&usdt_coins) == 276404249, 1);

        // get reserves when pool is locked
        let (_, _) = liquidity_pool::get_reserves_size<BTC, USDT, LP>(pool_owner_addr);

        let btc_coins_to_exchange = test_coins::mint<BTC>(&coin_admin, 1000000);
        liquidity_pool::pay_flashloan(btc_coins_to_exchange, coin::zero<USDT>(), loan);

        coin::destroy_zero(zero);
        test_coins::burn(&coin_admin, usdt_coins);
    }

    #[test]
    #[expected_failure(abort_code = 109)]
    fun test_fail_if_get_cumulative_prices_when_pool_is_locked() {
        let (coin_admin, pool_owner) = register_pool_with_liquidity(100000000, 28000000000);

        let pool_owner_addr = signer::address_of(&pool_owner);

        let (zero, usdt_coins, loan) =
            liquidity_pool::flashloan<BTC, USDT, LP>(pool_owner_addr, 0, 276404249);
        assert!(coin::value(&usdt_coins) == 276404249, 1);

        // get cumulative prices when pool is locked
        let (_, _, _) = liquidity_pool::get_cumulative_prices<BTC, USDT, LP>(pool_owner_addr);

        let btc_coins_to_exchange = test_coins::mint<BTC>(&coin_admin, 1000000);
        liquidity_pool::pay_flashloan(btc_coins_to_exchange, coin::zero<USDT>(), loan);

        coin::destroy_zero(zero);
        test_coins::burn(&coin_admin, usdt_coins);
    }
}
