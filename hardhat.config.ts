import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-verify";
import * as dotenv from "dotenv";
import "@nomicfoundation/hardhat-ethers";
import "@openzeppelin/hardhat-upgrades";

dotenv.config();

const pks: string[] = [process.env.PRIVATE_KEY].filter(
  (pk) => pk !== undefined
) as string[];

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
    },
  },
  networks: {
    sepolia: {
      url:
        process.env.SEPOLIA_RPC_URL ||
        "https://sepolia.infura.io/v3/YOUR-PROJECT-ID",
      accounts: pks,
    },
    "base-sepolia": {
      url: process.env.BASE_SEPOLIA_RPC_URL || "",
      accounts: pks,
    },
    base: {
      url: process.env.BASE_RPC_URL || "",
      accounts: pks,
    },
  },
  etherscan: {
    apiKey: {
      sepolia: process.env.ETHERSCAN_API_KEY || "",
      baseSepolia: process.env.BASE_SEPOLIA_API_KEY || "",
    },
  },
};

export default config;
