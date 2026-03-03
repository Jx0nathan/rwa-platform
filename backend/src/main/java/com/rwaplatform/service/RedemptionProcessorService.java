package com.rwaplatform.service;

import com.rwaplatform.util.ContractUtils;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.web3j.abi.FunctionEncoder;
import org.web3j.abi.FunctionReturnDecoder;
import org.web3j.abi.TypeReference;
import org.web3j.abi.datatypes.*;
import org.web3j.abi.datatypes.generated.Uint256;
import org.web3j.crypto.Credentials;
import org.web3j.crypto.RawTransaction;
import org.web3j.crypto.TransactionEncoder;
import org.web3j.protocol.Web3j;
import org.web3j.protocol.core.DefaultBlockParameterName;
import org.web3j.protocol.core.methods.request.Transaction;
import org.web3j.protocol.core.methods.response.EthSendTransaction;
import org.web3j.utils.Numeric;

import java.math.BigInteger;
import java.util.List;
import java.util.Map;

/**
 * 赎回自动结算服务。
 *
 * 每 5 分钟扫描所有产品 Vault 上的 pending 赎回请求，
 * 对已过期（requestedAt + redemptionDelay < now）的请求自动结算。
 *
 * 结算流程：
 *   1. 计算当前 NAV 下的 USDT 应付金额
 *   2. 检查 vault USDT 余额是否充足
 *   3. 充足 → 调用 fulfillRedemption()
 *   4. 不足 → 记录告警，等待托管行打款
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class RedemptionProcessorService {

    private final Web3j          web3j;
    private final ProductService productService;
    private final Credentials    operatorCredentials;

    private static final String ZERO_ADDR = "0x0000000000000000000000000000000000000000";

    // ─────────────────────────────────────────────
    //  定时任务：每 5 分钟
    // ─────────────────────────────────────────────

    @Scheduled(fixedDelayString = "${rwa.redemption-check-interval-ms}")
    public void processPending() {
        if (operatorCredentials == null) return;

        List<String> productIds = productService.getAllProductIds();
        for (String productId : productIds) {
            try {
                Map<String, String> info = productService.getProductAddresses(productId);
                if (info.isEmpty() || !"true".equals(info.get("active"))) continue;
                processVaultRedemptions(productId, info.get("vault"), info.get("token"));
            } catch (Exception e) {
                log.error("[RedemptionProcessor] 产品 {} 处理失败: {}", productId, e.getMessage());
            }
        }
    }

    // ─────────────────────────────────────────────
    //  处理单个 Vault 的赎回队列
    // ─────────────────────────────────────────────

    private void processVaultRedemptions(String productId, String vaultAddress, String tokenAddress)
            throws Exception {

        // 读取 redemptionDelay
        BigInteger delay = readRedemptionDelay(vaultAddress);
        long now = System.currentTimeMillis() / 1000;

        // 扫描链上 RedemptionRequested 事件（简化：扫描最近 10000 个区块）
        // 生产环境中应使用事件索引（Subgraph 或自建数据库）
        BigInteger latestBlock = web3j.ethBlockNumber().send().getBlockNumber();
        BigInteger fromBlock   = latestBlock.subtract(BigInteger.valueOf(10_000)).max(BigInteger.ZERO);

        // 用 eth_getLogs 获取 RedemptionRequested 事件
        // event RedemptionRequested(uint256 indexed requestId, address indexed user, uint256 shares, uint256 estimatedNAV)
        String eventSignature = "0x" + org.web3j.crypto.Hash.sha3String(
                "RedemptionRequested(uint256,address,uint256,uint256)"
        ).substring(2);

        List<org.web3j.protocol.core.methods.response.Log> logs = web3j.ethGetLogs(
                new org.web3j.protocol.core.methods.request.EthFilter(
                        org.web3j.protocol.core.DefaultBlockParameter.valueOf(fromBlock),
                        DefaultBlockParameterName.LATEST,
                        vaultAddress
                ).addSingleTopic(eventSignature)
        ).send().getLogs()
         .stream()
         .map(r -> (org.web3j.protocol.core.methods.response.Log) r)
         .toList();

        log.debug("[RedemptionProcessor] 产品 {} 发现 {} 条赎回事件", productId, logs.size());

        for (org.web3j.protocol.core.methods.response.Log evtLog : logs) {
            // requestId 是 indexed 参数（topics[1]）
            BigInteger requestId = Numeric.toBigInt(evtLog.getTopics().get(1));
            tryFulfill(productId, vaultAddress, tokenAddress, requestId, delay, now);
        }
    }

    private void tryFulfill(String productId, String vaultAddress, String tokenAddress,
                            BigInteger requestId, BigInteger delay, long now) {
        try {
            // 读取赎回请求详情
            RedemptionRequest req = readRedemptionRequest(vaultAddress, requestId);
            if (req == null)              return;
            if (req.status != 0)          return; // 非 Pending（0）
            if (now < req.requestedAt + delay.longValue()) return; // 未到结算时间

            // 计算应付 USDT
            BigInteger payout = ContractUtils.callUint256(
                    web3j, ZERO_ADDR, tokenAddress,
                    ContractUtils.encodeConvertToAssets(req.shares)
            );

            // 检查 vault 余额
            BigInteger vaultBalance = ContractUtils.callUint256(
                    web3j, ZERO_ADDR, vaultAddress,
                    encodeVaultLiquidity()
            );

            if (vaultBalance.compareTo(payout) < 0) {
                log.error("[RedemptionProcessor] 产品 {} requestId={} vault 余额不足！" +
                        "需要 {} USDT，当前 {} USDT。等待托管行打款。",
                        productId, requestId,
                        ContractUtils.formatUsdt(payout),
                        ContractUtils.formatUsdt(vaultBalance));
                return;
            }

            // 发送 fulfillRedemption 交易
            String calldata = ContractUtils.encodeFulfillRedemption(requestId, payout);
            sendTransaction(vaultAddress, calldata);

            log.info("[RedemptionProcessor] ✅ 产品 {} requestId={} 结算完成，支付 {} USDT",
                    productId, requestId, ContractUtils.formatUsdt(payout));

        } catch (Exception e) {
            log.error("[RedemptionProcessor] requestId={} 处理异常: {}", requestId, e.getMessage());
        }
    }

    // ─────────────────────────────────────────────
    //  链上读取辅助方法
    // ─────────────────────────────────────────────

    private BigInteger readRedemptionDelay(String vaultAddress) throws Exception {
        Function fn = new Function("redemptionDelay", List.of(), List.of(new TypeReference<Uint256>() {}));
        return ContractUtils.callUint256(web3j, ZERO_ADDR, vaultAddress, FunctionEncoder.encode(fn));
    }

    private String encodeVaultLiquidity() {
        Function fn = new Function("vaultLiquidity", List.of(), List.of(new TypeReference<Uint256>() {}));
        return FunctionEncoder.encode(fn);
    }

    private RedemptionRequest readRedemptionRequest(String vaultAddress, BigInteger requestId)
            throws Exception {
        Function fn = new Function(
                "redemptionRequests",
                List.of(new Uint256(requestId)),
                List.of(
                        new TypeReference<Address>() {},   // requester
                        new TypeReference<Uint256>() {},   // shares
                        new TypeReference<Uint256>() {},   // requestedAt
                        new TypeReference<Uint256>() {},   // estimatedNAV
                        new TypeReference<org.web3j.abi.datatypes.generated.Uint8>() {},  // status
                        new TypeReference<Uint256>() {}    // fulfilledAmount
                )
        );
        org.web3j.protocol.core.methods.response.EthCall result = web3j.ethCall(
                Transaction.createEthCallTransaction(ZERO_ADDR, vaultAddress, FunctionEncoder.encode(fn)),
                DefaultBlockParameterName.LATEST
        ).send();

        if (result.hasError()) return null;
        List<Type> decoded = FunctionReturnDecoder.decode(result.getValue(), fn.getOutputParameters());
        if (decoded.size() < 6) return null;

        RedemptionRequest req = new RedemptionRequest();
        req.requester   = decoded.get(0).getValue().toString();
        req.shares      = (BigInteger) decoded.get(1).getValue();
        req.requestedAt = ((BigInteger) decoded.get(2).getValue()).longValue();
        req.status      = ((BigInteger) decoded.get(4).getValue()).intValue();
        return req;
    }

    private void sendTransaction(String to, String calldata) throws Exception {
        BigInteger nonce    = web3j.ethGetTransactionCount(
                operatorCredentials.getAddress(), DefaultBlockParameterName.PENDING
        ).send().getTransactionCount();
        BigInteger gasPrice = web3j.ethGasPrice().send().getGasPrice();
        BigInteger gasLimit = BigInteger.valueOf(300_000);

        RawTransaction rawTx = RawTransaction.createTransaction(
                nonce, gasPrice, gasLimit, to, BigInteger.ZERO, calldata
        );
        byte[] signed = TransactionEncoder.signMessage(rawTx, operatorCredentials);
        EthSendTransaction sent = web3j.ethSendRawTransaction(Numeric.toHexString(signed)).send();
        if (sent.hasError()) throw new RuntimeException(sent.getError().getMessage());
    }

    // ─────────────────────────────────────────────
    //  内部数据类
    // ─────────────────────────────────────────────

    private static class RedemptionRequest {
        String     requester;
        BigInteger shares;
        long       requestedAt;
        int        status;      // 0=Pending, 1=Fulfilled, 2=Cancelled
    }
}
