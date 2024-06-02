# Flashloan DOS test

It's flashloan DOS test on the clone of Liquidswap on testnet.

The clone deployed on the address - `09f85897f830d193f15d7232fa1c714daae3bf0215d7ad19d0c8afb7f35afb9e`.

Sends transactions containing flashloans and swaps on the following [pool](https://fullnode.testnet.aptoslabs.com/v1/accounts/0x9546084083bc0d6c33e5c14ee40050ed3653ba3c9bfdc2133aa9570025a047e6/resource/0x9f85897f830d193f15d7232fa1c714daae3bf0215d7ad19d0c8afb7f35afb9e::liquidity_pool::LiquidityPool%3C0x43417434fd869edee76cca2a4d2301e528a1551b1d719b75c350c3c97d15b8b9::coins::BTC,%200x43417434fd869edee76cca2a4d2301e528a1551b1d719b75c350c3c97d15b8b9::coins::USDT,%200x9f85897f830d193f15d7232fa1c714daae3bf0215d7ad19d0c8afb7f35afb9e::curves::Uncorrelated%3E).

The test written in Typescript sends 25 flashloans and swaps from different accounts to one pool.

## Run

    PK_LOAN=key-1 PK_LOAN_2=key-2 PK_TRADER=key-3 npm run flashloan
