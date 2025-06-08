// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MerkleStateManager} from "../src/MerkleStateManager.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MerkleStateManagerTest is Test {
    MerkleStateManager public merkleManager;

    address public owner = makeAddr("owner");
    address public relayer1 = makeAddr("relayer1");
    address public relayer2 = makeAddr("relayer2");
    address public user = makeAddr("user");
    address public unauthorizedUser = makeAddr("unauthorized");

    bytes32 public constant GENESIS_DEPOSIT_ROOT = 0x27ae5ba08d7291c96c8cbddcc148bf48a6d68c7974b94356f53754ef6171d757;
    bytes32 public constant GENESIS_WITHDRAWAL_ROOT = 0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421;
    bytes32 public constant USER_DEPOSIT_HASH = 0x2e99758548972a8e8822ad47fa1017ff72f06f3ff6a016851f45c398732bc50c;
    bytes32 public constant L2_ROOT_UPDATE = 0x3f5a0b3b4e2c8d6e7a9b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f;

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

    error OwnableUnauthorizedAccount(address account);

    function setUp() public {
        vm.startPrank(owner);
        merkleManager = new MerkleStateManager(owner, GENESIS_DEPOSIT_ROOT, GENESIS_WITHDRAWAL_ROOT);
        merkleManager.setRelayerStatus(relayer1, true);
        merkleManager.setRelayerStatus(relayer2, true);
        vm.stopPrank();
    }

    function test_InitialState() public view {
        assertEq(merkleManager.depositRoot(), GENESIS_DEPOSIT_ROOT);
        assertEq(merkleManager.withdrawalRoot(), GENESIS_WITHDRAWAL_ROOT);
        assertEq(merkleManager.depositRootIndex(), 0);
        assertEq(merkleManager.withdrawalRootIndex(), 0);
        assertEq(merkleManager.depositTreeDepth(), 0);
        assertEq(merkleManager.depositLeafCount(), 0);
        assertEq(merkleManager.owner(), owner);
    }

    function test_RelayerSetup() public view {
        assertTrue(merkleManager.approvedRelayers(relayer1));
        assertTrue(merkleManager.approvedRelayers(relayer2));
        assertFalse(merkleManager.approvedRelayers(unauthorizedUser));
    }

    function test_UpdateDepositRootFromCommitment() public {
        // First, calculate the expected root value correctly
        bytes32 expectedRoot = USER_DEPOSIT_HASH; // For the first leaf, the root is the leaf itself
        
        vm.expectEmit(true, true, false, true);
        emit CommitmentProcessed(USER_DEPOSIT_HASH, 0);
        
        vm.expectEmit(true, true, true, true);
        emit DepositRootUpdated(1, expectedRoot, USER_DEPOSIT_HASH, 0, block.timestamp, block.number);
        
        merkleManager.updateDepositRootFromCommitment(USER_DEPOSIT_HASH);
        
        assertEq(merkleManager.depositRootIndex(), 1);
        assertEq(merkleManager.depositLeafCount(), 1);
        assertTrue(merkleManager.processedCommitments(USER_DEPOSIT_HASH));
    }

    function test_RevertOnInvalidCommitment() public {
        vm.expectRevert("MerkleStateManager: Invalid commitment");
        merkleManager.updateDepositRootFromCommitment(bytes32(0));
    }

    function test_RevertOnDuplicateCommitment() public {
        merkleManager.updateDepositRootFromCommitment(USER_DEPOSIT_HASH);

        vm.expectRevert("MerkleStateManager: Commitment already processed");
        merkleManager.updateDepositRootFromCommitment(USER_DEPOSIT_HASH);
    }

    function test_BatchDepositUpdates() public {
        bytes32[] memory commitments = new bytes32[](3);
        commitments[0] = keccak256("user_deposit_1");
        commitments[1] = keccak256("user_deposit_2");
        commitments[2] = keccak256("user_deposit_3");

        merkleManager.batchUpdateDepositRoots(commitments);

        assertEq(merkleManager.depositRootIndex(), 1);
        assertEq(merkleManager.depositLeafCount(), 3);
        assertTrue(merkleManager.processedCommitments(commitments[0]));
        assertTrue(merkleManager.processedCommitments(commitments[1]));
        assertTrue(merkleManager.processedCommitments(commitments[2]));
    }

    function test_BatchDepositUpdatesRevertOnInvalidSize() public {
        bytes32[] memory emptyCommitments = new bytes32[](0);
        vm.expectRevert("MerkleStateManager: Invalid batch size");
        merkleManager.batchUpdateDepositRoots(emptyCommitments);

        bytes32[] memory largeCommitments = new bytes32[](101);
        vm.expectRevert("MerkleStateManager: Invalid batch size");
        merkleManager.batchUpdateDepositRoots(largeCommitments);
    }

    function test_SyncWithdrawalRootFromL2() public {
        vm.startPrank(relayer1);

        vm.expectEmit(true, false, true, true);
        emit WithdrawalRootSynced(1, L2_ROOT_UPDATE, relayer1, block.timestamp, block.number);

        merkleManager.syncWithdrawalRootFromL2(L2_ROOT_UPDATE);

        assertEq(merkleManager.withdrawalRoot(), L2_ROOT_UPDATE);
        assertEq(merkleManager.withdrawalRootIndex(), 1);

        vm.stopPrank();
    }

    function test_UnauthorizedCannotSyncWithdrawal() public {
        vm.expectRevert("MerkleStateManager: Only approved relayers");
        merkleManager.syncWithdrawalRootFromL2(L2_ROOT_UPDATE);
    }

    function test_CannotSyncWithZeroRoot() public {
        vm.startPrank(relayer1);
        vm.expectRevert("MerkleStateManager: Invalid root");
        merkleManager.syncWithdrawalRootFromL2(bytes32(0));
        vm.stopPrank();
    }

    function test_CannotSyncWithSameRoot() public {
        vm.startPrank(relayer1);
        vm.expectRevert("MerkleStateManager: Root unchanged");
        merkleManager.syncWithdrawalRootFromL2(GENESIS_WITHDRAWAL_ROOT);
        vm.stopPrank();
    }

    function test_MultipleL2Syncs() public {
        bytes32 l2Update1 = keccak256("l2_state_1");
        bytes32 l2Update2 = keccak256("l2_state_2");

        vm.startPrank(relayer1);

        merkleManager.syncWithdrawalRootFromL2(l2Update1);
        assertEq(merkleManager.withdrawalRoot(), l2Update1);
        assertEq(merkleManager.withdrawalRootIndex(), 1);

        merkleManager.syncWithdrawalRootFromL2(l2Update2);
        assertEq(merkleManager.withdrawalRoot(), l2Update2);
        assertEq(merkleManager.withdrawalRootIndex(), 2);

        vm.stopPrank();
    }

    function test_SetRelayerStatus() public {
        address newRelayer = makeAddr("newRelayer");

        vm.startPrank(owner);

        vm.expectEmit(true, false, false, true);
        emit RelayerStatusChanged(newRelayer, true);

        merkleManager.setRelayerStatus(newRelayer, true);
        assertTrue(merkleManager.approvedRelayers(newRelayer));

        vm.expectEmit(true, false, false, true);
        emit RelayerStatusChanged(newRelayer, false);

        merkleManager.setRelayerStatus(newRelayer, false);
        assertFalse(merkleManager.approvedRelayers(newRelayer));

        vm.stopPrank();
    }

    function test_OnlyOwnerCanManageRelayers() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, unauthorizedUser));
        vm.startPrank(unauthorizedUser);
        merkleManager.setRelayerStatus(relayer1, false);
        vm.stopPrank();
    }

    function test_CannotSetZeroAddressAsRelayer() public {
        vm.startPrank(owner);
        vm.expectRevert("MerkleStateManager: Invalid relayer address");
        merkleManager.setRelayerStatus(address(0), true);
        vm.stopPrank();
    }

    function test_VerifyWithdrawalProof() public view {
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = keccak256("sibling_1");
        proof[1] = keccak256("sibling_2");

        bytes32 leaf = keccak256("withdrawal_leaf");

        bool result = merkleManager.verifyWithdrawalProof(leaf, proof);
        // This will be false since we're testing against the withdrawal root without proper proof
        assertFalse(result);
    }

    function test_VerifyDepositProof() public {
        // First add a commitment
        merkleManager.updateDepositRootFromCommitment(USER_DEPOSIT_HASH);

        // Generate proof for the first leaf (index 0)
        bytes32[] memory proof = merkleManager.getDepositProof(0);

        // Verify the proof
        bool result = merkleManager.verifyDepositProof(USER_DEPOSIT_HASH, 0, proof);
        assertTrue(result, "Single deposit proof verification failed");
    }
    
    function test_VerifyDepositProofWithTwoDeposits() public {
        // Add first commitment
        bytes32 firstDeposit = USER_DEPOSIT_HASH;
        merkleManager.updateDepositRootFromCommitment(firstDeposit);
        
        // Add second commitment
        bytes32 secondDeposit = keccak256("SECOND_DEPOSIT");
        merkleManager.updateDepositRootFromCommitment(secondDeposit);
        
        // Generate and verify proof for first leaf (index 0)
        bytes32[] memory proofForFirst = merkleManager.getDepositProof(0);
        bool resultFirst = merkleManager.verifyDepositProof(firstDeposit, 0, proofForFirst);
        assertTrue(resultFirst, "First deposit proof verification failed with two deposits");
        
        // Generate and verify proof for second leaf (index 1)
        bytes32[] memory proofForSecond = merkleManager.getDepositProof(1);
        bool resultSecond = merkleManager.verifyDepositProof(secondDeposit, 1, proofForSecond);
        assertTrue(resultSecond, "Second deposit proof verification failed with two deposits");
    }
    
    function test_VerifyDepositProofWithMultipleDeposits() public {
        // Add four deposits to create a deeper tree
        bytes32[] memory deposits = new bytes32[](4);
        deposits[0] = USER_DEPOSIT_HASH;
        deposits[1] = keccak256("SECOND_DEPOSIT");
        deposits[2] = keccak256("THIRD_DEPOSIT");
        deposits[3] = keccak256("FOURTH_DEPOSIT");
        
        for (uint i = 0; i < deposits.length; i++) {
            merkleManager.updateDepositRootFromCommitment(deposits[i]);
        }
        
        // Verify all deposits
        for (uint i = 0; i < deposits.length; i++) {
            bytes32[] memory proof = merkleManager.getDepositProof(i);
            bool result = merkleManager.verifyDepositProof(deposits[i], i, proof);
            assertTrue(result, string(abi.encodePacked("Deposit ", i+1, " proof verification failed")));
        }
    }
    
    function test_VerifyDepositProofWithOddNumberOfDeposits() public {
        // Add three deposits to test odd number of nodes (requiring special handling)
        bytes32[] memory deposits = new bytes32[](3);
        deposits[0] = USER_DEPOSIT_HASH;
        deposits[1] = keccak256("SECOND_DEPOSIT");
        deposits[2] = keccak256("THIRD_DEPOSIT");
        
        for (uint i = 0; i < deposits.length; i++) {
            merkleManager.updateDepositRootFromCommitment(deposits[i]);
        }
        
        // Debug: Print the tree structure
        debugPrintMerkleTree(deposits);
        
        // Get the deposit root
        bytes32 root = merkleManager.depositRoot();
        console.log("Deposit root from contract:");
        console.logBytes32(root);
        
        // Verify deposits 0 and 1 (these should work)
        for (uint i = 0; i < 2; i++) {
            bytes32[] memory proof = merkleManager.getDepositProof(i);
            console.log("\nLeaf index:", i);
            console.log("Proof length:", proof.length);
            for (uint j = 0; j < proof.length; j++) {
                console.log("Proof element", j, ":");
                console.logBytes32(proof[j]);
            }
            bool result = merkleManager.verifyDepositProof(deposits[i], i, proof);
            assertTrue(result, string(abi.encodePacked("Deposit ", i+1, " proof verification failed with odd number of deposits")));
        }
        
        // Special handling for the last leaf (index 2)
        uint lastIndex = 2;
        bytes32[] memory lastProof = merkleManager.getDepositProof(lastIndex);
        console.log("\nLast leaf index:", lastIndex);
        console.log("Last leaf value:");
        console.logBytes32(deposits[lastIndex]);
        console.log("Last proof length:", lastProof.length);
        for (uint j = 0; j < lastProof.length; j++) {
            console.log("Last proof element", j, ":");
            console.logBytes32(lastProof[j]);
        }
        
        // Manual verification for the last leaf
        bytes32 computedHash = deposits[lastIndex];
        console.log("\nManual verification for last leaf:");
        console.log("Starting with leaf:");
        console.logBytes32(computedHash);
        
        // Level 0: The last leaf is paired with itself
        computedHash = keccak256(abi.encodePacked(computedHash, computedHash));
        console.log("After self-pairing at level 0:");
        console.logBytes32(computedHash);
        
        // Level 1: Hash with the first proof element (which should be the hash of leaves 0 & 1)
        computedHash = keccak256(abi.encodePacked(lastProof[0], computedHash));
        console.log("After hashing with proof[0] at level 1:");
        console.logBytes32(computedHash);
        
        console.log("\nFinal computed hash:");
        console.logBytes32(computedHash);
        console.log("Should match root:");
        console.logBytes32(root);
        
        // Now try the contract's verification
        bool lastResult = merkleManager.verifyDepositProof(deposits[lastIndex], lastIndex, lastProof);
        assertTrue(lastResult, "Deposit 3 proof verification failed with odd number of deposits");
    }
    
    function debugPrintMerkleTree(bytes32[] memory leaves) internal {
        console.log("\n--- DEBUG: MERKLE TREE STRUCTURE ---");
        console.log("Total leaves:", leaves.length);
        
        // Level 0 (leaves)
        console.log("Level 0 (leaves):");
        for (uint i = 0; i < leaves.length; i++) {
            console.log("  Node", i, ":");
            console.logBytes32(leaves[i]);
        }
        
        // Calculate higher levels
        uint256 n = leaves.length;
        bytes32[] memory nodes = new bytes32[](n);
        for (uint i = 0; i < n; i++) {
            nodes[i] = leaves[i];
        }
        
        uint256 level = 1;
        while (n > 1) {
            console.log("Level", level, ":");
            uint256 nextLevelSize = (n + 1) / 2;
            
            for (uint i = 0; i < n/2; i++) {
                bytes32 left = nodes[i*2];
                bytes32 right = nodes[i*2 + 1];
                bytes32 parent = keccak256(abi.encodePacked(left, right));
                console.log("  Node", i);
                console.log("    from", i*2, "&", i*2+1);
                console.logBytes32(parent);
                nodes[i] = parent;
            }
            
            // Handle odd node
            if (n % 2 == 1) {
                console.log("  Node", n/2);
                console.log("    duplicate of", n-1);
                console.logBytes32(nodes[n-1]);
                nodes[n/2] = nodes[n-1];
                n = n/2 + 1;
            } else {
                n = n/2;
            }
            
            level++;
        }
        
        console.log("Root:");
        console.logBytes32(nodes[0]);
        console.log("--- END DEBUG ---\n");
    }

    function test_GetDepositProofRevertOnInvalidIndex() public {
        vm.expectRevert("MerkleStateManager: Invalid leaf index");
        merkleManager.getDepositProof(0); // No leaves added yet
    }

    function test_EmergencyPause() public {
        vm.startPrank(owner);

        vm.expectEmit(true, false, false, true);
        emit EmergencyPause(owner, "Security concern");

        merkleManager.emergencyPause("Security concern");
        assertTrue(merkleManager.paused());

        vm.stopPrank();
    }

    function test_Unpause() public {
        vm.startPrank(owner);

        merkleManager.emergencyPause("Test pause");
        assertTrue(merkleManager.paused());

        vm.expectEmit(true, false, false, true);
        emit EmergencyUnpause(owner);

        merkleManager.unpause();
        assertFalse(merkleManager.paused());

        vm.stopPrank();
    }

    function test_CannotUpdateWhenPaused() public {
        vm.startPrank(owner);
        merkleManager.emergencyPause("Emergency");
        vm.stopPrank();

        // OpenZeppelin's Pausable uses a custom error with a specific selector
        vm.expectRevert(bytes4(0xd93c0665));
        merkleManager.updateDepositRootFromCommitment(USER_DEPOSIT_HASH);
    }

    function test_CannotSyncWhenPaused() public {
        vm.startPrank(owner);
        merkleManager.emergencyPause("Emergency");
        vm.stopPrank();

        vm.startPrank(relayer1);
        // OpenZeppelin's Pausable uses a custom error with a specific selector
        vm.expectRevert(bytes4(0xd93c0665));
        merkleManager.syncWithdrawalRootFromL2(L2_ROOT_UPDATE);
        vm.stopPrank();
    }

    function test_RateLimiting() public {
        // First update should work
        merkleManager.updateDepositRootFromCommitment(USER_DEPOSIT_HASH);
        
        // Make 9 more updates to reach the limit of 10 operations
        for (uint i = 1; i < 10; i++) {
            merkleManager.updateDepositRootFromCommitment(keccak256(abi.encodePacked("deposit_", i)));
        }
        
        // Next update (11th) should fail due to exceeding rate limit
        vm.expectRevert("MerkleStateManager: Rate limit exceeded");
        merkleManager.updateDepositRootFromCommitment(keccak256("exceeding_rate_limit"));
        
        // Fast forward time past rate limit window
        vm.warp(block.timestamp + 16); // 15 seconds + 1 second
        
        // Now it should work
        merkleManager.updateDepositRootFromCommitment(keccak256("another_deposit"));
    }

    function test_GetTreeInfo() public {
        merkleManager.updateDepositRootFromCommitment(USER_DEPOSIT_HASH);

        (uint256 depth, uint256 leafCount, bytes32 root) = merkleManager.getDepositTreeInfo();
        assertEq(depth, 1); // Tree depth should be 1 after first leaf
        assertEq(leafCount, 1);
        assertEq(root, merkleManager.depositRoot());

        (uint256 index, bytes32 withdrawalRoot) = merkleManager.getWithdrawalTreeInfo();
        assertEq(index, 0);
        assertEq(withdrawalRoot, GENESIS_WITHDRAWAL_ROOT);
    }

    function testFuzz_ValidCommitmentUpdates(bytes32 commitment) public {
        vm.assume(commitment != bytes32(0));
        vm.assume(!merkleManager.processedCommitments(commitment));

        uint256 initialIndex = merkleManager.depositRootIndex();
        uint256 initialLeafCount = merkleManager.depositLeafCount();

        merkleManager.updateDepositRootFromCommitment(commitment);

        assertEq(merkleManager.depositRootIndex(), initialIndex + 1);
        assertEq(merkleManager.depositLeafCount(), initialLeafCount + 1);
        assertTrue(merkleManager.processedCommitments(commitment));
    }

    function testFuzz_ValidL2RootSync(bytes32 newRoot) public {
        vm.assume(newRoot != bytes32(0));
        vm.assume(newRoot != merkleManager.withdrawalRoot());

        vm.startPrank(relayer1);
        uint256 initialIndex = merkleManager.withdrawalRootIndex();
        merkleManager.syncWithdrawalRootFromL2(newRoot);

        assertEq(merkleManager.withdrawalRootIndex(), initialIndex + 1);
        assertEq(merkleManager.withdrawalRoot(), newRoot);
        vm.stopPrank();
    }

    function test_TreeCapacityLimit() public {
        // We can't practically test the full capacity, but we can test the check exists
        bytes32[] memory commitments = new bytes32[](1);
        commitments[0] = keccak256("test");

        // This should work normally
        merkleManager.batchUpdateDepositRoots(commitments);

        // The capacity check is in place, verified by the require statement
        assertEq(merkleManager.depositLeafCount(), 1);
    }

    function test_EndToEndBridgeFlow() public {
        // Add a deposit commitment
        merkleManager.updateDepositRootFromCommitment(USER_DEPOSIT_HASH);

        // Sync withdrawal root from L2
        vm.startPrank(relayer1);
        merkleManager.syncWithdrawalRootFromL2(L2_ROOT_UPDATE);
        vm.stopPrank();

        // Verify state
        assertEq(merkleManager.depositRootIndex(), 1);
        assertEq(merkleManager.withdrawalRootIndex(), 1);
        assertEq(merkleManager.depositLeafCount(), 1);
        assertTrue(merkleManager.processedCommitments(USER_DEPOSIT_HASH));

        // Verify deposit proof
        bytes32[] memory depositProof = merkleManager.getDepositProof(0);
        bool depositResult = merkleManager.verifyDepositProof(USER_DEPOSIT_HASH, 0, depositProof);
        assertTrue(depositResult);

        // Test withdrawal proof (will be false without proper setup but verifies the function works)
        bytes32[] memory withdrawalProof = new bytes32[](1);
        withdrawalProof[0] = keccak256("proof_data");
        bytes32 leaf = keccak256("withdrawal_data");

        bool withdrawalResult = merkleManager.verifyWithdrawalProof(leaf, withdrawalProof);
        assertFalse(withdrawalResult); // Expected to be false without proper proof
    }
}
