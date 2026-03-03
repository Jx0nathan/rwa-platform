# RWA Platform — Product Requirements Document

> Version: 1.0 | Status: Draft | Author: Jx0nathan

---

## 1. Vision & Positioning

**One-line**: A permissionless RWA-as-a-Service platform that turns traditional financial strategies into composable, yield-bearing on-chain assets.

**Core Thesis**: The first wave of RWA was about putting assets on-chain. The second wave is about making those assets *do something* — generating verifiable, sustainable yield that DeFi users can trust without reading a 50-page prospectus.

**Not building**: Another static tokenization wrapper.  
**Building**: On-chain yield infrastructure where every product has a transparent NAV, a real redemption path, and a verifiable underlying strategy.

---

## 2. Problem Statement

| Pain Point | Who Feels It | Current Workaround |
|---|---|---|
| $300B+ stablecoin supply earns ~0% | DeFi users | Manual bridging to CeFi |
| Institutional yield strategies inaccessible to retail | Retail investors | Can't access (min $1M+) |
| RWA tokens illiquid after issuance | RWA holders | Wait and hope |
| Asset managers can't reach on-chain capital | TradFi funds | None |
| No standard for on-chain fund compliance | Regulators | Manual compliance checks |

---

## 3. Product Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    USER INTERFACES                        │
│         Web App  │  API  │  DeFi Protocol Integration    │
└──────────────────────────┬───────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────┐
│                   PLATFORM LAYER                          │
│   Product Registry │ NAV Engine │ Compliance Module       │
└──────────────────────────┬───────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────┐
│                   SMART CONTRACT LAYER                    │
│  RWAFactory │ RWAVault │ RWAToken │ NAVOracle            │
└──────────────────────────┬───────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────┐
│                OFF-CHAIN ASSET LAYER                      │
│    SPV  │  Custodian  │  Fund Administrator  │  Auditor   │
└──────────────────────────────────────────────────────────┘
```

---

## 4. Product Lines (MVP → V2)

### 4.1 CASH+ (MVP)

**What**: Money market fund token, pegged 1:1 to USD, backed by US T-Bills + high-grade agency paper.

| Attribute | Value |
|---|---|
| Target yield | 4–5% APY |
| Redemption | T+1 (24h) |
| Minimum | None (permissionless) |
| KYC | None for < $10K, soft KYC above |
| Token standard | ERC-20 (NAV-based) |
| Underlying | USD money market fund managed by licensed asset manager |
| Chain | HashKey Chain (primary) + Ethereum (L1 bridge) |

**User Flow**:
```
User deposits USDT → Vault contract routes to custodian → 
Custodian buys T-Bills → NAV oracle updates price → 
User receives CASH+ tokens at current NAV
```

### 4.2 AoABT — Funding Rate Arbitrage Fund (V1)

**What**: Tokenized hedge fund capturing funding rate spread between CEX perpetuals and spot.

| Attribute | Value |
|---|---|
| Target yield | 12–18% APY |
| Strategy | Long spot + Short perp, delta-neutral |
| Historical drawdown | < 1% (5y backtest) |
| Minimum | $100,000 USDT (professional investor) |
| Redemption | T+7 (weekly) |
| Token standard | ERC-20 (NAV-based, variable price) |

### 4.3 BOND+ (V1)

**What**: Tokenized bond ETF exposure.

| Attribute | Value |
|---|---|
| Target yield | 5–7% APY |
| Minimum | $1,000 USDT |
| Redemption | T+3 |

### 4.4 EQUITY+ (V2)

**What**: Tokenized US equity ETF — 24/7 trading on-chain.

### 4.5 PRIVATE+ (V2)

**What**: Tokenized private equity fund shares. Institutional-only, locked 2-year minimum.

---

## 5. Core Technical Requirements

### 5.1 Smart Contracts

#### RWAToken
- ERC-20 compatible
- NAV-priced: token value = totalAssets / totalSupply
- Minting controlled by RWAVault only
- Role-based access control (RBAC)
- Pausable (emergency stop)
- Blacklist/whitelist support for compliance

#### RWAVault
- Accept USDT/USDC deposits
- Mint RWAToken proportional to current NAV
- Handle redemption queue (T+1 to T+7 depending on product)
- Emergency withdrawal mechanism
- Fee calculation (management fee, performance fee)

#### NAVOracle
- Accept price updates from authorized oracle nodes
- TWAP calculation (prevent flash loan manipulation)
- Heartbeat check (revert if price stale > 24h)
- Multi-sig update for large NAV deviations (> 5%)

#### RWAFactory
- Deploy new product vaults permissionlessly (within approved asset classes)
- Register products on-chain
- Emit events for indexers

#### SPVRegistry
- Map each product to its legal SPV entity
- Store custodian, auditor, fund admin addresses (off-chain identifiers)
- Compliance attestation timestamps

### 5.2 NAV Calculation (Off-Chain)

```
NAV = (Cash + MarketValueOfAssets - Liabilities - AccruedFees) / TotalShares

Updated: Every 24h (business days) via oracle push
Emergency update: If NAV deviates > 3% intraday
```

### 5.3 Redemption Engine

```
T+0: User submits redemption request on-chain
T+0: Vault locks tokens, emits RedemptionQueued event
T+0 → T+N: Backend processes redemption off-chain (sells assets)
T+N: Backend calls fulfillRedemption(), transfers USDT to user
T+N: Tokens burned
```

### 5.4 Compliance Module

- Jurisdiction blocklist (OFAC, etc.)
- Wallet screening via Chainalysis API hook
- Transaction size limits per tier
- KYC tier thresholds configurable per product

---

## 6. API Specification

### Products

```
GET /api/v1/products
→ List all active products with current NAV, APY, TVL

GET /api/v1/products/:id
→ Full product details including underlying asset breakdown

GET /api/v1/products/:id/nav-history
→ Historical NAV data (daily, up to 2 years)
```

### Positions

```
GET /api/v1/positions/:wallet
→ All RWA token balances for a wallet with USD value

GET /api/v1/positions/:wallet/yield-history
→ Yield earned over time
```

### Transactions

```
POST /api/v1/subscribe
Body: { productId, amount, walletAddress }
→ Returns: tx calldata to sign and broadcast

POST /api/v1/redeem
Body: { productId, shares, walletAddress }
→ Returns: tx calldata + estimated settlement time

GET /api/v1/transactions/:wallet
→ Transaction history
```

### Admin (Permissioned)

```
POST /api/v1/admin/nav-update
→ Push new NAV to oracle contract

POST /api/v1/admin/fulfill-redemptions
→ Batch fulfill pending redemptions
```

---

## 7. User Stories

### Retail User (DeFi native)
```
As a DeFi user with idle USDC,
I want to deposit into CASH+ and earn 4-5% yield
without reading any legal documents or completing KYC
so that my stablecoins work for me 24/7.
```

### Professional Investor
```
As an accredited investor,
I want to access the AoABT funding rate arbitrage strategy
with a minimum of $100K USDT
so that I can earn institutional-grade returns on-chain
with full transparency of the underlying strategy.
```

### DeFi Protocol (B2B)
```
As a lending protocol,
I want to accept CASH+ tokens as collateral
because they are yield-bearing, low-volatility assets
that improve the capital efficiency of my protocol.
```

### Asset Manager
```
As a traditional fund manager,
I want to tokenize my money market fund
using this platform's SPV + smart contract framework
so that I can reach on-chain capital without building
my own blockchain infrastructure.
```

---

## 8. Risk Framework

| Risk | Mitigation |
|---|---|
| Smart contract exploit | Audit (2 independent firms) + bug bounty |
| Oracle manipulation | TWAP + multi-sig for large updates |
| Custodian failure | Bankruptcy-remote SPV + insurance |
| Liquidity crisis (redemption rush) | Redemption queue + liquidity reserve (10% of TVL) |
| Regulatory action | Jurisdiction filters + legal opinions per market |
| NAV calculation error | Dual calculation (on-chain + off-chain cross-check) |

---

## 9. Milestones

| Phase | Target | Key Deliverable |
|---|---|---|
| MVP | Month 1-2 | CASH+ live on testnet, full audit |
| V1 | Month 3-4 | AoABT + BOND+ live on mainnet (HashKey Chain) |
| V1.5 | Month 5-6 | DeFi protocol integrations (Aave-style lending) |
| V2 | Month 7-9 | EQUITY+ + multi-chain (Ethereum L1) |
| V3 | Month 10-12 | Permissionless asset manager onboarding |

---

## 10. Success Metrics

| Metric | 6-Month Target |
|---|---|
| TVL | $10M |
| Active wallets | 1,000 |
| Products live | 3 (CASH+, AoABT, BOND+) |
| DeFi protocol integrations | 2 |
| Redemption SLA breach rate | < 1% |
| Smart contract incidents | 0 |
