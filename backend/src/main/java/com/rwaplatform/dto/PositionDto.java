package com.rwaplatform.dto;

import lombok.Builder;
import lombok.Data;
import java.util.List;

@Data
@Builder
public class PositionDto {
    private String wallet;
    private List<Position> positions;
    private String totalUSD;

    @Data
    @Builder
    public static class Position {
        private String productId;
        private String token;
        private String shares;
        private String nav;
        private String usdValue;
        private String navUpdatedAt;
    }
}
