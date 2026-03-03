package com.rwaplatform.dto;

import com.fasterxml.jackson.annotation.JsonInclude;
import lombok.Builder;
import lombok.Data;

@Data
@Builder
@JsonInclude(JsonInclude.Include.NON_NULL)
public class ProductDto {
    private String productId;
    private String name;
    private String symbol;
    private String strategyType;
    private String token;
    private String vault;
    private NavDto  nav;
    private TvlDto  tvl;
    private String deployedAt;
    private boolean active;

    @Data
    @Builder
    public static class NavDto {
        private String spot;        // 当前 NAV（18位小数格式化为字符串）
        private String twap;        // TWAP
        private String updatedAt;
        private boolean stale;
    }

    @Data
    @Builder
    public static class TvlDto {
        private String shares;      // 总份额（18位）
        private String usd;         // 估算美元价值（6位）
    }
}
