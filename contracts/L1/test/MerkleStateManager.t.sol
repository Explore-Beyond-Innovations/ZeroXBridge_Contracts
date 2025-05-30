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
        assertEq(merkleManager.owner(), owner);
    }

    function test_RelayerSetup() public view {
        assertTrue(merkleManager.approvedRelayers(relayer1));
        assertTrue(merkleManager.approvedRelayers(relayer2));
        assertFalse(merkleManager.approvedRelayers(unauthorizedUser));
    }

    function test_UpdateDepositRootFromCommitment() public {
        vm.expectEmit(true, true, false, true);
        emit CommitmentProcessed(USER_DEPOSIT_HASH);

        vm.expectEmit(true, false, true, true);
        emit DepositRootUpdated(1, keccak256(abi.encodePacked(GENESIS_DEPOSIT_ROOT, USER_DEPOSIT_HASH)), USER_DEPOSIT_HASH, block.timestamp, block.number);

        merkleManager.updateDepositRootFromCommitment(USER_DEPOSIT_HASH);

        assertEq(merkleManager.depositRootIndex(), 1);
        bytes32 expectedNewRoot = keccak256(abi.encodePacked(GENESIS_DEPOSIT_ROOT, USER_DEPOSIT_HASH));
        assertEq(merkleManager.depositRoot(), expectedNewRoot);
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
        bytes32 deposit1 = keccak256("user_deposit_1");
        bytes32 deposit2 = keccak256("user_deposit_2");
        bytes32 deposit3 = keccak256("user_deposit_3");

        merkleManager.updateDepositRootFromCommitment(deposit1);
        bytes32 root1 = keccak256(abi.encodePacked(GENESIS_DEPOSIT_ROOT, deposit1));
        assertEq(merkleManager.depositRoot(), root1);
        assertEq(merkleManager.depositRootIndex(), 1);

        merkleManager.updateDepositRootFromCommitment(deposit2);
        bytes32 root2 = keccak256(abi.encodePacked(root1, deposit2));
        assertEq(merkleManager.depositRoot(), root2);
        assertEq(merkleManager.depositRootIndex(), 2);

        merkleManager.updateDepositRootFromCommitment(deposit3);
        bytes32 root3 = keccak256(abi.encodePacked(root2, deposit3));
        assertEq(merkleManager.depositRoot(), root3);
        assertEq(merkleManager.depositRootIndex(), 3);

        assertTrue(merkleManager.processedCommitments(deposit1));
        assertTrue(merkleManager.processedCommitments(deposit2));
        assertTrue(merkleManager.processedCommitments(deposit3));
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
        assertFalse(result);
    }

    function testFuzz_ValidCommitmentUpdates(bytes32 commitment) public {
        vm.assume(commitment != bytes32(0));
        vm.assume(!merkleManager.processedCommitments(commitment));

        uint256 initialIndex = merkleManager.depositRootIndex();
        merkleManager.updateDepositRootFromCommitment(commitment);

        assertEq(merkleManager.depositRootIndex(), initialIndex + 1);
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

    function test_EndToEndBridgeFlow() public {
        merkleManager.updateDepositRootFromCommitment(USER_DEPOSIT_HASH);

        vm.startPrank(relayer1);
        merkleManager.syncWithdrawalRootFromL2(L2_ROOT_UPDATE);
        vm.stopPrank();

        assertEq(merkleManager.depositRootIndex(), 1);
        assertEq(merkleManager.withdrawalRootIndex(), 1);
        assertTrue(merkleManager.processedCommitments(USER_DEPOSIT_HASH));

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256("proof_data");
        bytes32 leaf = keccak256("withdrawal_data");

        bool result = merkleManager.verifyWithdrawalProof(leaf, proof);
        assertFalse(result);
    }
}
