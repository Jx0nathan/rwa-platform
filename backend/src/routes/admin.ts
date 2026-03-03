import { Router, Request, Response, NextFunction } from "express";
import { ethers } from "ethers";
import { z } from "zod";
import { getProvider, getWallet, getContracts } from "../utils/contracts";

export const adminRoutes = Router();

// Simple API key auth for admin routes
const adminAuth = (req: Request, res: Response, next: NextFunction) => {
  const key = req.headers["x-admin-key"];
  if (!key || key !== process.env.ADMIN_API_KEY) {
    return res.status(401).json({ error: "Unauthorized" });
  }
  next();
};

adminRoutes.use(adminAuth);

/**
 * POST /api/v1/admin/nav-update
 * Manually push a NAV update for a specific product.
 * Used when automated oracle service fails or for large-deviation confirmations.
 */
adminRoutes.post("/nav-update", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const schema = z.object({
      productId: z.string(),
      nav: z.string(),        // NAV value as string, e.g. "1.0045"
      forceConfirm: z.boolean().optional(), // Use confirmLargeDeviation if true
    });

    const parsed = schema.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: parsed.error.flatten() });

    const provider = getProvider();
    const wallet = getWallet(provider);
    const { factory, navOracle } = await getContracts(wallet);

    const product = await factory.getProduct(parsed.data.productId);
    if (!product.token) return res.status(404).json({ error: "Product not found" });

    const navBN = ethers.parseUnits(parsed.data.nav, 18);

    let tx;
    if (parsed.data.forceConfirm) {
      tx = await navOracle.confirmLargeDeviation(product.token, navBN);
    } else {
      tx = await navOracle.updateNAV(product.token, navBN);
    }

    const receipt = await tx.wait();
    res.json({ success: true, txHash: receipt.hash, productId: parsed.data.productId, nav: parsed.data.nav });
  } catch (err) {
    next(err);
  }
});

/**
 * POST /api/v1/admin/fulfill-redemption
 * Manually fulfill a specific redemption request.
 */
adminRoutes.post("/fulfill-redemption", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const schema = z.object({
      productId:  z.string(),
      requestId:  z.number(),
      usdtAmount: z.string(), // USDT amount with 6 decimals as string
    });

    const parsed = schema.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: parsed.error.flatten() });

    const provider = getProvider();
    const wallet = getWallet(provider);
    const { factory } = await getContracts(wallet);

    const product = await factory.getProduct(parsed.data.productId);
    const vaultABI = ["function fulfillRedemption(uint256 requestId, uint256 usdtAmount)"];
    const vault = new ethers.Contract(product.vault, vaultABI, wallet);

    const usdtBN = ethers.parseUnits(parsed.data.usdtAmount, 6);
    const tx = await vault.fulfillRedemption(parsed.data.requestId, usdtBN);
    const receipt = await tx.wait();

    res.json({ success: true, txHash: receipt.hash, requestId: parsed.data.requestId });
  } catch (err) {
    next(err);
  }
});
