import fs from "fs";
import path from "path";
import { ethers } from "hardhat";
import { SeedRoundFundraiser } from "../typechain-types";

async function main() {
  // Load tokens from JSON file
  const tokensFilePath = path.join(__dirname, "../tokens.json");
  const tokensData = JSON.parse(fs.readFileSync(tokensFilePath, "utf8"));

  if (!tokensData.tokens || !Array.isArray(tokensData.tokens)) {
    console.error('Invalid tokens.json format. Expected { "tokens": [...] }');
    return;
  }

  // Get the deployed contract
  const SeedRoundFundraiser = await ethers.getContractFactory(
    "SeedRoundFundraiser"
  );

  const fundraiserAddress = process.env.FUNDRAISER_ADDRESS!;
  if (!fundraiserAddress) {
    console.error("FUNDRAISER_ADDRESS is not set in the .env file");
    return;
  }

  const fundraiser = SeedRoundFundraiser.attach(
    fundraiserAddress
  ) as SeedRoundFundraiser;

  console.log(`Adding ${tokensData.tokens.length} tokens to whitelist...`);

  // Process tokens in batches to avoid gas issues
  const batchSize = 10;
  for (let i = 0; i < tokensData.tokens.length; i += batchSize) {
    const batch = tokensData.tokens.slice(i, i + batchSize);

    // Process each token in the current batch
    for (const token of batch) {
      if (!token.address || !token.price) {
        console.warn(`Skipping invalid token entry: ${JSON.stringify(token)}`);
        continue;
      }

      try {
        // Convert price to the contract's PRICE_PRECISION (1e18)
        const priceInWei = ethers.parseUnits(token.price.toString(), 18);

        console.log(
          `Adding token ${token.address} with price ${token.price} USD`
        );

        // Add token to whitelist
        const tx = await fundraiser.addWhitelistedToken(
          token.address,
          priceInWei
        );
        await tx.wait();

        console.log(`Successfully added token ${token.address} to whitelist`);
      } catch (error: any) {
        console.error(`Error adding token ${token.address}: ${error.message}`);
      }
    }

    console.log(
      `Processed batch ${i / batchSize + 1} of ${Math.ceil(
        tokensData.tokens.length / batchSize
      )}`
    );
  }

  console.log("Finished adding tokens to whitelist");
}

// Execute the script
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
