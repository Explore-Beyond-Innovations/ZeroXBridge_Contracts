// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "../lib/forge-std/src/Test.sol";
import {Counter} from "../src/Counter.sol";

contract CounterTest is Test {
    Counter public counter;
    address admin;
    address token1;
    address token2;

    function setUp() public {
        counter = new Counter();
        counter.setNumber(0);
        admin = address(0x123);
        token1 = address(0x456);
        token2 = address(0x789);
    }

    function test_Increment() public {
        counter.increment();
        assertEq(counter.number(), 1);
    }

    function testFuzz_SetNumber(uint256 x) public {
        counter.setNumber(x);
        assertEq(counter.number(), x);
    }

    function testWhitelistToken() public {
        // Whitelist token1
        vm.prank(admin);

        vm.expectEmit(true, true, false, false);
        emit Counter.WhitelistEvent(token1);
        counter.whitelistToken(token1); 

        // Check if token1 is whitelisted
        assertTrue(counter.isWhitelisted(token1), "Token1 should be whitelisted");

        // Check the storage variable directly
        assertTrue(counter.whitelistedTokens(token1), "Token should be whitelisted in storage");
    }

    function testDewhitelistToken() public {
        // Whitelist token1 first
        vm.prank(admin);
        counter.whitelistToken(token1);

        // Now dewhitelist token1
        vm.prank(admin);
        
        vm.expectEmit(true, true, false, false);
        emit Counter.DewhitelistEvent(token1);

        counter.dewhitelistToken(token1);

        // Check if token1 is dewhitelisted
        assertFalse(counter.isWhitelisted(token1), "Token1 should be dewhitelisted");
        assertFalse(counter.whitelistedTokens(token1), "Token1 should be dewhitelisted in storage");
    }

    function testOnlyAdminCanWhitelist() public {
        address nonAdmin = address(0x999);

        vm.startPrank(nonAdmin);
        vm.expectRevert("Only admin can perform this action");
        counter.whitelistToken(token1);
        vm.stopPrank();
    }

    function testOnlyAdminCanDewhitelist() public {
        // Whitelist token1 first
        vm.prank(admin);
        counter.whitelistToken(token1);

        address nonAdmin = address(0x999);

        vm.startPrank(nonAdmin);
        vm.expectRevert("Only admin can perform this action");
        counter.dewhitelistToken(token1);
        vm.stopPrank();
    }
}
