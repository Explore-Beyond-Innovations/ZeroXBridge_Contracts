// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../../src/ZeroXBridgeL1.sol";

contract ZeroXBridgeL1Script is Script {
    
    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER_ADDRESS");
        address admin = vm.envAddress("ADMIN_ADDRESS");
        
        // Get constructor arguments from command line
        address proofRegistry = vm.envAddress("PROOF_REGISTRY");
        require(proofRegistry != address(0), "ProofRegistry address required");
        
        vm.startBroadcast(deployerPrivateKey);

        // Deploy main bridge contract
        ZeroXBridgeL1 bridge = new ZeroXBridgeL1(
            admin,
            owner,
            proofRegistry
        );
        console.log("ZeroXBridgeL1 deployed at:", address(bridge));

        vm.stopBroadcast();
    }
}