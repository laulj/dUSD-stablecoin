# DUSD Stablecoin

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-^0.8.19-blue)](https://soliditylang.org/)

> [!CAUTION]
> The contracts have not been audited. Use at your own risk.

## Overview

**DUSD** is an overcollateralized, decentralized stablecoin pegged to the US Dollar. It is inspired by MakerDAO's DAI but simplified to use only **WETH** and **WBTC** as collateral. The system maintains a 1:1 USD peg through algorithmic stability mechanisms and always requires positions to be overcollateralized (minimum 200% collateralization ratio).

This repository contains two core contracts:

- `DUSDEngine` – Manages collateral deposits, DUSD minting/burning, and liquidations.
- `DUSD` – The ERC20 stablecoin token, minted and burned exclusively by the engine.

## Features

- **Multi-collateral support**: WETH and WBTC (extensible to more assets with price feeds).
- **Overcollateralization**: Users must maintain a collateral ratio above 200% to mint DUSD.
- **Liquidation mechanism**: Underwater positions can be liquidated with a 10% bonus for liquidators.
- **Two liquidation modes**:
    - **Proportional liquidation**: Seizes a proportional share of all collateral types.
    - **Single-asset liquidation**: Allows liquidators to specify which collateral to seize.
- **Chainlink price oracles**: Real-time price feeds with stale-data protection.
- **Reentrancy protection**: Guards on all state-changing functions.
- **Modular design**: Easy to add new collateral tokens.

## How It Works

### 1. Depositing Collateral

Users deposit WETH or WBTC into the `DUSDEngine`. Each user's collateral is tracked per token.

### 2. Minting DUSD

Users can mint DUSD against their deposited collateral, up to a maximum of 50% of the collateral's USD value (200% overcollateralization). The health factor is calculated as:

`healthFactor = (totalCollateralValue * PRECISION) / (totalDUSDMinted * OVERCOLLATERAL_RATIO)`,

where PRECISION = 1e18, OVERCOLLATERAL_RATIO = 2.

A health factor below `1e18` (i.e., < 1) indicates the position is undercollateralized and subject to liquidation.

### 3. Redeeming Collateral

Users can redeem their collateral by burning an equivalent amount of DUSD. The transaction will revert if it would bring the health factor below 1.

### 4. Liquidations

When a user's health factor falls below 1, anyone can liquidate them. Liquidators receive a 10% bonus on the seized collateral.

**Proportional liquidation (`liquidate`)**:

- Liquidator specifies the amount of DUSD debt to cover.
- The function automatically seizes a proportional share of **all** collateral types, preserving the user's original collateral composition.
- This ensures fair distribution and minimizes protocol risk.

**Single-asset liquidation (`liquidateByAsset`)**:

- Liquidator chooses which collateral asset to seize.
- The function calculates the required collateral (debt + 10% bonus) and transfers it from the user.
- This mode is more gas-efficient for liquidators targeting a specific asset.

Both functions require that the liquidation improves the user's health factor; otherwise, the transaction reverts. This prevents harmful partial liquidations when the debt to collateral ratio is below `1 + bonus` (e.g., < 110% or < 0.55 health factor).

## Contract Architecture

### DUSDEngine

- **State**:
    - `s_collateralTokenAddr` – list of supported collateral tokens.
    - `s_priceFeeds` – mapping from token to Chainlink price feed.
    - `s_userDepositedCollateral` – user balances per collateral token.
    - `s_DUSDMinted` – total DUSD minted by each user.
    - `i_dUSD` – the DUSD token contract.

- **Key Functions**:
    - `depositCollateral` – transfer collateral into the engine.
    - `mintDUSD` – mint DUSD against deposited collateral.
    - `redeemCollateral` – burn DUSD to withdraw collateral.
    - `liquidate` / `liquidateByAsset` – liquidate an undercollateralized position.
    - `getAccountTotalCollateralValue` – total USD value of a user's collateral (18 decimals).
    - `getTokenAmountFromUSD` – convert USD (18 decimals) to token amount.

### DUSD

- Standard ERC20 with burnable and ownable extensions.
- Mint and burn functions are restricted to the owner (the `DUSDEngine` after deployment).
- Custom errors for invalid amounts and zero addresses.

## Liquidation Details

### Health Factor Improvement Check

To prevent making a bad position worse, both liquidation functions enforce:

```solidity
if (endingHealthFactor <= startingHealthFactor) revert DUSDEngine__HealthFactorNotImproved();
```

This means that if the user's collateral ratio is below `1 + LIQUIDATION_BONUS / 100` (e.g., 110%), any partial liquidation would actually lower the ratio further, and the transaction reverts. Full liquidations (covering all debt) are still allowed because they eliminate the debt entirely.

### Maximum Debt to Cover

Helper functions are provided for liquidators to determine the safe debt amount:

getMaxDebtToCover(address user) – returns the maximum debt that can be covered in a proportional liquidation.

getMaxDebtToCoverForSpecificCollateral(address user, address collateralAddr) – returns the maximum debt that can be covered using only the specified collateral.

These ensure that debtToCover does not exceed the available collateral value, but **DO NOT** perform health factor improvement check.

### Price Oracles

The system uses Chainlink price feeds for accurate USD prices. Each collateral token must have a corresponding AggregatorV3Interface.

Prices are always normalized to 18 decimals (wei) internally.

Stale data protection: the custom OracleLib library reverts if the last update is older than 3 hours (configurable).

## Security Considerations

Reentrancy: All state-changing functions use OpenZeppelin's ReentrancyGuard.

Oracle staleness: Ensures prices are fresh; otherwise, transactions revert.

Health factor checks: Minting, redeeming, and liquidations all enforce minimum health.

Ownership: DUSD ownership **MUST** be transferred to the engine after deployment to allow minting/burning.

### Usage Examples

Deposit Collateral and Mint DUSD

```solidity
// Assume user has approved engine to spend WETH
engine.depositCollateralAndMintDUSD(WETH_ADDRESS, 1 ether, 500 ether);
```

### Liquidate a Position (Proportional)

```solidity
uint256 debtToCover = engine.getMaxDebtToCover(underwaterUser);
engine.liquidate(underwaterUser, debtToCover);
```

### Liquidate Using a Specific Asset

```solidity
uint256 debt = engine.getMaxDebtToCoverForSpecificCollateral(underwaterUser, WBTC_ADDRESS);
engine.liquidateByAsset(WBTC_ADDRESS, underwaterUser, debt);
```

## Getting Started

### Prerequisites

Foundry

### Installation

```bash
git clone https://github.com/laulj/dusd-stablecoin.git
cd dusd-stablecoin
forge build
```

## Testing

Unit, and Fuzz (stateful and stateless) are covered.

```bash
forge test
```

and for coverage based testing:

```bash
forge coverage
forge coverage --report debug
```

For gas reports:

```bash
forge test --gas-report
```

## Deployment

> [!CAUTION]
> **DO NOT** use .env file for storing sensitive information, use cast wallet for private key with real funds!

In general, you would want to deploy the DUSD token and then the engine, transferring ownership.

### Start a local node

```
make anvil
```

### Deploy

This will default to your local node. You need to have it running in another terminal in order for it to deploy.

```
make deploy
```

### Deployment to a testnet

> [!WARNING]
> FOR DEVELOPMENT, PLEASE USE A KEY THAT DOESN'T HAVE ANY REAL FUNDS ASSOCIATED WITH IT. - You can [learn how to export it here](https://metamask.zendesk.com/hc/en-us/articles/360015289632-How-to-Export-an-Account-Private-Key).

1. Setup environment variables

You'll want to set your `SEPOLIA_RPC_URL` and `PRIVATE_KEY` as environment variables. You can add them to a `.env` file, similar to what you see in `.env.example`.

- `PRIVATE_KEY`: The private key of your account (like from [metamask](https://metamask.io/)).
- `SEPOLIA_RPC_URL`: This is url of the sepolia testnet node you're working with. You can get setup with one for free from [Alchemy](https://alchemy.com/?a=673c802981)

Optionally, add your `ETHERSCAN_API_KEY` if you want to verify your contract on [Etherscan](https://etherscan.io/).

1. Get testnet ETH

Head over to [faucets.chain.link](https://faucets.chain.link/) and get some testnet ETH. You should see the ETH show up in your metamask.

2. Deploy

```
make deploy ARGS="--network sepolia"
```

## Scripts

Instead of scripts, we can directly use the `cast` command to interact with the contract.

For example, on Sepolia:

1. Get some WETH

```
cast send 0xdd13E55209Fd76AfE204dBda4007C227904f0a81 "deposit()" --value 0.1ether --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

2. Approve the WETH

```
cast send 0xdd13E55209Fd76AfE204dBda4007C227904f0a81 "approve(address,uint256)" 0x091EA0838eBD5b7ddA2F2A641B068d6D59639b98 1000000000000000000 --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

3. Deposit and Mint DSC

```
cast send 0x091EA0838eBD5b7ddA2F2A641B068d6D59639b98 "depositCollateralAndMintDsc(address,uint256,uint256)" 0xdd13E55209Fd76AfE204dBda4007C227904f0a81 100000000000000000 10000000000000000 --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

## License

This project is licensed under the MIT License – see the LICENSE file for details.

## Acknowledgments

- This project is based on the Cyfrin course on [foundry defi stablecoins](https://github.com/Cyfrin/foundry-defi-stablecoin-cu). The original exercise provided the foundation for learning and implementing the core concepts.
- Thanks to the Cyfrin team for the educational materials and guidance.
