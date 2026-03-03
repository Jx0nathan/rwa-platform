package com.rwaplatform.controller;

import com.rwaplatform.dto.SubscribeRequestDto;
import com.rwaplatform.dto.TransactionStepDto;
import com.rwaplatform.service.ProductService;
import com.rwaplatform.util.ContractUtils;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.math.BigInteger;
import java.util.List;
import java.util.Map;

/**
 * 认购接口。
 *
 * 返回两步待签名交易：
 *   Step 1 — USDT.approve(vault, amount)
 *   Step 2 — RWAVault.subscribe(amount)
 *
 * 后端不持有私钥；前端（钱包/SDK）负责签名和广播。
 */
@Slf4j
@RestController
@RequestMapping("/api/v1/subscribe")
@RequiredArgsConstructor
public class SubscribeController {

    private final ProductService productService;

    @Value("${rwa.usdt-address}")
    private String usdtAddress;

    @PostMapping
    public ResponseEntity<?> subscribe(@Valid @RequestBody SubscribeRequestDto req) {
        Map<String, String> info = productService.getProductAddresses(req.getProductId());

        if (info.isEmpty()) {
            return ResponseEntity.notFound().build();
        }
        if (!"true".equals(info.get("active"))) {
            return ResponseEntity.badRequest().body(Map.of("error", "产品未激活"));
        }

        BigInteger amountWei;
        try {
            amountWei = ContractUtils.parseUsdt(req.getAmount());
        } catch (Exception e) {
            return ResponseEntity.badRequest().body(Map.of("error", "amount 格式不合法: " + e.getMessage()));
        }

        if (amountWei.compareTo(BigInteger.ZERO) <= 0) {
            return ResponseEntity.badRequest().body(Map.of("error", "amount 必须大于 0"));
        }

        String vaultAddress = info.get("vault");

        // Step 1：USDT approve
        String approveData = ContractUtils.encodeApprove(vaultAddress, amountWei);

        // Step 2：subscribe
        String subscribeData = ContractUtils.encodeSubscribe(amountWei);

        TransactionStepDto response = TransactionStepDto.builder()
                .steps(List.of(
                        TransactionStepDto.Step.builder()
                                .step(1)
                                .description("授权 USDT 给 Vault 合约")
                                .to(usdtAddress)
                                .data(approveData)
                                .value("0")
                                .build(),
                        TransactionStepDto.Step.builder()
                                .step(2)
                                .description("认购 " + req.getProductId())
                                .to(vaultAddress)
                                .data(subscribeData)
                                .value("0")
                                .estimatedGas("150000")
                                .build()
                ))
                .meta(Map.of(
                        "productId",  req.getProductId(),
                        "amount",     req.getAmount(),
                        "vault",      vaultAddress,
                        "token",      info.get("token")
                ))
                .build();

        log.info("[Subscribe] 用户 {} 认购产品 {} 金额 {} USDT",
                req.getWalletAddress(), req.getProductId(), req.getAmount());

        return ResponseEntity.ok(response);
    }
}
