// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../../src/MerkleStateManager.sol";

contract MerkleStateManagerScript is Script {
    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER_ADDRESS");
        
        // Genesis roots - these should be calculated based on your initial state
        // For testing, we can use non-zero values
        bytes32 genesisDepositRoot = bytes32(uint256(1));
        bytes32 genesisWithdrawalRoot = bytes32(uint256(2));
        
        vm.startBroadcast(deployerPrivateKey);

        MerkleStateManager merkleStateManager = new MerkleStateManager(
            owner,
            genesisDepositRoot,
            genesisWithdrawalRoot
        );
        console.log("MerkleStateManager deployed at:", address(merkleStateManager));

        vm.stopBroadcast();
    }
} 