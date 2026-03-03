import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Full deployment script for the RWA Platform.
 *
 * Deploys:
 *   1. NAVOracle
 *   2. RWAFactory
 *   3. SPVRegistry
 *   4. CASH+ product (via factory)
 *   5. AoABT product (via factory)
 *
 * After deployment, writes addresses to deployments/<network>.json
 * for use by backend services.
 */
async function main() {
  const [deployer, oracleNode, vaultOperator, feeRecipient] = await ethers.getSigners();
  const network = await ethers.provider.getNetwork();

  console.log(`\n🚀 Deploying RWA Platform to ${network.name} (chainId: ${network.chainId})`);
  console.log(`   Deployer:      ${deployer.address}`);
  console.log(`   OracleNode:    ${oracleNode.address}`);
  console.log(`   VaultOperator: ${vaultOperator.address}`);
  console.log(`   FeeRecipient:  ${feeRecipient.address}\n`);

  // ─────────────────────────────────────────────
  //  USDT Address (use mock on testnets)
  // ─────────────────────────────────────────────
  let usdtAddress: string;
  const isLocalNetwork = network.chainId === 31337n || network.name === "localhost";

  if (isLocalNetwork) {
    const MockUSDT = await ethers.getContractFactory("MockERC20");
    const usdt = await MockUSDT.deploy("USD Tether", "USDT", 6);
    await usdt.waitForDeployment();
    usdtAddress = await usdt.getAddress();
    console.log(`✓ MockUSDT deployed:    ${usdtAddress}`);
  } else {
    // HashKey Chain mainnet/testnet USDT address
    usdtAddress = process.env.USDT_ADDRESS || "";
    if (!usdtAddress) throw new Error("USDT_ADDRESS not set for non-local network");
    console.log(`✓ Using USDT:           ${usdtAddress}`);
  }

  // ─────────────────────────────────────────────
  //  1. NAVOracle
  // ─────────────────────────────────────────────
  const NAVOracle = await ethers.getContractFactory("NAVOracle");
  const navOracle = await NAVOracle.deploy(deployer.address);
  await navOracle.waitForDeployment();
  const navOracleAddr = await navOracle.getAddress();
  console.log(`✓ NAVOracle deployed:   ${navOracleAddr}`);

  // Grant oracle node role
  await navOracle.addOracleNode(oracleNode.address);
  console.log(`  → Oracle node granted: ${oracleNode.address}`);

  // ─────────────────────────────────────────────
  //  2. RWAFactory
  // ─────────────────────────────────────────────
  const Factory = await ethers.getContractFactory("RWAFactory");
  const factory = await Factory.deploy(navOracleAddr, usdtAddress, deployer.address);
  await factory.waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log(`✓ RWAFactory deployed:  ${factoryAddr}`);

  // ─────────────────────────────────────────────
  //  3. SPVRegistry
  // ─────────────────────────────────────────────
  const SPVRegistry = await ethers.getContractFactory("SPVRegistry");
  const spvRegistry = await SPVRegistry.deploy(deployer.address);
  await spvRegistry.waitForDeployment();
  const spvRegistryAddr = await spvRegistry.getAddress();
  console.log(`✓ SPVRegistry deployed: ${spvRegistryAddr}`);

  // ─────────────────────────────────────────────
  //  4. Deploy CASH+ product
  // ─────────────────────────────────────────────
  console.log("\n📦 Deploying CASH+ product...");
  const cashPlusTx = await factory.deployProduct(
    {
      name: "CASH+ USD Money Market Fund",
      symbol: "CASH+",
      productId: "CASH+",
      strategyType: "money-market",
      redemptionDelay: 86400,          // T+1 (24 hours)
      minSubscription: 0,              // No minimum — permissionless
      managementFeeBps: 50,            // 0.5% annual
      feeRecipient: feeRecipient.address,
      spvAddress: ethers.ZeroAddress,  // Set later when SPV is incorporated
    },
    vaultOperator.address
  );
  await cashPlusTx.wait();

  const cashPlusProduct = await factory.getProduct("CASH+");
  console.log(`✓ CASH+ Token:          ${cashPlusProduct.token}`);
  console.log(`  CASH+ Vault:          ${cashPlusProduct.vault}`);

  // Initialize CASH+ NAV at $1.00
  await navOracle.connect(oracleNode).updateNAV(
    cashPlusProduct.token,
    ethers.parseUnits("1.0", 18)
  );
  console.log(`  NAV initialized:      $1.00`);

  // ─────────────────────────────────────────────
  //  5. Deploy AoABT product
  // ─────────────────────────────────────────────
  console.log("\n📦 Deploying AoABT product...");
  const aoabtTx = await factory.deployProduct(
    {
      name: "AoABT Funding Rate Arbitrage Fund",
      symbol: "AoABT",
      productId: "AoABT",
      strategyType: "funding-rate-arb",
      redemptionDelay: 7 * 86400,      // T+7 (weekly)
      minSubscription: ethers.parseUnits("100000", 6), // $100K minimum
      managementFeeBps: 100,           // 1% annual
      feeRecipient: feeRecipient.address,
      spvAddress: ethers.ZeroAddress,
    },
    vaultOperator.address
  );
  await aoabtTx.wait();

  const aoabtProduct = await factory.getProduct("AoABT");
  console.log(`✓ AoABT Token:          ${aoabtProduct.token}`);
  console.log(`  AoABT Vault:          ${aoabtProduct.vault}`);

  // Initialize AoABT NAV at $1.00
  await navOracle.connect(oracleNode).updateNAV(
    aoabtProduct.token,
    ethers.parseUnits("1.0", 18)
  );
  console.log(`  NAV initialized:      $1.00`);

  // ─────────────────────────────────────────────
  //  Write deployment manifest
  // ─────────────────────────────────────────────
  const deployment = {
    network: network.name,
    chainId: network.chainId.toString(),
    deployedAt: new Date().toISOString(),
    contracts: {
      NAVOracle:   navOracleAddr,
      RWAFactory:  factoryAddr,
      SPVRegistry: spvRegistryAddr,
      USDT:        usdtAddress,
    },
    products: {
      "CASH+": { token: cashPlusProduct.token, vault: cashPlusProduct.vault },
      "AoABT": { token: aoabtProduct.token,    vault: aoabtProduct.vault },
    },
    roles: {
      admin:         deployer.address,
      oracleNode:    oracleNode.address,
      vaultOperator: vaultOperator.address,
      feeRecipient:  feeRecipient.address,
    },
  };

  const deploymentsDir = path.join(__dirname, "../deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir);
  const outPath = path.join(deploymentsDir, `${network.name}.json`);
  fs.writeFileSync(outPath, JSON.stringify(deployment, null, 2));

  console.log(`\n✅ Deployment complete. Manifest saved to: ${outPath}`);
  console.log("\n📋 Summary:");
  console.log(JSON.stringify(deployment, null, 2));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
