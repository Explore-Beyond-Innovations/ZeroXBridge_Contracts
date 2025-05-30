# MerkleStateManager Contract

Simple Merkle state management for ZeroXBridge L1-L2 bridge operations.

## What it does
- Tracks deposit commitments from L1
- Syncs withdrawal roots from L2
- Verifies withdrawal proofs
- Controls who can update L2 state (relayers)

## Core Functions
```solidity
// Add new deposit commitment
updateDepositRootFromCommitment(bytes32 commitment)

// Sync L2 withdrawal state (relayers only)
syncWithdrawalRootFromL2(bytes32 newRoot)

// Check if withdrawal proof is valid
verifyWithdrawalProof(bytes32 leaf, bytes32[] proof)

// Manage relayer permissions (owner only)
setRelayerStatus(address relayer, bool status)
```

## Architecture
Contract uses modular libraries for clean code:
- **DepositRootModule** - manages deposit tracking
- **WithdrawalRootModule** - handles L2 sync
- **ProofValidation** - verifies merkle proofs
- **AccessControlModule** - manages permissions
- **CommitmentValidation** - prevents replay attacks
- **RootCalculation** - calculates new roots

## Setup
```solidity
// Deploy
MerkleStateManager manager = new MerkleStateManager(
    owner,
    initialDepositRoot,
    initialWithdrawalRoot
);

// Add relayers
manager.setRelayerStatus(relayerAddress, true);
```

## Usage in Bridge
```solidity
// When user deposits
manager.updateDepositRootFromCommitment(commitmentHash);

// When relayer syncs L2 state
manager.syncWithdrawalRootFromL2(newL2Root);

// When user withdraws
require(manager.verifyWithdrawalProof(leaf, proof), "Invalid proof");
```

## Security
- Owner controls relayers
- Reentrancy protection
- No replay attacks
- Input validation

## Testing
18 test cases covering all functionality. Run with:
```bash
forge test --match-contract MerkleStateManagerTest
```

Built for issue #63 - L1 Merkle State Manager implementation.
