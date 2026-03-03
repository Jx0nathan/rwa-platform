// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/INAVOracle.sol";

/**
 * @title NAVOracle
 * @notice Stores and validates NAV (Net Asset Value) per share for each RWA product.
 *
 * Design decisions:
 * - Authorized oracle nodes push NAV updates (pull model would require on-chain computation)
 * - Staleness check: if no update in STALE_THRESHOLD, mark price invalid
 * - Large deviation (> MAX_DEVIATION_BPS) requires multi-sig admin approval
 * - TWAP is maintained over last N updates to prevent single-point manipulation
 */
contract NAVOracle is INAVOracle, AccessControl, Pausable {
    bytes32 public constant ORACLE_NODE_ROLE = keccak256("ORACLE_NODE_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    uint256 public constant STALE_THRESHOLD = 36 hours;     // Price stale after 36h
    uint256 public constant MAX_DEVIATION_BPS = 500;        // 5% max single-update deviation
    uint256 public constant TWAP_WINDOW = 3;                // TWAP over last 3 observations
    uint256 public constant BPS_DENOMINATOR = 10_000;

    struct NAVHistory {
        uint256[3] navs;       // Circular buffer of last TWAP_WINDOW observations
        uint256 writeIndex;
        uint256 count;
    }

    // product address => latest NAV data
    mapping(address => NAVData) private _latestNAV;
    // product address => TWAP history
    mapping(address => NAVHistory) private _history;

    // Events
    event LargeDeviationDetected(address indexed product, uint256 oldNAV, uint256 newNAV, uint256 deviationBps);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
    }

    // ─────────────────────────────────────────────
    //  External: Oracle nodes push NAV updates
    // ─────────────────────────────────────────────

    /**
     * @notice Push a new NAV reading for a product.
     * @param product The RWAToken/Vault contract address.
     * @param newNAV  NAV per share in 18 decimals (1e18 = $1.00 USD).
     */
    function updateNAV(address product, uint256 newNAV)
        external
        override
        whenNotPaused
        onlyRole(ORACLE_NODE_ROLE)
    {
        require(product != address(0), "NAVOracle: zero address");
        require(newNAV > 0, "NAVOracle: NAV must be > 0");

        NAVData storage current = _latestNAV[product];

        // Deviation check: only enforce after first reading
        if (current.nav > 0) {
            uint256 deviationBps = _deviationBps(current.nav, newNAV);
            if (deviationBps > MAX_DEVIATION_BPS) {
                emit LargeDeviationDetected(product, current.nav, newNAV, deviationBps);
                // Large deviation: require explicit admin confirmation via separate call
                revert("NAVOracle: deviation too large, call confirmLargeDeviation");
            }
        }

        _writeNAV(product, newNAV);
    }

    /**
     * @notice Admin-confirmed NAV update for large deviations (> 5%).
     * @dev Requires ADMIN_ROLE — acts as a 2-step confirmation for significant moves.
     */
    function confirmLargeDeviation(address product, uint256 newNAV)
        external
        onlyRole(ADMIN_ROLE)
    {
        require(product != address(0), "NAVOracle: zero address");
        require(newNAV > 0, "NAVOracle: NAV must be > 0");
        _writeNAV(product, newNAV);
    }

    // ─────────────────────────────────────────────
    //  View functions
    // ─────────────────────────────────────────────

    function getLatestNAV(address product)
        external
        view
        override
        returns (NAVData memory)
    {
        return _latestNAV[product];
    }

    /**
     * @notice Returns TWAP of the last TWAP_WINDOW observations.
     * @dev Falls back to spot NAV if fewer than TWAP_WINDOW readings available.
     */
    function getTWAP(address product) external view returns (uint256) {
        NAVHistory storage h = _history[product];
        if (h.count == 0) return 0;

        uint256 total = 0;
        uint256 count = h.count < TWAP_WINDOW ? h.count : TWAP_WINDOW;
        for (uint256 i = 0; i < count; i++) {
            total += h.navs[i];
        }
        return total / count;
    }

    function isStale(address product) external view override returns (bool) {
        NAVData storage data = _latestNAV[product];
        if (!data.valid) return true;
        return block.timestamp - data.timestamp > STALE_THRESHOLD;
    }

    // ─────────────────────────────────────────────
    //  Admin
    // ─────────────────────────────────────────────

    function addOracleNode(address node) external onlyRole(ADMIN_ROLE) {
        _grantRole(ORACLE_NODE_ROLE, node);
        emit OracleNodeAdded(node);
    }

    function removeOracleNode(address node) external onlyRole(ADMIN_ROLE) {
        _revokeRole(ORACLE_NODE_ROLE, node);
        emit OracleNodeRemoved(node);
    }

    function pause() external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    // ─────────────────────────────────────────────
    //  Internal
    // ─────────────────────────────────────────────

    function _writeNAV(address product, uint256 newNAV) internal {
        uint256 oldNAV = _latestNAV[product].nav;

        _latestNAV[product] = NAVData({
            nav: newNAV,
            timestamp: block.timestamp,
            valid: true
        });

        // Update TWAP buffer
        NAVHistory storage h = _history[product];
        h.navs[h.writeIndex % TWAP_WINDOW] = newNAV;
        h.writeIndex++;
        if (h.count < TWAP_WINDOW) h.count++;

        emit NAVUpdated(product, newNAV, block.timestamp);

        if (oldNAV > 0) {
            emit NAVUpdated(product, newNAV, block.timestamp);
        }
    }

    function _deviationBps(uint256 oldNAV, uint256 newNAV) internal pure returns (uint256) {
        uint256 diff = oldNAV > newNAV ? oldNAV - newNAV : newNAV - oldNAV;
        return (diff * BPS_DENOMINATOR) / oldNAV;
    }
}
