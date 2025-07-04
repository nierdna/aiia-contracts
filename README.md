# AIIA Contracts

This repository contains a collection of smart contracts for the AIIA ecosystem, including Trading Vaults, Fundraising, Staking, and NFT Referral systems. The contracts are built with Hardhat and use OpenZeppelin libraries.

## Smart Contracts

The repository includes the following core contracts:

- **TradingVault**: An NFT-based trading position management system with reward distribution capabilities
- **SeedRoundFundraiser**: A contract for managing seed round fundraising with multiple rounds
- **Erc20Staking**: A staking contract for ERC20 tokens with off-chain reward calculations
- **MultiLevelReferralNFT**: An NFT-based multi-level referral system

## Prerequisites

Before running this project, make sure you have the following installed:
- [Node.js](https://nodejs.org/) (v16.0.0 or later)
- [pnpm](https://pnpm.io/) (preferred package manager)

## Installation

1. Clone the repository:
```bash
git clone https://github.com/yourusername/aiia-contracts.git
cd aiia-contracts
```

2. Install dependencies:
```bash
pnpm install
```

## Available Commands

### Compile Contracts
```bash
npx hardhat compile
```

### Run Tests
```bash
npx hardhat test
```

### Start Hardhat Node
```bash
npx hardhat node
```

### Deploy Contracts
```bash
npx hardhat run scripts/01-deploy.ts --network <network-name>
```

For TradingVault specific deployment:
```bash
npx hardhat run scripts/TradingVault/01-deploy.ts --network <network-name>
```

### Clean
Remove the build artifacts and cache:
```bash
npx hardhat clean
```

## Network Configuration

The project supports deploying to multiple networks including:
- Sepolia (Ethereum testnet)
- Base Sepolia (Base testnet)
- Base Mainnet

You can configure network settings in `hardhat.config.ts`.

## Environment Variables

Create a `.env` file in the root directory with the following variables:
```
PRIVATE_KEY=your_private_key_here
SEPOLIA_RPC_URL=your_sepolia_rpc_url
BASE_SEPOLIA_RPC_URL=your_base_sepolia_rpc_url
BASE_RPC_URL=your_base_mainnet_rpc_url
ETHERSCAN_API_KEY=your_etherscan_api_key
BASE_SEPOLIA_API_KEY=your_base_sepolia_api_key
```

Additional contract-specific environment variables can be found in deployment guides.

## Project Structure

```
├── contracts/          # Smart contracts
├── scripts/            # Deploy and interaction scripts
├── assets/             # Documentation assets like diagrams
├── hardhat.config.ts   # Hardhat configuration
└── .env                # Environment variables (create this)
```

## Deployment Guides

For detailed deployment instructions, refer to:
- `deploy.md` - General deployment guide
- `TradingVaultDocs.md` - TradingVault specific documentation

## License

This project is licensed under the MIT License. 