package com.rwaplatform.dto;

import com.fasterxml.jackson.annotation.JsonInclude;
import lombok.Builder;
import lombok.Data;
import java.util.List;
import java.util.Map;

/**
 * 返回给前端的待签名交易步骤。
 * 前端负责签名并广播，后端永远不接触私钥。
 */
@Data
@Builder
@JsonInclude(JsonInclude.Include.NON_NULL)
public class TransactionStepDto {

    private List<Step> steps;
    private Map<String, Object> meta;

    @Data
    @Builder
    public static class Step {
        private int    step;
        private String description;
        private String to;              // 目标合约地址
        private String data;            // 编码后的 calldata（hex）
        private String value;           // ETH value（通常为 "0"）
        private String estimatedGas;    // gas 估算（可选）
    }
}
