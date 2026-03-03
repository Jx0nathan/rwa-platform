package com.rwaplatform.controller;

import com.rwaplatform.service.ProductService;
import com.rwaplatform.util.ContractUtils;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.web3j.abi.FunctionEncoder;
import org.web3j.abi.TypeReference;
import org.web3j.abi.datatypes.Address;
import org.web3j.abi.datatypes.Bool;
import org.web3j.abi.datatypes.Function;
import org.web3j.abi.datatypes.generated.Uint256;
import org.web3j.crypto.Credentials;
import org.web3j.crypto.RawTransaction;
import org.web3j.crypto.TransactionEncoder;
import org.web3j.protocol.Web3j;
import org.web3j.protocol.core.DefaultBlockParameterName;
import org.web3j.protocol.core.methods.response.EthSendTransaction;
import org.web3j.utils.Numeric;

import java.math.BigInteger;
import java.util.List;
import java.util.Map;

/**
 * 管理员接口（需要 X-Admin-Key Header，由 SecurityConfig 过滤器验证）。
 *
 * 功能：
 *   - 手动推送 NAV（当自动推送失败时）
 *   - 确认大幅 NAV 偏差（confirmLargeDeviation）
 *   - 手动结算指定赎回申请
 */
@Slf4j
@RestController
@RequestMapping("/api/v1/admin")
@RequiredArgsConstructor
public class AdminController {

    private final Web3j          web3j;
    private final ProductService productService;
    private final Credentials    operatorCredentials;

    @org.springframework.beans.factory.annotation.Value("${rwa.nav-oracle-address}")
    private String navOracleAddress;

    // ─────────────────────────────────────────────
    //  POST /api/v1/admin/nav-update
    // ─────────────────────────────────────────────

    @PostMapping("/nav-update")
    public ResponseEntity<?> navUpdate(@RequestBody Map<String, Object> body) {
        String productId = (String) body.get("productId");
        String navStr    = (String) body.get("nav");
        boolean force    = Boolean.TRUE.equals(body.get("forceConfirm"));

        if (productId == null || navStr == null) {
            return ResponseEntity.badRequest().body(Map.of("error", "productId 和 nav 为必填项"));
        }

        Map<String, String> info = productService.getProductAddresses(productId);
        if (info.isEmpty()) return ResponseEntity.notFound().build();

        BigInteger navWei;
        try {
            navWei = new java.math.BigDecimal(navStr)
                    .movePointRight(18)
                    .setScale(0, java.math.RoundingMode.DOWN)
                    .toBigIntegerExact();
        } catch (Exception e) {
            return ResponseEntity.badRequest().body(Map.of("error", "nav 格式不合法"));
        }

        try {
            String tokenAddress = info.get("token");
            String calldata;

            if (force) {
                // confirmLargeDeviation(address, uint256)
                Function fn = new Function(
                        "confirmLargeDeviation",
                        List.of(new Address(tokenAddress), new Uint256(navWei)),
                        List.of()
                );
                calldata = FunctionEncoder.encode(fn);
            } else {
                calldata = ContractUtils.encodeUpdateNAV(tokenAddress, navWei);
            }

            String txHash = sendTransaction(navOracleAddress, calldata);
            log.info("[Admin] NAV 更新成功 产品={} nav={} force={} tx={}", productId, navStr, force, txHash);
            return ResponseEntity.ok(Map.of("success", true, "txHash", txHash, "nav", navStr));

        } catch (Exception e) {
            log.error("[Admin] NAV 更新失败: {}", e.getMessage());
            return ResponseEntity.internalServerError().body(Map.of("error", e.getMessage()));
        }
    }

    // ─────────────────────────────────────────────
    //  POST /api/v1/admin/fulfill-redemption
    // ─────────────────────────────────────────────

    @PostMapping("/fulfill-redemption")
    public ResponseEntity<?> fulfillRedemption(@RequestBody Map<String, Object> body) {
        String productId  = (String) body.get("productId");
        Object reqIdObj   = body.get("requestId");
        String usdtStr    = (String) body.get("usdtAmount");

        if (productId == null || reqIdObj == null || usdtStr == null) {
            return ResponseEntity.badRequest().body(Map.of("error", "productId、requestId、usdtAmount 为必填项"));
        }

        Map<String, String> info = productService.getProductAddresses(productId);
        if (info.isEmpty()) return ResponseEntity.notFound().build();

        try {
            BigInteger requestId  = new BigInteger(reqIdObj.toString());
            BigInteger usdtAmount = ContractUtils.parseUsdt(usdtStr);
            String vaultAddress   = info.get("vault");

            String calldata = ContractUtils.encodeFulfillRedemption(requestId, usdtAmount);
            String txHash   = sendTransaction(vaultAddress, calldata);

            log.info("[Admin] 赎回结算成功 requestId={} usdtAmount={} tx={}", requestId, usdtStr, txHash);
            return ResponseEntity.ok(Map.of("success", true, "txHash", txHash, "requestId", requestId));

        } catch (Exception e) {
            log.error("[Admin] 赎回结算失败: {}", e.getMessage());
            return ResponseEntity.internalServerError().body(Map.of("error", e.getMessage()));
        }
    }

    // ─────────────────────────────────────────────
    //  健康检查
    // ─────────────────────────────────────────────

    @GetMapping("/health")
    public ResponseEntity<?> health() throws Exception {
        BigInteger blockNumber = web3j.ethBlockNumber().send().getBlockNumber();
        return ResponseEntity.ok(Map.of(
                "status", "ok",
                "chainBlock", blockNumber.toString(),
                "timestamp", java.time.Instant.now().toString()
        ));
    }

    // ─────────────────────────────────────────────
    //  内部：发送签名交易
    // ─────────────────────────────────────────────

    private String sendTransaction(String to, String calldata) throws Exception {
        if (operatorCredentials == null) throw new IllegalStateException("运营私钥未配置");

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
        return sent.getTransactionHash();
    }
}
