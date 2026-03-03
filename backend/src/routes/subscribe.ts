import { Router, Request, Response, NextFunction } from "express";
import { ethers } from "ethers";
import { z } from "zod";
import { getProvider, getContracts, getVaultContract } from "../utils/contracts";

export const subscribeRoutes = Router();
const provider = getProvider();

const SubscribeSchema = z.object({
  productId:     z.string().min(1),
  amount:        z.string().min(1),  // USDT amount as string (6 decimals)
  walletAddress: z.string().regex(/^0x[0-9a-fA-F]{40}$/),
});

/**
 * POST /api/v1/subscribe
 *
 * Returns unsigned transaction calldata.
 * The frontend broadcasts and signs this — we never touch private keys.
 *
 * Two-step:
 *   1. USDT approve(vault, amount) — if not already approved
 *   2. vault.subscribe(amount)
 */
subscribeRoutes.post("/", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const parsed = SubscribeSchema.safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({ error: parsed.error.flatten() });
    }

    const { productId, amount, walletAddress } = parsed.data;
    const { factory } = await getContracts(provider);
    const product = await factory.getProduct(productId);

    if (!product.token || product.token === ethers.ZeroAddress) {
      return res.status(404).json({ error: "Product not found" });
    }
    if (!product.active) {
      return res.status(400).json({ error: "Product is not active" });
    }

    const amountBN = ethers.parseUnits(amount, 6); // USDT 6 decimals

    // Build vault.subscribe() calldata
    const vaultIface = new ethers.Interface([
      "function subscribe(uint256 assets) returns (uint256)",
    ]);
    const subscribeData = vaultIface.encodeFunctionData("subscribe", [amountBN]);

    // Build USDT approve calldata
    const usdtAddress = process.env.USDT_ADDRESS!;
    const erc20Iface = new ethers.Interface([
      "function approve(address spender, uint256 amount) returns (bool)",
    ]);
    const approveData = erc20Iface.encodeFunctionData("approve", [product.vault, amountBN]);

    // Estimate gas
    let estimatedGas = "100000";
    try {
      const vaultContract = getVaultContract(product.vault, provider as any);
      const gasEst = await vaultContract.subscribe.estimateGas(amountBN, {
        from: walletAddress,
      });
      estimatedGas = gasEst.toString();
    } catch (_) {}

    res.json({
      steps: [
        {
          step: 1,
          description: "Approve USDT spending",
          to: usdtAddress,
          data: approveData,
          value: "0",
        },
        {
          step: 2,
          description: `Subscribe to ${productId}`,
          to: product.vault,
          data: subscribeData,
          value: "0",
          estimatedGas,
        },
      ],
      meta: {
        productId,
        amount: amount,
        vault: product.vault,
        token: product.token,
      },
    });
  } catch (err) {
    next(err);
  }
});
