// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ZeroXBridgeL1} from "../src/ZeroXBridgeL1.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {console} from "forge-std/console.sol";

interface IGpsStatementVerifier {
    function verifyProofAndRegister(
        uint256[] calldata proofParams,
        uint256[] calldata proof,
        uint256[] calldata publicInputs,
        uint256 cairoVerifierId
    ) external returns (bool);
}

contract MockGpsStatementVerifier is IGpsStatementVerifier {
    bool public shouldVerifySucceed = true;
    mapping(bytes32 => bool) public registeredProofs;

    function setShouldVerifySucceed(bool _shouldSucceed) external {
        shouldVerifySucceed = _shouldSucceed;
    }

    function verifyProofAndRegister(
        uint256[] calldata proofParams,
        uint256[] calldata proof,
        uint256[] calldata publicInputs,
        uint256 cairoVerifierId
    ) external override returns (bool) {
        bytes32 proofHash = keccak256(abi.encodePacked(proof));
        require(!registeredProofs[proofHash], "Proof already registered");

        if (shouldVerifySucceed) {
            registeredProofs[proofHash] = true;
            return true;
        }
        return false;
    }

    function isProofRegistered(uint256[] calldata proof) external view returns (bool) {
        bytes32 proofHash = keccak256(abi.encodePacked(proof));
        return registeredProofs[proofHash];
    }
}

// Test contract for AssetPricer
contract ZeroXBridgeL1Test is Test {
    ZeroXBridgeL1 public assetPricer;
    MockERC20 public dai;
    MockERC20 public usdc;
    address public ethPriceFeed;
    address public daiPriceFeed;
    address public usdcPriceFeed;

    MockGpsStatementVerifier public mockVerifier;
    MockERC20 public token;

    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public relayer = address(0x4);
    address public nonRelayer = address(0x5);
    address public admin;
    address public token1;
    address public token2;

    uint256 public l2TxId = 12345;
    bytes32 public commitmentHash;

    uint256 public cairoVerifierId = 123456789;

    uint256[] public proofParams;
    uint256[] public proof;

    using ECDSA for bytes32;

    event WhitelistEvent(address indexed token);

    event DewhitelistEvent(address indexed token);

    event FundsUnlocked(address indexed user, uint256 amount, bytes32 commitmentHash);

    event RelayerStatusChanged(address indexed relayer, bool status);

    event FundsClaimed(address indexed user, uint256 amount);

    event ClaimEvent(address indexed user, uint256 amount);

    event DepositEvent(
        address indexed token,
        ZeroXBridgeL1.AssetType assetType,
        uint256 amount,
        address indexed user,
        bytes32 commitmentHash
    );

    function setUp() public {
        admin = address(0x123);
        token1 = address(0x456);
        token2 = address(0x789);
        token = new MockERC20(18);
        mockVerifier = new MockGpsStatementVerifier();

        vm.startPrank(owner);
        // Deploy the AssetPricer contract
        assetPricer = new ZeroXBridgeL1(address(mockVerifier), admin, cairoVerifierId, owner, address(token));

        // Setup approved relayer
        assetPricer.setRelayerStatus(relayer, true);

        // Mint tokens to the contract for testing
        uint256 initialMintAmount = 1000000 * 10 ** 18; // 1 million tokens
        token.mint(address(assetPricer), initialMintAmount);

        // Initialize proof array with dummy values for testing
        for (uint256 i = 0; i < 10; i++) {
            proofParams.push(i);
            proof.push(i + 100);
        }

        // Create a dummy commitment hash for tests involving unlock_funds_with_proof
        address user = 0xfc36a8C3f3FEC3217fa8bba11d2d5134e0354316;
        uint256 amount = 100 ether;
        commitmentHash = keccak256(abi.encodePacked(uint256(uint160(user)), amount, l2TxId, block.chainid));

        // Deploy mock ERC20 tokens
        dai = new MockERC20(18); // DAI with 18 decimals
        usdc = new MockERC20(6); // USDC with 6 decimals

        // Assign mock price feed addresses
        ethPriceFeed = address(1);
        daiPriceFeed = address(2);
        usdcPriceFeed = address(3);
        vm.stopPrank();

        vm.startPrank(admin);
        // Add supported tokens with their price feeds and decimals
        assetPricer.addSupportedToken(address(0), ethPriceFeed, 18); // ETH
        assetPricer.addSupportedToken(address(dai), daiPriceFeed, 18); // DAI
        assetPricer.addSupportedToken(address(usdc), usdcPriceFeed, 6); // USDC

        vm.stopPrank();
    }

    /**
     * Test Case 1: Happy Path - Calculate TVL with ETH and ERC20 tokens
     */
    function testUpdateAssetPricingHappyPath() public {
        // Fund the contract with ETH
        vm.deal(address(assetPricer), 1 ether); // 1 ETH = 1e18 wei

        // Mint DAI and USDC to the contract
        dai.mint(address(assetPricer), 1000 * 10 ** 18); // 1000 DAI
        usdc.mint(address(assetPricer), 500 * 10 ** 6); // 500 USDC

        // Mock Chainlink price feeds (prices in USD with 8 decimals)
        // ETH price: $2000 = 2000 * 10^8
        vm.mockCall(
            ethPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(2000 * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );
        // DAI price: $1 = 1 * 10^8
        vm.mockCall(
            daiPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1 * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );
        // USDC price: $1 = 1 * 10^8
        vm.mockCall(
            usdcPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1 * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );

        // Call update_tvl
        assetPricer.update_tvl();

        // Calculate expected TVL (in USD with 18 decimals)
        // ETH: 1 ETH * $2000 = $2000 = 2000e18
        // DAI: 1000 DAI * $1 = $1000 = 1000e18
        // USDC: 500 USDC * $1 = $500 = 500e18
        // Total TVL = 2000e18 + 1000e18 + 500e18 = 3500e18
        uint256 expectedTvl = 3500 * 10 ** 18;
        assertEq(assetPricer.tvl(), expectedTvl, "TVL should match expected value");
    }

    /**
     * Test Case 2: Zero Balance - Tokens with zero balance contribute nothing to TVL
     */
    function testUpdateAssetPricingZeroBalance() public {
        // Fund the contract with ETH
        vm.deal(address(assetPricer), 1 ether); // 1 ETH

        // Mint DAI but not USDC (USDC balance = 0)
        dai.mint(address(assetPricer), 1000 * 10 ** 18); // 1000 DAI

        // Mock price feeds
        vm.mockCall(
            ethPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(2000 * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );
        vm.mockCall(
            daiPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1 * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );
        vm.mockCall(
            usdcPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1 * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );

        // Call update_tvl
        assetPricer.update_tvl();

        // Expected TVL: 2000e18 (ETH) + 1000e18 (DAI) + 0 (USDC) = 3000e18
        uint256 expectedTvl = 3000 * 10 ** 18;
        assertEq(assetPricer.tvl(), expectedTvl, "TVL should exclude zero-balance tokens");
    }

    /**
     * Test Case 3: Missing Price Feed - Reverts if a token lacks a price feed
     */
    function testUpdateAssetPricingMissingPriceFeed() public {
        // Add a token without a price feed
        address tokenWithoutFeed = address(4);
        vm.startPrank(admin);
        assetPricer.addSupportedToken(tokenWithoutFeed, address(0), 18);
        vm.stopPrank();

        // Mock price feeds for existing tokens (ETH, DAI, USDC)
        vm.mockCall(
            address(1), // ethPriceFeed
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(2000 * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );
        vm.mockCall(
            address(2), // daiPriceFeed
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1 * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );
        vm.mockCall(
            address(3), // usdcPriceFeed
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1 * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );

        // Expect revert with the specific message
        vm.expectRevert("No price feed for token");
        assetPricer.update_tvl();
    }
    /**
     * Test Case 4: Invalid Price - Reverts if a price feed returns zero or negative
     */

    function testUpdateAssetPricingInvalidPrice() public {
        // Fund the contract to ensure it processes the price feed
        vm.deal(address(assetPricer), 1 ether);

        // Mock ETH price feed to return 0
        vm.mockCall(
            ethPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(0), uint256(0), uint256(0), uint80(0))
        );

        // Expect revert
        vm.expectRevert("Invalid price");
        assetPricer.update_tvl();
    }

    function registerUser(address user, uint256 starknetPubKey, uint256 ethAccountPrivateKey) internal {
        bytes32 digest = keccak256(abi.encodePacked("UserRegistration", user, starknetPubKey));

        // vm.startPrank(user);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ethAccountPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        assetPricer.registerUser(signature, starknetPubKey);
        // vm.stopPrank();
    }

    function testRegisterUser() public {
        address user = 0xfc36a8C3f3FEC3217fa8bba11d2d5134e0354316;
        uint256 starknetPubKey = 0x06ee7c7a561ae5c39e3a2866e8e208ed8ebe45da686e2929622102c80834b771;
        uint256 ethAccountPrivateKey = 0x0b97274c3a8422119bc974361f370a03d022745a3be21c621b26226b2d6faf3a;

        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);
        // vm.stopPrank();
    }

    function testClaimTokens() public {
        // Setup test data
        uint256 amount = 100 ether;

        address user = 0xfc36a8C3f3FEC3217fa8bba11d2d5134e0354316;
        uint256 starknetPubKey = 0x06ee7c7a561ae5c39e3a2866e8e208ed8ebe45da686e2929622102c80834b771;
        uint256 ethAccountPrivateKey = 0x0b97274c3a8422119bc974361f370a03d022745a3be21c621b26226b2d6faf3a;

        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);

        // Simulate funds being unlocked
        vm.prank(relayer);
        assetPricer.unlock_funds_with_proof(proofParams, proof, user, amount, l2TxId, commitmentHash);

        // Expect ClaimEvent to be emitted
        vm.expectEmit(true, true, false, true);
        emit ClaimEvent(user, amount);

        // Claim tokens
        vm.prank(user);
        assetPricer.claim_tokens();

        // Verify token transfer
        assertEq(token.balanceOf(user), amount);
        assertEq(assetPricer.claimableFunds(user), 0);
    }

    function testClaimTokensNoFunds() public {
        address user_1 = 0xfc36a8C3f3FEC3217fa8bba11d2d5134e0354316;
        uint256 starknetPubKey = 0x06ee7c7a561ae5c39e3a2866e8e208ed8ebe45da686e2929622102c80834b771;
        uint256 ethAccountPrivateKey = 0x0b97274c3a8422119bc974361f370a03d022745a3be21c621b26226b2d6faf3a;

        vm.prank(user_1);
        registerUser(user_1, starknetPubKey, ethAccountPrivateKey);

        // Attempt to claim with no funds
        vm.expectRevert("ZeroXBridge: No tokens to claim");
        vm.prank(user_1);
        assetPricer.claim_tokens();
    }

    function testFullClaimOnly() public {
        // Setup test data
        uint256 amount = 100 ether;
        // address user = address(0x123);
        address user = 0xfc36a8C3f3FEC3217fa8bba11d2d5134e0354316;
        uint256 starknetPubKey = 0x06ee7c7a561ae5c39e3a2866e8e208ed8ebe45da686e2929622102c80834b771;
        uint256 ethAccountPrivateKey = 0x0b97274c3a8422119bc974361f370a03d022745a3be21c621b26226b2d6faf3a;

        vm.startPrank(user);
        bytes32 digest = keccak256(abi.encodePacked("UserRegistration", user, starknetPubKey));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ethAccountPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        assetPricer.registerUser(signature, starknetPubKey);
        vm.stopPrank();

        // Simulate funds being unlocked
        vm.prank(relayer);
        assetPricer.unlock_funds_with_proof(proofParams, proof, user, amount, l2TxId, commitmentHash);

        // Verify initial claimable amount
        assertEq(assetPricer.claimableFunds(user), amount);

        // User claims full amount
        vm.prank(user);
        assetPricer.claim_tokens();

        // Verify no claimable funds remain after claim
        assertEq(assetPricer.claimableFunds(user), 0);

        // Verify tokens were transferred to user
        assertEq(token.balanceOf(user), amount);
    }

    /**
     * Test Case 5: Empty Supported Tokens - TVL is zero when no tokens are supported
     */
    function testUpdateAssetPricingEmptySupportedTokens() public {
        // Deploy a new AssetPricer with no supported tokens

        vm.startPrank(owner);
        // Deploy the AssetPricer contract
        ZeroXBridgeL1 newAssetPricer =
            new ZeroXBridgeL1(address(mockVerifier), admin, cairoVerifierId, owner, address(token));
        vm.stopPrank();

        // Call update_tvl
        newAssetPricer.update_tvl();

        // TVL should be 0
        assertEq(newAssetPricer.tvl(), 0, "TVL should be zero with no supported tokens");
    }

    function testWhitelistToken() public {
        // Whitelist token1
        vm.prank(admin);

        vm.expectEmit(true, true, false, false);
        emit WhitelistEvent(token1);

        assetPricer.whitelistToken(token1);

        // Check if token1 is whitelisted
        assertTrue(assetPricer.isWhitelisted(token1), "Token1 should be whitelisted");

        // Check the storage variable directly
        assertTrue(assetPricer.whitelistedTokens(token1), "Token should be whitelisted in storage");
    }

    function testDewhitelistToken() public {
        // Whitelist token1 first
        vm.prank(admin);
        assetPricer.whitelistToken(token1);

        // Now dewhitelist token1
        vm.prank(admin);

        vm.expectEmit(true, true, false, false);
        emit DewhitelistEvent(token1);

        assetPricer.dewhitelistToken(token1);

        // Check if token1 is dewhitelisted
        assertFalse(assetPricer.isWhitelisted(token1), "Token1 should be dewhitelisted");
        assertFalse(assetPricer.whitelistedTokens(token1), "Token1 should be dewhitelisted in storage");
    }

    function testOnlyAdminCanWhitelist() public {
        address nonAdmin = address(0x999);

        vm.startPrank(nonAdmin);
        vm.expectRevert("Only admin can perform this action");
        assetPricer.whitelistToken(token1);
        vm.stopPrank();
    }

    function testOnlyAdminCanDewhitelist() public {
        // Whitelist token1 first
        vm.prank(admin);
        assetPricer.whitelistToken(token1);

        address nonAdmin = address(0x999);

        vm.startPrank(nonAdmin);
        vm.expectRevert("Only admin can perform this action");
        assetPricer.dewhitelistToken(token1);
        vm.stopPrank();
    }

    function testRegisterToken() public {
        vm.prank(admin);
        assetPricer.registerToken(ZeroXBridgeL1.AssetType.ERC20, address(token));

        // (ZeroXBridgeL1.AssetType assetType, address registeredToken, bool isRegistered)

        ZeroXBridgeL1.TokenAssetData memory assetData =
            assetPricer.getTokenData(ZeroXBridgeL1.AssetType.ERC20, address(token));

        assertEq(uint256(assetData.assetType), uint256(ZeroXBridgeL1.AssetType.ERC20));
        assertEq(assetData.tokenAddress, address(token));
        assertTrue(assetData.isRegistered);
    }

    function testDuplicateAssetPrevention() public {
        vm.prank(admin);
        assetPricer.registerToken(ZeroXBridgeL1.AssetType.ERC20, address(token));

        // Try to register same token again
        vm.prank(admin);
        vm.expectRevert("Token already registered");
        assetPricer.registerToken(ZeroXBridgeL1.AssetType.ERC20, address(token));
    }

    // Test deposit_asset functionality
    function testSuccessfulETHDeposit() public {
        uint256 depositAmount = 1 ether;
        address depositUser = 0xfc36a8C3f3FEC3217fa8bba11d2d5134e0354316;

        vm.deal(depositUser, depositAmount);

        uint256 starknetPubKey = 0x06ee7c7a561ae5c39e3a2866e8e208ed8ebe45da686e2929622102c80834b771;
        uint256 ethAccountPrivateKey = 0x0b97274c3a8422119bc974361f370a03d022745a3be21c621b26226b2d6faf3a;

        vm.prank(depositUser);
        registerUser(depositUser, starknetPubKey, ethAccountPrivateKey);

        // Setup - whitelist the token for deposits
        vm.prank(admin);
        assetPricer.whitelistToken(address(0));
        assetPricer.registerToken(ZeroXBridgeL1.AssetType.ETH, address(0));

        // Expect the DepositEvent to be emitted
        vm.expectEmit(true, true, true, false);
        bytes32 expectedCommitmentHash = keccak256(
            abi.encodePacked(
                address(0),
                depositAmount,
                depositUser,
                uint256(0), // nonce is 0 for first deposit
                block.chainid
            )
        );
        emit DepositEvent(address(0), ZeroXBridgeL1.AssetType.ETH, depositAmount, depositUser, expectedCommitmentHash);

        // Make the deposit as user1
        vm.prank(depositUser);
        bytes32 returnedHash = assetPricer.deposit_asset{value: depositAmount}(
            ZeroXBridgeL1.AssetType.ETH, address(0), depositAmount, depositUser
        );
        // Verify the correct hash was returned
        assertEq(returnedHash, expectedCommitmentHash, "Commitment hash should match expected");

        // Verify token transfer happened correctly
        assertEq(address(assetPricer).balance, depositAmount);

        // Verify deposit tracking
        assertEq(assetPricer.userDeposits(address(0), depositUser), depositAmount, "User deposit should be tracked");

        // Verify nonce was incremented
        assertEq(assetPricer.nextDepositNonce(depositUser), 1, "Nonce should be incremented");
    }

    function testSuccessfulERC20Deposit() public {
        uint256 depositAmount = 100 * 10 ** 18; // 100 tokens with 18 decimals
        address depositUser = 0xfc36a8C3f3FEC3217fa8bba11d2d5134e0354316;

        uint256 starknetPubKey = 0x06ee7c7a561ae5c39e3a2866e8e208ed8ebe45da686e2929622102c80834b771;
        uint256 ethAccountPrivateKey = 0x0b97274c3a8422119bc974361f370a03d022745a3be21c621b26226b2d6faf3a;

        vm.prank(depositUser);
        registerUser(depositUser, starknetPubKey, ethAccountPrivateKey);

        // Setup - whitelist the token for deposits
        vm.prank(admin);
        assetPricer.whitelistToken(address(token));
        assetPricer.registerToken(ZeroXBridgeL1.AssetType.ERC20, address(token));

        // Mint tokens to user1
        token.mint(depositUser, depositAmount);

        vm.prank(depositUser);
        token.approve(address(assetPricer), depositAmount);

        bytes32 expectedCommitmentHash =
            keccak256(abi.encodePacked(address(token), depositAmount, depositUser, uint256(0), block.chainid));

        vm.prank(depositUser);
        bytes32 commitmentHash_ =
            assetPricer.deposit_asset(ZeroXBridgeL1.AssetType.ERC20, address(token), depositAmount, depositUser);

        assertEq(commitmentHash_, expectedCommitmentHash);
        assertEq(assetPricer.userDeposits(address(token), depositUser), depositAmount);
        assertEq(assetPricer.nextDepositNonce(depositUser), 1);
    }

    function testDepositAssetForOtherUser() public {
        address user_1 = 0xfc36a8C3f3FEC3217fa8bba11d2d5134e0354316;
        uint256 starknetPubKey = 0x06ee7c7a561ae5c39e3a2866e8e208ed8ebe45da686e2929622102c80834b771;
        uint256 ethAccountPrivateKey = 0x0b97274c3a8422119bc974361f370a03d022745a3be21c621b26226b2d6faf3a;

        vm.prank(user_1);
        registerUser(user_1, starknetPubKey, ethAccountPrivateKey);

        // Setup - whitelist the token for deposits
        vm.prank(admin);
        assetPricer.whitelistToken(address(token));
        assetPricer.registerToken(ZeroXBridgeL1.AssetType.ERC20, address(token));

        uint256 depositAmount = 100 * 10 ** 18;

        // Mint some tokens to user1
        token.mint(user_1, depositAmount);

        // Approve the bridge to spend user1's tokens
        vm.prank(user_1);
        token.approve(address(assetPricer), depositAmount);

        // User1 deposits for user2
        vm.prank(user_1);
        assetPricer.deposit_asset(ZeroXBridgeL1.AssetType.ERC20, address(token), depositAmount, user2);

        // Verify deposit tracking for user2 (not user1)
        assertEq(assetPricer.userDeposits(address(token), user2), depositAmount, "User2's deposit should be tracked");
        assertEq(assetPricer.userDeposits(address(token), user_1), 0, "User1 should not have deposits");

        // Verify nonce was incremented for user1 (the sender)
        assertEq(assetPricer.nextDepositNonce(user_1), 1, "User1's nonce should be incremented");
        assertEq(assetPricer.nextDepositNonce(user2), 0, "User2's nonce should not be incremented");
    }

    function testMultipleDepositsIncrementNonce() public {
        address user_1 = 0xfc36a8C3f3FEC3217fa8bba11d2d5134e0354316;
        uint256 starknetPubKey = 0x06ee7c7a561ae5c39e3a2866e8e208ed8ebe45da686e2929622102c80834b771;
        uint256 ethAccountPrivateKey = 0x0b97274c3a8422119bc974361f370a03d022745a3be21c621b26226b2d6faf3a;

        vm.prank(user_1);
        registerUser(user_1, starknetPubKey, ethAccountPrivateKey);

        // Setup - whitelist the token for deposits
        vm.prank(admin);
        assetPricer.whitelistToken(address(token));
        assetPricer.registerToken(ZeroXBridgeL1.AssetType.ERC20, address(token));

        uint256 depositAmount = 100 * 10 ** 18;

        // Mint some tokens to user1
        token.mint(user_1, depositAmount * 2);

        // Approve the bridge to spend user1's tokens
        vm.prank(user_1);
        token.approve(address(assetPricer), depositAmount * 2);

        // First deposit
        vm.prank(user_1);
        bytes32 hash1 = assetPricer.deposit_asset(ZeroXBridgeL1.AssetType.ERC20, address(token), depositAmount, user_1);

        // Second deposit
        vm.prank(user_1);
        bytes32 hash2 = assetPricer.deposit_asset(ZeroXBridgeL1.AssetType.ERC20, address(token), depositAmount, user_1);

        // Verify hashes are different due to different nonces
        assertTrue(hash1 != hash2, "Commitment hashes should be different");

        // Verify nonce was incremented twice
        assertEq(assetPricer.nextDepositNonce(user_1), 2, "Nonce should be incremented twice");

        // Verify deposit tracking accumulates
        assertEq(assetPricer.userDeposits(address(token), user_1), depositAmount * 2, "User deposits should accumulate");
    }

    function testCannotDepositNonWhitelistedToken() public {
        address user_1 = 0xfc36a8C3f3FEC3217fa8bba11d2d5134e0354316;
        uint256 starknetPubKey = 0x06ee7c7a561ae5c39e3a2866e8e208ed8ebe45da686e2929622102c80834b771;
        uint256 ethAccountPrivateKey = 0x0b97274c3a8422119bc974361f370a03d022745a3be21c621b26226b2d6faf3a;

        vm.prank(user_1);
        registerUser(user_1, starknetPubKey, ethAccountPrivateKey);
        // Do not whitelist the token

        uint256 depositAmount = 100 * 10 ** 18;

        // Mint some tokens to user1
        token.mint(user_1, depositAmount);

        // Approve the bridge to spend user1's tokens
        vm.prank(user_1);
        token.approve(address(assetPricer), depositAmount);

        // Attempt deposit should fail
        vm.prank(user_1);
        vm.expectRevert("ZeroXBridge: Token not whitelisted");
        assetPricer.deposit_asset(ZeroXBridgeL1.AssetType.ERC20, address(token), depositAmount, user_1);
    }

    function testCannotDepositZeroAmount() public {
        address user_1 = 0xfc36a8C3f3FEC3217fa8bba11d2d5134e0354316;
        uint256 starknetPubKey = 0x06ee7c7a561ae5c39e3a2866e8e208ed8ebe45da686e2929622102c80834b771;
        uint256 ethAccountPrivateKey = 0x0b97274c3a8422119bc974361f370a03d022745a3be21c621b26226b2d6faf3a;

        vm.prank(user_1);
        registerUser(user_1, starknetPubKey, ethAccountPrivateKey);

        // Setup - whitelist the token for deposits
        vm.prank(admin);
        assetPricer.whitelistToken(address(token));
        assetPricer.registerToken(ZeroXBridgeL1.AssetType.ERC20, address(token));

        // Attempt deposit with zero amount should fail
        vm.prank(user_1);
        vm.expectRevert("ZeroXBridge: Amount must be greater than zero");
        assetPricer.deposit_asset(ZeroXBridgeL1.AssetType.ERC20, address(token), 0, user_1);
    }

    function testCannotDepositToZeroAddress() public {
        address user_1 = 0xfc36a8C3f3FEC3217fa8bba11d2d5134e0354316;
        uint256 starknetPubKey = 0x06ee7c7a561ae5c39e3a2866e8e208ed8ebe45da686e2929622102c80834b771;
        uint256 ethAccountPrivateKey = 0x0b97274c3a8422119bc974361f370a03d022745a3be21c621b26226b2d6faf3a;

        vm.prank(user_1);
        registerUser(user_1, starknetPubKey, ethAccountPrivateKey);

        // Setup - whitelist the token for deposits
        vm.prank(admin);
        assetPricer.whitelistToken(address(token));
        assetPricer.registerToken(ZeroXBridgeL1.AssetType.ERC20, address(token));

        uint256 depositAmount = 100 * 10 ** 18;

        // Mint some tokens to user1
        token.mint(user_1, depositAmount);

        // Approve the bridge to spend user1's tokens
        vm.prank(user_1);
        token.approve(address(assetPricer), depositAmount);

        // Attempt deposit to zero address should fail
        vm.prank(user_1);
        vm.expectRevert("ZeroXBridge: Invalid user address");
        assetPricer.deposit_asset(ZeroXBridgeL1.AssetType.ERC20, address(token), depositAmount, address(0));
    }

    function testETHDepositEvent() public {
        uint256 depositAmount = 1 ether;
        address depositUser = 0xfc36a8C3f3FEC3217fa8bba11d2d5134e0354316;
        vm.deal(depositUser, depositAmount);

        uint256 starknetPubKey = 0x06ee7c7a561ae5c39e3a2866e8e208ed8ebe45da686e2929622102c80834b771;
        uint256 ethAccountPrivateKey = 0x0b97274c3a8422119bc974361f370a03d022745a3be21c621b26226b2d6faf3a;

        vm.prank(depositUser);
        registerUser(depositUser, starknetPubKey, ethAccountPrivateKey);

        // Setup - whitelist the token for deposits
        vm.prank(admin);
        assetPricer.whitelistToken(address(0));
        assetPricer.registerToken(ZeroXBridgeL1.AssetType.ETH, address(0));

        bytes32 expectedCommitmentHash =
            keccak256(abi.encodePacked(address(0), depositAmount, depositUser, uint256(0), block.chainid));

        vm.expectEmit(true, true, true, true);
        emit DepositEvent(address(0), ZeroXBridgeL1.AssetType.ETH, depositAmount, depositUser, expectedCommitmentHash);

        vm.prank(depositUser);
        assetPricer.deposit_asset{value: depositAmount}(
            ZeroXBridgeL1.AssetType.ETH, address(0), depositAmount, depositUser
        );
    }

    function testERC20DepositEvent() public {
        uint256 depositAmount = 100 * 10 ** 18;
        address depositUser = 0xfc36a8C3f3FEC3217fa8bba11d2d5134e0354316;

        token.mint(depositUser, depositAmount);

        uint256 starknetPubKey = 0x06ee7c7a561ae5c39e3a2866e8e208ed8ebe45da686e2929622102c80834b771;
        uint256 ethAccountPrivateKey = 0x0b97274c3a8422119bc974361f370a03d022745a3be21c621b26226b2d6faf3a;

        vm.prank(depositUser);
        registerUser(depositUser, starknetPubKey, ethAccountPrivateKey);

        // Setup - whitelist the token for deposits
        vm.prank(admin);
        assetPricer.whitelistToken(address(token));
        assetPricer.registerToken(ZeroXBridgeL1.AssetType.ERC20, address(token));

        vm.prank(depositUser);
        token.approve(address(assetPricer), depositAmount);

        bytes32 expectedCommitmentHash =
            keccak256(abi.encodePacked(address(token), depositAmount, depositUser, uint256(0), block.chainid));

        vm.expectEmit(true, true, true, true);
        emit DepositEvent(
            address(token), ZeroXBridgeL1.AssetType.ERC20, depositAmount, depositUser, expectedCommitmentHash
        );

        vm.prank(depositUser);
        assetPricer.deposit_asset(ZeroXBridgeL1.AssetType.ERC20, address(token), depositAmount, depositUser);
    }
}
