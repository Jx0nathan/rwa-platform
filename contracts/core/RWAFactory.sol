// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./RWAToken.sol";
import "./RWAVault.sol";

/**
 * @title RWAFactory
 * @notice Deploys new RWAToken + RWAVault pairs for each product.
 *
 * Asset managers can request a new product. After admin approval,
 * factory deploys the token + vault, registers them, and emits an event
 * so the backend can begin monitoring.
 */
contract RWAFactory is AccessControl {
    bytes32 public constant ADMIN_ROLE    = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    address public immutable navOracle;
    address public immutable usdt;

    struct ProductConfig {
        string name;
        string symbol;
        string productId;
        string strategyType;
        uint256 redemptionDelay;    // seconds
        uint256 minSubscription;    // USDT, 6 decimals (0 = no min)
        uint256 managementFeeBps;   // annual, e.g. 50 = 0.5%
        address feeRecipient;
        address spvAddress;
    }

    struct DeployedProduct {
        address token;
        address vault;
        string productId;
        string strategyType;
        uint256 deployedAt;
        bool active;
    }

    // productId => DeployedProduct
    mapping(string => DeployedProduct) public products;
    string[] public productIds;

    event ProductDeployed(
        string indexed productId,
        address indexed token,
        address indexed vault,
        string strategyType
    );
    event ProductDeactivated(string indexed productId);

    constructor(address navOracle_, address usdt_, address admin_) {
        require(navOracle_ != address(0), "Factory: zero oracle");
        require(usdt_ != address(0), "Factory: zero USDT");
        navOracle = navOracle_;
        usdt = usdt_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(OPERATOR_ROLE, admin_);
    }

    /**
     * @notice Deploy a new RWA product (token + vault pair).
     * @dev    Only ADMIN can deploy. Config validated on-chain, then contracts deployed.
     */
    function deployProduct(
        ProductConfig calldata config,
        address vaultOperator
    ) external onlyRole(ADMIN_ROLE) returns (address token, address vault) {
        require(bytes(config.productId).length > 0, "Factory: empty productId");
        require(products[config.productId].token == address(0), "Factory: productId exists");
        require(vaultOperator != address(0), "Factory: zero operator");

        // Deploy token
        token = address(new RWAToken(
            config.name,
            config.symbol,
            config.productId,
            config.strategyType,
            navOracle,
            msg.sender,         // admin
            address(0),         // vault: set after deploy below
            config.managementFeeBps,
            config.feeRecipient
        ));

        // Deploy vault
        vault = address(new RWAVault(
            usdt,
            token,
            msg.sender,         // admin
            vaultOperator,
            config.redemptionDelay,
            config.minSubscription
        ));

        // Grant vault role on token
        RWAToken(token).grantRole(keccak256("VAULT_ROLE"), vault);

        // Set SPV address
        if (config.spvAddress != address(0)) {
            RWAToken(token).setSPVAddress(config.spvAddress);
        }

        // Register
        products[config.productId] = DeployedProduct({
            token: token,
            vault: vault,
            productId: config.productId,
            strategyType: config.strategyType,
            deployedAt: block.timestamp,
            active: true
        });
        productIds.push(config.productId);

        emit ProductDeployed(config.productId, token, vault, config.strategyType);
    }

    function deactivateProduct(string calldata productId)
        external
        onlyRole(ADMIN_ROLE)
    {
        require(products[productId].token != address(0), "Factory: not found");
        products[productId].active = false;
        emit ProductDeactivated(productId);
    }

    function getAllProductIds() external view returns (string[] memory) {
        return productIds;
    }

    function getProduct(string calldata productId)
        external
        view
        returns (DeployedProduct memory)
    {
        return products[productId];
    }
}
