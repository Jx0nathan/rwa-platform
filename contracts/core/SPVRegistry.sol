// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title SPVRegistry
 * @notice On-chain registry mapping each RWA product to its off-chain legal structure.
 *
 * Each product has:
 *   - An SPV entity (legal shell company holding assets)
 *   - A custodian (bank/regulated entity holding cash/securities)
 *   - A fund administrator (independent NAV calculator)
 *   - An auditor (annual/quarterly asset verification)
 *   - Compliance attestations with timestamps
 *
 * This doesn't hold actual assets — it's a transparency layer that lets
 * any on-chain verifier check that a product has the required off-chain
 * legal scaffolding in place.
 */
contract SPVRegistry is AccessControl {
    bytes32 public constant ADMIN_ROLE     = keccak256("ADMIN_ROLE");
    bytes32 public constant ATTESTOR_ROLE  = keccak256("ATTESTOR_ROLE");

    struct SPVEntity {
        string  legalName;          // "Asseto CASH+ SPV Limited"
        string  jurisdiction;       // "Cayman Islands" | "Hong Kong" | "BVI"
        string  registrationNumber; // Incorporation number
        address custodian;          // Custodian wallet/identifier
        address fundAdmin;          // Fund administrator
        address auditor;            // Auditing firm
        uint256 lastAuditAt;        // Timestamp of last asset audit
        uint256 lastAttestationAt;  // Timestamp of last compliance check
        bool    compliant;          // Current compliance status
        string  custodianName;      // Human readable custodian name
        string  auditorName;        // Human readable auditor name
        string  ipfsAuditReport;    // IPFS hash of latest audit report
    }

    // product token address => SPV entity data
    mapping(address => SPVEntity) public registry;

    event SPVRegistered(address indexed product, string legalName, string jurisdiction);
    event AttestationUpdated(address indexed product, bool compliant, uint256 timestamp);
    event AuditReportUploaded(address indexed product, string ipfsHash, uint256 timestamp);

    constructor(address admin_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(ATTESTOR_ROLE, admin_);
    }

    /**
     * @notice Register or update SPV details for a product.
     */
    function registerSPV(address product, SPVEntity calldata entity)
        external
        onlyRole(ADMIN_ROLE)
    {
        require(product != address(0), "SPVRegistry: zero product");
        require(bytes(entity.legalName).length > 0, "SPVRegistry: empty name");
        registry[product] = entity;
        emit SPVRegistered(product, entity.legalName, entity.jurisdiction);
    }

    /**
     * @notice Update compliance attestation (called by authorized attestor after review).
     */
    function updateAttestation(address product, bool compliant)
        external
        onlyRole(ATTESTOR_ROLE)
    {
        require(registry[product].custodian != address(0), "SPVRegistry: not registered");
        registry[product].compliant = compliant;
        registry[product].lastAttestationAt = block.timestamp;
        emit AttestationUpdated(product, compliant, block.timestamp);
    }

    /**
     * @notice Upload IPFS hash of new audit report.
     */
    function uploadAuditReport(address product, string calldata ipfsHash)
        external
        onlyRole(ATTESTOR_ROLE)
    {
        require(registry[product].custodian != address(0), "SPVRegistry: not registered");
        registry[product].ipfsAuditReport = ipfsHash;
        registry[product].lastAuditAt = block.timestamp;
        emit AuditReportUploaded(product, ipfsHash, block.timestamp);
    }

    /**
     * @notice Check whether a product is fully compliant and recently attested.
     * @param maxAttestationAge Maximum acceptable age of attestation in seconds.
     */
    function isCompliant(address product, uint256 maxAttestationAge)
        external
        view
        returns (bool)
    {
        SPVEntity storage e = registry[product];
        if (!e.compliant) return false;
        if (e.lastAttestationAt == 0) return false;
        if (block.timestamp - e.lastAttestationAt > maxAttestationAge) return false;
        return true;
    }

    function getSPV(address product) external view returns (SPVEntity memory) {
        return registry[product];
    }
}
