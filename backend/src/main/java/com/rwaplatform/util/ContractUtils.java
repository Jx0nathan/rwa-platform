package com.rwaplatform.util;

import org.web3j.abi.FunctionEncoder;
import org.web3j.abi.FunctionReturnDecoder;
import org.web3j.abi.TypeReference;
import org.web3j.abi.datatypes.*;
import org.web3j.abi.datatypes.generated.Uint256;
import org.web3j.protocol.Web3j;
import org.web3j.protocol.core.DefaultBlockParameterName;
import org.web3j.protocol.core.methods.request.Transaction;
import org.web3j.protocol.core.methods.response.EthCall;

import java.io.IOException;
import java.math.BigDecimal;
import java.math.BigInteger;
import java.math.RoundingMode;
import java.util.Arrays;
import java.util.List;

/**
 * 合约调用工具类：封装 Web3j 的 ABI 编解码与 eth_call。
 */
public class ContractUtils {

    /** USDT 精度：6位 */
    public static final int USDT_DECIMALS = 6;
    /** 份额精度：18位 */
    public static final int SHARE_DECIMALS = 18;
    /** NAV 精度：18位，1e18 = $1.00 */
    public static final BigInteger ONE_E18 = BigInteger.TEN.pow(18);
    public static final BigInteger ONE_E6  = BigInteger.TEN.pow(6);
    public static final BigInteger ONE_E12 = BigInteger.TEN.pow(12);

    // ─────────────────────────────────────────────
    //  ABI 编码：常用函数
    // ─────────────────────────────────────────────

    /** ERC-20 balanceOf(address) */
    public static String encodeBalanceOf(String address) {
        Function fn = new Function(
                "balanceOf",
                List.of(new Address(address)),
                List.of(new TypeReference<Uint256>() {})
        );
        return FunctionEncoder.encode(fn);
    }

    /** ERC-20 totalSupply() */
    public static String encodeTotalSupply() {
        Function fn = new Function("totalSupply", List.of(), List.of(new TypeReference<Uint256>() {}));
        return FunctionEncoder.encode(fn);
    }

    /** RWAToken: convertToAssets(uint256) */
    public static String encodeConvertToAssets(BigInteger shares) {
        Function fn = new Function(
                "convertToAssets",
                List.of(new Uint256(shares)),
                List.of(new TypeReference<Uint256>() {})
        );
        return FunctionEncoder.encode(fn);
    }

    /** RWAToken: convertToShares(uint256) */
    public static String encodeConvertToShares(BigInteger assets) {
        Function fn = new Function(
                "convertToShares",
                List.of(new Uint256(assets)),
                List.of(new TypeReference<Uint256>() {})
        );
        return FunctionEncoder.encode(fn);
    }

    /** ERC-20: approve(address, uint256) */
    public static String encodeApprove(String spender, BigInteger amount) {
        Function fn = new Function(
                "approve",
                List.of(new Address(spender), new Uint256(amount)),
                List.of(new TypeReference<Bool>() {})
        );
        return FunctionEncoder.encode(fn);
    }

    /** RWAVault: subscribe(uint256) */
    public static String encodeSubscribe(BigInteger amount) {
        Function fn = new Function(
                "subscribe",
                List.of(new Uint256(amount)),
                List.of(new TypeReference<Uint256>() {})
        );
        return FunctionEncoder.encode(fn);
    }

    /** RWAVault: requestRedemption(uint256) */
    public static String encodeRequestRedemption(BigInteger shares) {
        Function fn = new Function(
                "requestRedemption",
                List.of(new Uint256(shares)),
                List.of(new TypeReference<Uint256>() {})
        );
        return FunctionEncoder.encode(fn);
    }

    /** NAVOracle: updateNAV(address, uint256) */
    public static String encodeUpdateNAV(String product, BigInteger nav) {
        Function fn = new Function(
                "updateNAV",
                List.of(new Address(product), new Uint256(nav)),
                List.of()
        );
        return FunctionEncoder.encode(fn);
    }

    /** RWAVault: fulfillRedemption(uint256, uint256) */
    public static String encodeFulfillRedemption(BigInteger requestId, BigInteger usdtAmount) {
        Function fn = new Function(
                "fulfillRedemption",
                List.of(new Uint256(requestId), new Uint256(usdtAmount)),
                List.of()
        );
        return FunctionEncoder.encode(fn);
    }

    // ─────────────────────────────────────────────
    //  eth_call 工具
    // ─────────────────────────────────────────────

    public static BigInteger callUint256(Web3j web3j, String from, String to, String data)
            throws IOException {
        EthCall result = web3j.ethCall(
                Transaction.createEthCallTransaction(from, to, data),
                DefaultBlockParameterName.LATEST
        ).send();

        if (result.hasError() || result.getValue() == null || result.getValue().equals("0x")) {
            return BigInteger.ZERO;
        }
        List<Type> decoded = FunctionReturnDecoder.decode(
                result.getValue(),
                List.of(new TypeReference<Uint256>() {})
        );
        return decoded.isEmpty() ? BigInteger.ZERO : (BigInteger) decoded.get(0).getValue();
    }

    // ─────────────────────────────────────────────
    //  精度转换工具
    // ─────────────────────────────────────────────

    /** BigInteger (6位小数) → 美元字符串，如 "1000.000000" */
    public static String formatUsdt(BigInteger amount) {
        return new BigDecimal(amount).movePointLeft(USDT_DECIMALS)
                .setScale(6, RoundingMode.DOWN).toPlainString();
    }

    /** BigInteger (18位小数) → 字符串 */
    public static String formatShares(BigInteger amount) {
        return new BigDecimal(amount).movePointLeft(SHARE_DECIMALS)
                .setScale(6, RoundingMode.DOWN).toPlainString();
    }

    /** 美元字符串 → BigInteger (6位小数) */
    public static BigInteger parseUsdt(String amount) {
        return new BigDecimal(amount).movePointRight(USDT_DECIMALS)
                .setScale(0, RoundingMode.DOWN).toBigIntegerExact();
    }

    /** 份额字符串 → BigInteger (18位小数) */
    public static BigInteger parseShares(String amount) {
        return new BigDecimal(amount).movePointRight(SHARE_DECIMALS)
                .setScale(0, RoundingMode.DOWN).toBigIntegerExact();
    }

    /** NAV BigInteger (18位) → 美元字符串，如 "1.050000" */
    public static String formatNav(BigInteger nav) {
        return new BigDecimal(nav).movePointLeft(SHARE_DECIMALS)
                .setScale(6, RoundingMode.DOWN).toPlainString();
    }
}
