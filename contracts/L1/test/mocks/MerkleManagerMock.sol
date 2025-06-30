// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MerkleManager} from "../../src/MerkleManager.sol";

/**
 * @title MerkleMockManager
 * @dev Manages deposit commitments and synced withdrawal roots for ZeroXBridge protocol
 */
contract MerkleMockManager is MerkleManager {
    /**
     * @dev Appends a new deposit commitment to the tree.
     * Updates peaks, root, and mappings. Emits DepositHashAppended.
     * @param commitmentHash The hash of the deposit commitment to append.
     */
    function appendDepositHashPublic(bytes32 commitmentHash) public {
        appendDepositHash(commitmentHash);
    }

    /**
     * @dev Appends multiple deposit commitments to the tree in a batch.
     * Updates peaks, root, and mappings for each. Emits DepositHashAppended for each.
     * @param commitmentHashes Array of deposit commitment hashes to append.
     */
    function multiAppendDepositHashPublic(bytes32[] memory commitmentHashes) public {
        multiAppendDepositHash(commitmentHashes);
    }
}
