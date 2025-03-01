# TradingVault Smart Contract Documentation

## Overview

The TradingVault is a sophisticated smart contract designed to manage trading positions as NFTs with reward distribution capabilities. It allows users to create, manage, and reduce trading positions while earning rewards based on position duration and price appreciation.

## System Workflow Diagram

The following diagram illustrates the key workflows and interactions within the TradingVault system:

![TradingVault System Workflow Diagram](assets/diagrams/TradingVault%20User%20Flow%20Sequence.png)

The diagram shows the main processes:
- Position Creation: Creating new positions and minting NFTs
- Price Update: Updating global price state
- Reward Configuration: Managing reward weight tiers
- Position Reduction: Reducing positions and calculating rewards
- Batch Position Reduction: Processing multiple positions in one transaction
- Add Reward: Adding rewards to the contract

## Key Features

- **NFT-Based Positions**: Each trading position is represented as an NFT, providing ownership and transferability
- **Reward Distribution**: Rewards are calculated based on price appreciation and position duration
- **Duration-Based Rewards**: Longer-held positions can receive higher reward weights
- **Role-Based Access Control**: Different roles for administration, operations, and price setting
- **Upgradeable Design**: Contract follows the upgradeable pattern for future improvements
- **Multi-Token Support**: Positions track their original currency token, allowing for currency changes

## Contract Architecture

The TradingVault contract inherits from several OpenZeppelin contracts:

- `Initializable`: Supports the upgradeable pattern
- `ERC721Upgradeable`: Implements NFT functionality for positions
- `OwnableUpgradeable`: Provides basic access control
- `AccessControlUpgradeable`: Implements role-based permissions

## Roles and Permissions

The contract implements three main roles:

1. **DEFAULT_ADMIN_ROLE**: Can grant other roles and manage contract settings
2. **OPERATOR_ROLE**: Can update currency, reward token, and reward configurations
3. **PRICE_SETTER_ROLE**: Can update the price used for position calculations

## Core Concepts

### Positions

A position represents a user's deposit in the vault and contains the following information:

- `entryPrice`: Price at which the position was opened
- `outPrice`: Price at which the position was closed (0 if still open)
- `remainingAmount`: Current amount remaining in the position
- `initAmount`: Initial amount when position was opened
- `openedAt`: Timestamp when position was opened
- `closedAt`: Timestamp when position was closed (0 if still open)
- `rewardedAmount`: Total rewards harvested from this position
- `lossAmount`: Total loss when reducing position at price < entryPrice
- `token`: Currency token used for this position

### Reward Configuration

Rewards are distributed based on position duration using configurable weight tiers:

- Each tier has a `weight` (out of BASE_WEIGHT = 10,000) and a `duration` threshold
- Positions held longer receive higher reward percentages
- The remaining reward portion goes to the treasury

### Price Mechanism

- The contract maintains a global `price` value set by price setters
- Rewards are calculated based on price appreciation: `(amount * (currentPrice - entryPrice)) / PERCENTAGE_BASE`
- If price decreases, users experience a loss proportional to the price difference

## Main Functions

### For Users

#### Creating Positions

```solidity
function createPosition(uint256 _amount, address _recipient) external returns (uint256)
```

Creates a new position with the specified amount and mints an NFT to the recipient (or sender if recipient is zero address).

#### Reducing Positions

```solidity
function reducePosition(uint256 _tokenId, uint256 _amount) external
```

Reduces a position by the specified amount, harvests any available rewards, and returns the appropriate amount of currency tokens.

```solidity
function reducePositions(uint256[] calldata _tokenIds, uint256[] calldata _amounts) external
```

Batch reduces multiple positions in a single transaction (all positions must use the same token).

#### Adding Rewards

```solidity
function addReward(uint256 _rewardAmount) external
```

Allows anyone to add reward tokens to the contract.

### For Administrators

#### Role Management

```solidity
function grantOperatorRole(address operator) external onlyRole(DEFAULT_ADMIN_ROLE)
function grantPriceSetterRole(address priceSetter) external onlyRole(DEFAULT_ADMIN_ROLE)
```

Grant operator and price setter roles to addresses.

#### Treasury Management

```solidity
function setTreasury(address _treasury) external onlyOwner
```

Updates the treasury address that receives a portion of rewards.

#### Position Reduction Control

```solidity
function setReduceEnabled(bool _enabled) external onlyOwner
```

Enables or disables the ability to reduce positions.

#### Currency Management

```solidity
function borrowCurrency(uint256 _amount) external onlyOwner
function repayCurrency(uint256 _amount) external
```

Allows the owner to borrow currency from the contract and anyone to repay borrowed currency.

#### Token Recovery

```solidity
function claimERC20(address _token, uint256 _amount) external onlyOwner
```

Allows the owner to claim any ERC20 tokens stuck in the contract (except currency and reward tokens).

### For Operators

#### Token Configuration

```solidity
function setCurrency(address _currency) external onlyRole(OPERATOR_ROLE)
function setRewardToken(address _rewardToken) external onlyRole(OPERATOR_ROLE)
```

Update the currency and reward token addresses.

#### Reward Configuration

```solidity
function updateRewardConfigs(RewardConfig[] calldata _configs) external onlyRole(OPERATOR_ROLE)
```

Updates the reward configurations with new duration-based weight tiers.

### For Price Setters

```solidity
function setPrice(uint256 _newPrice) external onlyRole(PRICE_SETTER_ROLE)
```

Updates the price used for position calculations.

## Reward Calculation

When a position is reduced, rewards are calculated as follows:

1. If current price <= entry price, no rewards are given
2. Total reward = `(reducedAmount * (currentPrice - entryPrice)) / PERCENTAGE_BASE`
3. User's duration is calculated: `duration = block.timestamp - position.openedAt`
4. Weight is determined based on duration tiers
5. User reward = `(totalReward * weight) / BASE_WEIGHT`
6. Treasury reward = `totalReward - userReward`

## Loss Calculation

When reducing a position at a price lower than the entry price:

1. Price difference = `entryPrice - currentPrice`
2. Loss amount = `(reducedAmount * priceDiff) / PERCENTAGE_BASE`
3. Amount returned to user = `reducedAmount - loss`

## Events

The contract emits various events to track activity:

- `PositionCreated`: When a new position is created
- `PositionReduced`: When a position is reduced
- `TotalAmountUpdated`: When the total amount in the vault changes
- `CurrencyBorrowed`: When currency is borrowed
- `CurrencyRepaid`: When borrowed currency is repaid
- `PriceUpdated`: When the price is updated
- `CurrencyUpdated`: When the currency token is changed
- `RewardTokenUpdated`: When the reward token is changed
- `TreasuryUpdated`: When the treasury address is updated
- `RewardConfigsUpdated`: When reward configurations are updated
- `ReduceEnabledUpdated`: When position reduction is enabled/disabled
- `TotalRewardsUpdated`: When total rewards are updated
- `TotalRewardsHarvestedUpdated`: When harvested rewards are updated

## Security Considerations

The contract implements several security features:

- Role-based access control for sensitive operations
- Protected token management (currency and reward tokens)
- Secure reward distribution with treasury allocation
- Upgradeable pattern for future improvements
- Comprehensive error handling with custom errors

## Usage Examples

### Creating a Position

1. Approve the TradingVault contract to spend your currency tokens
2. Call `createPosition(amount, recipient)` with the desired amount and recipient address
3. Receive an NFT representing your position

### Reducing a Position

1. As the position owner or approved address, call `reducePosition(tokenId, amount)`
2. Receive currency tokens and any earned rewards
3. If reducing the entire amount, the position is closed and the NFT is burned

### Adding Rewards

1. Approve the TradingVault contract to spend your reward tokens
2. Call `addReward(amount)` with the desired amount
3. Rewards are added to the pool for distribution

## Constants

- `EXPO = 1_000_000`: Exponent for price precision
- `PERCENTAGE_BASE = 100 * EXPO`: Base for percentage calculations
- `BASE_WEIGHT = 10_000`: Base for reward weight calculations

## Conclusion

The TradingVault contract provides a flexible and secure way to manage trading positions as NFTs with sophisticated reward distribution mechanisms. Its role-based access control and upgradeable design make it suitable for various trading applications while maintaining security and flexibility. 