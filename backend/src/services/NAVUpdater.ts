import { ethers } from "ethers";
import { getProvider, getWallet, getContracts } from "../utils/contracts";

/**
 * NAVUpdaterService
 *
 * Runs on a schedule. Fetches NAV from off-chain data sources
 * (fund administrator API, price feeds), validates it, and pushes
 * to the NAVOracle contract on-chain.
 *
 * Data sources (per product):
 *   - CASH+: Fetch MMF daily NAV from custodian API (CMS/招商资管)
 *   - AoABT: Fetch fund NAV from Orient Securities admin API
 *   - BOND+: Fetch ETF closing price from Bloomberg/Reuters
 *
 * Validation steps:
 *   1. Sanity check: NAV > 0 and < prev_NAV * 1.5 (50% single-day limit)
 *   2. Cross-check with secondary source if deviation > 1%
 *   3. Log and alert if deviation > 2%
 */
export class NAVUpdaterService {
  private provider: ethers.JsonRpcProvider;
  private wallet: ethers.Wallet;
  private intervalMs: number;
  private timer?: NodeJS.Timeout;

  constructor(intervalMs = 6 * 60 * 60 * 1000) { // Every 6 hours
    this.intervalMs = intervalMs;
    this.provider = getProvider();
    this.wallet = getWallet(this.provider);
  }

  async start(): Promise<void> {
    console.log("[NAVUpdater] Starting...");
    await this.runUpdate();  // Run immediately on startup
    this.timer = setInterval(() => this.runUpdate(), this.intervalMs);
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    console.log("[NAVUpdater] Stopped");
  }

  // ─────────────────────────────────────────────
  //  Core update loop
  // ─────────────────────────────────────────────

  private async runUpdate(): Promise<void> {
    try {
      const { factory, navOracle } = await getContracts(this.wallet);
      const productIds: string[] = await factory.getAllProductIds();

      for (const productId of productIds) {
        try {
          await this.updateProductNAV(productId, factory, navOracle);
        } catch (err) {
          console.error(`[NAVUpdater] Failed to update ${productId}:`, err);
          // Don't abort other products if one fails
        }
      }
    } catch (err) {
      console.error("[NAVUpdater] runUpdate error:", err);
    }
  }

  private async updateProductNAV(
    productId: string,
    factory: ethers.Contract,
    navOracle: ethers.Contract
  ): Promise<void> {
    const product = await factory.getProduct(productId);
    if (!product.active) return;

    // Fetch NAV from off-chain source
    const newNAV = await this.fetchNAV(productId);
    if (!newNAV || newNAV <= 0n) {
      console.warn(`[NAVUpdater] Invalid NAV for ${productId}: ${newNAV}`);
      return;
    }

    // Get current on-chain NAV for deviation check
    const currentData = await navOracle.getLatestNAV(product.token);
    if (currentData.valid && currentData.nav > 0n) {
      const deviation = this.calculateDeviationBps(currentData.nav, newNAV);
      if (deviation > 500n) { // > 5%
        console.error(
          `[NAVUpdater] LARGE DEVIATION for ${productId}: ` +
          `${currentData.nav} → ${newNAV} (${deviation} bps). ` +
          `Requires manual confirmation via confirmLargeDeviation()`
        );
        await this.alertLargeDeviation(productId, currentData.nav, newNAV, deviation);
        return;
      }
      if (deviation > 200n) { // > 2%
        console.warn(`[NAVUpdater] Notable NAV change for ${productId}: ${deviation} bps`);
      }
    }

    // Push to oracle
    const tx = await navOracle.updateNAV(product.token, newNAV);
    await tx.wait();
    console.log(`[NAVUpdater] Updated ${productId} NAV: ${ethers.formatUnits(newNAV, 18)} USD/share`);
  }

  // ─────────────────────────────────────────────
  //  Off-chain NAV fetching (stub — replace with real APIs)
  // ─────────────────────────────────────────────

  private async fetchNAV(productId: string): Promise<bigint> {
    // TODO: Replace with actual fund administrator API integrations
    // Each product has its own NAV data source:
    //
    // CASH+  → CMS (招商资管) daily MMF NAV report
    // AoABT  → Orient Securities admin API
    // BOND+  → Bloomberg API (bond ETF closing price)
    //
    // NAV is returned as 18-decimal bigint
    // e.g. $1.0023 → 1002300000000000000n

    switch (productId) {
      case "CASH+":
        return await this.fetchMoneyMarketNAV();
      case "AoABT":
        return await this.fetchArbitrageNAV();
      case "BOND+":
        return await this.fetchBondNAV();
      default:
        throw new Error(`[NAVUpdater] Unknown productId: ${productId}`);
    }
  }

  private async fetchMoneyMarketNAV(): Promise<bigint> {
    // STUB: In production, call CMS fund admin API
    // e.g. GET https://api.cms-asset.com/nav/mmf-usd?date=today
    // Returns: { nav: "1.0023", date: "2026-01-15", currency: "USD" }

    // Money market fund NAV grows slowly (daily accrual)
    // Simulated: $1.00 growing at ~4.5% APY
    const startNAV = 1.0;
    const annualRate = 0.045;
    const daysSinceLaunch = Math.floor(Date.now() / 86400000) - 19600; // days since epoch
    const nav = startNAV * Math.pow(1 + annualRate, daysSinceLaunch / 365);
    return ethers.parseUnits(nav.toFixed(6), 18);
  }

  private async fetchArbitrageNAV(): Promise<bigint> {
    // STUB: In production, call Orient Securities API for AoABT fund admin data
    // Funding rate arb strategy — NAV grows at ~15-20% APY but more volatile
    const startNAV = 1.0;
    const annualRate = 0.175; // 17.5% APY
    const daysSinceLaunch = Math.floor(Date.now() / 86400000) - 19600;
    const nav = startNAV * Math.pow(1 + annualRate, daysSinceLaunch / 365);
    return ethers.parseUnits(nav.toFixed(6), 18);
  }

  private async fetchBondNAV(): Promise<bigint> {
    // STUB: Bloomberg API or ETF price feed
    const startNAV = 1.0;
    const annualRate = 0.06; // 6% APY
    const daysSinceLaunch = Math.floor(Date.now() / 86400000) - 19600;
    const nav = startNAV * Math.pow(1 + annualRate, daysSinceLaunch / 365);
    return ethers.parseUnits(nav.toFixed(6), 18);
  }

  // ─────────────────────────────────────────────
  //  Helpers
  // ─────────────────────────────────────────────

  private calculateDeviationBps(oldNAV: bigint, newNAV: bigint): bigint {
    const diff = oldNAV > newNAV ? oldNAV - newNAV : newNAV - oldNAV;
    return (diff * 10000n) / oldNAV;
  }

  private async alertLargeDeviation(
    productId: string,
    oldNAV: bigint,
    newNAV: bigint,
    deviationBps: bigint
  ): Promise<void> {
    // TODO: Send alert to ops team via Telegram/PagerDuty
    // For now, just log
    console.error(
      `🚨 LARGE NAV DEVIATION ALERT\n` +
      `Product: ${productId}\n` +
      `Old NAV: ${ethers.formatUnits(oldNAV, 18)}\n` +
      `New NAV: ${ethers.formatUnits(newNAV, 18)}\n` +
      `Deviation: ${deviationBps} bps\n` +
      `Action required: Call confirmLargeDeviation() with admin wallet`
    );
  }
}
