package com.rwaplatform.service;

import com.rwaplatform.dto.ProductDto;
import com.rwaplatform.util.ContractUtils;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import org.web3j.abi.FunctionEncoder;
import org.web3j.abi.FunctionReturnDecoder;
import org.web3j.abi.TypeReference;
import org.web3j.abi.datatypes.*;
import org.web3j.abi.datatypes.generated.Uint256;
import org.web3j.protocol.Web3j;
import org.web3j.protocol.core.DefaultBlockParameterName;
import org.web3j.protocol.core.methods.request.Transaction;
import org.web3j.protocol.core.methods.response.EthCall;

import java.math.BigInteger;
import java.time.Instant;
import java.util.*;

/**
 * 产品查询服务：从链上读取产品列表、NAV、TVL 等信息。
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class ProductService {

    private final Web3j web3j;

    @Value("${rwa.factory-address}")
    private String factoryAddress;

    @Value("${rwa.nav-oracle-address}")
    private String navOracleAddress;

    // 零地址，用于 eth_call from 字段
    private static final String ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

    // ─────────────────────────────────────────────
    //  获取所有产品 ID
    // ─────────────────────────────────────────────

    @SuppressWarnings("unchecked")
    public List<String> getAllProductIds() {
        try {
            Function fn = new Function(
                    "getAllProductIds",
                    List.of(),
                    List.of(new TypeReference<DynamicArray<Utf8String>>() {})
            );
            String data = FunctionEncoder.encode(fn);
            EthCall result = web3j.ethCall(
                    Transaction.createEthCallTransaction(ZERO_ADDRESS, factoryAddress, data),
                    DefaultBlockParameterName.LATEST
            ).send();

            if (result.hasError() || result.getValue() == null) return List.of();
            List<Type> decoded = FunctionReturnDecoder.decode(
                    result.getValue(),
                    fn.getOutputParameters()
            );
            if (decoded.isEmpty()) return List.of();
            List<Utf8String> strings = (List<Utf8String>) decoded.get(0).getValue();
            return strings.stream().map(s -> (String) s.getValue()).toList();

        } catch (Exception e) {
            log.error("[ProductService] getAllProductIds 失败: {}", e.getMessage());
            return List.of();
        }
    }

    // ─────────────────────────────────────────────
    //  获取产品详情（token 地址、vault 地址、是否活跃）
    // ─────────────────────────────────────────────

    public Map<String, String> getProductAddresses(String productId) {
        try {
            Function fn = new Function(
                    "getProduct",
                    List.of(new Utf8String(productId)),
                    List.of(
                            new TypeReference<Address>() {},  // token
                            new TypeReference<Address>() {},  // vault
                            new TypeReference<Utf8String>() {},// productId
                            new TypeReference<Utf8String>() {},// strategyType
                            new TypeReference<Uint256>() {},   // deployedAt
                            new TypeReference<Bool>() {}       // active
                    )
            );
            String data = FunctionEncoder.encode(fn);
            EthCall result = web3j.ethCall(
                    Transaction.createEthCallTransaction(ZERO_ADDRESS, factoryAddress, data),
                    DefaultBlockParameterName.LATEST
            ).send();

            if (result.hasError() || result.getValue() == null) return Map.of();
            List<Type> decoded = FunctionReturnDecoder.decode(result.getValue(), fn.getOutputParameters());
            if (decoded.size() < 6) return Map.of();

            Map<String, String> info = new HashMap<>();
            info.put("token",        decoded.get(0).getValue().toString());
            info.put("vault",        decoded.get(1).getValue().toString());
            info.put("productId",    decoded.get(2).getValue().toString());
            info.put("strategyType", decoded.get(3).getValue().toString());
            info.put("deployedAt",   decoded.get(4).getValue().toString());
            info.put("active",       decoded.get(5).getValue().toString());
            return info;

        } catch (Exception e) {
            log.error("[ProductService] getProduct({}) 失败: {}", productId, e.getMessage());
            return Map.of();
        }
    }

    // ─────────────────────────────────────────────
    //  读取 NAV Oracle 数据
    // ─────────────────────────────────────────────

    public ProductDto.NavDto getNAV(String tokenAddress) {
        try {
            Function fn = new Function(
                    "getLatestNAV",
                    List.of(new Address(tokenAddress)),
                    List.of(
                            new TypeReference<Uint256>() {},  // nav
                            new TypeReference<Uint256>() {},  // timestamp
                            new TypeReference<Bool>() {}      // valid
                    )
            );
            String data = FunctionEncoder.encode(fn);
            EthCall result = web3j.ethCall(
                    Transaction.createEthCallTransaction(ZERO_ADDRESS, navOracleAddress, data),
                    DefaultBlockParameterName.LATEST
            ).send();

            if (result.hasError()) return null;
            List<Type> decoded = FunctionReturnDecoder.decode(result.getValue(), fn.getOutputParameters());
            if (decoded.size() < 3) return null;

            BigInteger nav       = (BigInteger) decoded.get(0).getValue();
            BigInteger timestamp = (BigInteger) decoded.get(1).getValue();
            boolean    valid     = (Boolean)    decoded.get(2).getValue();

            // 读取 TWAP
            BigInteger twap = getTWAP(tokenAddress);

            return ProductDto.NavDto.builder()
                    .spot(ContractUtils.formatNav(nav))
                    .twap(ContractUtils.formatNav(twap))
                    .updatedAt(Instant.ofEpochSecond(timestamp.longValue()).toString())
                    .stale(!valid)
                    .build();

        } catch (Exception e) {
            log.error("[ProductService] getNAV({}) 失败: {}", tokenAddress, e.getMessage());
            return null;
        }
    }

    private BigInteger getTWAP(String tokenAddress) {
        try {
            Function fn = new Function(
                    "getTWAP",
                    List.of(new Address(tokenAddress)),
                    List.of(new TypeReference<Uint256>() {})
            );
            return ContractUtils.callUint256(
                    web3j, ZERO_ADDRESS, navOracleAddress,
                    FunctionEncoder.encode(fn)
            );
        } catch (Exception e) {
            return BigInteger.ZERO;
        }
    }

    // ─────────────────────────────────────────────
    //  构建完整 ProductDto
    // ─────────────────────────────────────────────

    public List<ProductDto> listProducts() {
        List<String> ids = getAllProductIds();
        List<ProductDto> result = new ArrayList<>();

        for (String id : ids) {
            ProductDto dto = buildProductDto(id);
            if (dto != null && dto.isActive()) result.add(dto);
        }
        return result;
    }

    public ProductDto buildProductDto(String productId) {
        Map<String, String> info = getProductAddresses(productId);
        if (info.isEmpty()) return null;

        boolean active = Boolean.parseBoolean(info.get("active"));
        String tokenAddress = info.get("token");

        ProductDto.NavDto nav = getNAV(tokenAddress);

        BigInteger totalSupply = BigInteger.ZERO;
        BigInteger totalAssets = BigInteger.ZERO;
        try {
            totalSupply = ContractUtils.callUint256(
                    web3j, ZERO_ADDRESS, tokenAddress,
                    ContractUtils.encodeTotalSupply()
            );
            if (totalSupply.compareTo(BigInteger.ZERO) > 0) {
                totalAssets = ContractUtils.callUint256(
                        web3j, ZERO_ADDRESS, tokenAddress,
                        ContractUtils.encodeConvertToAssets(totalSupply)
                );
            }
        } catch (Exception e) {
            log.warn("[ProductService] TVL 读取失败: {}", e.getMessage());
        }

        long deployedAt = Long.parseLong(info.getOrDefault("deployedAt", "0"));

        return ProductDto.builder()
                .productId(productId)
                .strategyType(info.get("strategyType"))
                .token(tokenAddress)
                .vault(info.get("vault"))
                .nav(nav)
                .tvl(ProductDto.TvlDto.builder()
                        .shares(ContractUtils.formatShares(totalSupply))
                        .usd(ContractUtils.formatUsdt(totalAssets))
                        .build())
                .deployedAt(deployedAt > 0
                        ? Instant.ofEpochSecond(deployedAt).toString()
                        : null)
                .active(active)
                .build();
    }
}
