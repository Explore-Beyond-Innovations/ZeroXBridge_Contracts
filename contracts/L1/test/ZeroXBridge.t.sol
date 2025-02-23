// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "../lib/forge-std/src/Test.sol";
import {ZeroXBridge} from "../src/ZeroXBridge.sol";

contract ZeroXBridgeTest is Test {
    ZeroXBridge public zeroXBridge;
    address admin;
    address token1;
    address token2;

    event WhitelistEvent(address indexed token);
    event DewhitelistEvent(address indexed token);

    function setUp() public {
        zeroXBridge = new ZeroXBridge();
        admin = zeroXBridge.admin();
        token1 = address(0x456);
        token2 = address(0x789);
    }


    function testWhitelistToken() public {
        // Whitelist token1
        vm.prank(admin);

        vm.expectEmit(true, true, false, false);
        emit WhitelistEvent(token1);
        
        zeroXBridge.whitelistToken(token1); 

        // Check if token1 is whitelisted
        assertTrue(zeroXBridge.isWhitelisted(token1), "Token1 should be whitelisted");

        // Check the storage variable directly
        assertTrue(zeroXBridge.whitelistedTokens(token1), "Token should be whitelisted in storage");
    }

    function testDewhitelistToken() public {
        // Whitelist token1 first
        vm.prank(admin);
        zeroXBridge.whitelistToken(token1);

        // Now dewhitelist token1
        vm.prank(admin);
        
        vm.expectEmit(true, true, false, false);
        emit DewhitelistEvent(token1);

        zeroXBridge.dewhitelistToken(token1);

        // Check if token1 is dewhitelisted
        assertFalse(zeroXBridge.isWhitelisted(token1), "Token1 should be dewhitelisted");
        assertFalse(zeroXBridge.whitelistedTokens(token1), "Token1 should be dewhitelisted in storage");
    }

    function testOnlyAdminCanWhitelist() public {
        address nonAdmin = address(0x999);

        vm.startPrank(nonAdmin);
        vm.expectRevert("Only admin can perform this action");
        zeroXBridge.whitelistToken(token1);
        vm.stopPrank();
    }

    function testOnlyAdminCanDewhitelist() public {
        // Whitelist token1 first
        vm.prank(admin);
        zeroXBridge.whitelistToken(token1);

        address nonAdmin = address(0x999);

        vm.startPrank(nonAdmin);
        vm.expectRevert("Only admin can perform this action");
        zeroXBridge.dewhitelistToken(token1);
        vm.stopPrank();
    }
}
