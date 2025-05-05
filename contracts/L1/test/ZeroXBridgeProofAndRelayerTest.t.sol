// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/ZeroXBridgeL1.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock ERC20 Token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ZeroXBridgeTest is Test {
    ZeroXBridgeL1 public bridge;
    MockERC20 public token;

    address public owner = address(0x1);
    address public user = 0xfc36a8C3f3FEC3217fa8bba11d2d5134e0354316;
    uint256 public starknetPubKey = 0x06ee7c7a561ae5c39e3a2866e8e208ed8ebe45da686e2929622102c80834b771;
    uint256 public ethAccountPrivateKey = 0x0b97274c3a8422119bc974361f370a03d022745a3be21c621b26226b2d6faf3a;
    address public user2 = address(0x3);
    address public relayer = address(0x4);
    address public nonRelayer = address(0x5);
    uint256 public blockHash = 0x0123456;

    event FundsUnlocked(address indexed user, uint256 amount, bytes32 commitmentHash);

    event RelayerStatusChanged(address indexed relayer, bool status);

    event ClaimEvent(address indexed user, uint256 amount);

    error OwnableUnauthorizedAccount(address account);

    function setUp() public {
        vm.startPrank(owner);

        // Deploy Mock ERC20 Token
        token = new MockERC20("MockToken", "MTK");

        // Initialize bridge with mock verifier
        address admin = address(0x123);
        bridge = new ZeroXBridgeL1(admin, owner, address(token));

        // Setup approved relayer
        bridge.setRelayerStatus(relayer, true);

        // Mint tokens to the contract for testing
        uint256 initialMintAmount = 1000000 * 10 ** 18; // 1 million tokens
        token.mint(address(bridge), initialMintAmount);

        vm.stopPrank();
    }

    // ========================
    // Ownership Tests
    // ========================

    function testOwnership() public view {
        assertEq(bridge.owner(), owner);
    }

    function test_RevertWhen_NonOwnerCallsRestrictedFunctions() public {
        vm.startPrank(user);

        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user));
        bridge.setRelayerStatus(relayer, false);

        vm.stopPrank();
    }

    // ========================
    // Relayer Management Tests
    // ========================

    function testSetRelayerStatus() public {
        vm.startPrank(owner);

        // Test adding a relayer
        vm.expectEmit(true, true, true, true);
        emit RelayerStatusChanged(user, true);
        bridge.setRelayerStatus(user, true);
        assertTrue(bridge.approvedRelayers(user));

        // Test removing a relayer
        vm.expectEmit(true, true, true, true);
        emit RelayerStatusChanged(user, false);
        bridge.setRelayerStatus(user, false);
        assertFalse(bridge.approvedRelayers(user));

        vm.stopPrank();
    }

    function testOnlyApprovedRelayersCanSubmitProofs() public {
        uint256 amount = 1 ether;
        uint256 l2TxId = 12345;
        uint256 commitmentHash = uint256(keccak256(abi.encodePacked(starknetPubKey, amount, blockHash)));

        // Non-relayer attempt should fail
        vm.startPrank(nonRelayer);
        vm.expectRevert("ZeroXBridge: Only approved relayers can submit proofs");
        bridge.unlock_funds_with_proof(commitmentHash, starknetPubKey, amount, blockHash);
        vm.stopPrank();

        // Approved relayer should succeed (assuming valid proof)
        vm.prank(relayer);
        bridge.unlock_funds_with_proof(commitmentHash, starknetPubKey, amount, blockHash);

        // Verify funds were added
        assertEq(bridge.claimableFunds(user), amount);
    }

    // ========================
    // Proof Verification Tests
    // ========================

    function testSuccessfulProofVerification() public {
        uint256 amount = 2 ** 18; // amount to unlock
        uint256 commitmentHash = uint256(keccak256(abi.encodePacked(starknetPubKey, amount, blockHash)));

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true);
        emit FundsUnlocked(user, amount, commitmentHash);
        bridge.unlock_funds_with_proof(commitmentHash, starknetPubKey, amount, blockHash);

        // Verify funds were added
        assertEq(bridge.claimableFunds(user), amount);

        // Verify the proof and commitment are marked as used
        bytes32 proofHash = keccak256(abi.encodePacked(proof));
        assertTrue(bridge.verifiedProofs(proofHash));
        assertTrue(bridge.verifiedProofs(commitmentHash));
    }

    function test_RevertFailingProofVerification() public {
        uint256 amount = 1 ether;
        uint256 commitmentHash = uint256(keccak256(abi.encodePacked(starknetPubKey, amount, blockHash)));

        vm.prank(relayer);
        // vm.expectRevert("ZeroXBridge: Invalid proof");
        vm.expectRevert(abi.encodePacked("ZeroXBridge: Invalid proof"));

        bridge.unlock_funds_with_proof(commitmentHash, starknetPubKey, amount, blockHash);

        // Verify no funds were added
        assertEq(bridge.claimableFunds(user), 0);
    }

    function testInvalidCommitmentHash() public {
        uint256 amount = 1 ether;
        // Deliberately create wrong commitment hash
        bytes32 wrongCommitmentHash = keccak256(abi.encodePacked("wrong data"));

        vm.prank(relayer);
        vm.expectRevert("ZeroXBridge: Invalid commitment hash");
        bridge.unlock_funds_with_proof(wrongCommitmentHash, starknetPubKey, amount, blockHash);
    }

    // ========================
    // Replay Attack Prevention Tests
    // ========================

    function testPreventProofReuse() public {
        uint256 amount = 1 ether;
        blockHash = 0x0123456;
        commitmentHash = uint256(keccak256(abi.encodePacked(starknetPubKey, amount, blockHash)));

        // First attempt should succeed
        vm.prank(relayer);
        bridge.unlock_funds_with_proof(commitmentHash, starknetPubKey, amount, blockHash);

        // Same proof should be rejected
        vm.prank(relayer);
        vm.expectRevert("ZeroXBridge: Proof has already been used");
        bridge.unlock_funds_with_proof(commitmentHash, starknetPubKey, amount, blockHash);
    }

    function testPreventCommitmentReuse() public {
        uint256 amount = 1 ether;
        blockHash = 0x0123456;
        commitmentHash = uint256(keccak256(abi.encodePacked(starknetPubKey, amount, blockHash)));

        // First attempt should succeed
        vm.prank(relayer);
        bridge.unlock_funds_with_proof(commitmentHash, starknetPubKey, amount, blockHash);

        // Different proof but same commitment should be rejected
        vm.prank(relayer);
        vm.expectRevert("ZeroXBridge: Commitment already processed");
        bridge.unlock_funds_with_proof(commitmentHash, starknetPubKey, amount, blockHash);
    }

    // ========================
    // Claim Function Tests
    // ========================

    function registerUser(address user, uint256 starknetPubKey, uint256 ethAccountPrivateKey) internal {
        bytes32 digest = keccak256(abi.encodePacked("UserRegistration", user, starknetPubKey));

        // vm.startPrank(user);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ethAccountPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        bridge.registerUser(signature, starknetPubKey);
        // vm.stopPrank();
    }

    function testSuccessfulClaim() public {
        testSuccessfulProofVerification();

        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);

        // Set claimable funds for user
        uint256 amount = bridge.claimableFunds(user);

        uint256 contractBalance = token.balanceOf(address(bridge));

        console.log("contract funds: ", token.balanceOf(address(bridge)));

        // Expect the FundsClaimed event to be emitted
        vm.expectEmit(true, true, true, true);
        emit ClaimEvent(user, amount);

        // User claims the funds
        vm.startPrank(user);
        bridge.claim_tokens();
        vm.stopPrank();

        // Assert that the user's claimable funds are now 0
        assertEq(bridge.claimableFunds(user), 0);

        // Check if the contract's token balance has decreased by the claimed amount
        assertEq(token.balanceOf(address(bridge)), contractBalance - amount);
        assertEq(token.balanceOf(user), amount);
    }

    function testClaimNoFunds() public {
        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);

        vm.startPrank(user);
        vm.expectRevert("ZeroXBridge: No tokens to claim");
        bridge.claim_tokens();
        vm.stopPrank();
    }

    function testClaimAfterFundsClaimed() public {
        testSuccessfulProofVerification();

        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);

        // Claim the funds
        vm.prank(user);
        bridge.claim_tokens();

        // Try to claim again, should fail because funds are already claimed
        vm.startPrank(user);
        vm.expectRevert("ZeroXBridge: No tokens to claim");
        bridge.claim_tokens();
        vm.stopPrank();
    }
}
