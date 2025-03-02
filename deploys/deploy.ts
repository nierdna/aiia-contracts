import * as hre from "hardhat";
import "dotenv/config";
import { formatEther } from "ethers";
const { ethers, upgrades } = hre;

async function main() {
  const [deployer] = await ethers.getSigners();
  const networkName = hre.network.name;
  console.log("Network name:", networkName);
  // Contract name to deploy
  const contractName = "SeedRoundFundraiser";

  console.log("Deploying contracts with the account:", deployer.address);
  console.log(
    "Balance: ",
    formatEther(await deployer.provider.getBalance(deployer.address))
  );

  const projectToken = process.env.PROJECT_TOKEN;

  if (!projectToken) {
    console.log(`Currency not found, skipping ${contractName} deployment`);
    return;
  }

  const owner = process.env.OWNER_ADDRESS;

  if (!owner) {
    console.log(`Owner not found, skipping ${contractName} deployment`);
    return;
  }

  console.log(`Deploying ${contractName} contract`);
  const Factory = await ethers.getContractFactory(contractName, deployer);
  const contract = await upgrades.deployProxy(Factory, [projectToken, owner], {
    initializer: "initialize",
  });
  await contract.waitForDeployment();
  const proxy = await contract.getAddress();
  console.log(`${contractName} Proxy:`, proxy);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
