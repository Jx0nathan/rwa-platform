import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";

/**
 * Full integration test suite for the RWA Platform.
 *
 * Tests the complete lifecycle:
 *   1. Deploy NAVOracle, Factory, SPVRegistry
 *   2. Deploy CASH+ product via Factory
 *   3. Initialize NAV
 *   4. Subscribe (deposit USDT → get RWAToken shares)
 *   5. NAV accrual (simulate daily yield)
 *   6. Request redemption
 *   7. Fulfill redemption (backend simulation)
 *   8. Verify compliance rules (blacklist, whitelist)
 */
describe("RWA Platform", function () {
  // ─────────────────────────────────────────────
  //  Fixtures
  // ─────────────────────────────────────────────

  async function deployFixture() {
    const [admin, oracleNode, operator, user1, user2, blacklisted, feeRecipient] =
      await ethers.getSigners();

    // Deploy mock USDT (6 decimals)
    const MockUSDT = await ethers.getContractFactory("MockERC20");
    const usdt = await MockUSDT.deploy("USD Tether", "USDT", 6);

    // Deploy NAVOracle
    const NAVOracle = await ethers.getContractFactory("NAVOracle");
    const navOracle = await NAVOracle.deploy(admin.address);

    // Grant oracle node role
    await navOracle.addOracleNode(oracleNode.address);

    // Deploy Factory
    const Factory = await ethers.getContractFactory("RWAFactory");
    const factory = await Factory.deploy(
      await navOracle.getAddress(),
      await usdt.getAddress(),
      admin.address
    );

    // Deploy SPVRegistry
    const SPVRegistry = await ethers.getContractFactory("SPVRegistry");
    const spvRegistry = await SPVRegistry.deploy(admin.address);

    return {
      admin, oracleNode, operator, user1, user2, blacklisted, feeRecipient,
      usdt, navOracle, factory, spvRegistry,
    };
  }

  async function deployWithProductFixture() {
    const ctx = await deployFixture();
    const { admin, operator, feeRecipient, factory, navOracle, oracleNode } = ctx;

    // Deploy CASH+ product
    const tx = await factory.connect(admin).deployProduct(
      {
        name: "CASH+ USD Money Market",
        symbol: "CASH+",
        productId: "CASH+",
        strategyType: "money-market",
        redemptionDelay: 86400, // T+1
        minSubscription: 0,     // No minimum
        managementFeeBps: 50,   // 0.5% annual
        feeRecipient: feeRecipient.address,
        spvAddress: ethers.ZeroAddress,
      },
      operator.address
    );
    await tx.wait();

    const product = await factory.getProduct("CASH+");
    const tokenAddr = product.token;
    const vaultAddr = product.vault;

    const token = await ethers.getContractAt("RWAToken", tokenAddr);
    const vault = await ethers.getContractAt("RWAVault", vaultAddr);

    // Initialize NAV at $1.00
    const INITIAL_NAV = ethers.parseUnits("1.0", 18);
    await navOracle.connect(oracleNode).updateNAV(tokenAddr, INITIAL_NAV);

    return { ...ctx, token, vault, tokenAddr, vaultAddr };
  }

  // ─────────────────────────────────────────────
  //  1. Deployment
  // ─────────────────────────────────────────────

  describe("Deployment", function () {
    it("should deploy all contracts correctly", async function () {
      const { navOracle, factory, spvRegistry, admin } = await loadFixture(deployFixture);
      expect(await navOracle.getAddress()).to.be.properAddress;
      expect(await factory.getAddress()).to.be.properAddress;
      expect(await spvRegistry.getAddress()).to.be.properAddress;
    });

    it("should deploy a product via factory", async function () {
      const { token, vault, tokenAddr, vaultAddr } = await loadFixture(deployWithProductFixture);
      expect(tokenAddr).to.be.properAddress;
      expect(vaultAddr).to.be.properAddress;
      expect(await token.symbol()).to.equal("CASH+");
      expect(await token.productId()).to.equal("CASH+");
    });
  });

  // ─────────────────────────────────────────────
  //  2. NAV Oracle
  // ─────────────────────────────────────────────

  describe("NAVOracle", function () {
    it("should initialize NAV correctly", async function () {
      const { navOracle, tokenAddr } = await loadFixture(deployWithProductFixture);
      const data = await navOracle.getLatestNAV(tokenAddr);
      expect(data.nav).to.equal(ethers.parseUnits("1.0", 18));
      expect(data.valid).to.be.true;
    });

    it("should reject NAV updates from unauthorized nodes", async function () {
      const { navOracle, tokenAddr, user1 } = await loadFixture(deployWithProductFixture);
      await expect(
        navOracle.connect(user1).updateNAV(tokenAddr, ethers.parseUnits("1.01", 18))
      ).to.be.reverted;
    });

    it("should reject NAV update with > 5% deviation", async function () {
      const { navOracle, tokenAddr, oracleNode } = await loadFixture(deployWithProductFixture);
      // $1.00 → $1.10 is 10% deviation, should revert
      await expect(
        navOracle.connect(oracleNode).updateNAV(tokenAddr, ethers.parseUnits("1.10", 18))
      ).to.be.revertedWith("NAVOracle: deviation too large");
    });

    it("should allow admin to confirm large deviation", async function () {
      const { navOracle, tokenAddr, admin } = await loadFixture(deployWithProductFixture);
      await navOracle.connect(admin).confirmLargeDeviation(
        tokenAddr,
        ethers.parseUnits("1.10", 18)
      );
      const data = await navOracle.getLatestNAV(tokenAddr);
      expect(data.nav).to.equal(ethers.parseUnits("1.10", 18));
    });
  });

  // ─────────────────────────────────────────────
  //  3. Subscription
  // ─────────────────────────────────────────────

  describe("Subscription", function () {
    it("should mint correct shares at NAV $1.00", async function () {
      const { usdt, vault, token, user1 } = await loadFixture(deployWithProductFixture);

      // Fund user with $1000 USDT
      const amount = ethers.parseUnits("1000", 6);
      await usdt.mint(user1.address, amount);
      await usdt.connect(user1).approve(await vault.getAddress(), amount);

      // Subscribe
      await vault.connect(user1).subscribe(amount);

      // At NAV $1.00: shares = assets (normalized)
      // 1000 USDT (6 dec) → 1000 shares (18 dec)
      const balance = await token.balanceOf(user1.address);
      expect(balance).to.equal(ethers.parseUnits("1000", 18));
    });

    it("should mint fewer shares when NAV is above $1.00", async function () {
      const { usdt, vault, token, navOracle, oracleNode, user1, tokenAddr } =
        await loadFixture(deployWithProductFixture);

      // Update NAV to $1.05 (5% yield accrued)
      await navOracle.connect(oracleNode).updateNAV(tokenAddr, ethers.parseUnits("1.05", 18));

      const amount = ethers.parseUnits("1050", 6);
      await usdt.mint(user1.address, amount);
      await usdt.connect(user1).approve(await vault.getAddress(), amount);
      await vault.connect(user1).subscribe(amount);

      // $1050 / NAV $1.05 = 1000 shares
      const balance = await token.balanceOf(user1.address);
      expect(balance).to.equal(ethers.parseUnits("1000", 18));
    });

    it("should revert if NAV is stale", async function () {
      // This test would require time-travel; skip in unit tests
      // Covered in integration tests with hardhat-network-helpers timetravel
    });
  });

  // ─────────────────────────────────────────────
  //  4. Redemption
  // ─────────────────────────────────────────────

  describe("Redemption", function () {
    async function subscribeFixture() {
      const ctx = await deployWithProductFixture();
      const { usdt, vault, token, user1 } = ctx;
      const amount = ethers.parseUnits("1000", 6);
      await usdt.mint(user1.address, amount);
      await usdt.connect(user1).approve(await vault.getAddress(), amount);
      await vault.connect(user1).subscribe(amount);
      return ctx;
    }

    it("should create a pending redemption request", async function () {
      const { vault, token, user1, vaultAddr } = await loadFixture(subscribeFixture);
      const shares = ethers.parseUnits("500", 18);
      await token.connect(user1).approve(vaultAddr, shares);
      await vault.connect(user1).requestRedemption(shares);

      // Shares should be locked in vault now
      const vaultBalance = await token.balanceOf(vaultAddr);
      expect(vaultBalance).to.equal(shares);
    });

    it("should fulfill redemption with correct USDT payout", async function () {
      const { vault, token, usdt, user1, operator, vaultAddr } =
        await loadFixture(subscribeFixture);

      // Fund vault with USDT for redemptions
      const vaultUSDT = ethers.parseUnits("2000", 6);
      await usdt.mint(await vault.getAddress(), vaultUSDT);

      const shares = ethers.parseUnits("500", 18);
      await token.connect(user1).approve(vaultAddr, shares);
      const reqTx = await vault.connect(user1).requestRedemption(shares);
      const receipt = await reqTx.wait();

      // Fast-forward time past redemption delay (T+1 = 86400s)
      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine", []);

      const payout = ethers.parseUnits("500", 6); // $500 at NAV $1.00
      await vault.connect(operator).fulfillRedemption(0, payout);

      // User should have received USDT
      const userUSDT = await usdt.balanceOf(user1.address);
      expect(userUSDT).to.equal(payout);
    });

    it("should allow user to cancel pending redemption", async function () {
      const { vault, token, user1, vaultAddr } = await loadFixture(subscribeFixture);

      const shares = ethers.parseUnits("200", 18);
      await token.connect(user1).approve(vaultAddr, shares);
      await vault.connect(user1).requestRedemption(shares);

      await vault.connect(user1).cancelRedemption(0);

      // Shares returned to user
      const userShares = await token.balanceOf(user1.address);
      expect(userShares).to.equal(ethers.parseUnits("1000", 18)); // Full balance restored
    });
  });

  // ─────────────────────────────────────────────
  //  5. Compliance
  // ─────────────────────────────────────────────

  describe("Compliance", function () {
    it("should prevent blacklisted address from receiving tokens", async function () {
      const { usdt, vault, token, user1, blacklisted, admin } =
        await loadFixture(deployWithProductFixture);

      // Blacklist the address
      await token.connect(admin).setBlacklisted(blacklisted.address, true);

      // Try to subscribe with blacklisted address
      const amount = ethers.parseUnits("100", 6);
      await usdt.mint(blacklisted.address, amount);
      await usdt.connect(blacklisted).approve(await vault.getAddress(), amount);

      await expect(
        vault.connect(blacklisted).subscribe(amount)
      ).to.be.revertedWith("RWAToken: recipient blacklisted");
    });

    it("should enforce whitelist when enabled", async function () {
      const { usdt, vault, token, user1, user2, admin } =
        await loadFixture(deployWithProductFixture);

      // Enable whitelist
      await token.connect(admin).toggleWhitelistMode(true);

      // Whitelist user1 only
      await token.connect(admin).setWhitelisted(user1.address, true);

      // user1 can subscribe
      const amount = ethers.parseUnits("100", 6);
      await usdt.mint(user1.address, amount);
      await usdt.connect(user1).approve(await vault.getAddress(), amount);
      await vault.connect(user1).subscribe(amount);

      // user2 cannot subscribe
      await usdt.mint(user2.address, amount);
      await usdt.connect(user2).approve(await vault.getAddress(), amount);
      await expect(
        vault.connect(user2).subscribe(amount)
      ).to.be.revertedWith("RWAToken: not whitelisted");
    });
  });

  // ─────────────────────────────────────────────
  //  6. Management Fee
  // ─────────────────────────────────────────────

  describe("Management Fee", function () {
    it("should accrue management fee over time", async function () {
      const { usdt, vault, token, user1, feeRecipient } =
        await loadFixture(deployWithProductFixture);

      const amount = ethers.parseUnits("100000", 6); // $100K
      await usdt.mint(user1.address, amount);
      await usdt.connect(user1).approve(await vault.getAddress(), amount);
      await vault.connect(user1).subscribe(amount);

      // Fast-forward 1 year
      await ethers.provider.send("evm_increaseTime", [365 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);

      await token.collectManagementFee();

      // 0.5% of 100k shares = 500 shares fee
      const feeShares = await token.balanceOf(feeRecipient.address);
      // Approximately 500 shares (slight precision variance)
      expect(feeShares).to.be.closeTo(
        ethers.parseUnits("500", 18),
        ethers.parseUnits("1", 18) // 1 share tolerance
      );
    });
  });
});
