import express from "express";
import cors from "cors";
import dotenv from "dotenv";
import { productRoutes } from "./routes/products";
import { positionRoutes } from "./routes/positions";
import { subscribeRoutes } from "./routes/subscribe";
import { redeemRoutes } from "./routes/redeem";
import { adminRoutes } from "./routes/admin";
import { errorHandler } from "./middleware/errorHandler";
import { requestLogger } from "./middleware/requestLogger";
import { NAVUpdaterService } from "./services/NAVUpdater";
import { RedemptionProcessorService } from "./services/RedemptionProcessor";

dotenv.config();

const app = express();
const PORT = process.env.PORT || 3000;

// ─────────────────────────────────────────────
//  Middleware
// ─────────────────────────────────────────────
app.use(cors());
app.use(express.json());
app.use(requestLogger);

// ─────────────────────────────────────────────
//  Routes
// ─────────────────────────────────────────────
app.use("/api/v1/products",   productRoutes);
app.use("/api/v1/positions",  positionRoutes);
app.use("/api/v1/subscribe",  subscribeRoutes);
app.use("/api/v1/redeem",     redeemRoutes);
app.use("/api/v1/admin",      adminRoutes);

app.get("/healthz", (_req, res) => {
  res.json({ status: "ok", timestamp: new Date().toISOString() });
});

app.use(errorHandler);

// ─────────────────────────────────────────────
//  Background Services
// ─────────────────────────────────────────────
const navUpdater = new NAVUpdaterService();
const redemptionProcessor = new RedemptionProcessorService();

async function startServices() {
  try {
    await navUpdater.start();
    await redemptionProcessor.start();
    console.log("[services] NAV updater and redemption processor started");
  } catch (err) {
    console.error("[services] Failed to start background services:", err);
  }
}

// ─────────────────────────────────────────────
//  Start
// ─────────────────────────────────────────────
app.listen(PORT, async () => {
  console.log(`[server] RWA Platform API running on port ${PORT}`);
  await startServices();
});

export default app;
