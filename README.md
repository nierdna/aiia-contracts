# Hardhat Project

This project demonstrates a basic Hardhat use case. It comes with sample contracts, tests for those contracts, and scripts that deploy the contracts.

## Prerequisites

Before running this project, make sure you have the following installed:
- [Node.js](https://nodejs.org/) (v14.0.0 or later)
- [npm](https://www.npmjs.com/) (usually comes with Node.js)

## Installation

1. Clone the repository:
```bash
git clone <your-repo-url>
cd <your-repo-name>
```

2. Install dependencies:
```bash
npm install
```

## Available Commands

Here are the most common commands you'll need:

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
npx hardhat run scripts/deploy.js --network <network-name>
```

### Clean
Remove the build artifacts and cache:
```bash
npx hardhat clean
```

### Network Configuration
To deploy to different networks, update the `hardhat.config.js` file with your network settings and API keys.

Example networks:
- localhost
- goerli
- mainnet

### Environment Variables
Create a `.env` file in the root directory with the following variables:
```
PRIVATE_KEY=your_private_key_here
ETHERSCAN_API_KEY=your_etherscan_api_key_here
ALCHEMY_API_KEY=your_alchemy_api_key_here
```

## Project Structure

```
├── contracts/          # Smart contracts
├── scripts/           # Deploy and interaction scripts
├── test/             # Test files
├── hardhat.config.js # Hardhat configuration
└── .env              # Environment variables (create this)
```

## Helpful Tips

1. Use `hardhat console` to interact with your contracts:
```bash
npx hardhat console --network localhost
```

2. For local development:
   - Start a local node: `npx hardhat node`
   - Deploy to local network: `npx hardhat run scripts/deploy.js --network localhost`

3. Verify contracts on Etherscan:
```bash
npx hardhat verify --network <network> <deployed-contract-address> <constructor-arguments>
```

## License

This project is licensed under the [MIT License](LICENSE). 