// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title MerkleStateManager
 * @dev Manages deposit commitments and synced withdrawal roots for ZeroXBridge protocol
 * @notice Compatible with Alexandria Merkle Trees using deterministic leaf ordering and proper tree construction
 */
contract MerkleStateManager is Ownable, ReentrancyGuard, Pausable {
    using MerkleProof for bytes32[];

    // Core state variables
    bytes32 public depositRoot;
    bytes32 public withdrawalRoot;
    uint256 public depositRootIndex;
    uint256 public withdrawalRootIndex;

    // Tree management
    uint256 public depositTreeDepth;
    uint256 public depositLeafCount;

    // History tracking
    mapping(uint256 => bytes32) public depositRootHistory;
    mapping(uint256 => bytes32) public withdrawalRootHistory;
    mapping(uint256 => uint256) public depositRootTimestamps;
    mapping(uint256 => uint256) public withdrawalRootTimestamps;

    // Security and access control
    mapping(address => bool) public approvedRelayers;
    mapping(bytes32 => bool) public processedCommitments;
    mapping(bytes32 => uint256) public commitmentToLeafIndex;

    // Alexandria tree structure
    bytes32[] public leaves;
    mapping(uint256 => bytes32) public merkleTree;

    // Rate limiting
    mapping(address => uint256) public lastOperationTime;
    mapping(address => uint256) public operationCount;
    uint256 private constant RATE_LIMIT_WINDOW = 10 seconds; // For testing
    uint256 private constant MAX_OPERATIONS_PER_WINDOW = 10; // Increased for testing

    // Tree capacity management
    uint256 public constant MAX_TREE_DEPTH = 32;
    uint256 public constant MAX_LEAF_COUNT = 2**32 - 1;

    // Events
    event DepositRootUpdated(
        uint256 indexed index,
        bytes32 newRoot,
        bytes32 indexed commitment,
        uint256 leafIndex,
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
    event CommitmentProcessed(bytes32 indexed commitment, uint256 leafIndex);
    event EmergencyPause(address indexed admin, string reason);
    event EmergencyUnpause(address indexed admin);

    // Custom errors
    error InvalidCommitment();
    error CommitmentAlreadyProcessed();
    error InvalidRelayer();
    error OnlyApprovedRelayers();
    error InvalidRoot();
    error RootUnchanged();
    error InvalidBatchSize();
    error RateLimitExceeded();
    error InvalidLeafIndex();
    error TreeCapacityExceeded();

    /**
     * @dev Constructor initializes the contract with genesis roots
     * @param initialOwner The initial owner of the contract
     * @param genesisDepositRoot The initial deposit root
     * @param genesisWithdrawalRoot The initial withdrawal root
     */
    constructor(
        address initialOwner,
        bytes32 genesisDepositRoot,
        bytes32 genesisWithdrawalRoot
    ) Ownable(initialOwner) {
        require(initialOwner != address(0), "MerkleStateManager: Invalid owner");
        require(genesisDepositRoot != bytes32(0), "MerkleStateManager: Invalid genesis deposit root");
        require(genesisWithdrawalRoot != bytes32(0), "MerkleStateManager: Invalid genesis withdrawal root");

        depositRoot = genesisDepositRoot;
        withdrawalRoot = genesisWithdrawalRoot;

        // Store genesis roots in history
        depositRootHistory[0] = genesisDepositRoot;
        withdrawalRootHistory[0] = genesisWithdrawalRoot;
        depositRootTimestamps[0] = block.timestamp;
        withdrawalRootTimestamps[0] = block.timestamp;
    }

    /**
     * @dev Modifier to check rate limiting
     */
    modifier rateLimited() {
        _checkRateLimit();
        _;
        _updateRateLimit();
    }

    /**
     * @dev Modifier to ensure only approved relayers can call certain functions
     */
    modifier onlyRelayer() {
        if (!approvedRelayers[msg.sender]) {
            revert OnlyApprovedRelayers();
        }
        _;
    }

    /**
     * @dev Updates deposit root from a new commitment using Alexandria tree structure
     * @param commitment The commitment hash to add to the tree
     */
    function updateDepositRootFromCommitment(
        bytes32 commitment
    ) external whenNotPaused nonReentrant rateLimited {
        if (commitment == bytes32(0)) {
            revert InvalidCommitment();
        }
        if (processedCommitments[commitment]) {
            revert CommitmentAlreadyProcessed();
        }
        if (depositLeafCount >= MAX_LEAF_COUNT) {
            revert TreeCapacityExceeded();
        }

        // Mark commitment as processed
        processedCommitments[commitment] = true;
        uint256 leafIndex = depositLeafCount;
        commitmentToLeafIndex[commitment] = leafIndex;

        // Add leaf to the tree
        leaves.push(commitment);

        // Calculate new root using Alexandria tree construction
        bytes32 newRoot = _calculateNewDepositRoot(commitment, leafIndex);

        // Update state
        depositRoot = newRoot;
        depositRootIndex++;
        depositLeafCount++;

        // Update tree depth if necessary
        uint256 newDepth = _calculateTreeDepth(depositLeafCount);
        if (newDepth > depositTreeDepth) {
            depositTreeDepth = newDepth;
        }

        // Store in history
        depositRootHistory[depositRootIndex] = newRoot;
        depositRootTimestamps[depositRootIndex] = block.timestamp;

        // Emit events
        emit CommitmentProcessed(commitment, leafIndex);
        emit DepositRootUpdated(
            depositRootIndex,
            newRoot,
            commitment,
            leafIndex,
            block.timestamp,
            block.number
        );
    }

    /**
     * @dev Batch update deposit roots for efficiency
     * @param commitments Array of commitments to process
     */
    function batchUpdateDepositRoots(
        bytes32[] calldata commitments
    ) external whenNotPaused nonReentrant rateLimited {
        if (commitments.length == 0 || commitments.length > 100) {
            revert InvalidBatchSize();
        }
        if (depositLeafCount + commitments.length > MAX_LEAF_COUNT) {
            revert TreeCapacityExceeded();
        }

        uint256 startLeafIndex = depositLeafCount;

        // Process all commitments
        for (uint256 i = 0; i < commitments.length; i++) {
            bytes32 commitment = commitments[i];

            if (commitment == bytes32(0)) {
                revert InvalidCommitment();
            }
            if (processedCommitments[commitment]) {
                revert CommitmentAlreadyProcessed();
            }

            processedCommitments[commitment] = true;
            commitmentToLeafIndex[commitment] = startLeafIndex + i;
            leaves.push(commitment);

            emit CommitmentProcessed(commitment, startLeafIndex + i);
        }

        // Update leaf count
        depositLeafCount += commitments.length;

        // Calculate new root for the entire batch
        bytes32 newRoot = _recalculateDepositRoot();

        // Update state
        depositRoot = newRoot;
        depositRootIndex++;

        // Update tree depth
        uint256 newDepth = _calculateTreeDepth(depositLeafCount);
        if (newDepth > depositTreeDepth) {
            depositTreeDepth = newDepth;
        }

        // Store in history
        depositRootHistory[depositRootIndex] = newRoot;
        depositRootTimestamps[depositRootIndex] = block.timestamp;

        emit DepositRootUpdated(
            depositRootIndex,
            newRoot,
            commitments[0], // First commitment as reference
            startLeafIndex,
            block.timestamp,
            block.number
        );
    }

    /**
     * @dev Syncs withdrawal root from L2
     * @param newRoot The new withdrawal root from L2
     */
    function syncWithdrawalRootFromL2(
        bytes32 newRoot
    ) external whenNotPaused nonReentrant onlyRelayer rateLimited {
        if (newRoot == bytes32(0)) {
            revert InvalidRoot();
        }
        if (newRoot == withdrawalRoot) {
            revert RootUnchanged();
        }

        // Update state
        withdrawalRoot = newRoot;
        withdrawalRootIndex++;

        // Store in history
        withdrawalRootHistory[withdrawalRootIndex] = newRoot;
        withdrawalRootTimestamps[withdrawalRootIndex] = block.timestamp;

        emit WithdrawalRootSynced(
            withdrawalRootIndex,
            newRoot,
            msg.sender,
            block.timestamp,
            block.number
        );
    }

    /**
     * @dev Manages relayer approval status
     * @param relayer The relayer address
     * @param status The approval status
     */
    function setRelayerStatus(address relayer, bool status) external onlyOwner {
        if (relayer == address(0)) {
            revert InvalidRelayer();
        }

        approvedRelayers[relayer] = status;
        emit RelayerStatusChanged(relayer, status);
    }

    /**
     * @dev Emergency pause function
     * @param reason The reason for pausing
     */
    function emergencyPause(string calldata reason) external onlyOwner {
        _pause();
        emit EmergencyPause(msg.sender, reason);
    }

    /**
     * @dev Unpause the contract
     */
    function unpause() external onlyOwner {
        _unpause();
        emit EmergencyUnpause(msg.sender);
    }

    /**
     * @dev Verifies a withdrawal proof against the current withdrawal root
     * @param leaf The leaf to verify
     * @param proof The Merkle proof
     * @return True if the proof is valid
     */
    function verifyWithdrawalProof(
        bytes32 leaf,
        bytes32[] calldata proof
    ) external view returns (bool) {
        return MerkleProof.verify(proof, withdrawalRoot, leaf);
    }

    /**
     * @dev Verifies a deposit proof against the current deposit root
     * @param leaf The leaf to verify
     * @param leafIndex The index of the leaf in the tree
     * @param proof The Merkle proof
     * @return True if the proof is valid
     */
    function verifyDepositProof(
        bytes32 leaf,
        uint256 leafIndex,
        bytes32[] calldata proof
    ) external view returns (bool) {
        if (leafIndex >= depositLeafCount) {
            return false;
        }

        return MerkleProof.verify(proof, depositRoot, leaf);
    }

    /**
     * @dev Gets the Merkle proof for a deposit at a specific index
     * @param leafIndex The index of the leaf
     * @return The Merkle proof
     */
    function getDepositProof(uint256 leafIndex) external view returns (bytes32[] memory) {
        if (leafIndex >= depositLeafCount) {
            revert InvalidLeafIndex();
        }

        return _generateMerkleProof(leafIndex);
    }

    /**
     * @dev Gets deposit tree information
     * @return depth The current tree depth
     * @return leafCount The current leaf count
     * @return root The current deposit root
     */
    function getDepositTreeInfo() external view returns (
        uint256 depth,
        uint256 leafCount,
        bytes32 root
    ) {
        return (depositTreeDepth, depositLeafCount, depositRoot);
    }

    /**
     * @dev Gets withdrawal tree information
     * @return index The current withdrawal root index
     * @return root The current withdrawal root
     */
    function getWithdrawalTreeInfo() external view returns (
        uint256 index,
        bytes32 root
    ) {
        return (withdrawalRootIndex, withdrawalRoot);
    }

    /**
     * @dev Calculates new deposit root using Alexandria tree construction
     * @param commitment The new commitment to add
     * @param leafIndex The index where the commitment will be placed
     * @return The new Merkle root
     */
    function _calculateNewDepositRoot(
        bytes32 commitment,
        uint256 leafIndex
    ) internal view returns (bytes32) {
        if (leafIndex == 0) {
            return commitment;
        }

        // Build the tree from scratch with the new leaf
        bytes32[] memory tempLeaves = new bytes32[](depositLeafCount + 1);
        for (uint256 i = 0; i < depositLeafCount; i++) {
            tempLeaves[i] = leaves[i];
        }
        tempLeaves[leafIndex] = commitment;

        return _calculateMerkleRoot(tempLeaves);
    }

    /**
     * @dev Recalculates the entire deposit root from current leaves
     * @return The calculated Merkle root
     */
    function _recalculateDepositRoot() internal view returns (bytes32) {
        return _calculateMerkleRoot(leaves);
    }

    /**
     * @dev Calculates Merkle root from an array of leaves
     * @param leafArray The array of leaves
     * @return The calculated Merkle root
     */
    function _calculateMerkleRoot(bytes32[] memory leafArray) internal pure returns (bytes32) {
        if (leafArray.length == 0) {
            return bytes32(0);
        }
        if (leafArray.length == 1) {
            return leafArray[0];
        }

        uint256 n = leafArray.length;
        bytes32[] memory tree = new bytes32[](n);

        // Copy leaves to tree
        for (uint256 i = 0; i < n; i++) {
            tree[i] = leafArray[i];
        }

        // Build tree bottom-up
        while (n > 1) {
            for (uint256 i = 0; i < n / 2; i++) {
                tree[i] = keccak256(abi.encodePacked(tree[2 * i], tree[2 * i + 1]));
            }
            if (n % 2 == 1) {
                tree[n / 2] = tree[n - 1];
                n = n / 2 + 1;
            } else {
                n = n / 2;
            }
        }

        return tree[0];
    }

    /**
     * @dev Calculates the depth needed for a tree with given leaf count
     * @param leafCount The number of leaves
     * @return The required tree depth
     */
    function _calculateTreeDepth(uint256 leafCount) internal pure returns (uint256) {
        if (leafCount <= 1) return leafCount;

        uint256 depth = 0;
        uint256 temp = leafCount - 1;
        while (temp > 0) {
            temp >>= 1;
            depth++;
        }
        return depth;
    }

    /**
     * @dev Generates a Merkle proof for a leaf at a specific index
     * @param leafIndex The index of the leaf
     * @return The Merkle proof
     */
    function _generateMerkleProof(uint256 leafIndex) internal view returns (bytes32[] memory) {
        if (depositLeafCount <= 1) {
            return new bytes32[](0);
        }

        bytes32[] memory proof = new bytes32[](depositTreeDepth);
        uint256 proofIndex = 0;
        uint256 currentIndex = leafIndex;
        uint256 levelSize = depositLeafCount;

        // Generate proof by traversing up the tree
        for (uint256 level = 0; level < depositTreeDepth && levelSize > 1; level++) {
            if (currentIndex % 2 == 0) {
                // Left node, need right sibling
                if (currentIndex + 1 < levelSize) {
                    proof[proofIndex] = _getTreeNode(level, currentIndex + 1);
                } else {
                    proof[proofIndex] = bytes32(0);
                }
            } else {
                // Right node, need left sibling
                proof[proofIndex] = _getTreeNode(level, currentIndex - 1);
            }

            proofIndex++;
            currentIndex = currentIndex / 2;
            levelSize = (levelSize + 1) / 2;
        }

        // Trim the proof to actual size
        bytes32[] memory trimmedProof = new bytes32[](proofIndex);
        for (uint256 i = 0; i < proofIndex; i++) {
            trimmedProof[i] = proof[i];
        }

        return trimmedProof;
    }

    /**
     * @dev Gets a node from the tree at a specific level and index
     * @param level The level in the tree (0 = leaves)
     * @param index The index at that level
     * @return The node value
     */
    function _getTreeNode(uint256 level, uint256 index) internal view returns (bytes32) {
        if (level == 0) {
            return index < depositLeafCount ? leaves[index] : bytes32(0);
        }

        // For higher levels, we'd need to calculate or store the intermediate nodes
        // For simplicity, we'll calculate on-demand
        uint256 leftChild = index * 2;
        uint256 rightChild = leftChild + 1;

        bytes32 left = _getTreeNode(level - 1, leftChild);
        bytes32 right = _getTreeNode(level - 1, rightChild);

        if (left == bytes32(0)) return bytes32(0);
        if (right == bytes32(0)) return left;

        return keccak256(abi.encodePacked(left, right));
    }

    /**
     * @dev Checks rate limiting for the caller
     */
    function _checkRateLimit() internal view {
        uint256 currentTime = block.timestamp;
        uint256 lastTime = lastOperationTime[msg.sender];

        if (currentTime < lastTime + RATE_LIMIT_WINDOW) {
            if (operationCount[msg.sender] >= MAX_OPERATIONS_PER_WINDOW) {
                revert RateLimitExceeded();
            }
        }
    }

    /**
     * @dev Updates rate limiting state for the caller
     */
    function _updateRateLimit() internal {
        uint256 currentTime = block.timestamp;
        uint256 lastTime = lastOperationTime[msg.sender];

        if (currentTime >= lastTime + RATE_LIMIT_WINDOW) {
            // Reset the window
            operationCount[msg.sender] = 1;
            lastOperationTime[msg.sender] = currentTime;
        } else {
            // Increment counter
            operationCount[msg.sender]++;
        }
    }
}
