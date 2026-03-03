// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/IRWAToken.sol";
import "../interfaces/INAVOracle.sol";

/**
 * @title RWAToken
 * @notice ERC-20 token representing shares in an on-chain RWA fund.
 *
 * Pricing model:
 *   - Token price = NAV per share, pushed by authorized oracle
 *   - Shares = Assets deposited / Current NAV
 *   - Assets redeemable = Shares held * Current NAV
 *
 * This is NOT a stablecoin. The price floats with the underlying fund's NAV.
 * For CASH+ (money market), NAV is ~$1.00 but accrues daily yield.
 * For AoABT, NAV starts at $1.00 and grows at ~20% APY.
 *
 * Compliance:
 *   - Blacklist: OFAC-screened addresses cannot transfer
 *   - Whitelist mode: optional, can restrict to KYC'd wallets only
 *   - Transfer size limits: configurable per-product
 */
contract RWAToken is IRWAToken, ERC20, AccessControl, Pausable {
    bytes32 public constant VAULT_ROLE      = keccak256("VAULT_ROLE");
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 public constant ADMIN_ROLE      = keccak256("ADMIN_ROLE");

    // Oracle providing NAV data for this token
    INAVOracle public immutable navOracle;

    // Product metadata
    string public productId;        // e.g. "CASH+", "AoABT"
    string public strategyType;     // e.g. "money-market", "arb", "bond"
    address public spvAddress;      // Off-chain SPV legal entity identifier (for reference)

    // Compliance
    mapping(address => bool) public blacklisted;
    bool public whitelistEnabled;
    mapping(address => bool) public whitelisted;
    uint256 public maxTransferAmount; // 0 = no limit

    // Fee tracking
    uint256 public managementFeeBps;    // Annual management fee in BPS (e.g. 50 = 0.5%)
    uint256 public lastFeeCollection;   // Timestamp of last fee collection
    address public feeRecipient;

    // ─────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────
    event BlacklistUpdated(address indexed account, bool blacklisted);
    event WhitelistUpdated(address indexed account, bool whitelisted);
    event WhitelistModeToggled(bool enabled);
    event ManagementFeeCollected(uint256 shares, uint256 timestamp);
    event SPVAddressUpdated(address indexed spv);

    // ─────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────
    constructor(
        string memory name_,
        string memory symbol_,
        string memory productId_,
        string memory strategyType_,
        address navOracle_,
        address admin_,
        address vault_,
        uint256 managementFeeBps_,
        address feeRecipient_
    ) ERC20(name_, symbol_) {
        require(navOracle_ != address(0), "RWAToken: zero oracle");
        require(admin_ != address(0), "RWAToken: zero admin");
        require(vault_ != address(0), "RWAToken: zero vault");
        require(managementFeeBps_ <= 200, "RWAToken: fee too high"); // max 2% annual

        navOracle = INAVOracle(navOracle_);
        productId = productId_;
        strategyType = strategyType_;
        managementFeeBps = managementFeeBps_;
        feeRecipient = feeRecipient_;
        lastFeeCollection = block.timestamp;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(VAULT_ROLE, vault_);
        _grantRole(COMPLIANCE_ROLE, admin_);
    }

    // ─────────────────────────────────────────────
    //  Core: NAV-based mint / burn (Vault only)
    // ─────────────────────────────────────────────

    /**
     * @notice Mint shares to `to` proportional to `assets` at current NAV.
     * @param to     Recipient of shares.
     * @param assets Amount of underlying asset (USDT, 6 decimals) being deposited.
     * @return shares Number of RWAToken shares minted.
     */
    function mint(address to, uint256 assets)
        external
        override
        onlyRole(VAULT_ROLE)
        whenNotPaused
        returns (uint256 shares)
    {
        require(to != address(0), "RWAToken: zero recipient");
        require(!blacklisted[to], "RWAToken: recipient blacklisted");
        if (whitelistEnabled) require(whitelisted[to], "RWAToken: not whitelisted");

        shares = convertToShares(assets);
        require(shares > 0, "RWAToken: zero shares");

        _mint(to, shares);
        emit Minted(to, shares, assets);
    }

    /**
     * @notice Burn shares from `from`, returns equivalent asset amount.
     * @param from   Address whose shares to burn.
     * @param shares Number of shares to burn.
     * @return assets Equivalent asset amount (USDT, 6 decimals).
     */
    function burn(address from, uint256 shares)
        external
        override
        onlyRole(VAULT_ROLE)
        whenNotPaused
        returns (uint256 assets)
    {
        require(from != address(0), "RWAToken: zero address");
        require(!blacklisted[from], "RWAToken: sender blacklisted");

        assets = convertToAssets(shares);
        require(assets > 0, "RWAToken: zero assets");

        _burn(from, shares);
        emit Burned(from, shares, assets);
    }

    // ─────────────────────────────────────────────
    //  NAV & Conversions
    // ─────────────────────────────────────────────

    /**
     * @notice Current NAV per share from oracle. Reverts if stale.
     */
    function nav() public view override returns (uint256) {
        INAVOracle.NAVData memory data = navOracle.getLatestNAV(address(this));
        require(data.valid, "RWAToken: NAV not initialized");
        require(!navOracle.isStale(address(this)), "RWAToken: NAV is stale");
        return data.nav;
    }

    /**
     * @notice Total assets under management in USDT terms (18 decimal normalized).
     */
    function totalAssets() external view override returns (uint256) {
        return _navToAssets(totalSupply(), nav());
    }

    /**
     * @notice Convert asset amount (USDT 6-decimal) to shares (18-decimal token).
     * @dev    assets * 1e18 / NAV. NAV is 18 decimals per share.
     *         USDT is 6 decimals, so normalize: assets * 1e12 to get 18 decimals.
     */
    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 currentNAV = nav();
        // assets (6 dec) → normalize to 18 dec → divide by NAV (18 dec)
        return (assets * 1e12 * 1e18) / currentNAV;
    }

    /**
     * @notice Convert shares (18-decimal) back to asset amount (USDT 6-decimal).
     */
    function convertToAssets(uint256 shares) public view override returns (uint256) {
        uint256 currentNAV = nav();
        // shares (18 dec) * NAV (18 dec) / 1e18 → normalize back to 6 dec
        return (shares * currentNAV) / (1e18 * 1e12);
    }

    // ─────────────────────────────────────────────
    //  Management Fee
    // ─────────────────────────────────────────────

    /**
     * @notice Collect accrued management fee by minting shares to feeRecipient.
     * @dev Anyone can trigger but shares go to feeRecipient.
     *      Fee = totalSupply * annualFeeBps / BPS / (365 days / elapsed)
     */
    function collectManagementFee() external whenNotPaused {
        uint256 elapsed = block.timestamp - lastFeeCollection;
        if (elapsed == 0 || managementFeeBps == 0) return;

        uint256 annualFeeShares = (totalSupply() * managementFeeBps) / 10_000;
        uint256 elapsedFeeShares = (annualFeeShares * elapsed) / 365 days;

        if (elapsedFeeShares == 0) return;

        lastFeeCollection = block.timestamp;
        _mint(feeRecipient, elapsedFeeShares);
        emit ManagementFeeCollected(elapsedFeeShares, block.timestamp);
    }

    // ─────────────────────────────────────────────
    //  Compliance
    // ─────────────────────────────────────────────

    function setBlacklisted(address account, bool status)
        external
        onlyRole(COMPLIANCE_ROLE)
    {
        blacklisted[account] = status;
        emit BlacklistUpdated(account, status);
    }

    function setWhitelisted(address account, bool status)
        external
        onlyRole(COMPLIANCE_ROLE)
    {
        whitelisted[account] = status;
        emit WhitelistUpdated(account, status);
    }

    function toggleWhitelistMode(bool enabled) external onlyRole(ADMIN_ROLE) {
        whitelistEnabled = enabled;
        emit WhitelistModeToggled(enabled);
    }

    function setMaxTransferAmount(uint256 amount) external onlyRole(ADMIN_ROLE) {
        maxTransferAmount = amount;
    }

    function setSPVAddress(address spv) external onlyRole(ADMIN_ROLE) {
        spvAddress = spv;
        emit SPVAddressUpdated(spv);
    }

    // ─────────────────────────────────────────────
    //  ERC-20 Overrides (compliance hooks)
    // ─────────────────────────────────────────────

    function _update(address from, address to, uint256 value)
        internal
        override
        whenNotPaused
    {
        // Skip compliance checks for mint/burn (from == 0 or to == 0)
        if (from != address(0) && to != address(0)) {
            require(!blacklisted[from], "RWAToken: sender blacklisted");
            require(!blacklisted[to], "RWAToken: recipient blacklisted");
            if (whitelistEnabled) {
                require(whitelisted[from], "RWAToken: sender not whitelisted");
                require(whitelisted[to], "RWAToken: recipient not whitelisted");
            }
            if (maxTransferAmount > 0) {
                require(value <= maxTransferAmount, "RWAToken: transfer exceeds limit");
            }
        }
        super._update(from, to, value);
    }

    // ─────────────────────────────────────────────
    //  Admin
    // ─────────────────────────────────────────────

    function pause() external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    function updateFeeRecipient(address newRecipient) external onlyRole(ADMIN_ROLE) {
        require(newRecipient != address(0), "RWAToken: zero address");
        feeRecipient = newRecipient;
    }

    // ─────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────

    function _navToAssets(uint256 shares, uint256 _nav) internal pure returns (uint256) {
        return (shares * _nav) / 1e18;
    }
}
