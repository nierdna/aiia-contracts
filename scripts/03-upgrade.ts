import * as hre from "hardhat";
import "dotenv/config";
import { formatEther } from "ethers";
const { ethers, upgrades } = hre;

async function main() {
  const [deployer] = await ethers.getSigners();
  const networkName = hre.network.name;
  console.log("Network name:", networkName);
  // Contract name to deploy
  const contractName = process.env.CONTRACT_NAME!;

  const contractAddress = process.env.CONTRACT_ADDRESS!;
  if (!contractAddress) {
    console.error("CONTRACT_ADDRESS is not set in the .env file");
    return;
  }

  console.log("Upgrading contracts with the account:", deployer.address);
  console.log(
    "Balance: ",
    formatEther(await deployer.provider.getBalance(deployer.address))
  );

  let proxy: any = contractAddress;

  const oldImplemented = await upgrades.erc1967.getImplementationAddress(proxy);
  const Factory = await ethers.getContractFactory(contractName, deployer);
  const contract = await upgrades.upgradeProxy(proxy, Factory);
  await contract.waitForDeployment();

  // new implemented
  const implemented = await upgrades.erc1967.getImplementationAddress(proxy);

  console.log(`Upgrade ${contractName}:`, oldImplemented, implemented);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
