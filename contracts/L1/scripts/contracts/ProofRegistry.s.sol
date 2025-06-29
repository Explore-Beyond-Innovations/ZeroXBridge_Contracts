// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../../src/ProofRegistry.sol";

contract ProofRegistryScript is Script {
    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        ProofRegistry proofRegistry = new ProofRegistry();
        console.log("ProofRegistry deployed at:", address(proofRegistry));

        vm.stopBroadcast();
    }
} 