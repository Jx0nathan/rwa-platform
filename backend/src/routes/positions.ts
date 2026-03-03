import { Router, Request, Response, NextFunction } from "express";
import { ethers } from "ethers";
import { getProvider, getContracts, getTokenContract } from "../utils/contracts";

export const positionRoutes = Router();
const provider = getProvider();

/**
 * GET /api/v1/positions/:wallet
 * All RWA token holdings for a wallet with current USD value.
 */
positionRoutes.get("/:wallet", async (req: Request, res: Response, next: NextFunction) => {
  try {
    if (!/^0x[0-9a-fA-F]{40}$/.test(req.params.wallet)) {
      return res.status(400).json({ error: "Invalid wallet address" });
    }

    const wallet = req.params.wallet;
    const { factory, navOracle } = await getContracts(provider);
    const productIds: string[] = await factory.getAllProductIds();

    const positions = await Promise.all(
      productIds.map(async (id) => {
        const p = await factory.getProduct(id);
        if (!p.active) return null;

        const token = getTokenContract(p.token, provider);
        const balance: bigint = await token.balanceOf(wallet);
        if (balance === 0n) return null;

        const navData = await navOracle.getLatestNAV(p.token);
        const usdValue: bigint = await token.convertToAssets(balance);

        return {
          productId: id,
          token: p.token,
          shares: ethers.formatUnits(balance, 18),
          nav: ethers.formatUnits(navData.nav, 18),
          usdValue: ethers.formatUnits(usdValue, 6),
          navUpdatedAt: new Date(Number(navData.timestamp) * 1000).toISOString(),
        };
      })
    );

    const filtered = positions.filter(Boolean);
    const totalUSD = filtered.reduce((sum, p) => sum + parseFloat(p!.usdValue), 0);

    res.json({
      wallet,
      positions: filtered,
      totalUSD: totalUSD.toFixed(6),
    });
  } catch (err) {
    next(err);
  }
});
