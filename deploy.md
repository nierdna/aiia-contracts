# Seed Round Fundraiser Deployment Guide

## Preparation

1. Make sure all dependencies are installed:
   ```bash
   npm install
   ```

2. Create a `.env` file from `.env.example` and update the following information:
   ```
   PROJECT_TOKEN=<project token address>
   OWNER_ADDRESS=<owner wallet address>
   PRIVATE_KEY=<private key of the deployment wallet>
   SEPOLIA_RPC_URL=<Sepolia network RPC URL>
   BASE_SEPOLIA_RPC_URL=<Base Sepolia network RPC URL>
   BASE_RPC_URL=<Base network RPC URL>
   ETHERSCAN_API_KEY=<Etherscan API key for contract verification>
   BASE_SEPOLIA_API_KEY=<Base Sepolia API key for contract verification>
   ```

## Deploy to Different Networks

### Sepolia Network (Default)

1. Run the following command to deploy the Seed Round Fundraiser to Sepolia:
   ```bash
   npm run deploy:seed-round-fundraiser
   ```
   or
   ```bash
   npm run deploy:seed-round-fundraiser:sepolia
   ```

### Base Sepolia Network

1. Run the following command to deploy the Seed Round Fundraiser to Base Sepolia:
   ```bash
   npm run deploy:seed-round-fundraiser:base-sepolia
   ```

### Base Mainnet

1. Run the following command to deploy the Seed Round Fundraiser to Base Mainnet:
   ```bash
   npm run deploy:seed-round-fundraiser:base
   ```

2. After successful deployment, the contract address will be displayed in the terminal.

## Contract Verification

Verify the contract on the respective block explorer:

### Sepolia
```bash
npx hardhat verify --network sepolia <contract_address>
```

### Base Sepolia
```bash
npx hardhat verify --network base-sepolia <contract_address>
```

### Base Mainnet
```bash
npx hardhat verify --network base <contract_address>
```

## Notes

- Ensure the deployment wallet has sufficient ETH to pay for gas fees.
- The PROJECT_TOKEN address must be a valid project token address.
- The OWNER_ADDRESS will have administrative rights to the contract after deployment.
- You can deploy to different networks by using the appropriate script command or by specifying the network flag manually: `npx hardhat run deploys/deploy.ts --network <network-name>`