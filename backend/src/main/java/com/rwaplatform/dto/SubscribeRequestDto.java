package com.rwaplatform.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import lombok.Data;

@Data
public class SubscribeRequestDto {

    @NotBlank(message = "productId 不能为空")
    private String productId;

    /** USDT 金额（6位小数字符串，例如 "1000.000000"） */
    @NotBlank(message = "amount 不能为空")
    private String amount;

    @NotBlank(message = "walletAddress 不能为空")
    @Pattern(regexp = "^0x[0-9a-fA-F]{40}$", message = "walletAddress 格式不合法")
    private String walletAddress;
}
