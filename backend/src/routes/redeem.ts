import { Router, Request, Response, NextFunction } from "express";
import { ethers } from "ethers";
import { z } from "zod";
import { getProvider, getContracts, getTokenContract } from "../utils/contracts";

export const redeemRoutes = Router();
const provider = getProvider();

const RedeemSchema = z.object({
  productId:     z.string().min(1),
  shares:        z.string().min(1),  // Share amount (18 decimals string)
  walletAddress: z.string().regex(/^0x[0-9a-fA-F]{40}$/),
});

/**
 * POST /api/v1/redeem
 * Returns unsigned calldata for:
 *   1. rwaToken.approve(vault, shares)
 *   2. vault.requestRedemption(shares)
 */
redeemRoutes.post("/", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const parsed = RedeemSchema.safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({ error: parsed.error.flatten() });
    }

    const { productId, shares, walletAddress } = parsed.data;
    const { factory, navOracle } = await getContracts(provider);
    const product = await factory.getProduct(productId);

    if (!product.token || product.token === ethers.ZeroAddress) {
      return res.status(404).json({ error: "Product not found" });
    }

    const sharesBN = ethers.parseUnits(shares, 18);

    // Check user balance
    const token = getTokenContract(product.token, provider);
    const balance: bigint = await token.balanceOf(walletAddress);
    if (balance < sharesBN) {
      return res.status(400).json({
        error: "Insufficient shares",
        available: ethers.formatUnits(balance, 18),
        requested: shares,
      });
    }

    // Estimate redemption value at current NAV
    const estimatedUSDT: bigint = await token.convertToAssets(sharesBN);
    const navData = await navOracle.getLatestNAV(product.token);

    // Build calldata
    const erc20Iface = new ethers.Interface([
      "function approve(address spender, uint256 amount) returns (bool)",
    ]);
    const vaultIface = new ethers.Interface([
      "function requestRedemption(uint256 shares) returns (uint256)",
    ]);

    res.json({
      steps: [
        {
          step: 1,
          description: "Approve RWAToken for vault",
          to: product.token,
          data: erc20Iface.encodeFunctionData("approve", [product.vault, sharesBN]),
          value: "0",
        },
        {
          step: 2,
          description: "Request redemption",
          to: product.vault,
          data: vaultIface.encodeFunctionData("requestRedemption", [sharesBN]),
          value: "0",
        },
      ],
      estimate: {
        shares,
        estimatedUSDT: ethers.formatUnits(estimatedUSDT, 6),
        navAtRequest: ethers.formatUnits(navData.nav, 18),
        settlementNote: "Actual payout reflects NAV at time of settlement",
      },
    });
  } catch (err) {
    next(err);
  }
});

/**
 * GET /api/v1/redeem/pending/:wallet
 * List all pending redemptions for a wallet.
 */
redeemRoutes.get("/pending/:wallet", async (req: Request, res: Response, next: NextFunction) => {
  try {
    if (!/^0x[0-9a-fA-F]{40}$/.test(req.params.wallet)) {
      return res.status(400).json({ error: "Invalid wallet address" });
    }

    const { factory } = await getContracts(provider);
    const productIds: string[] = await factory.getAllProductIds();
    const pending: object[] = [];

    for (const id of productIds) {
      const p = await factory.getProduct(id);
      if (!p.active) continue;

      try {
        const vaultABI = [
          "function getPendingRedemptions(address user) view returns (uint256[], tuple(address,uint256,uint256,uint256,uint8,uint256)[])",
          "function redemptionDelay() view returns (uint256)",
        ];
        const vault = new ethers.Contract(p.vault, vaultABI, provider);
        const [ids, reqs] = await vault.getPendingRedemptions(req.params.wallet);
        const delay: bigint = await vault.redemptionDelay();

        for (let i = 0; i < ids.length; i++) {
          const req_r = reqs[i];
          const readyAt = Number(req_r[2]) + Number(delay);
          pending.push({
            productId: id,
            requestId: ids[i].toString(),
            shares: ethers.formatUnits(req_r[1], 18),
            requestedAt: new Date(Number(req_r[2]) * 1000).toISOString(),
            readyAt: new Date(readyAt * 1000).toISOString(),
            isReady: Math.floor(Date.now() / 1000) >= readyAt,
          });
        }
      } catch (_) {}
    }

    res.json({ pending });
  } catch (err) {
    next(err);
  }
});
