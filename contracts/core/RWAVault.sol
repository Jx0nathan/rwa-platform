// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IRWAToken.sol";

/**
 * @title RWAVault
 * @notice Entry point for user subscriptions and redemptions.
 *
 * Flow — Subscription:
 *   1. User approves USDT → Vault
 *   2. User calls subscribe(amount)
 *   3. Vault pulls USDT, calls RWAToken.mint()
 *   4. User receives RWAToken shares immediately
 *   5. Backend detects SubscriptionProcessed event, moves USDT to custodian off-chain
 *
 * Flow — Redemption:
 *   1. User calls requestRedemption(shares)
 *   2. Vault locks shares (transfers to vault), queues redemption
 *   3. Backend processes off-chain (sells underlying assets)
 *   4. Backend calls fulfillRedemption(requestId), vault sends USDT to user, burns shares
 *
 * Liquidity buffer:
 *   - Vault keeps a LIQUIDITY_RESERVE_BPS of TVL in USDT for instant redemptions
 *   - Requests > buffer go into the queue (T+N settlement)
 */
contract RWAVault is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE    = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE"); // Backend service

    // Settlement delay: varies by product
    uint256 public redemptionDelay;  // in seconds, e.g. 86400 = T+1

    // Liquidity reserve: percentage of TVL kept liquid
    uint256 public liquidityReserveBps = 1000; // 10% default
    uint256 public constant BPS_DENOMINATOR = 10_000;

    IERC20  public immutable usdt;
    IRWAToken public immutable rwaToken;

    // ─────────────────────────────────────────────
    //  Redemption Queue
    // ─────────────────────────────────────────────

    enum RedemptionStatus { Pending, Fulfilled, Cancelled }

    struct RedemptionRequest {
        address requester;
        uint256 shares;
        uint256 requestedAt;
        uint256 estimatedNAV;    // NAV at time of request (for reference)
        RedemptionStatus status;
        uint256 fulfilledAmount; // Actual USDT paid out
    }

    uint256 private _nextRequestId;
    mapping(uint256 => RedemptionRequest) public redemptionRequests;
    mapping(address => uint256[]) public userRedemptionIds;

    uint256 public totalPendingShares; // Shares locked in pending redemptions

    // ─────────────────────────────────────────────
    //  Subscription limits
    // ─────────────────────────────────────────────
    uint256 public minSubscription; // 0 = no minimum (CASH+ style)
    uint256 public maxSubscription; // 0 = no max

    // ─────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────
    event SubscriptionProcessed(
        address indexed user,
        uint256 assets,
        uint256 shares,
        uint256 navAtSubscription
    );
    event RedemptionRequested(
        uint256 indexed requestId,
        address indexed user,
        uint256 shares,
        uint256 estimatedNAV
    );
    event RedemptionFulfilled(
        uint256 indexed requestId,
        address indexed user,
        uint256 shares,
        uint256 usdtPaid
    );
    event RedemptionCancelled(uint256 indexed requestId, address indexed user);
    event LiquidityReserveUpdated(uint256 newBps);

    // ─────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────

    constructor(
        address usdt_,
        address rwaToken_,
        address admin_,
        address operator_,
        uint256 redemptionDelay_,
        uint256 minSubscription_
    ) {
        require(usdt_ != address(0), "RWAVault: zero USDT");
        require(rwaToken_ != address(0), "RWAVault: zero token");
        require(admin_ != address(0), "RWAVault: zero admin");

        usdt = IERC20(usdt_);
        rwaToken = IRWAToken(rwaToken_);
        redemptionDelay = redemptionDelay_;
        minSubscription = minSubscription_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(OPERATOR_ROLE, operator_);
    }

    // ─────────────────────────────────────────────
    //  Subscription
    // ─────────────────────────────────────────────

    /**
     * @notice Subscribe to the fund by depositing USDT.
     * @param assets Amount of USDT (6 decimals) to deposit.
     * @return shares Number of RWAToken shares received.
     */
    function subscribe(uint256 assets)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        require(assets > 0, "RWAVault: zero amount");
        if (minSubscription > 0) {
            require(assets >= minSubscription, "RWAVault: below minimum");
        }
        if (maxSubscription > 0) {
            require(assets <= maxSubscription, "RWAVault: above maximum");
        }

        // Pull USDT from user
        usdt.safeTransferFrom(msg.sender, address(this), assets);

        // Mint RWAToken shares to user (NAV check inside)
        shares = rwaToken.mint(msg.sender, assets);

        uint256 currentNAV = rwaToken.nav();
        emit SubscriptionProcessed(msg.sender, assets, shares, currentNAV);
    }

    // ─────────────────────────────────────────────
    //  Redemption
    // ─────────────────────────────────────────────

    /**
     * @notice Request redemption of `shares` back to USDT.
     * @dev    Shares are locked in vault immediately. USDT is sent after `redemptionDelay`.
     *         If vault has enough liquid USDT, may be fulfilled instantly.
     * @param shares Amount of RWAToken shares to redeem.
     * @return requestId ID to track this redemption.
     */
    function requestRedemption(uint256 shares)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        require(shares > 0, "RWAVault: zero shares");
        require(
            IERC20(address(rwaToken)).balanceOf(msg.sender) >= shares,
            "RWAVault: insufficient shares"
        );

        // Lock shares in vault
        IERC20(address(rwaToken)).safeTransferFrom(msg.sender, address(this), shares);
        totalPendingShares += shares;

        uint256 estimatedNAV = rwaToken.nav();

        requestId = _nextRequestId++;
        redemptionRequests[requestId] = RedemptionRequest({
            requester: msg.sender,
            shares: shares,
            requestedAt: block.timestamp,
            estimatedNAV: estimatedNAV,
            status: RedemptionStatus.Pending,
            fulfilledAmount: 0
        });
        userRedemptionIds[msg.sender].push(requestId);

        emit RedemptionRequested(requestId, msg.sender, shares, estimatedNAV);

        // Attempt instant fulfillment if enough liquidity in vault
        _tryInstantFulfillment(requestId);
    }

    /**
     * @notice Backend operator fulfills a pending redemption after off-chain processing.
     * @param requestId  The redemption request ID.
     * @param usdtAmount Actual USDT amount to pay out (may differ from estimate due to NAV change).
     */
    function fulfillRedemption(uint256 requestId, uint256 usdtAmount)
        external
        nonReentrant
        onlyRole(OPERATOR_ROLE)
    {
        RedemptionRequest storage req = redemptionRequests[requestId];
        require(req.status == RedemptionStatus.Pending, "RWAVault: not pending");
        require(
            block.timestamp >= req.requestedAt + redemptionDelay,
            "RWAVault: too early"
        );
        require(usdtAmount > 0, "RWAVault: zero payout");
        require(
            usdt.balanceOf(address(this)) >= usdtAmount,
            "RWAVault: insufficient USDT"
        );

        req.status = RedemptionStatus.Fulfilled;
        req.fulfilledAmount = usdtAmount;
        totalPendingShares -= req.shares;

        // Burn locked shares
        rwaToken.burn(address(this), req.shares);

        // Send USDT to user
        usdt.safeTransfer(req.requester, usdtAmount);

        emit RedemptionFulfilled(requestId, req.requester, req.shares, usdtAmount);
    }

    /**
     * @notice Cancel a pending redemption (user or admin only).
     * @dev Returns locked shares to user. Only possible before fulfillment.
     */
    function cancelRedemption(uint256 requestId) external nonReentrant {
        RedemptionRequest storage req = redemptionRequests[requestId];
        require(req.status == RedemptionStatus.Pending, "RWAVault: not pending");
        require(
            msg.sender == req.requester || hasRole(ADMIN_ROLE, msg.sender),
            "RWAVault: unauthorized"
        );

        req.status = RedemptionStatus.Cancelled;
        totalPendingShares -= req.shares;

        // Return shares to user
        IERC20(address(rwaToken)).safeTransfer(req.requester, req.shares);

        emit RedemptionCancelled(requestId, req.requester);
    }

    // ─────────────────────────────────────────────
    //  Admin: Fund management
    // ─────────────────────────────────────────────

    /**
     * @notice Operator deposits USDT into vault (from off-chain custodian) to fund redemptions.
     */
    function depositLiquidity(uint256 amount) external onlyRole(OPERATOR_ROLE) {
        usdt.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Operator sweeps USDT from vault to custodian (off-chain).
     * @dev    Maintains liquidity reserve — cannot sweep below reserve floor.
     */
    function sweepToCustodian(address custodian, uint256 amount)
        external
        onlyRole(OPERATOR_ROLE)
    {
        require(custodian != address(0), "RWAVault: zero custodian");
        uint256 vaultBalance = usdt.balanceOf(address(this));
        uint256 reserveFloor = _liquidityReserveFloor();
        require(
            vaultBalance - amount >= reserveFloor,
            "RWAVault: would breach liquidity reserve"
        );
        usdt.safeTransfer(custodian, amount);
    }

    function setRedemptionDelay(uint256 delay) external onlyRole(ADMIN_ROLE) {
        require(delay <= 30 days, "RWAVault: delay too long");
        redemptionDelay = delay;
    }

    function setLiquidityReserveBps(uint256 bps) external onlyRole(ADMIN_ROLE) {
        require(bps <= 5000, "RWAVault: reserve > 50%");
        liquidityReserveBps = bps;
        emit LiquidityReserveUpdated(bps);
    }

    function setMinSubscription(uint256 amount) external onlyRole(ADMIN_ROLE) {
        minSubscription = amount;
    }

    function setMaxSubscription(uint256 amount) external onlyRole(ADMIN_ROLE) {
        maxSubscription = amount;
    }

    function pause() external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    // ─────────────────────────────────────────────
    //  View
    // ─────────────────────────────────────────────

    function getPendingRedemptions(address user)
        external
        view
        returns (uint256[] memory ids, RedemptionRequest[] memory reqs)
    {
        uint256[] storage allIds = userRedemptionIds[user];
        uint256 pendingCount;
        for (uint256 i; i < allIds.length; i++) {
            if (redemptionRequests[allIds[i]].status == RedemptionStatus.Pending) {
                pendingCount++;
            }
        }
        ids = new uint256[](pendingCount);
        reqs = new RedemptionRequest[](pendingCount);
        uint256 j;
        for (uint256 i; i < allIds.length; i++) {
            if (redemptionRequests[allIds[i]].status == RedemptionStatus.Pending) {
                ids[j] = allIds[i];
                reqs[j] = redemptionRequests[allIds[i]];
                j++;
            }
        }
    }

    function vaultLiquidity() external view returns (uint256) {
        return usdt.balanceOf(address(this));
    }

    // ─────────────────────────────────────────────
    //  Internal
    // ─────────────────────────────────────────────

    function _liquidityReserveFloor() internal view returns (uint256) {
        uint256 totalSupply = IERC20(address(rwaToken)).totalSupply();
        uint256 totalAssetsEstimate = rwaToken.convertToAssets(totalSupply);
        return (totalAssetsEstimate * liquidityReserveBps) / BPS_DENOMINATOR;
    }

    /**
     * @dev Attempt instant fulfillment if vault has liquid USDT for this request.
     */
    function _tryInstantFulfillment(uint256 requestId) internal {
        RedemptionRequest storage req = redemptionRequests[requestId];
        uint256 estimatedPayout = rwaToken.convertToAssets(req.shares);
        uint256 vaultBalance = usdt.balanceOf(address(this));

        // Only do instant if vault has enough AND we won't breach reserve floor
        if (vaultBalance >= estimatedPayout) {
            uint256 reserveFloor = _liquidityReserveFloor();
            if (vaultBalance - estimatedPayout >= reserveFloor) {
                req.status = RedemptionStatus.Fulfilled;
                req.fulfilledAmount = estimatedPayout;
                totalPendingShares -= req.shares;

                rwaToken.burn(address(this), req.shares);
                usdt.safeTransfer(req.requester, estimatedPayout);

                emit RedemptionFulfilled(requestId, req.requester, req.shares, estimatedPayout);
            }
        }
    }
}
