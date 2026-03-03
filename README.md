# RWA Platform

> 链上真实世界资产（RWA）代币化基础设施，受 Asseto Finance 架构启发设计。

---

## 项目简介

本项目是一套完整的 RWA 即服务（RWA-as-a-Service）平台，将传统金融产品（货币市场基金、套利基金、债券 ETF）代币化，通过智能合约实现链上认购、赎回与 NAV 定价，部署于 HashKey Chain L2，同时支持以太坊 L1 桥接。

**核心特性：**
- 每个产品独立的 `RWAToken`（ERC-20）+ `RWAVault`（认购/赎回入口）
- NAV 预言机驱动的浮动份额定价（TWAP + 偏差保护）
- 链上 SPV 注册表（法律透明层，含 IPFS 审计报告）
- 完整的合规模块（黑名单/白名单，KYC 分层）
- TypeScript 后端 API + 后台自动 NAV 推送 + 赎回处理服务

---

## 产品线

| 产品 | 类型 | 目标 APY | 最低认购 | 赎回周期 |
|---|---|---|---|---|
| **CASH+** | 货币市场基金 | 4–5% | 无限制 | T+1 |
| **AoABT** | 资金费率套利基金 | 12–18% | $100,000 USDT | T+7 |
| **BOND+** | 债券 ETF | 5–7% | $1,000 USDT | T+3 |
| **EQUITY+** *(V2)* | 美股 ETF | 市场收益 | TBD | T+3 |
| **PRIVATE+** *(V2)* | 私募股权 | TBD | 机构专属 | 锁定 2 年 |

---

## 目录结构

```
rwa-platform/
├── contracts/
│   ├── core/
│   │   ├── NAVOracle.sol        # NAV 预言机（TWAP + 偏差保护 + 36h 过期检查）
│   │   ├── RWAToken.sol         # ERC-20 份额代币（NAV 铸造/销毁 + 合规控制）
│   │   ├── RWAVault.sol         # 认购/赎回 Vault（队列 + 流动性准备金）
│   │   ├── RWAFactory.sol       # 产品一键部署工厂
│   │   └── SPVRegistry.sol      # SPV 法律实体注册表
│   ├── interfaces/
│   │   ├── IRWAToken.sol
│   │   └── INAVOracle.sol
│   └── mocks/
│       └── MockERC20.sol        # 测试用 USDT
├── backend/
│   └── src/
│       ├── index.ts             # API 服务入口
│       ├── routes/              # REST 路由（products / positions / subscribe / redeem / admin）
│       ├── services/
│       │   ├── NAVUpdater.ts    # 定时 NAV 推送服务（每 6 小时）
│       │   └── RedemptionProcessor.ts  # 自动赎回结算服务（每 5 分钟）
│       ├── middleware/
│       └── utils/contracts.ts   # 合约 ABI + Provider 工具
├── test/
│   └── RWAPlatform.test.ts      # Hardhat 集成测试（6 个测试组）
├── scripts/
│   └── deploy.ts                # 全套部署脚本
├── PRD.md                       # 产品需求文档
├── hardhat.config.ts
└── package.json
```

---

## 快速开始

### 1. 安装依赖

```bash
npm install
```

### 2. 配置环境变量

复制示例文件并填写：

```bash
cp .env.example .env
```

```env
# 区块链节点
RPC_URL=https://hashkeychain-testnet.alt.technology

# 部署账户私钥
DEPLOYER_PRIVATE_KEY=0x...
OPERATOR_PRIVATE_KEY=0x...

# 合约地址（部署后填写）
FACTORY_ADDRESS=
NAV_ORACLE_ADDRESS=
USDT_ADDRESS=

# 后端
PORT=3000
ADMIN_API_KEY=your-secret-key
```

### 3. 编译合约

```bash
npx hardhat compile
```

### 4. 运行测试

```bash
npx hardhat test
```

### 5. 本地部署

```bash
# 启动本地节点
npx hardhat node

# 新终端部署
npx hardhat run scripts/deploy.ts --network localhost
```

### 6. 部署至 HashKey Chain 测试网

```bash
npx hardhat run scripts/deploy.ts --network hashkeyTestnet
```

---

## 智能合约设计

### NAV 定价模型

```
份额数 = 存入金额(6位) × 1e12 × 1e18 / 当前 NAV(18位)
资产估值 = 份额数 × 当前 NAV / (1e18 × 1e12)
```

- USDT：6 位小数
- RWAToken 份额：18 位小数
- NAV：18 位小数（1e18 = $1.00）

### 预言机安全机制

| 机制 | 参数 |
|---|---|
| TWAP 窗口 | 最近 3 次观测均值 |
| 偏差保护 | 超过 5%（500 BPS）需管理员多签确认 |
| 过期阈值 | 36 小时未更新标记为无效 |

### 赎回流程

```
用户提交赎回申请
  → 份额锁定至 Vault
  → 后端监听事件
  → 等待赎回延迟期（T+1 至 T+7）
  → 后端调用 fulfillRedemption()
  → 份额销毁，USDT 转回用户
```

### 角色权限

| 角色 | 权限 |
|---|---|
| `ADMIN_ROLE` | 暂停合约、更新配置、确认大幅 NAV 偏差 |
| `VAULT_ROLE` | 铸造/销毁 RWAToken |
| `ORACLE_NODE_ROLE` | 推送 NAV 价格 |
| `COMPLIANCE_ROLE` | 管理黑名单/白名单 |
| `OPERATOR_ROLE` | 结算赎回、管理流动性 |

---

## API 文档

### 查询产品列表

```bash
GET /api/v1/products
```

### 查询持仓

```bash
GET /api/v1/positions/0xYourWallet
```

### 认购（返回待签名交易）

```bash
POST /api/v1/subscribe
{
  "productId": "CASH+",
  "amount": "1000.00",
  "walletAddress": "0x..."
}
```

### 赎回申请

```bash
POST /api/v1/redeem
{
  "productId": "CASH+",
  "shares": "1000.000000000000000000",
  "walletAddress": "0x..."
}
```

---

## 支持网络

| 网络 | Chain ID | 用途 |
|---|---|---|
| HashKey Chain 测试网 | 133 | 开发测试 |
| HashKey Chain 主网 | 177 | 生产部署 |
| 以太坊主网 | 1 | L1 桥接 |
| Localhost (Hardhat) | 31337 | 本地开发 |

---

## License

MIT
