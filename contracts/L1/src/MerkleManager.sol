// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@soliditymmr/src/lib/StatelessMmr.sol";
import "@soliditymmr/src/lib/StatelessMmrHelpers.sol";
import {console} from "forge-std/console.sol";

/**
 * @title MerkleManager
 * @dev Manages deposit commitments and synced withdrawal roots for ZeroXBridge protocol
 */
contract MerkleManager {
    // Mapping of node index to relative root hash
    mapping(uint256 => bytes32) internal nodeIndexToRoot;

    // Mapping of node index to peaks. Peaks can be calculated and/or stored off-chain
    mapping(uint256 => bytes32[]) internal nodeIndexToPeaks;

    // Mapping of commitment hash to its index in the tree
    mapping(bytes32 => uint256) internal commitmentHashToIndex;

    // Peaks of the last tree can be calculated and/or stored off-chain
    bytes32[] internal lastPeaks;

    // Latest elements count
    uint256 internal lastElementsCount;

    // Latest root hash
    bytes32 internal lastRoot;

    // Number of leaves in the tree
    uint256 internal leavesCount;

    // Emitted event after each successful `append` operation
    // Index of the appended deposit
    // The deposit commitment hash
    // The new root hash after append
    // The new number of elements in the tree
    event DepositHashAppended(uint256 index, bytes32 commitmentHash, bytes32 rootHash, uint256 elementsCount);

    /**
     * @dev Appends a new deposit commitment to the tree.
     * Updates peaks, root, and mappings. Emits DepositHashAppended.
     * @param commitmentHash The hash of the deposit commitment to append.
     */
    function appendDepositHash(bytes32 commitmentHash) internal {
        // Append element to the tree and retrieve updated peaks and root
        (uint256 nextElementsCount, bytes32 nextRootHash, bytes32[] memory nextPeaks) =
            StatelessMmr.appendWithPeaksRetrieval(commitmentHash, lastPeaks, lastElementsCount, lastRoot);

        // Update contract state with new peaks, root, and element count
        lastPeaks = nextPeaks;
        lastElementsCount = nextElementsCount;
        lastRoot = nextRootHash;
        nodeIndexToRoot[nextElementsCount] = lastRoot;
        nodeIndexToPeaks[nextElementsCount] = lastPeaks;

        // Map commitment hash to its correct MMR leaf index
        uint256 mmrLeafIndex = leafCountToMmrIndex(leavesCount);
        commitmentHashToIndex[commitmentHash] = mmrLeafIndex;
        leavesCount += 1;

        // Emit event for the appended deposit
        emit DepositHashAppended(leavesCount, commitmentHash, lastRoot, lastElementsCount);
    }

    /**
     * @dev Appends multiple deposit commitments to the tree in a batch.
     * Updates peaks, root, and mappings for each. Emits DepositHashAppended for each.
     * @param commitmentHashes Array of deposit commitment hashes to append.
     */
    function multiAppendDepositHash(bytes32[] memory commitmentHashes) internal {
        // Initialize local variables with current state
        uint256 nextElementsCount = lastElementsCount;
        bytes32 nextRoot = lastRoot;
        bytes32[] memory nextPeaks = lastPeaks;

        // Loop through each commitment hash and append to the tree
        for (uint256 i = 0; i < commitmentHashes.length; ++i) {
            (nextElementsCount, nextRoot, nextPeaks) =
                StatelessMmr.appendWithPeaksRetrieval(commitmentHashes[i], nextPeaks, nextElementsCount, nextRoot);

            uint256 mmrLeafIndex = leafCountToMmrIndex(leavesCount);

            // Map commitment hash to its correct MMR leaf index
            commitmentHashToIndex[commitmentHashes[i]] = mmrLeafIndex;

            leavesCount += 1;

            // Emit event for each appended deposit
            emit DepositHashAppended(leavesCount, commitmentHashes[i], lastRoot, lastElementsCount);
        }

        // Update contract state with new peaks, root, and element count
        lastPeaks = nextPeaks;
        lastElementsCount = nextElementsCount;
        lastRoot = nextRoot;
        nodeIndexToRoot[nextElementsCount] = lastRoot;
        nodeIndexToPeaks[nextElementsCount] = lastPeaks;
    }

    /**
     * @dev Returns the root hash of the tree.
     * @return The latest root hash.
     */
    function getRootHash() external view returns (bytes32) {
        return lastRoot;
    }

    /**
     * @dev Returns the number of nodes in the tree.
     * @return The latest elements count.
     */
    function getElementsCount() external view returns (uint256) {
        return lastElementsCount;
    }

    /**
     * @dev Returns the number of nodes in the tree.
     * @param commitmentHash Commitment hash to check for.
     * @return The index of the commitment hash in the tree.
     */
    function getCommitmentIndex(bytes32 commitmentHash) external view returns (uint256) {
        // Return the index of the commitment hash in the tree
        return commitmentHashToIndex[commitmentHash];
    }

    /**
     * @dev Returns the peaks of the last tree.
     * @return Array of peak hashes.
     */
    function getLastPeaks() external view returns (bytes32[] memory) {
        return lastPeaks;
    }

    /**
     * @dev Verifies a Merkle proof for a deposit.
     * @param index The index of the leaf in the tree.
     * @param value The value of the leaf.
     * @param proof The Merkle proof array.
     * @param peaks The peaks of the tree.
     * @param elementsCount The total number of elements in the tree.
     * @param root The expected root hash.
     */
    function verifyDepositProof(
        uint256 index,
        bytes32 value,
        bytes32[] memory proof,
        bytes32[] memory peaks,
        uint256 elementsCount,
        bytes32 root
    ) external pure {
        // Verify the proof using StatelessMmr
        StatelessMmr.verifyProof(index, value, proof, peaks, elementsCount, root);
    }

    /**
     * @dev Converts a leaf count (0-based) to the actual MMR leaf index
     * @param leafCount The sequential leaf number (0, 1, 2, 3...)
     * @return The actual MMR index where this leaf is positioned
     */
    function leafCountToMmrIndex(uint256 leafCount) internal pure returns (uint256) {
        if (leafCount == 0) return 0;

        // Calculate the number of internal nodes before this leaf
        uint256 internalNodes = 0;
        uint256 temp = leafCount;

        while (temp > 0) {
            temp >>= 1;
            internalNodes += temp;
        }

        return leafCount + internalNodes;
    }
}
