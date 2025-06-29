// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../../src/MerkleManager.sol";

contract MerkleManagerScript is Script {
    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        MerkleManager merkleManager = new MerkleManager();
        console.log("MerkleManager deployed at:", address(merkleManager));

        vm.stopBroadcast();
    }
} 