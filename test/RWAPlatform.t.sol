// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../contracts/core/NAVOracle.sol";
import "../contracts/core/RWAToken.sol";
import "../contracts/core/RWAVault.sol";
import "../contracts/core/RWAFactory.sol";
import "../contracts/core/SPVRegistry.sol";
import "../contracts/mocks/MockERC20.sol";

/**
 * @title RWAPlatform.t.sol
 * @notice Foundry 集成测试：覆盖 NAV 预言机、认购、赎回、合规、管理费全流程
 */
contract RWAPlatformTest is Test {

    // ─────────────────────────────────────────────
    //  角色
    // ─────────────────────────────────────────────
    address admin       = makeAddr("admin");
    address oracleNode  = makeAddr("oracleNode");
    address operator    = makeAddr("operator");
    address user1       = makeAddr("user1");
    address user2       = makeAddr("user2");
    address blacklisted = makeAddr("blacklisted");
    address feeRecipient= makeAddr("feeRecipient");

    // ─────────────────────────────────────────────
    //  合约
    // ─────────────────────────────────────────────
    MockERC20   usdt;
    NAVOracle   navOracle;
    RWAFactory  factory;
    SPVRegistry spvRegistry;

    RWAToken    cashPlusToken;
    RWAVault    cashPlusVault;

    // ─────────────────────────────────────────────
    //  常量
    // ─────────────────────────────────────────────
    uint256 constant INITIAL_NAV  = 1e18;         // $1.00
    uint256 constant ONE_USDT     = 1e6;
    uint256 constant ONE_SHARE    = 1e18;

    bytes32 constant ORACLE_NODE_ROLE = keccak256("ORACLE_NODE_ROLE");
    bytes32 constant ADMIN_ROLE       = keccak256("ADMIN_ROLE");
    bytes32 constant COMPLIANCE_ROLE  = keccak256("COMPLIANCE_ROLE");

    // ─────────────────────────────────────────────
    //  Setup
    // ─────────────────────────────────────────────

    function setUp() public {
        vm.startPrank(admin);

        // 部署 mock USDT（6位）
        usdt = new MockERC20("USD Tether", "USDT", 6);

        // 部署 NAVOracle
        navOracle = new NAVOracle(admin);
        navOracle.grantRole(ORACLE_NODE_ROLE, oracleNode);

        // 部署 Factory
        factory = new RWAFactory(address(navOracle), address(usdt), admin);

        // 部署 SPVRegistry
        spvRegistry = new SPVRegistry(admin);

        // 部署 CASH+ 产品
        RWAFactory.ProductConfig memory cfg = RWAFactory.ProductConfig({
            name:              "CASH+ USD Money Market",
            symbol:            "CASH+",
            productId:         "CASH+",
            strategyType:      "money-market",
            redemptionDelay:   1 days,
            minSubscription:   0,
            managementFeeBps:  50,   // 0.5%
            feeRecipient:      feeRecipient,
            spvAddress:        address(0)
        });
        (address tokenAddr, address vaultAddr) = factory.deployProduct(cfg, operator);

        cashPlusToken = RWAToken(tokenAddr);
        cashPlusVault = RWAVault(vaultAddr);

        vm.stopPrank();

        // 初始化 NAV $1.00
        vm.prank(oracleNode);
        navOracle.updateNAV(address(cashPlusToken), INITIAL_NAV);
    }

    // ─────────────────────────────────────────────
    //  1. 部署验证
    // ─────────────────────────────────────────────

    function test_Deployment_TokenSymbol() public view {
        assertEq(cashPlusToken.symbol(), "CASH+");
        assertEq(cashPlusToken.productId(), "CASH+");
    }

    function test_Deployment_InitialNAV() public view {
        (uint256 nav, , bool valid) = navOracle.getLatestNAV(address(cashPlusToken));
        assertEq(nav, INITIAL_NAV);
        assertTrue(valid);
    }

    // ─────────────────────────────────────────────
    //  2. NAV Oracle
    // ─────────────────────────────────────────────

    function test_Oracle_UpdateNAV() public {
        uint256 newNAV = 1.01e18; // $1.01
        vm.prank(oracleNode);
        navOracle.updateNAV(address(cashPlusToken), newNAV);

        (uint256 nav, , bool valid) = navOracle.getLatestNAV(address(cashPlusToken));
        assertEq(nav, newNAV);
        assertTrue(valid);
    }

    function test_Oracle_UnauthorizedReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        navOracle.updateNAV(address(cashPlusToken), 1.01e18);
    }

    function test_Oracle_LargeDeviationReverts() public {
        // $1.00 → $1.10 = 10% 偏差，应 revert
        vm.prank(oracleNode);
        vm.expectRevert("NAVOracle: deviation too large");
        navOracle.updateNAV(address(cashPlusToken), 1.10e18);
    }

    function test_Oracle_AdminCanConfirmLargeDeviation() public {
        vm.prank(admin);
        navOracle.confirmLargeDeviation(address(cashPlusToken), 1.10e18);

        (uint256 nav, , ) = navOracle.getLatestNAV(address(cashPlusToken));
        assertEq(nav, 1.10e18);
    }

    function test_Oracle_StaleNAV() public {
        // 快进 37 小时，超过 36h staleness 阈值
        skip(37 hours);
        ( , , bool valid) = navOracle.getLatestNAV(address(cashPlusToken));
        assertFalse(valid);
    }

    function test_Oracle_TWAP() public {
        // 第一次更新已在 setUp()
        skip(1 hours);
        vm.prank(oracleNode);
        navOracle.updateNAV(address(cashPlusToken), 1.01e18);

        skip(1 hours);
        vm.prank(oracleNode);
        navOracle.updateNAV(address(cashPlusToken), 1.02e18);

        uint256 twap = navOracle.getTWAP(address(cashPlusToken));
        // TWAP = (1.00 + 1.01 + 1.02) / 3 ≈ 1.01e18
        assertApproxEqAbs(twap, 1.01e18, 0.005e18);
    }

    // ─────────────────────────────────────────────
    //  3. 认购
    // ─────────────────────────────────────────────

    function _mintAndSubscribe(address user, uint256 usdtAmount) internal returns (uint256 shares) {
        usdt.mint(user, usdtAmount);
        vm.startPrank(user);
        usdt.approve(address(cashPlusVault), usdtAmount);
        shares = cashPlusVault.subscribe(usdtAmount);
        vm.stopPrank();
    }

    function test_Subscribe_CorrectSharesAtParNAV() public {
        // NAV $1.00，存 $1000 → 1000 shares
        uint256 shares = _mintAndSubscribe(user1, 1000 * ONE_USDT);
        assertEq(shares, 1000 * ONE_SHARE);
        assertEq(cashPlusToken.balanceOf(user1), 1000 * ONE_SHARE);
    }

    function test_Subscribe_FewerSharesAboveParNAV() public {
        // NAV 更新为 $1.05
        vm.prank(oracleNode);
        navOracle.updateNAV(address(cashPlusToken), 1.05e18);

        // 存 $1050 → 1000 shares（$1050 / $1.05 = 1000）
        uint256 shares = _mintAndSubscribe(user1, 1050 * ONE_USDT);
        assertApproxEqAbs(shares, 1000 * ONE_SHARE, 1e15); // 0.001 share tolerance
    }

    function test_Subscribe_ZeroAmountReverts() public {
        vm.prank(user1);
        vm.expectRevert("RWAVault: zero amount");
        cashPlusVault.subscribe(0);
    }

    function test_Subscribe_WhenPausedReverts() public {
        vm.prank(admin);
        cashPlusVault.pause();

        usdt.mint(user1, 1000 * ONE_USDT);
        vm.startPrank(user1);
        usdt.approve(address(cashPlusVault), 1000 * ONE_USDT);
        vm.expectRevert();
        cashPlusVault.subscribe(1000 * ONE_USDT);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────
    //  4. 赎回
    // ─────────────────────────────────────────────

    function test_Redeem_RequestLocksShares() public {
        _mintAndSubscribe(user1, 1000 * ONE_USDT);

        uint256 shares = 500 * ONE_SHARE;
        vm.startPrank(user1);
        cashPlusToken.approve(address(cashPlusVault), shares);
        cashPlusVault.requestRedemption(shares);
        vm.stopPrank();

        // 份额应锁定在 vault
        assertEq(cashPlusToken.balanceOf(address(cashPlusVault)), shares);
        assertEq(cashPlusToken.balanceOf(user1), 500 * ONE_SHARE);
    }

    function test_Redeem_FulfillAfterDelay() public {
        _mintAndSubscribe(user1, 1000 * ONE_USDT);

        // 给 vault 注入 USDT 用于赎回
        usdt.mint(address(cashPlusVault), 2000 * ONE_USDT);

        uint256 shares = 500 * ONE_SHARE;
        vm.startPrank(user1);
        cashPlusToken.approve(address(cashPlusVault), shares);
        cashPlusVault.requestRedemption(shares);
        vm.stopPrank();

        // 快进 T+1
        skip(1 days + 1);

        uint256 payout = 500 * ONE_USDT;
        vm.prank(operator);
        cashPlusVault.fulfillRedemption(0, payout);

        // 用户收到 USDT
        assertEq(usdt.balanceOf(user1), payout);
        // 份额已销毁
        assertEq(cashPlusToken.balanceOf(address(cashPlusVault)), 0);
    }

    function test_Redeem_FulfillBeforeDelayReverts() public {
        _mintAndSubscribe(user1, 1000 * ONE_USDT);
        usdt.mint(address(cashPlusVault), 2000 * ONE_USDT);

        uint256 shares = 500 * ONE_SHARE;
        vm.startPrank(user1);
        cashPlusToken.approve(address(cashPlusVault), shares);
        cashPlusVault.requestRedemption(shares);
        vm.stopPrank();

        // 不快进时间，直接结算应 revert
        vm.prank(operator);
        vm.expectRevert("RWAVault: too early");
        cashPlusVault.fulfillRedemption(0, 500 * ONE_USDT);
    }

    function test_Redeem_UserCanCancel() public {
        _mintAndSubscribe(user1, 1000 * ONE_USDT);

        uint256 shares = 300 * ONE_SHARE;
        vm.startPrank(user1);
        cashPlusToken.approve(address(cashPlusVault), shares);
        cashPlusVault.requestRedemption(shares);
        cashPlusVault.cancelRedemption(0);
        vm.stopPrank();

        // 份额全部归还
        assertEq(cashPlusToken.balanceOf(user1), 1000 * ONE_SHARE);
    }

    // ─────────────────────────────────────────────
    //  5. 合规
    // ─────────────────────────────────────────────

    function test_Compliance_BlacklistBlocksTransfer() public {
        _mintAndSubscribe(user1, 500 * ONE_USDT);

        // 将 user1 列入黑名单
        vm.prank(admin);
        cashPlusToken.setBlacklisted(user1, true);

        // user1 无法转账
        vm.prank(user1);
        vm.expectRevert("RWAToken: sender blacklisted");
        cashPlusToken.transfer(user2, 100 * ONE_SHARE);
    }

    function test_Compliance_BlacklistBlocksSubscription() public {
        vm.prank(admin);
        cashPlusToken.setBlacklisted(blacklisted, true);

        usdt.mint(blacklisted, 500 * ONE_USDT);
        vm.startPrank(blacklisted);
        usdt.approve(address(cashPlusVault), 500 * ONE_USDT);
        vm.expectRevert("RWAToken: recipient blacklisted");
        cashPlusVault.subscribe(500 * ONE_USDT);
        vm.stopPrank();
    }

    function test_Compliance_WhitelistMode() public {
        // 开启白名单模式，只有 user1 被授权
        vm.startPrank(admin);
        cashPlusToken.toggleWhitelistMode(true);
        cashPlusToken.setWhitelisted(user1, true);
        vm.stopPrank();

        // user1 可以认购
        _mintAndSubscribe(user1, 100 * ONE_USDT);
        assertGt(cashPlusToken.balanceOf(user1), 0);

        // user2 被拒绝
        usdt.mint(user2, 100 * ONE_USDT);
        vm.startPrank(user2);
        usdt.approve(address(cashPlusVault), 100 * ONE_USDT);
        vm.expectRevert("RWAToken: not whitelisted");
        cashPlusVault.subscribe(100 * ONE_USDT);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────
    //  6. 管理费
    // ─────────────────────────────────────────────

    function test_ManagementFee_AccruesOverYear() public {
        // 认购 $100K
        _mintAndSubscribe(user1, 100_000 * ONE_USDT);

        // 快进 1 年
        skip(365 days);

        cashPlusToken.collectManagementFee();

        // 0.5% × 100,000 shares ≈ 500 shares
        uint256 feeShares = cashPlusToken.balanceOf(feeRecipient);
        assertApproxEqAbs(feeShares, 500 * ONE_SHARE, 1 * ONE_SHARE);
    }

    // ─────────────────────────────────────────────
    //  7. NAV 计价：convertToShares / convertToAssets
    // ─────────────────────────────────────────────

    function test_NAV_ConvertToSharesAndBack() public view {
        uint256 assets = 5000 * ONE_USDT;
        uint256 shares = cashPlusToken.convertToShares(assets);
        uint256 back   = cashPlusToken.convertToAssets(shares);
        // 双向转换精度误差 < $0.01
        assertApproxEqAbs(back, assets, 100); // 100 = $0.0001 in 6-dec USDT
    }

    // ─────────────────────────────────────────────
    //  8. Fuzz 测试
    // ─────────────────────────────────────────────

    function testFuzz_Subscribe_AnyAmount(uint256 amount) public {
        // 限制范围：$1 ～ $10M
        amount = bound(amount, ONE_USDT, 10_000_000 * ONE_USDT);

        uint256 shares = _mintAndSubscribe(user1, amount);
        assertGt(shares, 0);
        assertEq(cashPlusToken.balanceOf(user1), shares);
    }
}
