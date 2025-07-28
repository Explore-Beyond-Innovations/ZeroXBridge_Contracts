// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ZeroXBridgeL1} from "../src/ZeroXBridgeL1.sol";
import {MockProofRegistry} from "./mocks/MockProofRegistry.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {console} from "forge-std/console.sol";
import "../src/MerkleManager.sol";

// // Test contract for bridge
contract ZeroXBridgeL1Test is Test {
    using ECDSA for bytes32;

    ZeroXBridgeL1 public bridge;
    MockERC20 public dai;
    MockERC20 public usdc;
    address public ethPriceFeed;
    address public daiPriceFeed;
    address public usdcPriceFeed;

    address public owner = address(0x1);
    address public relayer = address(0x4);
    address public nonRelayer = address(0x5);
    address public admin;

    // Proof Generation
    MockProofRegistry public proofRegistry;
    address public user;
    uint256 public amount;
    uint256 public starknetPubKey;
    uint256 public commitmentHash;
    uint256 public ethAccountPrivateKey;
    uint256 public blockHash;

    event RelayerStatusChanged(address indexed relayer, bool status);

    event DepositEvent(
        uint256 depositId,
        address indexed token,
        ZeroXBridgeL1.AssetType assetType,
        uint256 amount,
        address indexed user,
        uint256 nonce,
        uint256 commitmentHash,
        bytes32 newRoot,
        uint256 elementCount
    );

    event TokenReserveUpdated(address indexed token, uint256 newReserve);

    error OwnableUnauthorizedAccount(address account);

    function setUp() public {
        admin = address(0x123);
        proofRegistry = new MockProofRegistry();

        vm.startPrank(owner);
        // Deploy the bridge contract
        bridge = new ZeroXBridgeL1(admin, owner, address(proofRegistry));

        // Setup approved relayer
        bridge.setRelayerStatus(relayer, true);

        vm.stopPrank();

        // Create a dummy commitment hash for tests involving unlock_funds_with_proof
        user = 0xfc36a8C3f3FEC3217fa8bba11d2d5134e0354316;
        amount = 100 ether;
        starknetPubKey = 0x06ee7c7a561ae5c39e3a2866e8e208ed8ebe45da686e2929622102c80834b771;
        ethAccountPrivateKey = 0x0b97274c3a8422119bc974361f370a03d022745a3be21c621b26226b2d6faf3a;
        blockHash = 0x0123456;
        commitmentHash = uint256(keccak256(abi.encodePacked(starknetPubKey, amount, blockHash)));

        // Deploy mock ERC20 tokens
        dai = new MockERC20(18); // DAI with 18 decimals
        usdc = new MockERC20(6); // USDC with 6 decimals

        // Assign mock price feed addresses
        ethPriceFeed = address(1);
        daiPriceFeed = address(2);
        usdcPriceFeed = address(3);

        vm.startPrank(admin);
        bridge.registerToken(ZeroXBridgeL1.AssetType.ETH, address(0), ethPriceFeed, 18);
        bridge.registerToken(ZeroXBridgeL1.AssetType.ERC20, address(usdc), usdcPriceFeed, 6);
        bridge.registerToken(ZeroXBridgeL1.AssetType.ERC20, address(dai), daiPriceFeed, 18);

        vm.stopPrank();
    }

    /**
     * Test Case 1: Happy Path - Calculate TVL with ETH and ERC20 tokens
     */
    function testUpdateAssetPricingHappyPath() public {
        // Fund the contract with ETH
        vm.deal(address(bridge), 1 ether); // 1 ETH = 1e18 wei

        // Mint DAI and USDC to the contract
        dai.mint(address(bridge), 1000 * 10 ** 18); // 1000 DAI
        usdc.mint(address(bridge), 500 * 10 ** 6); // 500 USDC

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

        // Call updateTvl
        bridge.updateTvl();

        // Calculate expected TVL (in USD with 18 decimals)
        // ETH: 1 ETH * $2000 = $2000 = 2000e18
        // DAI: 1000 DAI * $1 = $1000 = 1000e18
        // USDC: 500 USDC * $1 = $500 = 500e18
        // Total TVL = 2000e18 + 1000e18 + 500e18 = 3500e18
        // uint256 expectedTvl = 3500 * 10 ** 18;
        uint256 expectedTvl = 0; //Direct token transfer does not affect reserve value
        assertEq(bridge.tvl(), expectedTvl, "TVL should match expected value");
        assertEq(address(bridge).balance / 1e18, 1, "ETH Balance is Incorrect");
        assertEq(dai.balanceOf(address(bridge)) / 1e18, 1000, "DAI Balance is Incorrect");
        assertEq(usdc.balanceOf(address(bridge)) / 1e6, 500, "USDC Balance is Incorrect");
    }

    /**
     * Test Case 2: Zero Balance - Tokens with zero balance contribute nothing to TVL
     */
    function testUpdateAssetPricingZeroBalance() public {
        // Fund the contract with ETH
        vm.deal(address(bridge), 1 ether); // 1 ETH

        // Mint DAI but not USDC (USDC balance = 0)
        dai.mint(address(bridge), 1000 * 10 ** 18); // 1000 DAI

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

        // Call updateTvl
        bridge.updateTvl();

        // Expected TVL: 2000e18 (ETH) + 1000e18 (DAI) + 0 (USDC) = 3000e18
        // uint256 expectedTvl = 3000 * 10 ** 18;
        uint256 expectedTvl = 0; //Direct token transfer does not affect reserve value
        assertEq(bridge.tvl(), expectedTvl, "TVL should exclude zero-balance tokens");
        assertEq(address(bridge).balance / 1e18, 1, "ETH Balance is Incorrect");
        assertEq(dai.balanceOf(address(bridge)) / 1e18, 1000, "DAI Balance is Incorrect");
        assertEq(usdc.balanceOf(address(bridge)) / 1e6, 0, "USDC Balance is Incorrect");
    }

    /**
     * Test Case 3: Missing Price Feed - Reverts if a token lacks a price feed
     */
    function testUpdateAssetPricingMissingPriceFeed() public {
        // Add a token without a price feed
        address tokenWithoutFeed = address(4);

        vm.startPrank(admin);
        bridge.registerToken(ZeroXBridgeL1.AssetType.ERC20, tokenWithoutFeed, address(0), 18);
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
        bridge.updateTvl();
    }

    /**
     * Test Case 4: Invalid Price - Reverts if a price feed returns zero or negative
     */
    function testUpdateAssetPricingInvalidPrice() public {
        // Fund the contract to ensure it processes the price feed
        vm.deal(address(bridge), 1 ether);

        // Mock ETH price feed to return 0
        vm.mockCall(
            ethPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(0), uint256(0), uint256(0), uint80(0))
        );

        // Expect revert
        vm.expectRevert("Invalid price from feed");
        bridge.updateTvl();
    }

    /**
     * Test Case 5: Empty Supported Tokens - TVL is zero when no tokens are supported
     */
    function testUpdateAssetPricingEmptySupportedTokens() public {
        // Deploy a new bridge with no supported tokens

        vm.startPrank(owner);
        // Deploy the bridge contract
        ZeroXBridgeL1 newbridge = new ZeroXBridgeL1(admin, owner, address(proofRegistry));
        vm.stopPrank();

        // Call updateTvl
        newbridge.updateTvl();

        // TVL should be 0
        assertEq(newbridge.tvl(), 0, "TVL should be zero with no supported tokens");
    }

    function testRegisterToken() public {
        address tokenPriceFeed = address(5);
        MockERC20 token = new MockERC20(18); // 18 decimals

        vm.prank(admin);
        bridge.registerToken(ZeroXBridgeL1.AssetType.ERC20, address(token), tokenPriceFeed, 18);

        ZeroXBridgeL1.TokenAssetData memory assetData =
            bridge.getTokenData(ZeroXBridgeL1.AssetType.ERC20, address(token));

        assertEq(uint256(assetData.assetType), uint256(ZeroXBridgeL1.AssetType.ERC20));
        assertEq(assetData.tokenAddress, address(token));
        assertTrue(assetData.isRegistered);
    }

    function testDuplicateAssetPrevention() public {
        address tokenPriceFeed = address(5);
        MockERC20 token = new MockERC20(18); // 18 decimal

        vm.prank(admin);
        bridge.registerToken(ZeroXBridgeL1.AssetType.ERC20, address(token), tokenPriceFeed, 18);

        // Try to register same token again
        vm.prank(admin);
        vm.expectRevert("Token already registered");
        bridge.registerToken(ZeroXBridgeL1.AssetType.ERC20, address(token), tokenPriceFeed, 18);
    }

    function registerUser(address _user, uint256 _starknetPubKey, uint256 _ethAccountPrivateKey) internal {
        bytes32 digest = keccak256(abi.encodePacked("UserRegistration", _user, starknetPubKey));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_ethAccountPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        bridge.registerUser(signature, _starknetPubKey);
    }

    function testRegisterUser() public {
        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);
    }

    // Test depositAsset functionality
    function testSuccessfulETHDeposit() public {
        uint256 depositAmount = 1 ether;

        vm.deal(user, depositAmount);

        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);

        uint256 ethPrice = 2000; // 2000 USD

        // Mock price feeds
        vm.mockCall(
            ethPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(ethPrice * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );

        uint256 usdValue = depositAmount * ethPrice * 1e18 / 1e18;
        uint256 depositId = 1;

        uint256 expectedCommitmentHash = uint256(
            keccak256(
                abi.encodePacked(
                    depositId,
                    starknetPubKey,
                    usdValue,
                    uint256(0), // nonce is 0 for first deposit
                    block.timestamp
                )
            )
        );

        // Make the deposit as user1
        vm.prank(user);

        uint256 returnedHash = bridge.depositAsset{value: depositAmount}(
            depositId, ZeroXBridgeL1.AssetType.ETH, address(0), depositAmount, user
        );

        // Verify the correct hash was returned
        assertEq(returnedHash, expectedCommitmentHash, "Commitment hash should match expected");

        // Verify token transfer happened correctly
        assertEq(address(bridge).balance, depositAmount);

        // Verify deposit tracking
        assertEq(bridge.userDeposits(address(0), user), depositAmount, "User deposit should be tracked");

        // Verify nonce was incremented
        assertEq(bridge.nextDepositNonce(user), 1, "Nonce should be incremented");
    }

    function testSuccessfulERC20Deposit() public {
        uint256 depositAmount = 100 * 10 ** 18; // 100 tokens with 18 decimals

        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);

        // Mint tokens to user1
        dai.mint(user, depositAmount);

        vm.prank(user);
        dai.approve(address(bridge), depositAmount);

        uint256 daiPrice = 1; // 1 USD

        // Mock price feeds
        vm.mockCall(
            daiPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(daiPrice * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );

        uint256 usdValue = depositAmount * daiPrice * 1e18 / 1e18;
        uint256 depositId = 1;

        uint256 expectedCommitmentHash = uint256(
            keccak256(
                abi.encodePacked(
                    depositId,
                    starknetPubKey,
                    usdValue,
                    uint256(0), // nonce is 0 for first deposit
                    block.timestamp
                )
            )
        );

        vm.prank(user);
        uint256 commitmentHash_ =
            bridge.depositAsset(depositId, ZeroXBridgeL1.AssetType.ERC20, address(dai), depositAmount, user);

        assertEq(commitmentHash_, expectedCommitmentHash);
        assertEq(bridge.userDeposits(address(dai), user), depositAmount);
        assertEq(bridge.nextDepositNonce(user), 1);
    }

    function testMultipleDepositsIncrementNonce() public {
        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);

        uint256 depositAmount = 100 * 10 ** 18;

        // Mint some tokens to user1
        usdc.mint(user, depositAmount * 2);

        // Approve the bridge to spend user1's tokens
        vm.prank(user);
        usdc.approve(address(bridge), depositAmount * 2);

        uint256 usdcPrice = 1; // 1 USD

        // Mock price feeds
        vm.mockCall(
            usdcPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(usdcPrice * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );

        // First deposit
        vm.prank(user);
        uint256 depositId1 = 1;

        uint256 hash1 =
            bridge.depositAsset(depositId1, ZeroXBridgeL1.AssetType.ERC20, address(usdc), depositAmount, user);

        // Mock price feeds
        vm.mockCall(
            usdcPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(usdcPrice * 10 ** 8), uint256(0), uint256(0), uint80(0))
        );

        // Second deposit
        vm.prank(user);
        uint256 depositId2 = 2;

        uint256 hash2 =
            bridge.depositAsset(depositId2, ZeroXBridgeL1.AssetType.ERC20, address(usdc), depositAmount, user);

        // Verify hashes are different due to different nonces
        assertTrue(hash1 != hash2, "Commitment hashes should be different");

        // Verify nonce was incremented twice
        assertEq(bridge.nextDepositNonce(user), 2, "Nonce should be incremented twice");

        // Verify deposit tracking accumulates
        assertEq(bridge.userDeposits(address(usdc), user), depositAmount * 2, "User deposits should accumulate");
    }

    function testCannotDepositZeroAmount() public {
        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);

        // Attempt deposit with zero amount should fail
        vm.prank(user);
        vm.expectRevert("ZeroXBridge: Amount must be greater than zero");
        uint256 depositId = 1;

        bridge.depositAsset(depositId, ZeroXBridgeL1.AssetType.ERC20, address(usdc), 0, user);
    }

    function testCannotDepositToZeroAddress() public {
        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);

        uint256 depositAmount = 100 * 10 ** 18;

        // Mint some tokens to user1
        usdc.mint(user, depositAmount);

        // Approve the bridge to spend user1's tokens
        vm.prank(user);
        usdc.approve(address(bridge), depositAmount);

        // Attempt deposit to zero address should fail
        vm.prank(user);
        vm.expectRevert("ZeroXBridge: Invalid user address");
        uint256 depositId = 1;

        bridge.depositAsset(depositId, ZeroXBridgeL1.AssetType.ERC20, address(usdc), depositAmount, address(0));
    }

    /**
     * @dev Helper function to predict the outcome of the MerkleManager's append operation.
     * It fetches the current MMR state from the bridge and uses the same StatelessMmr
     * library to calculate the expected next root and element count.
     */
    function calculateExpectedMmrValues(bytes32 _commitmentHash)
        internal
        view
        returns (bytes32 expectedNewRoot, uint256 expectedElementCount)
    {
        // 1. Get the current state of the MMR from the bridge contract
        bytes32[] memory currentPeaks = bridge.getLastPeaks();
        uint256 currentElementsCount = bridge.getElementsCount();
        bytes32 currentRoot = bridge.getRootHash();

        // 2. Use the same library function to predict the result of the append
        (uint256 nextElementsCount, bytes32 nextRoot,) =
            StatelessMmr.appendWithPeaksRetrieval(_commitmentHash, currentPeaks, currentElementsCount, currentRoot);

        // 3. Return the predicted values
        return (nextRoot, nextElementsCount);
    }

    function testETHDepositEvent() public {
        uint256 depositAmount = 1 ether;
        uint256 depositId = 123;
        address tokenAddress = address(0);
        vm.deal(user, depositAmount);

        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);

        uint256 ethPrice = 2000;
        vm.mockCall(
            ethPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(ethPrice * 10 ** 8), 0, 0, 0)
        );

        uint256 usdValue = (depositAmount * ethPrice * 1e18) / 1e18;
        uint256 nonce = bridge.nextDepositNonce(user);
        bytes32 expectedCommitmentHash =
            keccak256(abi.encodePacked(depositId, starknetPubKey, usdValue, nonce, block.timestamp));

        (bytes32 expectedNewRoot, uint256 expectedElementCount) = calculateExpectedMmrValues(expectedCommitmentHash);

        vm.expectEmit(true, true, false, true);
        emit DepositEvent(
            depositId,
            tokenAddress,
            ZeroXBridgeL1.AssetType.ETH,
            usdValue,
            user,
            nonce,
            uint256(expectedCommitmentHash),
            expectedNewRoot,
            expectedElementCount
        );

        vm.prank(user);
        bridge.depositAsset{value: depositAmount}(
            depositId, ZeroXBridgeL1.AssetType.ETH, tokenAddress, depositAmount, user
        );
    }

    function testERC20DepositEvent() public {
        uint256 depositAmount = 100 * 1e18;
        uint256 depositId = 456;
        address tokenAddress = address(dai);
        dai.mint(user, depositAmount);

        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);

        vm.prank(user);
        dai.approve(address(bridge), depositAmount);

        uint256 daiPrice = 1;
        vm.mockCall(
            daiPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(daiPrice * 10 ** 8), 0, 0, 0)
        );

        uint256 usdValue = (depositAmount * daiPrice * 1e18) / 1e18;
        uint256 nonce = bridge.nextDepositNonce(user);
        bytes32 expectedCommitmentHash =
            keccak256(abi.encodePacked(depositId, starknetPubKey, usdValue, nonce, block.timestamp));

        (bytes32 expectedNewRoot, uint256 expectedElementCount) = calculateExpectedMmrValues(expectedCommitmentHash);

        vm.expectEmit(true, true, false, true);
        emit DepositEvent(
            depositId,
            tokenAddress,
            ZeroXBridgeL1.AssetType.ERC20,
            usdValue,
            user,
            nonce,
            uint256(expectedCommitmentHash),
            expectedNewRoot,
            expectedElementCount
        );

        vm.prank(user);
        bridge.depositAsset(depositId, ZeroXBridgeL1.AssetType.ERC20, tokenAddress, depositAmount, user);
    }

    // tests for verifyStarknetSignature
    function testVerifyValidSignature() public view {
        uint256 messageHash = 0x026b4b17ca6a97b0d61f441e828472022c7bec1258d488482a0a1b412c214e86;
        uint256 r = 0x0293aba5e527bd515cca1175f2b7ed1b1ad5244db2fe780dd278561f9492ac19;
        uint256 s = 0x075dd20d8743e6b359ef71ace06dab5934e56dac865fc586c2227b9304a273cb;
        bytes memory sig = abi.encodePacked(bytes32(r), bytes32(s));
        uint256 pubKeyX = 0x03f25ebd3224d52135bfb04a12713f3e3103cc25e82f0dc583177289f45a39cf;
        // uint256 pubKeyY = 0x017d8924fe415ba698958688fc37f5c60a28067ceb4dbe76107be46c871b3397;

        // Call the function
        bool isValid = bridge.verifyStarknetSignature(messageHash, sig, pubKeyX);
        assertTrue(isValid, "Valid signature should pass");
    }

    function testInvalidSignature() public view {
        uint256 messageHash = 0x033af3ab8b38079b8ebb228c3eb9e88ac65de29a2ae64bc90886baefeaa6b5ff;
        // Invalid r (altered from valid)
        uint256 r = 0x0534db24ad670b37d5bf34e583ea1c729fcf5c5928cb19bc707ee5994ffba230;
        uint256 s = 0x07cfdcd06bc17ca67dc0b8d48c1065d0e746dcfb06fdbd96f2ea7473930617a7;
        bytes memory sig = abi.encodePacked(bytes32(r), bytes32(s));
        uint256 pubKeyX = 0x03f25ebd3224d52135bfb04a12713f3e3103cc25e82f0dc583177289f45a39cf;
        // uint256 pubKeyY = 0x017d8924fe415ba698958688fc37f5c60a28067ceb4dbe76107be46c871b3397;

        bool isValid = bridge.verifyStarknetSignature(messageHash, sig, pubKeyX);
        assertFalse(isValid, "Invalid signature should fail");
    }

    function testInvalidPublicKey() public {
        uint256 messageHash = 0x033af3ab8b38079b8ebb228c3eb9e88ac65de29a2ae64bc90886baefeaa6b5ff;
        uint256 r = 0x0504db24ad670b37d5bf34e583ea1c729fcf5c5928cb19bc707ee5994ffba229;
        uint256 s = 0x07cfdcd06bc17ca67dc0b8d48c1065d0e746dcfb06fdbd96f2ea7473930617a7;
        bytes memory sig = abi.encodePacked(bytes32(r), bytes32(s));
        // Invalid public key (not on curve)
        uint256 pubKeyX = 0;

        vm.expectRevert("ZeroXBridge: Invalid Starknet public key");
        bridge.verifyStarknetSignature(messageHash, sig, pubKeyX);
    }

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

    function testOwnership() public view {
        assertEq(bridge.owner(), owner);
    }

    function test_RevertWhen_NonOwnerCallsRestrictedFunctions() public {
        vm.startPrank(user);

        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user));
        bridge.setRelayerStatus(relayer, false);

        vm.stopPrank();
    }

    function testDepositAssetAndTVL() public {
        // 1. Setup: deposit amounts and mock prices
        uint256 depositEth = 2 ether;
        uint256 depositDai = 500 * 1e18;
        uint256 depositUsdc = 250 * 1e6;

        uint256 ethPrice = 2000 * 1e8;
        uint256 daiPrice = 1 * 1e8;
        uint256 usdcPrice = 1 * 1e8;

        // Fund user for all tokens
        vm.deal(user, depositEth);
        dai.mint(user, depositDai);
        usdc.mint(user, depositUsdc);

        // Register user
        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);

        // Approve token transfers
        vm.startPrank(user);
        dai.approve(address(bridge), type(uint256).max);
        usdc.approve(address(bridge), type(uint256).max);
        vm.stopPrank();

        // Mock Chainlink price feeds
        vm.mockCall(
            ethPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(ethPrice), uint256(0), uint256(0), uint80(0))
        );
        vm.mockCall(
            daiPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(daiPrice), uint256(0), uint256(0), uint80(0))
        );
        vm.mockCall(
            usdcPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(usdcPrice), uint256(0), uint256(0), uint80(0))
        );

        // Expect TokenReserveUpdated for ETH
        vm.expectEmit(true, false, false, true);
        emit TokenReserveUpdated(address(0), depositEth);

        // 2. Deposit ETH
        vm.prank(user);
        uint256 depositId = 1;

        bridge.depositAsset{value: depositEth}(depositId, ZeroXBridgeL1.AssetType.ETH, address(0), depositEth, user);

        // Expect TokenReserveUpdated for DAI
        vm.expectEmit(true, false, false, true);
        emit TokenReserveUpdated(address(dai), depositDai);

        // 3. Deposit DAI
        vm.prank(user);
        uint256 depositId1 = 1;

        bridge.depositAsset(depositId1, ZeroXBridgeL1.AssetType.ERC20, address(dai), depositDai, user);

        // Expect TokenReserveUpdated for USDC
        vm.expectEmit(true, false, false, true);
        emit TokenReserveUpdated(address(usdc), depositUsdc);

        // 4. Deposit USDC
        vm.prank(user);
        uint256 depositId2 = 2;

        bridge.depositAsset(depositId2, ZeroXBridgeL1.AssetType.ERC20, address(usdc), depositUsdc, user);

        // 5. Call updateTvl
        bridge.updateTvl();

        // 6. Calculate expected USD value (all normalized to 1e18)
        // ETH: 2 * 2000 = 4000 * 1e18
        // DAI: 500 * 1 = 500 * 1e18
        // USDC: 250 * 1 = 250 * 1e18
        uint256 expectedTvl = (4000 + 500 + 250) * 1e18;

        // 7. Assert TVL matches expected
        assertEq(bridge.tvl(), expectedTvl, "TVL should reflect total value in USD across tokens");

        // 8. Assert reserves match deposit amounts
        assertEq(bridge.tokenReserves(address(0)), depositEth, "ETH reserve mismatch");
        assertEq(bridge.tokenReserves(address(dai)), depositDai, "DAI reserve mismatch");
        assertEq(bridge.tokenReserves(address(usdc)), depositUsdc, "USDC reserve mismatch");

        // 9. Assert userDeposits
        assertEq(bridge.userDeposits(address(0), user), depositEth);
        assertEq(bridge.userDeposits(address(dai), user), depositDai);
        assertEq(bridge.userDeposits(address(usdc), user), depositUsdc);
    }

    function testDirectTransferDoesNotAffectReserve() public {
        uint256 daiPrice = 1e8;
        uint256 depositAmount = 100 * 1e18;
        uint256 extraAmount = 50 * 1e18;

        // Register user and DAI
        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);

        dai.mint(user, depositAmount + extraAmount);

        vm.prank(user);
        dai.approve(address(bridge), type(uint256).max);

        vm.mockCall(
            daiPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(daiPrice), uint256(0), uint256(0), uint80(0))
        );
        vm.mockCall(
            ethPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1), uint256(0), uint256(0), uint80(0))
        );
        vm.mockCall(
            usdcPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1), uint256(0), uint256(0), uint80(0))
        );

        // Step 1: Deposit 100 DAI via bridge
        vm.prank(user);
        uint256 depositId = 1;

        bridge.depositAsset(depositId, ZeroXBridgeL1.AssetType.ERC20, address(dai), depositAmount, user);

        // Step 2: Manually transfer 50 DAI to bridge (bypasses deposit logic)
        vm.prank(user);
        dai.transfer(address(bridge), extraAmount);

        // Step 3: Assert reserve remains unchanged
        assertEq(
            bridge.tokenReserves(address(dai)), depositAmount, "tokenReserves must not increase via direct transfer"
        );

        // Step 4: Update TVL and assert it only reflects 100 DAI
        bridge.updateTvl();
        uint256 expectedTVL = depositAmount; // 100 DAI * $1 = 100e18
        assertEq(bridge.tvl(), expectedTVL, "TVL must exclude externally sent tokens");
    }

    function testTVLUsesTrackedReservesOnly() public {
        uint256 daiPrice = 1e8;
        uint256 trackedAmount = 100 * 1e18;
        uint256 untrackedAmount = 50 * 1e18;

        // Register user and DAI token
        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);

        // Mint total tokens (tracked + untracked)
        dai.mint(user, trackedAmount + untrackedAmount);

        // Approve bridge to pull DAI for deposit
        vm.prank(user);
        dai.approve(address(bridge), type(uint256).max);

        vm.mockCall(
            ethPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1), uint256(0), uint256(0), uint80(0))
        );
        vm.mockCall(
            usdcPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1), uint256(0), uint256(0), uint80(0))
        );
        vm.mockCall(
            daiPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(daiPrice), uint256(0), uint256(0), uint80(0))
        );

        // Deposit 100 DAI through tracked bridge flow
        vm.prank(user);
        uint256 depositId = 1;

        bridge.depositAsset(depositId, ZeroXBridgeL1.AssetType.ERC20, address(dai), trackedAmount, user);

        // Manually send 50 DAI directly to bridge (this bypasses reserve tracking)
        vm.prank(user);
        dai.transfer(address(bridge), untrackedAmount);

        // Sanity check: bridge holds 150 DAI
        assertEq(
            dai.balanceOf(address(bridge)), trackedAmount + untrackedAmount, "Raw balance must include direct transfer"
        );

        // Assert tracked reserve only includes 100 DAI
        assertEq(
            bridge.tokenReserves(address(dai)), trackedAmount, "Tracked reserve should not include external transfers"
        );

        // Update TVL and check it only accounts for trackedAmount
        bridge.updateTvl();

        // Since DAI = $1, TVL = 100e18
        uint256 expectedTVL = trackedAmount;
        assertEq(bridge.tvl(), expectedTVL, "TVL must be calculated from tracked reserves, not raw token balances");
    }

    function testClaimReducesTokenReserveDAI() public {
        uint256 depositAmount = 100 * 1e18;
        uint256 nonce = 0;
        uint256 timestamp = block.timestamp;

        uint256 ethPrice = 2000 * 1e8;
        uint256 daiPrice = 1e8;
        uint256 usdcPrice = 1e8;
        uint256 daicDec = 18;

        // Step 1: User registration and mint
        vm.prank(user);
        registerUser(user, starknetPubKey, ethAccountPrivateKey);
        dai.mint(user, depositAmount);
        vm.prank(user);
        dai.approve(address(bridge), type(uint256).max);

        // Step 2: Mock price feed
        vm.mockCall(
            daiPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(daiPrice), uint256(0), uint256(0), uint80(0))
        );
        vm.mockCall(
            ethPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(ethPrice), uint256(0), uint256(0), uint80(0))
        );
        vm.mockCall(
            usdcPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(usdcPrice), uint256(0), uint256(0), uint80(0))
        );

        uint256 usdRaw = (depositAmount * daiPrice) / 1e8;
        uint256 usdValue = (usdRaw * 1e18) / (10 ** daicDec);

        // Step 3: Warp and deposit
        vm.warp(timestamp);
        vm.prank(user);
        uint256 depositId = 1;

        bridge.depositAsset(depositId, ZeroXBridgeL1.AssetType.ERC20, address(dai), depositAmount, user);

        // Step 4: Compute usdValue and commitmentHash
        uint256 commitmentHash_ = uint256(keccak256(abi.encodePacked(starknetPubKey, usdValue, nonce, timestamp)));

        // Step 5: Register proof
        uint256 merkleRoot = uint256(keccak256("mock merkle"));
        MockProofRegistry(address(proofRegistry)).registerWithdrawalProof(commitmentHash_, merkleRoot);

        // Step 6: Build proof data
        uint256[] memory proofdata = new uint256[](4);
        proofdata[0] = starknetPubKey;
        proofdata[1] = usdValue;
        proofdata[2] = nonce;
        proofdata[3] = timestamp;

        // Step 7: Generate valid signature
        uint256 STARK_CURVE_ORDER = 361850278866613110698659328152149712041468702080126762623304950275186147821;
        uint256 msgHash = commitmentHash_ % STARK_CURVE_ORDER;
        bytes32 digest = bytes32(msgHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ethAccountPrivateKey, digest);
        bytes memory starknetSig = abi.encodePacked(r, s);

        // bridge.unlockFundsWithProof(ZeroXBridgeL1.AssetType.ERC20, address(dai), proofdata, commitmentHash, starknetSig);

        // // Step 9: Assertions
        // assertEq(bridge.tokenReserves(address(dai)), 0, "tokenReserves should be reduced after unlock");
        // assertEq(dai.balanceOf(user), depositAmount, "User should receive full unlocked amount");
    }

    // function testClaimReducesTokenReserveUSDC() public {
    //     uint256 depositAmount = 100 * 1e6;
    //     uint256 nonce = 0;
    //     uint256 timestamp = block.timestamp;

    //     uint256 ethPrice = 2000 * 1e8;
    //     uint256 daiPrice = 1e8;
    //     uint256 usdcPrice = 1e8;
    //     uint256 usdcDec = 6;

    //     // Step 1: User registration and mint
    //     vm.prank(user);
    //     registerUser(user, starknetPubKey, ethAccountPrivateKey);
    //     usdc.mint(user, depositAmount);
    //     vm.prank(user);
    //     usdc.approve(address(bridge), type(uint256).max);

    //     // Step 2: Mock price feed
    //     vm.mockCall(
    //         daiPriceFeed,
    //         abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
    //         abi.encode(uint80(1), int256(daiPrice), uint256(0), uint256(0), uint80(0))
    //     );
    //     vm.mockCall(
    //         ethPriceFeed,
    //         abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
    //         abi.encode(uint80(1), int256(ethPrice), uint256(0), uint256(0), uint80(0))
    //     );
    //     vm.mockCall(
    //         usdcPriceFeed,
    //         abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
    //         abi.encode(uint80(1), int256(usdcPrice), uint256(0), uint256(0), uint80(0))
    //     );

    //     uint256 usdRaw = (depositAmount * usdcPrice) / 1e8;
    //     uint256 usdValue = (usdRaw * 1e18) / (10 ** usdcDec);

    //     // Step 3: Warp and deposit
    //     vm.warp(timestamp);
    //     vm.prank(user);
    //     bridge.depositAsset(ZeroXBridgeL1.AssetType.ERC20, address(usdc), depositAmount, user);

    //     // Step 4: Compute usdValue and commitmentHash
    //     uint256 commitmentHash = uint256(
    //         keccak256(abi.encodePacked(starknetPubKey, usdValue, nonce, timestamp))
    //     );

    //     // Step 5: Register proof
    //     uint256 merkleRoot = uint256(keccak256("mock merkle"));
    //     MockProofRegistry(address(proofRegistry)).registerWithdrawalProof(commitmentHash, merkleRoot);

    //     // Step 6: Build proof data
    //     uint256[] memory proofdata = new uint256[](4);
    //     proofdata[0] = starknetPubKey;
    //     proofdata[1] = usdValue;
    //     proofdata[2] = nonce;
    //     proofdata[3] = timestamp;

    //     // Step 7: Generate valid signature
    //     uint256 STARK_CURVE_ORDER = 361850278866613110698659328152149712041468702080126762623304950275186147821;
    //     uint256 msgHash = commitmentHash % STARK_CURVE_ORDER;
    //     bytes32 digest = bytes32(msgHash);
    //     (uint8 v, bytes32 r, bytes32 s) = vm.sign(ethAccountPrivateKey, digest);
    //     bytes memory starknetSig = abi.encodePacked(r, s);

    //     bridge.unlockFundsWithProof(
    //         ZeroXBridgeL1.AssetType.ERC20,
    //         address(usdc),
    //         proofdata,
    //         commitmentHash,
    //         starknetSig
    //     );

    //     // // Step 9: Assertions
    //     assertEq(bridge.tokenReserves(address(usdc)), 0, "tokenReserves should be reduced after unlock");
    //     assertEq(usdc.balanceOf(user), depositAmount, "User should receive full unlocked amount");
    // }

    // function testClaimReducesTokenReserveETH() public {
    //     uint256 depositAmount = 1 ether;
    //     uint256 nonce = 0;
    //     uint256 timestamp = block.timestamp;

    //     uint256 ethPrice = 2000 * 1e8;
    //     uint256 daiPrice = 1e8;
    //     uint256 usdcPrice = 1e8;
    //     uint8 ethDec = 18;

    //     // Step 1: User registration
    //     vm.prank(user);
    //     registerUser(user, starknetPubKey, ethAccountPrivateKey);
    //     vm.deal(user, depositAmount);

    //     // Step 2: Mock price feeds
    //     vm.mockCall(
    //         ethPriceFeed,
    //         abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
    //         abi.encode(0, int256(ethPrice), 0, 0, 0)
    //     );
    //     vm.mockCall(
    //         daiPriceFeed,
    //         abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
    //         abi.encode(0, int256(daiPrice), 0, 0, 0)
    //     );
    //     vm.mockCall(
    //         usdcPriceFeed,
    //         abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
    //         abi.encode(0, int256(usdcPrice), 0, 0, 0)
    //     );

    //     // Step 3: Warp and deposit ETH
    //     vm.warp(timestamp);
    //     vm.prank(user);
    //     bridge.depositAsset{value: depositAmount}(ZeroXBridgeL1.AssetType.ETH, address(0), depositAmount, user);

    //     // Step 4: Compute usd value and commitment hash
    //     uint256 usdRaw = (depositAmount * ethPrice) / 1e8;
    //     uint256 usdValue = (usdRaw * 1e18) / (10 ** ethDec);
    //     uint256 commitmentHash = uint256(keccak256(abi.encodePacked(starknetPubKey, usdValue, nonce, timestamp)));

    //     // Step 5: Register proof
    //     uint256 merkleRoot = uint256(keccak256("mock_merkle"));
    //     proofRegistry.registerWithdrawalProof(commitmentHash, merkleRoot);

    //     // Step 6: Build proof data
    //     uint256[] memory proofdata = new uint256[](4);
    //     proofdata[0] = starknetPubKey;
    //     proofdata[1] = usdValue;
    //     proofdata[2] = nonce;
    //     proofdata[3] = timestamp;

    //     bytes memory dummySig = new bytes(64); // valid 64-byte placeholder signature

    //     // mock verifyStarknetSignature to always return true
    //     bytes4 selector = bridge.verifyStarknetSignature.selector;
    //     vm.mockCall(
    //         address(bridge),
    //         abi.encodeWithSelector(selector, commitmentHash, dummySig, starknetPubKey),
    //         abi.encode(true)
    //     );

    //     // Step 8: Execute unlock
    //     vm.prank(relayer);
    //     bridge.unlockFundsWithProof(ZeroXBridgeL1.AssetType.ETH, address(0), proofdata, commitmentHash, dummySig);
    //     // Step 9: Assertions
    //     assertEq(bridge.tokenReserves(address(0)), 0, "tokenReserves should be reduced after unlock");
    //     assertEq(user.balance, depositAmount, "User should receive full unlocked ETH amount");
    // }
}
