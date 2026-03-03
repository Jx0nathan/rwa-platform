package com.rwaplatform.service;

import com.rwaplatform.util.ContractUtils;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.web3j.crypto.Credentials;
import org.web3j.protocol.Web3j;
import org.web3j.protocol.core.methods.response.EthSendTransaction;
import org.web3j.protocol.core.methods.response.EthGetTransactionReceipt;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.math.RoundingMode;
import java.util.List;
import java.util.Map;

/**
 * NAV 自动推送服务。
 *
 * 每隔 6 小时从链下数据源（基金行政管理人 API）拉取最新 NAV，
 * 验证合理性后推送到链上 NAVOracle 合约。
 *
 * 每个产品有独立的数据源：
 *   CASH+  → 货币市场基金管理人 API（每日 NAV 报告）
 *   AoABT  → 套利基金行政管理人 API
 *   BOND+  → Bloomberg/Reuters 债券 ETF 收盘价
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class NavUpdaterService {

    private final Web3j          web3j;
    private final ProductService productService;
    private final Credentials    operatorCredentials;  // 可能为 null（只读模式）

    @Value("${rwa.nav-oracle-address}")
    private String navOracleAddress;

    // ─────────────────────────────────────────────
    //  定时任务：每 6 小时执行一次
    // ─────────────────────────────────────────────

    @Scheduled(fixedDelayString = "${rwa.nav-update-interval-ms}")
    public void runUpdate() {
        if (operatorCredentials == null) {
            log.warn("[NAVUpdater] 未配置运营私钥，跳过 NAV 推送");
            return;
        }
        log.info("[NAVUpdater] 开始 NAV 更新周期");

        List<String> productIds = productService.getAllProductIds();
        for (String productId : productIds) {
            try {
                updateProductNAV(productId);
            } catch (Exception e) {
                log.error("[NAVUpdater] 产品 {} NAV 更新失败: {}", productId, e.getMessage());
            }
        }
        log.info("[NAVUpdater] NAV 更新周期完成，共处理 {} 个产品", productIds.size());
    }

    // ─────────────────────────────────────────────
    //  单产品 NAV 更新
    // ─────────────────────────────────────────────

    private void updateProductNAV(String productId) throws Exception {
        Map<String, String> info = productService.getProductAddresses(productId);
        if (info.isEmpty() || !"true".equals(info.get("active"))) return;

        String tokenAddress = info.get("token");
        BigInteger newNAV   = fetchNAVFromDataSource(productId);

        if (newNAV == null || newNAV.compareTo(BigInteger.ZERO) <= 0) {
            log.warn("[NAVUpdater] 产品 {} 获取的 NAV 无效，跳过", productId);
            return;
        }

        // 从链上读取当前 NAV，做偏差检查
        BigInteger currentNAV = getCurrentOnChainNAV(tokenAddress);
        if (currentNAV.compareTo(BigInteger.ZERO) > 0) {
            long deviationBps = calculateDeviationBps(currentNAV, newNAV);
            if (deviationBps > 500) {
                log.error("[NAVUpdater] 🚨 产品 {} NAV 偏差过大（{}bps），需要管理员手动确认！", productId, deviationBps);
                sendAlert(productId, currentNAV, newNAV, deviationBps);
                return;
            }
            if (deviationBps > 200) {
                log.warn("[NAVUpdater] 产品 {} NAV 偏差显著（{}bps），注意", productId, deviationBps);
            }
        }

        // 推送链上
        String calldata = ContractUtils.encodeUpdateNAV(tokenAddress, newNAV);
        pushTransaction(calldata);
        log.info("[NAVUpdater] 产品 {} NAV 更新成功: ${}", productId,
                ContractUtils.formatNav(newNAV));
    }

    // ─────────────────────────────────────────────
    //  链下 NAV 数据拉取（待接入真实 API）
    // ─────────────────────────────────────────────

    private BigInteger fetchNAVFromDataSource(String productId) {
        // TODO：接入真实基金行政管理人 API
        //
        // CASH+  → GET https://fund-admin.example.com/nav/mmf-usd?date=today
        // AoABT  → GET https://orient-securities-api.example.com/funds/aoabt/nav
        // BOND+  → GET https://bloomberg-api.example.com/etf/bond-usd/close
        //
        // 返回格式：18位小数 BigInteger（1e18 = $1.00）

        return switch (productId) {
            case "CASH+"  -> simulateMoneyMarketNAV();
            case "AoABT"  -> simulateArbitrageNAV();
            case "BOND+"  -> simulateBondNAV();
            default       -> null;
        };
    }

    /** 货币市场基金：~4.5% APY，线性增长 */
    private BigInteger simulateMoneyMarketNAV() {
        double daysSinceLaunch = (System.currentTimeMillis() / 86_400_000.0) - 19_600;
        double nav = Math.pow(1 + 0.045, daysSinceLaunch / 365.0);
        return toNAVBigInteger(nav);
    }

    /** 资金费率套利：~17.5% APY */
    private BigInteger simulateArbitrageNAV() {
        double daysSinceLaunch = (System.currentTimeMillis() / 86_400_000.0) - 19_600;
        double nav = Math.pow(1 + 0.175, daysSinceLaunch / 365.0);
        return toNAVBigInteger(nav);
    }

    /** 债券 ETF：~6% APY */
    private BigInteger simulateBondNAV() {
        double daysSinceLaunch = (System.currentTimeMillis() / 86_400_000.0) - 19_600;
        double nav = Math.pow(1 + 0.060, daysSinceLaunch / 365.0);
        return toNAVBigInteger(nav);
    }

    private BigInteger toNAVBigInteger(double nav) {
        return new BigDecimal(nav)
                .setScale(18, RoundingMode.DOWN)
                .multiply(new BigDecimal(ContractUtils.ONE_E18))
                .toBigInteger();
    }

    // ─────────────────────────────────────────────
    //  链上读取当前 NAV
    // ─────────────────────────────────────────────

    private BigInteger getCurrentOnChainNAV(String tokenAddress) {
        try {
            // getLatestNAV 返回 (nav, timestamp, valid) 元组
            // 这里简化：直接读 nav()（RWAToken 上的公共方法）
            return ContractUtils.callUint256(
                    web3j,
                    "0x0000000000000000000000000000000000000000",
                    tokenAddress,
                    "0xf0141d84"  // nav() function selector
            );
        } catch (Exception e) {
            log.warn("[NAVUpdater] 读取链上 NAV 失败: {}", e.getMessage());
            return BigInteger.ZERO;
        }
    }

    // ─────────────────────────────────────────────
    //  发送交易
    // ─────────────────────────────────────────────

    private void pushTransaction(String calldata) throws Exception {
        BigInteger nonce     = web3j.ethGetTransactionCount(
                operatorCredentials.getAddress(),
                org.web3j.protocol.core.DefaultBlockParameterName.PENDING
        ).send().getTransactionCount();

        BigInteger gasPrice  = web3j.ethGasPrice().send().getGasPrice();
        BigInteger gasLimit  = BigInteger.valueOf(200_000);

        org.web3j.crypto.RawTransaction rawTx = org.web3j.crypto.RawTransaction.createTransaction(
                nonce, gasPrice, gasLimit, navOracleAddress, BigInteger.ZERO, calldata
        );
        byte[] signed = org.web3j.crypto.TransactionEncoder.signMessage(rawTx, operatorCredentials);
        String hex    = org.web3j.utils.Numeric.toHexString(signed);

        EthSendTransaction sent = web3j.ethSendRawTransaction(hex).send();
        if (sent.hasError()) {
            throw new RuntimeException("交易失败: " + sent.getError().getMessage());
        }
        log.debug("[NAVUpdater] 交易已发送: {}", sent.getTransactionHash());
    }

    // ─────────────────────────────────────────────
    //  辅助
    // ─────────────────────────────────────────────

    private long calculateDeviationBps(BigInteger oldNAV, BigInteger newNAV) {
        BigInteger diff = oldNAV.subtract(newNAV).abs();
        return diff.multiply(BigInteger.valueOf(10_000))
                   .divide(oldNAV)
                   .longValue();
    }

    private void sendAlert(String productId, BigInteger oldNAV, BigInteger newNAV, long bps) {
        // TODO：接入 Telegram/PagerDuty 告警
        log.error("""
                ===== NAV 大幅偏差告警 =====
                产品：{}
                原 NAV：${}
                新 NAV：${}
                偏差：{} bps
                需要：调用 confirmLargeDeviation() 进行管理员确认
                ===========================
                """,
                productId,
                ContractUtils.formatNav(oldNAV),
                ContractUtils.formatNav(newNAV),
                bps);
    }
}
