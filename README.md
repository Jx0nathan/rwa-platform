# RWA Platform

> 链上真实世界资产（RWA）代币化基础设施，支持任意 EVM 兼容链。

---

## 技术栈

| 层 | 技术 |
|---|---|
| 智能合约 | Solidity 0.8.20 + **Foundry** |
| 合约库 | OpenZeppelin Contracts v5（git submodule） |
| 后端 API | **Java 21 + Spring Boot 3.2 + Web3j** |
| 构建工具 | Maven |
| 支持链 | 任意 EVM 兼容链（Ethereum、Polygon、Arbitrum 等） |

---

## 产品线

| 产品 | 类型 | 目标 APY | 最低认购 | 赎回周期 |
|---|---|---|---|---|
| **CASH+** | 货币市场基金 | 4–5% | 无限制 | T+1 |
| **AoABT** | 资金费率套利基金 | 12–18% | $100,000 USDT | T+7 |
| **BOND+** | 债券 ETF | 5–7% | $1,000 USDT | T+3 |

---

## 目录结构

```
rwa-platform/
├── contracts/
│   ├── core/
│   │   ├── NAVOracle.sol        # NAV 预言机（TWAP + 偏差保护 + 36h 过期）
│   │   ├── RWAToken.sol         # ERC-20 份额代币（NAV 定价 + 合规控制）
│   │   ├── RWAVault.sol         # 认购/赎回 Vault（队列 + 流动性准备金）
│   │   ├── RWAFactory.sol       # 产品一键部署工厂
│   │   └── SPVRegistry.sol      # SPV 法律实体注册表（IPFS 审计报告）
│   ├── interfaces/
│   └── mocks/
│       └── MockERC20.sol        # 测试用 USDT
├── test/
│   └── RWAPlatform.t.sol        # Foundry 测试（8 个测试组 + Fuzz）
├── script/
│   └── Deploy.s.sol             # Foundry 部署脚本
├── lib/
│   └── openzeppelin-contracts/  # git submodule
├── backend/
│   ├── pom.xml                  # Maven 构建文件
│   └── src/main/java/com/rwaplatform/
│       ├── RwaPlatformApplication.java
│       ├── controller/          # REST API 控制器
│       ├── service/             # 业务逻辑 + 后台定时任务
│       ├── dto/                 # 请求/响应数据类
│       ├── config/              # Web3j、安全配置
│       └── util/                # ABI 编解码工具
├── foundry.toml                 # Foundry 配置
├── PRD.md                       # 产品需求文档
└── .env.example                 # 环境变量模板
```

---

## 快速开始

### 1. 安装 Foundry

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### 2. 安装合约依赖（OpenZeppelin）

```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.0.0 --no-commit
```

### 3. 编译合约

```bash
forge build
```

### 4. 运行测试

```bash
# 运行所有测试
forge test -vvv

# 运行指定测试
forge test --match-test test_Subscribe_CorrectSharesAtParNAV -vvvv

# 运行 Fuzz 测试
forge test --match-test testFuzz -vvv
```

### 5. 本地部署

```bash
# 启动本地 anvil 节点
anvil

# 新终端执行部署（使用 anvil 默认账户）
forge script script/Deploy.s.sol \
  --rpc-url http://localhost:8545 \
  --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

### 6. 部署至主网/测试网

```bash
# 配置环境变量
cp .env.example .env
# 填写 RPC_URL、DEPLOYER_PRIVATE_KEY 等

forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify \
  --private-key $DEPLOYER_PRIVATE_KEY \
  -vvvv
```

---

## 后端 API

### 启动（开发模式）

```bash
cd backend

# 配置环境变量
export RPC_URL=http://localhost:8545
export FACTORY_ADDRESS=0x...
export NAV_ORACLE_ADDRESS=0x...
export OPERATOR_PRIVATE_KEY=0x...

mvn spring-boot:run
```

### 打包运行

```bash
cd backend
mvn clean package
java -jar target/rwa-platform-backend-0.1.0.jar
```

### API 端点

```
GET  /api/v1/products              # 产品列表
GET  /api/v1/products/{id}         # 产品详情
GET  /api/v1/positions/{wallet}    # 持仓查询
POST /api/v1/subscribe             # 认购（返回待签名 calldata）
POST /api/v1/redeem                # 赎回申请
GET  /api/v1/redeem/pending/{w}    # 待结算赎回
POST /api/v1/admin/nav-update      # 手动推送 NAV（需要 X-Admin-Key）
POST /api/v1/admin/fulfill-redemption  # 手动结算赎回（需要 X-Admin-Key）
GET  /api/v1/admin/health          # 节点健康检查
GET  /healthz                      # 服务健康检查
```

### 认购示例

```bash
curl -X POST http://localhost:8080/api/v1/subscribe \
  -H "Content-Type: application/json" \
  -d '{
    "productId": "CASH+",
    "amount": "1000.000000",
    "walletAddress": "0xYourWallet"
  }'
```

返回两步待签名交易（approve + subscribe），由前端签名广播。

---

## 合约设计

### NAV 定价公式

```
份额数 = 存入金额(6位) × 1e12 × 1e18 / 当前 NAV(18位)
美元估值 = 份额数 × 当前 NAV / (1e18 × 1e12)
```

### 预言机安全机制

| 机制 | 参数 |
|---|---|
| TWAP 窗口 | 最近 3 次观测均值 |
| 偏差保护 | > 5%（500 BPS）需管理员调用 `confirmLargeDeviation()` |
| 过期阈值 | 36 小时未更新标记为无效 |

### 角色权限

| 角色 | 权限 |
|---|---|
| `ADMIN_ROLE` | 暂停合约、配置参数、确认大幅 NAV 偏差 |
| `VAULT_ROLE` | 铸造/销毁 RWAToken |
| `ORACLE_NODE_ROLE` | 推送 NAV |
| `COMPLIANCE_ROLE` | 黑名单/白名单管理 |
| `OPERATOR_ROLE` | 赎回结算、流动性管理 |

---

## License

MIT
