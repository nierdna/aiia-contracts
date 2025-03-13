import * as hre from "hardhat";
import "dotenv/config";
import { formatEther } from "ethers";
const { ethers, upgrades } = hre;
async function main() {
  const [deployer] = await ethers.getSigners();
  const networkName = hre.network.name;
  // Add TradingVault and Proxy contract names
  const contractName = "TradingVault";

  console.log("Deploying contracts with the account:", deployer.address);
  console.log(
    "Balance: ",
    formatEther(await deployer.provider.getBalance(deployer.address))
  );

  // Deploy or upgrade each contract
  let currency: string = process.env.CURRENCY || "";
  let reward: string = process.env.REWARD || "";
  let treasury = process.env.TREASURY || "";
  let owner = process.env.OWNER || "";

  if (!currency || !reward || !treasury || !owner) {
    console.log(
      `Currency or reward or treasury or owner not found, skipping ${contractName} deployment`
    );
    return;
  }

  console.log(`Deploying ${contractName} contract`);
  const Factory = await ethers.getContractFactory(contractName, deployer);
  const contract = await upgrades.deployProxy(
    Factory,
    [currency, reward, treasury, owner],
    {
      initializer: "initialize",
    }
  );
  await contract.waitForDeployment();
  const proxy = await contract.getAddress();
  const implemented = await upgrades.erc1967.getImplementationAddress(proxy);
  console.log(`${contractName} Proxy:`, proxy);
  console.log(`${contractName} Implementation:`, implemented);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
