// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRWAToken {
    // --- Events ---
    event Minted(address indexed to, uint256 shares, uint256 assets);
    event Burned(address indexed from, uint256 shares, uint256 assets);
    event NAVUpdated(uint256 oldNAV, uint256 newNAV, uint256 timestamp);

    // --- Core ---
    function mint(address to, uint256 assets) external returns (uint256 shares);
    function burn(address from, uint256 shares) external returns (uint256 assets);
    function nav() external view returns (uint256); // NAV per share in 18 decimals (1e18 = $1.00)
    function totalAssets() external view returns (uint256);

    // --- Conversions ---
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}
