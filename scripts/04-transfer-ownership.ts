import * as hre from "hardhat";
import dotenv from "dotenv";

const { ethers, upgrades } = hre;
const envFile = process.env.ENV_FILE || ".env";
dotenv.config({ path: envFile });

async function main() {
  const [deployer] = await ethers.getSigners();
  const networkName = hre.network.name;

  console.log("Executing with account:", deployer.address);

  // Get the deployed Proxy contract address
  const tradingVaultProxy = process.env.CONTRACT_ADDRESS;

  if (!tradingVaultProxy) {
    console.error("TradingVault Proxy address not found");
    return;
  }

  // Get the ProxyAdmin address
  const proxyAdminAddress = await upgrades.erc1967.getAdminAddress(
    tradingVaultProxy
  );
  console.log("Current ProxyAdmin address:", proxyAdminAddress);

  // Connect to ProxyAdmin using ABI
  const proxyAdminABI = [
    "function owner() view returns (address)",
    "function transferOwnership(address newOwner) public",
  ];
  const proxyAdmin = new ethers.Contract(
    proxyAdminAddress,
    proxyAdminABI,
    deployer
  );

  // Get current owner address
  const currentOwner = await proxyAdmin.owner();
  console.log("Current owner:", currentOwner);

  // Get new owner address from environment variable or hardcoded value
  const newOwner: string = "0xAC7C223b7EF649f438fe275494651e60ddc1f778";

  if (!newOwner || !ethers.isAddress(newOwner)) {
    console.error("Invalid new address. Please provide a valid address.");
    return;
  }

  console.log(
    "Transferring ProxyAdmin ownership from",
    currentOwner,
    "to",
    newOwner
  );

  // Execute ownership transfer
  const tx = await proxyAdmin.transferOwnership(newOwner);
  await tx.wait();

  // Confirm new owner
  const newCurrentOwner = await proxyAdmin.owner();
  console.log("New ProxyAdmin owner:", newCurrentOwner);

  if (newCurrentOwner.toLowerCase() === newOwner.toLowerCase()) {
    console.log("Ownership transfer successful!");
  } else {
    console.error("Ownership transfer failed!");
  }
}

// Run script
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
