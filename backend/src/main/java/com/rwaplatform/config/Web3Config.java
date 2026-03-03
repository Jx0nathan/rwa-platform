package com.rwaplatform.config;

import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.web3j.crypto.Credentials;
import org.web3j.protocol.Web3j;
import org.web3j.protocol.http.HttpService;
import org.web3j.tx.gas.DefaultGasProvider;
import org.web3j.tx.gas.ContractGasProvider;

/**
 * Web3j Bean 配置。
 * - Web3j：连接 EVM 节点（RPC_URL）
 * - Credentials：运营账户私钥，用于签署链上交易
 */
@Slf4j
@Configuration
public class Web3Config {

    @Value("${rwa.rpc-url}")
    private String rpcUrl;

    @Value("${rwa.operator-private-key:}")
    private String operatorPrivateKey;

    @Bean
    public Web3j web3j() {
        log.info("[Web3Config] 连接节点: {}", rpcUrl);
        return Web3j.build(new HttpService(rpcUrl));
    }

    /**
     * 运营账户凭证（用于 NAV 推送、赎回结算等链上操作）。
     * 如果未配置私钥（只读场景），返回 null。
     */
    @Bean
    public Credentials operatorCredentials() {
        if (operatorPrivateKey == null || operatorPrivateKey.isBlank()) {
            log.warn("[Web3Config] OPERATOR_PRIVATE_KEY 未配置，链上写操作将不可用");
            return null;
        }
        return Credentials.create(operatorPrivateKey);
    }

    @Bean
    public ContractGasProvider gasProvider() {
        return new DefaultGasProvider();
    }
}
