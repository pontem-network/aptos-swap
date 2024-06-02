#!/bin/bash

source ./.env

aptos init --rest-url $APTOS_NODE_URL --faucet-url $APTOS_FAUCET_URL --private-key $PK_LOAN --assume-yes
aptos init --rest-url $APTOS_NODE_URL --faucet-url $APTOS_FAUCET_URL --private-key $PK_LOAN_2 --assume-yes
aptos init --rest-url $APTOS_NODE_URL --faucet-url $APTOS_FAUCET_URL --private-key $PK_TRADER --assume-yes