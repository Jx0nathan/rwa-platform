import { ethers } from "ethers";
import { getProvider, getWallet, getContracts } from "../utils/contracts";

/**
 * RedemptionProcessorService
 *
 * Scans on-chain for pending redemption requests that are past their
 * redemption delay, then fulfills them.
 *
 * Steps per redemption:
 *   1. Detect RedemptionRequested events (on-chain or via DB cache)
 *   2. Wait until requestedAt + redemptionDelay
 *   3. Check vault has enough USDT liquidity
 *   4. If not enough liquidity: trigger off-chain asset sale via custodian API
 *   5. Wait for custodian to wire USDT to vault wallet
 *   6. Call vault.depositLiquidity() to fund the vault
 *   7. Call vault.fulfillRedemption(requestId, actualAmount)
 */
export class RedemptionProcessorService {
  private provider: ethers.JsonRpcProvider;
  private wallet: ethers.Wallet;
  private intervalMs: number;
  private timer?: NodeJS.Timeout;

  constructor(intervalMs = 5 * 60 * 1000) { // Every 5 minutes
    this.intervalMs = intervalMs;
    this.provider = getProvider();
    this.wallet = getWallet(this.provider);
  }

  async start(): Promise<void> {
    console.log("[RedemptionProcessor] Starting...");
    this.timer = setInterval(() => this.processPending(), this.intervalMs);
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
  }

  private async processPending(): Promise<void> {
    try {
      const { factory } = await getContracts(this.wallet);
      const productIds: string[] = await factory.getAllProductIds();

      for (const productId of productIds) {
        try {
          const product = await factory.getProduct(productId);
          if (!product.active) continue;
          await this.processProductRedemptions(product.vault);
        } catch (err) {
          console.error(`[RedemptionProcessor] Error for ${productId}:`, err);
        }
      }
    } catch (err) {
      console.error("[RedemptionProcessor] processPending error:", err);
    }
  }

  private async processProductRedemptions(vaultAddress: string): Promise<void> {
    const vaultABI = [
      "function redemptionDelay() view returns (uint256)",
      "event RedemptionRequested(uint256 indexed requestId, address indexed user, uint256 shares, uint256 estimatedNAV)",
      "function redemptionRequests(uint256) view returns (address requester, uint256 shares, uint256 requestedAt, uint256 estimatedNAV, uint8 status, uint256 fulfilledAmount)",
      "function fulfillRedemption(uint256 requestId, uint256 usdtAmount) external",
      "function vaultLiquidity() view returns (uint256)",
      "function depositLiquidity(uint256 amount) external",
    ];

    const vault = new ethers.Contract(vaultAddress, vaultABI, this.wallet);

    // Scan recent RedemptionRequested events (last 10k blocks)
    const latestBlock = await this.provider.getBlockNumber();
    const fromBlock = Math.max(0, latestBlock - 10000);

    const filter = vault.filters.RedemptionRequested();
    const events = await vault.queryFilter(filter, fromBlock, latestBlock);

    const delay: bigint = await vault.redemptionDelay();
    const now = BigInt(Math.floor(Date.now() / 1000));

    for (const event of events) {
      const parsedLog = vault.interface.parseLog({
        topics: event.topics as string[],
        data: event.data,
      });
      if (!parsedLog) continue;

      const requestId: bigint = parsedLog.args[0];

      try {
        const req = await vault.redemptionRequests(requestId);
        if (req.status !== 0n) continue; // Not Pending (0 = Pending)
        if (now < req.requestedAt + delay) continue; // Not ready yet

        const estimatedPayout = await this.calculatePayout(vaultAddress, req.shares);
        await this.ensureLiquidity(vault, estimatedPayout, vaultAddress);

        const tx = await vault.fulfillRedemption(requestId, estimatedPayout);
        await tx.wait();
        console.log(
          `[RedemptionProcessor] Fulfilled requestId=${requestId} ` +
          `for ${req.requester}, payout=${ethers.formatUnits(estimatedPayout, 6)} USDT`
        );
      } catch (err) {
        console.error(`[RedemptionProcessor] Failed to fulfill requestId=${requestId}:`, err);
      }
    }
  }

  /**
   * Calculate actual USDT payout at current NAV.
   * This may differ from estimatedNAV at time of request.
   */
  private async calculatePayout(vaultAddress: string, shares: bigint): Promise<bigint> {
    // Fetch token address from vault, then get current NAV
    const vaultABI = [
      "function rwaToken() view returns (address)",
    ];
    const tokenABI = [
      "function convertToAssets(uint256 shares) view returns (uint256)",
    ];

    const vault = new ethers.Contract(vaultAddress, vaultABI, this.provider);
    const tokenAddress: string = await vault.rwaToken();
    const token = new ethers.Contract(tokenAddress, tokenABI, this.provider);

    return await token.convertToAssets(shares);
  }

  /**
   * If vault doesn't have enough USDT, wire from custodian.
   */
  private async ensureLiquidity(
    vault: ethers.Contract,
    required: bigint,
    vaultAddress: string
  ): Promise<void> {
    const available: bigint = await vault.vaultLiquidity();
    if (available >= required) return;

    const shortfall = required - available;
    console.log(
      `[RedemptionProcessor] Vault short ${ethers.formatUnits(shortfall, 6)} USDT. ` +
      `Requesting custodian wire...`
    );

    // TODO: Call custodian API to initiate USDT transfer to vault
    // e.g. POST https://custody-api.bank.com/transfer
    //      { from: "spv-account", to: vaultAddress, amount: shortfall }
    //
    // After custodian processes (T+0 to T+1), they'll send USDT to
    // a hot wallet controlled by the operator, which then calls
    // vault.depositLiquidity(amount) to fund the vault.
    //
    // For now, we throw so the operator is alerted.
    throw new Error(
      `[RedemptionProcessor] Insufficient vault liquidity for ${vaultAddress}. ` +
      `Shortfall: ${ethers.formatUnits(shortfall, 6)} USDT. ` +
      `Manual custodian wire required.`
    );
  }
}
