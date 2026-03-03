// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/core/NAVOracle.sol";
import "../contracts/core/RWAFactory.sol";
import "../contracts/core/SPVRegistry.sol";
import "../contracts/mocks/MockERC20.sol";

/**
 * @title Deploy
 * @notice 全套部署脚本（Foundry Script）
 *
 * 使用方法：
 *   forge script script/Deploy.s.sol \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --private-key $DEPLOYER_PRIVATE_KEY \
 *     -vvvv
 *
 * 环境变量：
 *   DEPLOYER_PRIVATE_KEY  — 部署账户私钥
 *   ORACLE_NODE           — 预言机节点地址（可选，默认用 deployer）
 *   VAULT_OPERATOR        — Vault 运营账户地址
 *   FEE_RECIPIENT         — 管理费收款地址
 *   USDT_ADDRESS          — USDT 合约地址（本地测试时留空，自动部署 MockERC20）
 */
contract Deploy is Script {

    function run() external {
        // ─── 读取环境变量 ─────────────────────────
        address deployer      = msg.sender;
        address oracleNode    = vm.envOr("ORACLE_NODE",     deployer);
        address vaultOperator = vm.envOr("VAULT_OPERATOR",  deployer);
        address feeRecipient  = vm.envOr("FEE_RECIPIENT",   deployer);
        address usdtAddr      = vm.envOr("USDT_ADDRESS",    address(0));
        bool    isLocalnet    = (block.chainid == 31337);

        console.log("===========================================");
        console.log("RWA Platform Deployment");
        console.log("===========================================");
        console.log("Chain ID:       ", block.chainid);
        console.log("Deployer:       ", deployer);
        console.log("Oracle Node:    ", oracleNode);
        console.log("Vault Operator: ", vaultOperator);
        console.log("Fee Recipient:  ", feeRecipient);

        vm.startBroadcast();

        // ─── USDT ─────────────────────────────────
        if (usdtAddr == address(0) || isLocalnet) {
            MockERC20 mockUSDT = new MockERC20("USD Tether", "USDT", 6);
            usdtAddr = address(mockUSDT);
            console.log("MockUSDT:       ", usdtAddr);
        } else {
            console.log("USDT:           ", usdtAddr);
        }

        // ─── 1. NAVOracle ─────────────────────────
        NAVOracle navOracle = new NAVOracle(deployer);
        navOracle.grantRole(keccak256("ORACLE_NODE_ROLE"), oracleNode);
        console.log("NAVOracle:      ", address(navOracle));

        // ─── 2. RWAFactory ────────────────────────
        RWAFactory factory = new RWAFactory(address(navOracle), usdtAddr, deployer);
        console.log("RWAFactory:     ", address(factory));

        // ─── 3. SPVRegistry ───────────────────────
        SPVRegistry spvRegistry = new SPVRegistry(deployer);
        console.log("SPVRegistry:    ", address(spvRegistry));

        // ─── 4. CASH+ ─────────────────────────────
        console.log("\nDeploying CASH+...");
        (address cashPlusToken, address cashPlusVault) = factory.deployProduct(
            RWAFactory.ProductConfig({
                name:             "CASH+ USD Money Market Fund",
                symbol:           "CASH+",
                productId:        "CASH+",
                strategyType:     "money-market",
                redemptionDelay:  1 days,
                minSubscription:  0,
                managementFeeBps: 50,          // 0.5%
                feeRecipient:     feeRecipient,
                spvAddress:       address(0)
            }),
            vaultOperator
        );
        console.log("CASH+ Token:    ", cashPlusToken);
        console.log("CASH+ Vault:    ", cashPlusVault);

        // 初始化 NAV $1.00（仅本地或 oracleNode == deployer）
        if (oracleNode == deployer) {
            navOracle.updateNAV(cashPlusToken, 1e18);
            console.log("CASH+ NAV initialized: $1.00");
        }

        // ─── 5. AoABT ─────────────────────────────
        console.log("\nDeploying AoABT...");
        (address aoabtToken, address aoabtVault) = factory.deployProduct(
            RWAFactory.ProductConfig({
                name:             "AoABT Funding Rate Arbitrage Fund",
                symbol:           "AoABT",
                productId:        "AoABT",
                strategyType:     "funding-rate-arb",
                redemptionDelay:  7 days,
                minSubscription:  100_000 * 1e6, // $100K USDT
                managementFeeBps: 100,            // 1%
                feeRecipient:     feeRecipient,
                spvAddress:       address(0)
            }),
            vaultOperator
        );
        console.log("AoABT Token:    ", aoabtToken);
        console.log("AoABT Vault:    ", aoabtVault);

        if (oracleNode == deployer) {
            navOracle.updateNAV(aoabtToken, 1e18);
            console.log("AoABT NAV initialized: $1.00");
        }

        vm.stopBroadcast();

        // ─── 输出部署摘要 ─────────────────────────
        console.log("\n===========================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("===========================================");
        console.log("Copy these into your .env:");
        console.log("");
        console.log("NAV_ORACLE_ADDRESS=", address(navOracle));
        console.log("FACTORY_ADDRESS=",    address(factory));
        console.log("SPV_REGISTRY_ADDRESS=",address(spvRegistry));
        console.log("USDT_ADDRESS=",       usdtAddr);
    }
}
