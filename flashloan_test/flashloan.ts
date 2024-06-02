/* eslint-disable no-console */

import * as dotenv from "dotenv";
dotenv.config();

import {AptosClient, AptosAccount, CoinClient, BCS, TxnBuilderTypes, Types as AptosTypes} from "aptos";
const {
  AccountAddress,
  EntryFunction,
  TransactionPayloadEntryFunction,
  RawTransaction,
  ChainId,
} = TxnBuilderTypes;

export const NODE_URL = process.env.APTOS_NODE_URL || "https://fullnode.testnet.aptoslabs.com";

const PK_LOAN = process.env.PK_LOAN as string;
const PK_LOAN_2 = process.env.PK_LOAN_2 as string;
const PK_TRADER = process.env.PK_TRADER as string;

const APTOS_COIN = '0x1::aptos_coin::AptosCoin';
const USDT_COIN = '0x43417434fd869edee76cca2a4d2301e528a1551b1d719b75c350c3c97d15b8b9::coins::USDT';

function parsePrivateKey(pk: string) {
  if (pk.startsWith('0x')) {
    pk = pk.substring(2);
  }

  return Buffer.from(pk, 'hex');
}

(async () => {
  const client = new AptosClient(NODE_URL);
  const coinClient = new CoinClient(client);

  const pk_loan = parsePrivateKey(PK_LOAN);
  const pk_loan_2 = parsePrivateKey(PK_LOAN_2);
  const pk_trader = parsePrivateKey(PK_TRADER);

  const loaner = new AptosAccount(pk_loan);
  const loaner_2 = new AptosAccount(pk_loan_2);
  const trader = new AptosAccount(pk_trader);

  console.log("=== Addresses ===");
  console.log(`Loaner: ${loaner.address()}`);
  console.log(`Loaner 2: ${loaner_2.address()}`);
  console.log(`Trader: ${trader.address()}`);
  console.log("");

  const accounts = [
      loaner,
      loaner_2,
      trader,
  ];

  const coins = [
      APTOS_COIN,
      USDT_COIN,
  ];

  for (let account of accounts) {
    console.log(`Account: ${account.address()}`);

    for (let coin of coins) {
      let name = coin.split('::').pop();
      let balance = await coinClient.checkBalance(account, {
        coinType: coin
      });
      console.log(`Balance ${name}: ${balance.toString()}`)
    }
  }

  const flashloanPayload = new TransactionPayloadEntryFunction(
    EntryFunction.natural(
      "09f85897f830d193f15d7232fa1c714daae3bf0215d7ad19d0c8afb7f35afb9e::flashloan_swap",
      "identity_swap",
      [],
      [BCS.bcsSerializeUint64(1000)],
    ),
  );

  const swapPayload = new TransactionPayloadEntryFunction(
      EntryFunction.natural(
          "09f85897f830d193f15d7232fa1c714daae3bf0215d7ad19d0c8afb7f35afb9e::flashloan_swap",
          "swap",
          [],
          [BCS.bcsSerializeUint64(100)],
      )
  );

  const chainId = new ChainId((await client.getChainId()));

  const txIds: Promise<any>[] = [];

  let loaner_sequence = (await client.getAccount(loaner.address())).sequence_number;
  let loaner_2_sequence = (await client.getAccount(loaner_2.address())).sequence_number;
  let trader_sequence =  (await client.getAccount(trader.address())).sequence_number;

  for (let i = 0; i < 25; i++) {
    const loan_raw_tx = new RawTransaction(
        AccountAddress.fromHex(loaner.address()),
        BigInt(loaner_sequence),
        flashloanPayload,
        BigInt(2000),
        BigInt(500),
        BigInt(Math.floor(Date.now() / 1000) + 10),
        chainId,
    );

    const loan_2_raw_tx = new RawTransaction(
        AccountAddress.fromHex(loaner_2.address()),
        BigInt(loaner_2_sequence),
        flashloanPayload,
        BigInt(2000),
        BigInt(500),
        BigInt(Math.floor(Date.now() / 1000) + 10),
        chainId,
    );

    const swap_raw_tx = new RawTransaction(
        AccountAddress.fromHex(trader.address()),
        BigInt(trader_sequence),
        swapPayload,
        BigInt(2000),
        BigInt(500),
        BigInt(Math.floor(Date.now() / 1000) + 10),
        chainId,
    );

    const loan_1_tx = AptosClient.generateBCSTransaction(loaner, loan_raw_tx);
    const loan_2_tx = AptosClient.generateBCSTransaction(loaner_2, loan_2_raw_tx);
    const trader_tx = AptosClient.generateBCSTransaction(trader, swap_raw_tx);

    let resp_1 = client.submitSignedBCSTransaction(loan_1_tx);
    let resp_2 = client.submitSignedBCSTransaction(loan_2_tx);
    let resp_3 = client.submitSignedBCSTransaction(trader_tx);

    txIds.push(resp_1);
    txIds.push(resp_2);
    txIds.push(resp_3);

    loaner_sequence = (parseInt(loaner_sequence) + 1).toString();
    loaner_2_sequence = (parseInt(loaner_2_sequence) + 1).toString();
    trader_sequence = (parseInt(trader_sequence) + 1).toString();
  }

  console.log('Hashes: ');
  await Promise.all(txIds).then(values => {
    for (let v of values) {
      console.log(v.hash);
      client.waitForTransactionWithResult(v.hash).then(r => {
        let tx = r as AptosTypes.UserTransaction;
        if (!tx.success) {
          console.log('Fail!');
          console.log(r);
        }
      });
    }
  });
  console.log('Done');
})();