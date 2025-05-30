// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MerkleStateManager
 * @dev Manages deposit commitments and synced withdrawal roots for ZeroXBridge protocol
 * @notice Compatible with Alexandria Merkle Trees using deterministic leaf ordering
 */
contract MerkleStateManager is Ownable, ReentrancyGuard {
    using MerkleProof for bytes32[];

    bytes32 public depositRoot;
    bytes32 public withdrawalRoot;
    uint256 public depositRootIndex;
    uint256 public withdrawalRootIndex;

    mapping(uint256 => bytes32) public depositRootHistory;
    mapping(uint256 => bytes32) public withdrawalRootHistory;
    mapping(uint256 => uint256) public depositRootTimestamps;
    mapping(uint256 => uint256) public depositRootBlockNumbers;
    mapping(uint256 => uint256) public withdrawalRootTimestamps;
    mapping(uint256 => uint256) public withdrawalRootBlockNumbers;

    mapping(address => bool) public approvedRelayers;
    mapping(bytes32 => bool) public processedCommitments;

    event DepositRootUpdated(
        uint256 indexed index,
        bytes32 newRoot,
        bytes32 indexed commitment,
        uint256 timestamp,
        uint256 blockNumber
    );

    event WithdrawalRootSynced(
        uint256 indexed index,
        bytes32 newRoot,
        address indexed relayer,
        uint256 timestamp,
        uint256 blockNumber
    );

    event RelayerStatusChanged(address indexed relayer, bool status);
    event CommitmentProcessed(bytes32 indexed commitment);

    modifier onlyRelayer() {
        require(approvedRelayers[msg.sender], "MerkleStateManager: Only approved relayers");
        _;
    }

    /**
     * @dev Constructor initializes the contract with owner and initial roots
     * @param _owner Contract owner address
     * @param _initialDepositRoot Initial deposit root (can be zero)
     * @param _initialWithdrawalRoot Initial withdrawal root (can be zero)
     */
    constructor(
        address _owner,
        bytes32 _initialDepositRoot,
        bytes32 _initialWithdrawalRoot
    ) Ownable(_owner) {
        depositRoot = _initialDepositRoot;
        withdrawalRoot = _initialWithdrawalRoot;
        depositRootIndex = 0;
        withdrawalRootIndex = 0;

        DepositRootModule.initialize(
            _initialDepositRoot,
            depositRootHistory,
            depositRootTimestamps,
            depositRootBlockNumbers
        );

        WithdrawalRootModule.initialize(
            _initialWithdrawalRoot,
            withdrawalRootHistory,
            withdrawalRootTimestamps,
            withdrawalRootBlockNumbers
        );
    }

    /**
     * @dev Updates deposit root from a new commitment hash
     * @param commitment The commitment hash to add to the deposit tree
     */
    function updateDepositRootFromCommitment(bytes32 commitment) external nonReentrant {
        CommitmentValidation.validateNewCommitment(commitment, processedCommitments);

        bytes32 newRoot = DepositRootModule.updateRoot(
            commitment,
            depositRoot,
            depositRootIndex,
            depositRootHistory,
            depositRootTimestamps,
            depositRootBlockNumbers
        );

        depositRoot = newRoot;
        depositRootIndex++;
        processedCommitments[commitment] = true;

        emit CommitmentProcessed(commitment);
        emit DepositRootUpdated(
            depositRootIndex,
            newRoot,
            commitment,
            block.timestamp,
            block.number
        );
    }

    /**
     * @dev Syncs withdrawal root from L2 - only callable by approved relayers
     * @param newRoot The new withdrawal root from L2
     */
    function syncWithdrawalRootFromL2(bytes32 newRoot) external onlyRelayer nonReentrant {
        WithdrawalRootModule.updateRoot(
            newRoot,
            withdrawalRoot,
            withdrawalRootIndex,
            withdrawalRootHistory,
            withdrawalRootTimestamps,
            withdrawalRootBlockNumbers
        );

        withdrawalRoot = newRoot;
        withdrawalRootIndex++;

        emit WithdrawalRootSynced(
            withdrawalRootIndex,
            newRoot,
            msg.sender,
            block.timestamp,
            block.number
        );
    }

    /**
     * @dev Verifies a Merkle proof against the current withdrawal root
     * @param leaf The leaf to verify
     * @param proof The Merkle proof
     * @return true if proof is valid, false otherwise
     */
    function verifyWithdrawalProof(
        bytes32 leaf,
        bytes32[] calldata proof
    ) external view returns (bool) {
        return ProofValidation.verifyProof(proof, withdrawalRoot, leaf);
    }

    /**
     * @dev Sets relayer status for withdrawal root synchronization
     * @param relayer The relayer address
     * @param status True to approve, false to revoke
     */
    function setRelayerStatus(address relayer, bool status) external onlyOwner {
        AccessControlModule.updateRelayerStatus(relayer, status, approvedRelayers);
        emit RelayerStatusChanged(relayer, status);
    }
}

/**
 * @title DepositRootModule
 * @dev Modular logic for managing deposit root tracking and updates
 */
library DepositRootModule {
    /**
     * @dev Initialize deposit root state
     */
    function initialize(
        bytes32 initialRoot,
        mapping(uint256 => bytes32) storage historyStorage,
        mapping(uint256 => uint256) storage timestampStorage,
        mapping(uint256 => uint256) storage blockStorage
    ) internal {
        historyStorage[0] = initialRoot;
        timestampStorage[0] = block.timestamp;
        blockStorage[0] = block.number;
    }

    /**
     * @dev Update deposit root with new commitment
     */
    function updateRoot(
        bytes32 commitment,
        bytes32 currentRoot,
        uint256 currentIndex,
        mapping(uint256 => bytes32) storage historyStorage,
        mapping(uint256 => uint256) storage timestampStorage,
        mapping(uint256 => uint256) storage blockStorage
    ) internal returns (bytes32) {
        bytes32 newRoot = RootCalculation.calculateNewDepositRoot(currentRoot, commitment);

        uint256 newIndex = currentIndex + 1;
        historyStorage[newIndex] = newRoot;
        timestampStorage[newIndex] = block.timestamp;
        blockStorage[newIndex] = block.number;

        return newRoot;
    }
}

/**
 * @title WithdrawalRootModule
 * @dev Modular logic for managing withdrawal root tracking and updates
 */
library WithdrawalRootModule {
    /**
     * @dev Initialize withdrawal root state
     */
    function initialize(
        bytes32 initialRoot,
        mapping(uint256 => bytes32) storage historyStorage,
        mapping(uint256 => uint256) storage timestampStorage,
        mapping(uint256 => uint256) storage blockStorage
    ) internal {
        historyStorage[0] = initialRoot;
        timestampStorage[0] = block.timestamp;
        blockStorage[0] = block.number;
    }

    /**
     * @dev Update withdrawal root from L2
     */
    function updateRoot(
        bytes32 newRoot,
        bytes32 currentRoot,
        uint256 currentIndex,
        mapping(uint256 => bytes32) storage historyStorage,
        mapping(uint256 => uint256) storage timestampStorage,
        mapping(uint256 => uint256) storage blockStorage
    ) internal {
        require(newRoot != bytes32(0), "MerkleStateManager: Invalid root");
        require(newRoot != currentRoot, "MerkleStateManager: Root unchanged");

        uint256 newIndex = currentIndex + 1;
        historyStorage[newIndex] = newRoot;
        timestampStorage[newIndex] = block.timestamp;
        blockStorage[newIndex] = block.number;
    }
}

/**
 * @title ProofValidation
 * @dev Modular logic for Merkle proof verification
 */
library ProofValidation {
    using MerkleProof for bytes32[];

    /**
     * @dev Verify a Merkle proof against a given root
     */
    function verifyProof(
        bytes32[] calldata proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool) {
        return proof.verify(root, leaf);
    }

    /**
     * @dev Verify multiple proofs in batch (future enhancement)
     */
    function verifyBatchProofs(
        bytes32[][] calldata proofs,
        bytes32 root,
        bytes32[] calldata leaves
    ) internal pure returns (bool[] memory) {
        require(proofs.length == leaves.length, "ProofValidation: Array length mismatch");

        bool[] memory results = new bool[](proofs.length);
        for (uint256 i = 0; i < proofs.length; i++) {
            results[i] = verifyProof(proofs[i], root, leaves[i]);
        }
        return results;
    }
}

/**
 * @title AccessControlModule
 * @dev Modular logic for access control management
 */
library AccessControlModule {
    /**
     * @dev Update relayer status with validation
     */
    function updateRelayerStatus(
        address relayer,
        bool status,
        mapping(address => bool) storage relayerStorage
    ) internal {
        require(relayer != address(0), "MerkleStateManager: Invalid relayer address");
        relayerStorage[relayer] = status;
    }

    /**
     * @dev Check if address is approved relayer
     */
    function isApprovedRelayer(
        address relayer,
        mapping(address => bool) storage relayerStorage
    ) internal view returns (bool) {
        return relayerStorage[relayer];
    }
}

/**
 * @title CommitmentValidation
 * @dev Modular logic for commitment validation and replay protection
 */
library CommitmentValidation {
    /**
     * @dev Validate new commitment for processing
     */
    function validateNewCommitment(
        bytes32 commitment,
        mapping(bytes32 => bool) storage processedStorage
    ) internal view {
        require(commitment != bytes32(0), "MerkleStateManager: Invalid commitment");
        require(!processedStorage[commitment], "MerkleStateManager: Commitment already processed");
    }

    /**
     * @dev Check if commitment has been processed
     */
    function isCommitmentProcessed(
        bytes32 commitment,
        mapping(bytes32 => bool) storage processedStorage
    ) internal view returns (bool) {
        return processedStorage[commitment];
    }
}

/**
 * @title RootCalculation
 * @dev Modular logic for root calculation algorithms
 */
library RootCalculation {
    /**
     * @dev Calculate new deposit root using Alexandria-compatible method
     */
    function calculateNewDepositRoot(
        bytes32 currentRoot,
        bytes32 commitment
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(currentRoot, commitment));
    }

    /**
     * @dev Calculate root from leaf array (future enhancement)
     */
    function calculateRootFromLeaves(
        bytes32[] memory leaves
    ) internal pure returns (bytes32) {
        require(leaves.length > 0, "RootCalculation: Empty leaves array");

        bytes32 root = leaves[0];
        for (uint256 i = 1; i < leaves.length; i++) {
            root = keccak256(abi.encodePacked(root, leaves[i]));
        }
        return root;
    }
}
