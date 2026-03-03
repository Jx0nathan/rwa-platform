package com.rwaplatform.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import lombok.Data;

@Data
public class RedeemRequestDto {

    @NotBlank(message = "productId 不能为空")
    private String productId;

    /** 份额数量（18位小数字符串） */
    @NotBlank(message = "shares 不能为空")
    private String shares;

    @NotBlank(message = "walletAddress 不能为空")
    @Pattern(regexp = "^0x[0-9a-fA-F]{40}$", message = "walletAddress 格式不合法")
    private String walletAddress;
}
