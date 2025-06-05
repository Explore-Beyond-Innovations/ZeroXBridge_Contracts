# ZeroXBridge Contracts

**ZeroXBridge** is a cross-chain liquidity protocol designed to enable secure asset locking on Ethereum (L1) and pegged liquidity minting on Starknet (L2) using Zero-Knowledge proofs. This repository houses the L1 and L2 smart contracts that power the core bridging functionality, xZB token economics, oracle updates, and dynamic protocol configurations.

---

## 📁 Directory Structure

```
contracts/
├── L1/        # Ethereum contracts (Solidity + Foundry)
└── L2/        # Starknet contracts (Cairo + Scarb/snfoundry)
```

---

## 🔗 L1 Contracts (`contracts/L1`)

### 🔸 `ZeroXBridgeL1.sol`
Core L1 bridge contract that:
- Accepts asset deposits from users (e.g., ERC-20 tokens)
- Records locked value and user ownership
- Emits events and Merkle-compatible data for L2 proof generation
- Verifies relayer-authenticated proofs for asset redemption

> 🔒 Uses `ElipticCurve.sol` for relayer signature verification

---

## 🧪 Tests (`contracts/L1/test`)

### 🔹 `MockERC20.sol`
Utility token used for testing deposit functionality.

### 🔹 `ZeroXBridgeL1.t.sol` & `ZeroXBridgeProofAndRelayerTest.t.sol`
Unit and integration tests verifying:
- Asset locking logic
- Event emission
- Relayer and proof verification
- Edge case handling

---

## 🌌 L2 Contracts (`contracts/L2`)

### 🔸 `ZeroXBridgeL2.cairo`
Main bridge contract on Starknet responsible for:
- Accepting zkProofs of locked L1 assets
- Minting `xZB` tokens to L2 users
- Enforcing unique proof constraints
- Burning `xZB` to trigger off-ramp redemptions

### 🔹 `xZBERC20.cairo`
Cairo-native ERC-20 implementation of the xZB token.
- Standard balance tracking and transfers
- Internal mint and burn access controlled by the bridge

### 🔹 `mint_xZB.cairo`
Wrapper contract/function for controlled minting of xZB.
- Uses access-controlled bridge to mint tokens
- Modularizes mint logic for governance upgrades

### 🔹 `L2Oracle.cairo`
Tracks time-weighted average prices (TWAP) or external price feeds.
- Fetches or stores L1-equivalent USD values for locked tokens
- Enables fair value minting of xZB

### 🔹 `Dynamicrate.cairo`
Dynamic rate controller for minting or redemption.
- Adjusts protocol-wide conversion ratios based on:
  - Supply/demand
  - Oracle input
  - DAO governance

### 🔹 `Timelock.cairo`
Timelocked governance contract.
- Enforces a delay on critical updates (e.g., oracle, mint cap)
- Protects against instant malicious changes

### 🔹 `DAO.cairo`
On-chain governance interface.
- Enables decentralized proposals and voting
- Interfaces with the timelock contract
- Allows community-driven control of bridge parameters

---

## 🧪 Tests (`contracts/L2/tests`)

- `test_ZeroXBridgeL2.cairo`: Tests the L2 bridging logic
- `test_xZBERC20.cairo`: Tests ERC20 compliance of xZB
- `test_L2Oracle.cairo`: Validates price updates and accuracy
- `test_Dynamicrate.cairo`: Simulates variable rate mechanics
- `test_DAO.cairo`: Covers proposal and voting execution paths

---

## 🚀 Getting Started

### L1 (Foundry)
```bash
cd contracts/L1
forge build
forge test
```

### L2 (Scarb/snfoundry)
```bash
cd contracts/L2
scarb build
snfoundry test
```

---

## 🧩 Design Philosophy

ZeroXBridge contracts are modular and upgrade-friendly. With security and transparency in mind:
- Proofs are required for minting
- Rates are governed dynamically via DAO
- Timelocks enforce safety for sensitive changes
- All tokens are pegged 1:1 via oracle-fed fair pricing

---

## 🧠 Contributing

We welcome PRs and ideas! Please fork the repo and submit pull requests to the relevant contract (L1 or L2). For major changes, start a discussion first to ensure alignment.

---

## 📜 License

MIT License © ZeroXBridge Contributors




Replaced keccak256 with Pedersen-style hash (compatible with Cairo's hash logic)
Updated commitment hash structure to include starknetPubKey, amount, blockHash, and nonce
Added nonce tracking in ZeroXBridgeL1 to prevent replay attacks
 Integrated IProofRegistry interface to verify withdrawal proofs and merkle roots
Updated unlockFundsWithProof flow to check proof validity before releasing funds
Enhanced ZeroXBridgeTest with tests for:
Valid proof unlocking
Invalid relayer access
Reused nonce rejection
Unregistered proof handling
Extended MockProofRegistry to simulate verified proof registration
 Minor adjustments to MockERC20 (no logic changes)
Ensures L1 contract verifies data from L2 bridge correctly