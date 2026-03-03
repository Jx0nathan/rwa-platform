package com.rwaplatform.controller;

import com.rwaplatform.dto.ProductDto;
import com.rwaplatform.dto.RedeemRequestDto;
import com.rwaplatform.dto.TransactionStepDto;
import com.rwaplatform.service.ProductService;
import com.rwaplatform.util.ContractUtils;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.web3j.protocol.Web3j;

import java.math.BigInteger;
import java.util.List;
import java.util.Map;

@Slf4j
@RestController
@RequestMapping("/api/v1/redeem")
@RequiredArgsConstructor
public class RedeemController {

    private final ProductService productService;
    private final Web3j          web3j;

    private static final String ZERO_ADDR = "0x0000000000000000000000000000000000000000";

    /**
     * POST /api/v1/redeem
     * 返回两步赎回 calldata：
     *   Step 1 — RWAToken.approve(vault, shares)
     *   Step 2 — RWAVault.requestRedemption(shares)
     */
    @PostMapping
    public ResponseEntity<?> redeem(@Valid @RequestBody RedeemRequestDto req) {
        Map<String, String> info = productService.getProductAddresses(req.getProductId());
        if (info.isEmpty()) return ResponseEntity.notFound().build();

        BigInteger sharesWei;
        try {
            sharesWei = ContractUtils.parseShares(req.getShares());
        } catch (Exception e) {
            return ResponseEntity.badRequest().body(Map.of("error", "shares 格式不合法"));
        }

        if (sharesWei.compareTo(BigInteger.ZERO) <= 0) {
            return ResponseEntity.badRequest().body(Map.of("error", "shares 必须大于 0"));
        }

        String tokenAddress = info.get("token");
        String vaultAddress = info.get("vault");

        // 检查余额
        BigInteger balance = BigInteger.ZERO;
        BigInteger estimatedPayout = BigInteger.ZERO;
        try {
            balance = ContractUtils.callUint256(web3j, ZERO_ADDR, tokenAddress,
                    ContractUtils.encodeBalanceOf(req.getWalletAddress()));
            if (balance.compareTo(sharesWei) < 0) {
                return ResponseEntity.badRequest().body(Map.of(
                        "error", "份额余额不足",
                        "available", ContractUtils.formatShares(balance),
                        "requested", req.getShares()
                ));
            }
            estimatedPayout = ContractUtils.callUint256(web3j, ZERO_ADDR, tokenAddress,
                    ContractUtils.encodeConvertToAssets(sharesWei));
        } catch (Exception e) {
            log.warn("[Redeem] 余额检查失败: {}", e.getMessage());
        }

        // 读取当前 NAV
        ProductDto.NavDto nav = productService.getNAV(tokenAddress);
        String navStr = (nav != null) ? nav.getSpot() : "未知";

        String approveData = ContractUtils.encodeApprove(vaultAddress, sharesWei);
        String redeemData  = ContractUtils.encodeRequestRedemption(sharesWei);

        TransactionStepDto response = TransactionStepDto.builder()
                .steps(List.of(
                        TransactionStepDto.Step.builder()
                                .step(1)
                                .description("授权 RWAToken 给 Vault")
                                .to(tokenAddress)
                                .data(approveData)
                                .value("0")
                                .build(),
                        TransactionStepDto.Step.builder()
                                .step(2)
                                .description("提交赎回申请")
                                .to(vaultAddress)
                                .data(redeemData)
                                .value("0")
                                .estimatedGas("120000")
                                .build()
                ))
                .meta(Map.of(
                        "productId",       req.getProductId(),
                        "shares",          req.getShares(),
                        "estimatedUSDT",   ContractUtils.formatUsdt(estimatedPayout),
                        "navAtRequest",    navStr,
                        "settlementNote",  "实际支付金额以结算时 NAV 为准"
                ))
                .build();

        return ResponseEntity.ok(response);
    }

    /**
     * GET /api/v1/redeem/pending/{wallet}
     * 查询钱包的所有待结算赎回申请。
     */
    @GetMapping("/pending/{wallet}")
    public ResponseEntity<?> getPending(@PathVariable String wallet) {
        if (!wallet.matches("^0x[0-9a-fA-F]{40}$")) {
            return ResponseEntity.badRequest().body(Map.of("error", "钱包地址格式不合法"));
        }
        // 实际实现需要扫描链上事件或查询索引数据库
        // 简化返回空列表，生产中接入 Subgraph 或自建事件索引
        return ResponseEntity.ok(Map.of("pending", List.of(), "wallet", wallet));
    }
}
