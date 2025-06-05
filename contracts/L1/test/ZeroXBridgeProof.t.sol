// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {ZeroXBridgeL1} from "../src/ZeroXBridgeL1.sol";
import {MockProofRegistry} from "./mocks/MockProofRegistry.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ZeroXBridgeTest is Test {
    ZeroXBridgeL1 public bridge;
    MockERC20 public dai;
    MockERC20 public usdc;
    address public ethPriceFeed;
    address public daiPriceFeed;
    address public usdcPriceFeed;

    address public owner = address(0x1);
    address public admin;

    // Proof Generation
    MockProofRegistry public proofRegistry;
    address public user;
    uint256 public amount;
    uint256 public starknetPubKey;
    uint256 public commitmentHash;
    uint256 public blockHash;
    uint256 public nonce;

    address public user2 = address(0x3);
    address public relayer = address(0x4);
    address public nonRelayer = address(0x5);

    event FundsUnlocked(address indexed user, uint256 amount, uint256 commitmentHash);
    event RelayerStatusChanged(address indexed relayer, bool status);
    event ClaimEvent(address indexed user, uint256 amount);

    error OwnableUnauthorizedAccount(address account);

    function setUp() public {
        admin = address(0x123);
        proofRegistry = new MockProofRegistry();

        vm.startPrank(owner);
        bridge = new ZeroXBridgeL1(admin, owner, address(proofRegistry));
        bridge.setRelayerStatus(relayer, true);
        vm.stopPrank();

        // User details
        user = 0xfc36a8C3f3FEC3217fa8bba11d2d5134e0354316;
        amount = 100 ether;
        starknetPubKey = 0x06ee7c7a561ae5c39e3a2866e8e208ed8ebe45da686e2929622102c80834b771;
        blockHash = 0x0123456;
        nonce = 1;

        // Mocked Pedersen hash value (replace with actual value from Cairo if needed)
        commitmentHash = 0x1abcde;

        // Deploy mock ERC20 tokens
        dai = new MockERC20(18);
        usdc = new MockERC20(6);

        ethPriceFeed = address(1);
        daiPriceFeed = address(2);
        usdcPriceFeed = address(3);

        vm.startPrank(admin);
        bridge.registerToken(ZeroXBridgeL1.AssetType.ETH, address(0), ethPriceFeed, 18);
        bridge.registerToken(ZeroXBridgeL1.AssetType.ERC20, address(usdc), usdcPriceFeed, 6);
        bridge.registerToken(ZeroXBridgeL1.AssetType.ERC20, address(dai), daiPriceFeed, 18);
        vm.stopPrank();
    }

    function testUnlockFundsWithValidProof() public {
        // Register the fact in the mock proof registry
        proofRegistry.setProof(commitmentHash);

        vm.prank(relayer);
        bridge.unlockFundsWithProof(user, amount, starknetPubKey, blockHash, nonce);

        // If you want, verify event emission
        // (Forge auto-detects emitted events for assertions)
    }

    function testFailUnlockFundsWithInvalidRelayer() public {
        proofRegistry.setProof(commitmentHash);

        vm.prank(nonRelayer);
        bridge.unlockFundsWithProof(user, amount, starknetPubKey, blockHash, nonce);
    }

    function testFailUnlockFundsWithUnregisteredProof() public {
        vm.prank(relayer);
        bridge.unlockFundsWithProof(user, amount, starknetPubKey, blockHash, nonce);
    }

    function testFailUnlockFundsWithUsedNonce() public {
        proofRegistry.setProof(commitmentHash);

        // First unlock succeeds
        vm.prank(relayer);
        bridge.unlockFundsWithProof(user, amount, starknetPubKey, blockHash, nonce);

        // Attempt re-use of nonce should fail
        vm.prank(relayer);
        bridge.unlockFundsWithProof(user, amount, starknetPubKey, blockHash, nonce);
    }
}
