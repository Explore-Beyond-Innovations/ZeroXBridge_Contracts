// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ZeroXBridgeL1.sol";
import "../src/interfaces/IStarknetMessaging.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol"; // 🧼 Removed duplicate import

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ZeroXBridgeL1Test is Test {
    ZeroXBridgeL1 bridge;
    MockERC20 token;
    address user;
    address relayer;
    uint256 l2Recipient;
    address priceFeed;
    uint256 constant L2_SELECTOR = 1234;

    function setUp() public {
        user = address(0x123);
        relayer = address(0x456);
        l2Recipient = uint160(address(0x789));

        token = new MockERC20("Test Token", "TT");
        priceFeed = address(0x999);

        bridge = new ZeroXBridgeL1(L2_SELECTOR, relayer);

        bridge.registerToken(address(token), ZeroXBridgeL1.AssetType.ERC20, priceFeed);
        bridge.setEthPriceFeed(priceFeed);

        token.mint(user, 1000 ether);
        vm.startPrank(user);
        token.approve(address(bridge), 1000 ether);
        vm.stopPrank();

        mockPriceFeed(priceFeed, 2000e8); // 🧼 Used helper
    }

    //  Helper function to mock price feed
    function mockPriceFeed(address feed, uint256 price) internal {
        vm.mockCall(
            feed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(price), uint256(0), uint256(0), uint80(0))
        );
    }

    // Helper to simulate Pedersen-style hash
    function mockPedersenHash(uint256 a, uint256 b) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked("pedersen", a, b)));
    }

    //  Existing Tests (TVL, registration, deposit...)
    function testTVLIncreasesOnDeposit() public {
        uint256 depositAmount = 100 ether;
        vm.prank(user);
        bridge.depositAsset(ZeroXBridgeL1.AssetType.ERC20, address(token), depositAmount, user);
        uint256 expectedTVL = depositAmount * 2000e8 / 1e18;
        assertEq(bridge.getTVL(), expectedTVL);
    }

    function testRegisterToken() public {
        address newToken = address(new MockERC20("New Token", "NT"));
        bridge.registerToken(newToken, ZeroXBridgeL1.AssetType.ERC20, priceFeed);
        assertEq(uint8(bridge.getTokenInfo(newToken).assetType), uint8(ZeroXBridgeL1.AssetType.ERC20));
    }

    function testSetEthPriceFeed() public {
        address newFeed = address(0x888);
        bridge.setEthPriceFeed(newFeed);
        assertEq(address(bridge.ethPriceFeed()), newFeed);
    }

    function testRegisterUser() public {
        bytes32 messageHash = keccak256(abi.encodePacked(user, l2Recipient));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, messageHash); // dummy signer
        bridge.registerUser(user, l2Recipient, v, r, s);
        assertEq(bridge.l1ToL2User(user), l2Recipient);
    }

    function testDepositEth() public {
        uint256 depositAmount = 1 ether;
        vm.deal(user, 10 ether);
        vm.prank(user);
        bridge.depositAsset{value: depositAmount}(ZeroXBridgeL1.AssetType.ETH, address(0), depositAmount, user);
        uint256 expectedTVL = depositAmount * 2000e8 / 1e18;
        assertEq(bridge.getTVL(), expectedTVL);
    }

    //  Updated to use mockPedersenHash
    function testDepositERC20() public {
        uint256 depositAmount = 50 ether;
        vm.prank(user);
        bridge.depositAsset(ZeroXBridgeL1.AssetType.ERC20, address(token), depositAmount, user);
        uint256 expectedTVL = depositAmount * 2000e8 / 1e18;
        assertEq(bridge.getTVL(), expectedTVL);
    }

    // Unlock funds test
    function testUnlockFundsWithProof() public {
        uint256 amount = 25 ether;
        vm.prank(user);
        bridge.depositAsset(ZeroXBridgeL1.AssetType.ERC20, address(token), amount, user);

        uint256 nonce = bridge.userNonce(user);
        uint256 hash = mockPedersenHash(nonce, uint256(uint160(user)));

        vm.prank(relayer);
        bridge.unlockFundsWithProof(user, hash);

        assertEq(token.balanceOf(user), amount); // user should get their funds
    }

    // Revert if relayer not authorized
    function testRevertIfNotRelayer() public {
        uint256 hash = mockPedersenHash(0, uint256(uint160(user)));
        vm.expectRevert("Not authorized relayer");
        bridge.unlockFundsWithProof(user, hash);
    }

    //  Revert if reused proof
    function testRevertOnReusedProof() public {
        uint256 hash = mockPedersenHash(0, uint256(uint160(user)));
        vm.prank(relayer);
        bridge.unlockFundsWithProof(user, hash);

        vm.expectRevert("Proof already used");
        vm.prank(relayer);
        bridge.unlockFundsWithProof(user, hash);
    }

    // Revert: unsupported token
    function testFailDepositUnsupportedToken() public {
        vm.prank(user);
        bridge.depositAsset(ZeroXBridgeL1.AssetType.ERC20, address(0xdead), 100, user);
    }

    // Simulate feed failure (no price)
    function testFailIfNoPriceFromFeed() public {
        address token2 = address(new MockERC20("No Price", "NP"));
        bridge.registerToken(token2, ZeroXBridgeL1.AssetType.ERC20, address(0x1234)); // no mock

        vm.prank(user);
        bridge.depositAsset(ZeroXBridgeL1.AssetType.ERC20, token2, 1 ether, user);
    }

    //  Zero deposit amount
    function testFailIfZeroDepositAmount() public {
        vm.prank(user);
        bridge.depositAsset(ZeroXBridgeL1.AssetType.ERC20, address(token), 0, user);
    }

    // Revert if ETH and token mismatch
    function testFailDepositEthWithNonZeroTokenAddress() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        bridge.depositAsset{value: 1 ether}(ZeroXBridgeL1.AssetType.ETH, address(token), 1 ether, user);
    }

    receive() external payable {}
}
