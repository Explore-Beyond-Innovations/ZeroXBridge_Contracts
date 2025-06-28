## 📦 Deployment

### Prerequisites

Before deploying, ensure you have the following installed:

- **Node.js** (v16 or higher)
- **Scarb** (Cairo package manager)
- **Starknet Foundry** (snforge/sncast)

### Environment Setup

Create a `.env` file in the `contracts/L2` directory:

```bash
# Starknet Configuration
STARKNET_PRIVATE_KEY=your_private_key_here
STARKNET_ACCOUNT_ADDRESS=your_account_address_here
STARKNET_RPC_URL=https://starknet-sepolia.public.blastapi.io/rpc/v0_7

# Contract Configuration
OWNER_ADDRESS=0x... # Owner of deployed contracts (defaults to deployer)
MIN_RATE=1000000000000000000    # Minimum conversion rate (1.0 with 18 decimals)
MAX_RATE=2000000000000000000    # Maximum conversion rate (2.0 with 18 decimals)

# Network (optional)
STARKNET_NETWORK=sepolia
```

### Contract Deployment Order

The deployment follows this dependency order:

1. **ProofRegistry** - No dependencies
2. **L2Oracle** - Requires owner
3. **xZBERC20** - Requires owner
4. **ZeroXBridgeL2** - Requires all above contracts + rate parameters

### Post-Deployment Setup

After successful deployment:

1. **Bridge Address**: The xZBERC20 contract's bridge address is automatically set to ZeroXBridgeL2
2. **Ownership**: All contracts are owned by the specified owner address
3. **Rate Limits**: Min/max conversion rates are configured

### Available NPM Scripts

```bash
# Deployment commands
npm run deploy:testnet    # Deploy to Sepolia testnet
npm run deploy:devnet     # Deploy to local devnet
npm run deploy            # Deploy to mainnet (with confirmation)

# Utility commands
npm run deploy:validate   # Validate deployment setup
```

### Network Configuration

#### Default RPC URLs:
- **Sepolia**: `https://starknet-sepolia.public.blastapi.io/rpc/v0_7`
- **Mainnet**: `https://starknet-mainnet.public.blastapi.io/rpc/v0_7`
- **Devnet**: `http://127.0.0.1:5050`


## Deployed Contracts

### Sepolia

- Oracle Contract: [0x006aff010e672d581173fa959a17de9132b4e2e8ab2ce515b5d191c8f75fcc80](https://sepolia.starkscan.co/contract/0x006aff010e672d581173fa959a17de9132b4e2e8ab2ce515b5d191c8f75fcc80#read-write-contract)

- Proof Registry: [0x0055c36521975f4c6a2ec2d20add8d7161022f97bc01c07cf1677005f16ea5f9](https://sepolia.starkscan.co/contract/0x0055c36521975f4c6a2ec2d20add8d7161022f97bc01c07cf1677005f16ea5f9#read-write-contract-sub-read)

- xZBERC20: [0x00d989185d5246739f38fd5032b4ff44c2f203386b0a9b7f391c8e11967cb92b](https://sepolia.starkscan.co/contract/0x00d989185d5246739f38fd5032b4ff44c2f203386b0a9b7f391c8e11967cb92b#read-write-contract)

- L2Bridge: [0x0123a4ce7980e3c4f5832af0735fc3beabdc157379e09aaf7c5e62dfa8c19427](https://sepolia.starkscan.co/contract/0x0123a4ce7980e3c4f5832af0735fc3beabdc157379e09aaf7c5e62dfa8c19427#read-write-contract-sub-write)
