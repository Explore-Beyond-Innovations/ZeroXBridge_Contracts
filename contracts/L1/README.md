# ZeroXBridge L1 Contracts

This directory contains the Ethereum L1 contracts for the ZeroXBridge protocol.

## Deployed (SEPOLIA)

- Proof Registry: [0xafac655B56B0403B6ADA6d0EF1A60257AF093d16](https://sepolia.etherscan.io/address/0xafac655B56B0403B6ADA6d0EF1A60257AF093d16#code)

- L1 Bridge: [0x8F25bFe32269632dfd8D223D51FF145414d8107b](https://sepolia.etherscan.io/address/0x8F25bFe32269632dfd8D223D51FF145414d8107b#code)

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help

## Setup

1. Install dependencies:
```bash
npm install
```

2. Create a `.env` file with the following variables:
```env
# Required for all networks
PRIVATE_KEY=0xyour_private_key_here # Append 0x before your PRIVATE KEY
OWNER_ADDRESS=owner_address_here
ADMIN_ADDRESS=admin_address_here
ALCHEMY_API_KEY=your_api_key  # Network-specific API KEY
```

## Deployment

The deployment script supports three networks:
- Mainnet
- Sepolia (testnet)
- Anvil (local)

### Commands

1. Deploy to mainnet:
```bash
npm run deploy
```

2. Deploy to Sepolia testnet:
```bash
npm run deploy:testnet
```

3. Deploy to local Anvil network:
```bash
npm run deploy:anvil
```

### Contract Deployment Order

The contracts are deployed in the following order:
1. ProofRegistry
2. MerkleManager
3. MerkleStateManager
4. ZeroXBridgeL1
