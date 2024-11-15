// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ===================== Contract Addresses =====================================
address constant AWESOMEX = 0xa99AFcC6Aa4530d01DFFF8E55ec66E4C424c048c;
address constant DRAGONX = 0x96a5399D07896f757Bd4c6eF56461F58DB951862;
address constant TITANX = 0xF19308F923582A6f7c465e5CE7a9Dc1BEC6665B1;
address constant WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

address constant AWESOMEX_TREASURY = 0xCb1C9ab495656a9224EC9D76b97412fE0AB31f8a;
address constant AWESOMEX_LAUNCHPAD = 0xb4a217e7dE12FA3B0e859Ec3F639BC2b64D57874;

// ===================== POOLS ==================================================
address constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
address constant DRAGONX_AWX_POOL = 0xf643D9b4826F616240b302A4Cb3c073a7F30441b;
uint24 constant POOL_FEE_1PERCENT = 10000;

// ===================== VARIABLES ===================================================
uint256 constant AWESOME_PRICE = 88_800_000 ether;
uint256 constant GOLD_PRICE = 888_000_000 ether;
uint256 constant ELITE_PRICE = 8_880_000_000 ether;

uint8 constant MIN_TIER = 1;
uint8 constant MAX_TIER = 24;
uint8 constant TREASURY_FEE = 3;
uint8 constant LAUNCHPAD_FEE = 5;
uint8 constant LAUNCHPAD_FEE_ON_CLAIM = 3;
uint8 constant PERCENTAGE_BASE = 100;
