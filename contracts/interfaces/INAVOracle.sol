// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface INAVOracle {
    struct NAVData {
        uint256 nav;       // NAV per share, 18 decimals
        uint256 timestamp; // Last update timestamp
        bool valid;        // Whether this reading is valid
    }

    event NAVUpdated(address indexed product, uint256 nav, uint256 timestamp);
    event OracleNodeAdded(address indexed node);
    event OracleNodeRemoved(address indexed node);

    function getLatestNAV(address product) external view returns (NAVData memory);
    function isStale(address product) external view returns (bool);
    function updateNAV(address product, uint256 newNAV) external;
}
