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

    bytes32 public depositRoot;
    bytes32 public withdrawalRoot;
    uint256 public depositRootIndex;
    uint256 public withdrawalRootIndex;
    uint256 public depositTreeDepth;
    uint256 public depositLeafCount;

    mapping(uint256 => bytes32) public depositRootHistory;
    mapping(uint256 => bytes32) public withdrawalRootHistory;
    mapping(uint256 => uint256) public depositRootTimestamps;
    mapping(uint256 => uint256) public withdrawalRootTimestamps;
    mapping(address => bool) public approvedRelayers;
    mapping(bytes32 => bool) public processedCommitments;
    mapping(bytes32 => uint256) public commitmentToLeafIndex;
    bytes32[] public leaves;
    mapping(uint256 => bytes32) public merkleTree;
    mapping(address => uint256) public lastOperationTime;
    mapping(address => uint256) public operationCount;
    uint256 private constant RATE_LIMIT_WINDOW = 15 seconds;
    uint256 private constant MAX_OPERATIONS_PER_WINDOW = 10;
    uint256 public constant MAX_TREE_DEPTH = 32;
    uint256 public constant MAX_LEAF_COUNT = 2**32 - 1;

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
        depositRootHistory[0] = genesisDepositRoot;
        withdrawalRootHistory[0] = genesisWithdrawalRoot;
        depositRootTimestamps[0] = block.timestamp;
        withdrawalRootTimestamps[0] = block.timestamp;
    }

    // Using OpenZeppelin's built-in whenNotPaused modifier instead of custom implementation

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
        require(approvedRelayers[msg.sender], "MerkleStateManager: Only approved relayers");
        _;
    }

    /**
     * @dev Updates deposit root from a new commitment using Alexandria tree structure
     * @param commitment The commitment hash to add to the tree
     */
    function updateDepositRootFromCommitment(
        bytes32 commitment
    ) external whenNotPaused nonReentrant rateLimited {
        require(commitment != bytes32(0), "MerkleStateManager: Invalid commitment");
        require(!processedCommitments[commitment], "MerkleStateManager: Commitment already processed");
        require(depositLeafCount < MAX_LEAF_COUNT, "MerkleStateManager: Tree capacity exceeded");

        processedCommitments[commitment] = true;
        uint256 leafIndex = depositLeafCount;
        commitmentToLeafIndex[commitment] = leafIndex;
        leaves.push(commitment);
        bytes32 newRoot = _calculateNewDepositRoot(commitment, leafIndex);
        depositRoot = newRoot;
        depositRootIndex++;
        depositLeafCount++;
        uint256 newDepth = _calculateTreeDepth(depositLeafCount);
        if (newDepth > depositTreeDepth) {
            depositTreeDepth = newDepth;
        }
        depositRootHistory[depositRootIndex] = newRoot;
        depositRootTimestamps[depositRootIndex] = block.timestamp;

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
        require(commitments.length > 0 && commitments.length <= 100, "MerkleStateManager: Invalid batch size");
        require(depositLeafCount + commitments.length <= MAX_LEAF_COUNT, "MerkleStateManager: Batch exceeds capacity");
        uint256 startLeafIndex = depositLeafCount;
        for (uint256 i = 0; i < commitments.length; i++) {
            bytes32 commitment = commitments[i];
            require(commitment != bytes32(0), "MerkleStateManager: Invalid commitment in batch");
            require(!processedCommitments[commitment], "MerkleStateManager: Duplicate commitment in batch");
            processedCommitments[commitment] = true;
            commitmentToLeafIndex[commitment] = startLeafIndex + i;
            leaves.push(commitment);
            emit CommitmentProcessed(commitment, startLeafIndex + i);
        }

        // Update leaf count
        depositLeafCount += commitments.length;

        // Calculate new root for the entire batch
        bytes32 newRoot = _recalculateDepositRoot();

        depositRoot = newRoot;
        depositRootIndex++;
        uint256 newDepth = _calculateTreeDepth(depositLeafCount);
        if (newDepth > depositTreeDepth) {
            depositTreeDepth = newDepth;
        }
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
        require(newRoot != bytes32(0), "MerkleStateManager: Invalid root");
        require(newRoot != withdrawalRoot, "MerkleStateManager: Root unchanged");
        withdrawalRoot = newRoot;
        withdrawalRootIndex++;
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
        require(relayer != address(0), "MerkleStateManager: Invalid relayer address");
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
        require(leafIndex < depositLeafCount, "MerkleStateManager: Invalid leaf index");

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
     * @dev Optimized Merkle root calculation using Alexandria-style approach
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

        // Pad to next power of 2 for deterministic structure (Alexandria style)
        uint256 paddedSize = _nextPowerOfTwo(n);
        bytes32[] memory tree = new bytes32[](paddedSize);

        for (uint256 i = 0; i < n; i++) {
            tree[i] = leafArray[i];
        }
        for (uint256 i = n; i < paddedSize; i++) {
            tree[i] = bytes32(0);
        }

        // Build tree bottom-up with deterministic ordering
        uint256 currentSize = paddedSize;
        while (currentSize > 1) {
            for (uint256 i = 0; i < currentSize / 2; i++) {
                bytes32 left = tree[2 * i];
                bytes32 right = tree[2 * i + 1];
                tree[i] = keccak256(abi.encodePacked(left, right));
            }
            currentSize = currentSize / 2;
        }

        return tree[0];
    }

    /**
     * @dev Calculate next power of 2 for deterministic tree structure
     */
    function _nextPowerOfTwo(uint256 n) internal pure returns (uint256) {
        if (n <= 1) return 1;
        uint256 power = 1;
        while (power < n) {
            power <<= 1;
        }
        return power;
    }

    /**
     * @dev Optimized proof generation using stored intermediate nodes
     * @param leafIndex The index of the leaf
     * @return The Merkle proof
     */
    function _generateMerkleProof(uint256 leafIndex) internal view returns (bytes32[] memory) {
        if (depositLeafCount <= 1) {
            return new bytes32[](0);
        }

        uint256 treeSize = _nextPowerOfTwo(depositLeafCount);
        uint256 depth = _log2(treeSize);
        bytes32[] memory proof = new bytes32[](depth);
        uint256 currentIndex = leafIndex;
        for (uint256 i = 0; i < depth; i++) {
            uint256 siblingIndex = currentIndex ^ 1;
            if (siblingIndex < depositLeafCount) {
                proof[i] = leaves[siblingIndex];
            } else {
                proof[i] = bytes32(0);
            }
            currentIndex = currentIndex / 2;
        }
        return proof;
    }

    /**
     * @dev Calculate log2 of a number
     */
    function _log2(uint256 n) internal pure returns (uint256) {
        uint256 result = 0;
        while (n > 1) {
            n >>= 1;
            result++;
        }
        return result;
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
     * @dev Checks rate limiting for the caller
     */
    function _checkRateLimit() internal view {
        uint256 currentTime = block.timestamp;
        uint256 lastTime = lastOperationTime[msg.sender];
        if (currentTime < lastTime + RATE_LIMIT_WINDOW) {
            require(operationCount[msg.sender] < MAX_OPERATIONS_PER_WINDOW, "MerkleStateManager: Rate limit exceeded");
        }
    }

    /**
     * @dev Updates rate limiting state for the caller
     */
    function _updateRateLimit() internal {
        uint256 currentTime = block.timestamp;
        uint256 lastTime = lastOperationTime[msg.sender];
        if (currentTime >= lastTime + RATE_LIMIT_WINDOW) {
            operationCount[msg.sender] = 1;
            lastOperationTime[msg.sender] = currentTime;
        } else {
            operationCount[msg.sender]++;
        }
    }
}
