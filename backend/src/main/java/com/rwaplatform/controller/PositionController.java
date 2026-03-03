package com.rwaplatform.controller;

import com.rwaplatform.dto.PositionDto;
import com.rwaplatform.service.ProductService;
import com.rwaplatform.util.ContractUtils;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.web3j.protocol.Web3j;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.math.RoundingMode;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

@Slf4j
@RestController
@RequestMapping("/api/v1/positions")
@RequiredArgsConstructor
public class PositionController {

    private final Web3j          web3j;
    private final ProductService productService;

    private static final String ZERO_ADDR = "0x0000000000000000000000000000000000000000";

    /**
     * 查询钱包持有的所有 RWA 代币及当前美元估值。
     */
    @GetMapping("/{wallet}")
    public ResponseEntity<?> getPositions(@PathVariable String wallet) {
        if (!wallet.matches("^0x[0-9a-fA-F]{40}$")) {
            return ResponseEntity.badRequest().body(Map.of("error", "钱包地址格式不合法"));
        }

        List<PositionDto.Position> positions = new ArrayList<>();
        BigDecimal totalUSD = BigDecimal.ZERO;

        for (String productId : productService.getAllProductIds()) {
            Map<String, String> info = productService.getProductAddresses(productId);
            if (info.isEmpty() || !"true".equals(info.get("active"))) continue;

            String tokenAddress = info.get("token");
            try {
                BigInteger balance = ContractUtils.callUint256(
                        web3j, ZERO_ADDR, tokenAddress,
                        ContractUtils.encodeBalanceOf(wallet)
                );
                if (balance.compareTo(BigInteger.ZERO) == 0) continue;

                BigInteger usdValue = ContractUtils.callUint256(
                        web3j, ZERO_ADDR, tokenAddress,
                        ContractUtils.encodeConvertToAssets(balance)
                );

                ProductDto.NavDto nav = productService.getNAV(tokenAddress);
                String updatedAt = nav != null ? nav.getUpdatedAt() : null;
                String navSpot   = nav != null ? nav.getSpot() : "0";

                String usdStr = ContractUtils.formatUsdt(usdValue);
                totalUSD = totalUSD.add(new BigDecimal(usdStr));

                positions.add(PositionDto.Position.builder()
                        .productId(productId)
                        .token(tokenAddress)
                        .shares(ContractUtils.formatShares(balance))
                        .nav(navSpot)
                        .usdValue(usdStr)
                        .navUpdatedAt(updatedAt)
                        .build());

            } catch (Exception e) {
                log.warn("[PositionController] 读取 {} 余额失败: {}", productId, e.getMessage());
            }
        }

        return ResponseEntity.ok(PositionDto.builder()
                .wallet(wallet)
                .positions(positions)
                .totalUSD(totalUSD.setScale(6, RoundingMode.DOWN).toPlainString())
                .build());
    }
}
