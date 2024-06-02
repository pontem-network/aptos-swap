#!/bin/bash

set -e
set -x

source ./flashloan_test/.env

aptos init \
    --rest-url $APTOS_NODE_URL \
    --faucet-url $APTOS_FAUCET_URL \
    --private-key $LIQUIDSWAP_PK

aptos account fund-with-faucet --account 43417434fd869edee76cca2a4d2301e528a1551b1d719b75c350c3c97d15b8b9 --amount 1000000000000000

mkdir local/
cd local/

git clone git@github.com:pontem-network/uq64x64.git
cd uq64x64/
aptos move publish
cd -

git clone git@github.com:pontem-network/U256.git
cd U256/
aptos move publish
cd -

git clone git@github.com:pontem-network/test-coins.git
cd test-coins/
git checkout no-extended
aptos move publish
cd -

# back to root
cd ../

cd liquidswap_init/
aptos move publish
cd -

cd liquidswap_lp/
aptos move compile --save-metadata
LP_COIN_METADATA_BCS_HEX=$(cat ./build/LiquidswapLP/package-metadata.bcs | hexdump -ve '/1 "%02x"')
LP_COIN_BYTECODE_HEX=$(cat ./build/LiquidswapLP/bytecode_modules/lp_coin.mv | hexdump -ve '/1 "%02x"')
aptos move run \
    --function-id 0x43417434fd869edee76cca2a4d2301e528a1551b1d719b75c350c3c97d15b8b9::lp_account::initialize_lp_account \
    --args hex:$LP_COIN_METADATA_BCS_HEX \
    --args hex:$LP_COIN_BYTECODE_HEX
cd -

# initialize pools
aptos move publish
aptos move run \
    --function-id 0x43417434fd869edee76cca2a4d2301e528a1551b1d719b75c350c3c97d15b8b9::liquidity_pool::initialize

# deploy BTC, USDT coins
cd ../test-coins
aptos move publish
aptos move run \
    --function-id 0x43417434fd869edee76cca2a4d2301e528a1551b1d719b75c350c3c97d15b8b9::coins::register_coins
aptos move run \
    --function-id 0x1::managed_coin::register \
    --type-args 0x43417434fd869edee76cca2a4d2301e528a1551b1d719b75c350c3c97d15b8b9::coins::USDT
aptos move run \
    --function-id 0x1::managed_coin::register \
    --type-args 0x43417434fd869edee76cca2a4d2301e528a1551b1d719b75c350c3c97d15b8b9::coins::BTC
cd -

# mint coins
aptos move run \
    --function-id 0x43417434fd869edee76cca2a4d2301e528a1551b1d719b75c350c3c97d15b8b9::coins::mint_coin \
    --type-args 0x43417434fd869edee76cca2a4d2301e528a1551b1d719b75c350c3c97d15b8b9::coins::USDT \
    --args address:43417434fd869edee76cca2a4d2301e528a1551b1d719b75c350c3c97d15b8b9 \
    --args u64:10000000000000
aptos move run \
    --function-id 0x43417434fd869edee76cca2a4d2301e528a1551b1d719b75c350c3c97d15b8b9::coins::mint_coin \
    --type-args 0x43417434fd869edee76cca2a4d2301e528a1551b1d719b75c350c3c97d15b8b9::coins::BTC \
    --args address:43417434fd869edee76cca2a4d2301e528a1551b1d719b75c350c3c97d15b8b9 \
    --args u64:40000000000

# register pool and add liquidity
aptos move run \
    --function-id 0x43417434fd869edee76cca2a4d2301e528a1551b1d719b75c350c3c97d15b8b9::scripts::register_pool_and_add_liquidity \
    --type-args 0x43417434fd869edee76cca2a4d2301e528a1551b1d719b75c350c3c97d15b8b9::coins::BTC \
    --type-args 0x43417434fd869edee76cca2a4d2301e528a1551b1d719b75c350c3c97d15b8b9::coins::USDT \
    --type-args 0x43417434fd869edee76cca2a4d2301e528a1551b1d719b75c350c3c97d15b8b9::curves::Uncorrelated \
    --args u64:400000000 \
    --args u64:400000000 \
    --args u64:100000000000 \
    --args u64:100000000000
