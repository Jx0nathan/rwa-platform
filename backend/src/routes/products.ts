import { Router, Request, Response, NextFunction } from "express";
import { ethers } from "ethers";
import { getProvider, getContracts, getTokenContract } from "../utils/contracts";

export const productRoutes = Router();
const provider = getProvider();

/**
 * GET /api/v1/products
 * List all active RWA products with live NAV and key metrics.
 */
productRoutes.get("/", async (_req: Request, res: Response, next: NextFunction) => {
  try {
    const { factory, navOracle } = await getContracts(provider);
    const productIds: string[] = await factory.getAllProductIds();

    const products = await Promise.all(
      productIds.map(async (id) => {
        const p = await factory.getProduct(id);
        if (!p.active) return null;

        let navData = null;
        let totalSupply = "0";
        let totalAssets = "0";

        try {
          navData = await navOracle.getLatestNAV(p.token);
          const token = getTokenContract(p.token, provider);
          totalSupply = ethers.formatUnits(await token.totalSupply(), 18);
          totalAssets = ethers.formatUnits(await token.totalAssets(), 6);
        } catch (_) {}

        return {
          productId: p.productId,
          strategyType: p.strategyType,
          token: p.token,
          vault: p.vault,
          nav: navData ? {
            value: ethers.formatUnits(navData.nav, 18),
            updatedAt: new Date(Number(navData.timestamp) * 1000).toISOString(),
            stale: !navData.valid,
          } : null,
          tvl: {
            shares: totalSupply,
            usd: totalAssets,
          },
          deployedAt: new Date(Number(p.deployedAt) * 1000).toISOString(),
        };
      })
    );

    res.json({ products: products.filter(Boolean) });
  } catch (err) {
    next(err);
  }
});

/**
 * GET /api/v1/products/:id
 * Full product details including SPV metadata and vault state.
 */
productRoutes.get("/:id", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const { factory, navOracle } = await getContracts(provider);
    const p = await factory.getProduct(req.params.id);

    if (!p.token || p.token === ethers.ZeroAddress) {
      return res.status(404).json({ error: "Product not found" });
    }

    const token = getTokenContract(p.token, provider);
    const [name, symbol, totalSupply, navData, twap] = await Promise.all([
      token.name(),
      token.symbol(),
      token.totalSupply(),
      navOracle.getLatestNAV(p.token),
      navOracle.getTWAP(p.token),
    ]);

    res.json({
      productId: p.productId,
      name,
      symbol,
      strategyType: p.strategyType,
      token: p.token,
      vault: p.vault,
      nav: {
        spot: ethers.formatUnits(navData.nav, 18),
        twap: ethers.formatUnits(twap, 18),
        updatedAt: new Date(Number(navData.timestamp) * 1000).toISOString(),
      },
      totalSupply: ethers.formatUnits(totalSupply, 18),
      deployedAt: new Date(Number(p.deployedAt) * 1000).toISOString(),
    });
  } catch (err) {
    next(err);
  }
});
