// File: contracts/L2/src/core/merkle_state_manager.cairo
// ZeroXBridge L2 Merkle State Manager Contract
// Manages withdrawal commitments and L1 deposit root synchronization

use starknet::ContractAddress;

#[starknet::interface]
trait IMerkleStateManager<TContractState> {
    // Read functions
    fn get_deposit_root(self: @TContractState) -> felt252;
    fn get_withdrawal_root(self: @TContractState) -> felt252;
    fn get_deposit_root_index(self: @TContractState) -> u64;
    fn get_withdrawal_root_index(self: @TContractState) -> u64;
    fn get_deposit_root_history(self: @TContractState, index: u64) -> felt252;
    fn get_withdrawal_root_history(self: @TContractState, index: u64) -> felt252;
    fn get_deposit_root_timestamp(self: @TContractState, index: u64) -> u64;
    fn get_withdrawal_root_timestamp(self: @TContractState, index: u64) -> u64;
    fn verify_merkle_proof(
        self: @TContractState, 
        leaf: felt252, 
        proof: Array<felt252>, 
        root: felt252
    ) -> bool;

    // Write functions
    fn update_withdrawal_root_from_commitment(ref self: TContractState, commitment: felt252);
    fn sync_deposit_root_from_l1(ref self: TContractState, new_root: felt252);
    
    // Admin functions
    fn set_authorized_relayer(ref self: TContractState, relayer: ContractAddress);
    fn set_bridge_contract(ref self: TContractState, bridge: ContractAddress);
}

#[starknet::contract]
mod MerkleStateManager {
    use starknet::{ContractAddress, get_caller_address, get_block_timestamp};
    use starknet::storage::LegacyMap;
    use array::ArrayTrait;
    use core::poseidon::poseidon_hash_span;

    #[storage]
    struct Storage {
        // Current roots
        deposit_root: felt252,
        withdrawal_root: felt252,
        
        // Root indices for versioning
        deposit_root_index: u64,
        withdrawal_root_index: u64,
        
        // Historical storage
        deposit_root_history: LegacyMap<u64, felt252>,
        withdrawal_root_history: LegacyMap<u64, felt252>,
        
        // Timestamp tracking
        deposit_root_timestamp: LegacyMap<u64, u64>,
        withdrawal_root_timestamp: LegacyMap<u64, u64>,
        
        // Access control
        authorized_relayer: ContractAddress,
        bridge_contract: ContractAddress,
        owner: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        WithdrawalRootUpdated: WithdrawalRootUpdated,
        DepositRootSynced: DepositRootSynced,
        RelayerUpdated: RelayerUpdated,
        BridgeContractUpdated: BridgeContractUpdated,
    }

    #[derive(Drop, starknet::Event)]
    struct WithdrawalRootUpdated {
        #[key]
        index: u64,
        new_root: felt252,
        commitment: felt252,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct DepositRootSynced {
        #[key]
        index: u64,
        new_root: felt252,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct RelayerUpdated {
        old_relayer: ContractAddress,
        new_relayer: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct BridgeContractUpdated {
        old_bridge: ContractAddress,
        new_bridge: ContractAddress,
    }

    mod Errors {
        const UNAUTHORIZED: felt252 = 'Unauthorized caller';
        const INVALID_ROOT: felt252 = 'Invalid root provided';
        const ZERO_ADDRESS: felt252 = 'Zero address not allowed';
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        authorized_relayer: ContractAddress,
        bridge_contract: ContractAddress
    ) {
        assert(!owner.is_zero(), Errors::ZERO_ADDRESS);
        assert(!authorized_relayer.is_zero(), Errors::ZERO_ADDRESS);
        assert(!bridge_contract.is_zero(), Errors::ZERO_ADDRESS);
        
        self.owner.write(owner);
        self.authorized_relayer.write(authorized_relayer);
        self.bridge_contract.write(bridge_contract);
        
        // Initialize with empty roots
        self.deposit_root.write(0);
        self.withdrawal_root.write(0);
        self.deposit_root_index.write(0);
        self.withdrawal_root_index.write(0);
    }

    #[abi(embed_v0)]
    impl MerkleStateManagerImpl of super::IMerkleStateManager<ContractState> {
        
        fn get_deposit_root(self: @ContractState) -> felt252 {
            self.deposit_root.read()
        }

        fn get_withdrawal_root(self: @ContractState) -> felt252 {
            self.withdrawal_root.read()
        }

        fn get_deposit_root_index(self: @ContractState) -> u64 {
            self.deposit_root_index.read()
        }

        fn get_withdrawal_root_index(self: @ContractState) -> u64 {
            self.withdrawal_root_index.read()
        }

        fn get_deposit_root_history(self: @ContractState, index: u64) -> felt252 {
            self.deposit_root_history.read(index)
        }

        fn get_withdrawal_root_history(self: @ContractState, index: u64) -> felt252 {
            self.withdrawal_root_history.read(index)
        }

        fn get_deposit_root_timestamp(self: @ContractState, index: u64) -> u64 {
            self.deposit_root_timestamp.read(index)
        }

        fn get_withdrawal_root_timestamp(self: @ContractState, index: u64) -> u64 {
            self.withdrawal_root_timestamp.read(index)
        }

        fn verify_merkle_proof(
            self: @ContractState, 
            leaf: felt252, 
            proof: Array<felt252>, 
            root: felt252
        ) -> bool {
            self._verify_proof(leaf, proof, root)
        }

        fn update_withdrawal_root_from_commitment(ref self: ContractState, commitment: felt252) {
            let caller = get_caller_address();
            assert(caller == self.bridge_contract.read(), Errors::UNAUTHORIZED);
            assert(commitment != 0, Errors::INVALID_ROOT);

            let current_index = self.withdrawal_root_index.read();
            let new_index = current_index + 1;
            let timestamp = get_block_timestamp();

            self.withdrawal_root.write(commitment);
            self.withdrawal_root_index.write(new_index);
            self.withdrawal_root_history.write(new_index, commitment);
            self.withdrawal_root_timestamp.write(new_index, timestamp);

            self.emit(WithdrawalRootUpdated {
                index: new_index,
                new_root: commitment,
                commitment: commitment,
                timestamp: timestamp,
            });
        }

        fn sync_deposit_root_from_l1(ref self: ContractState, new_root: felt252) {
            let caller = get_caller_address();
            assert(caller == self.authorized_relayer.read(), Errors::UNAUTHORIZED);
            assert(new_root != 0, Errors::INVALID_ROOT);

            let current_index = self.deposit_root_index.read();
            let new_index = current_index + 1;
            let timestamp = get_block_timestamp();

            self.deposit_root.write(new_root);
            self.deposit_root_index.write(new_index);
            self.deposit_root_history.write(new_index, new_root);
            self.deposit_root_timestamp.write(new_index, timestamp);

            self.emit(DepositRootSynced {
                index: new_index,
                new_root: new_root,
                timestamp: timestamp,
            });
        }

        fn set_authorized_relayer(ref self: ContractState, relayer: ContractAddress) {
            let caller = get_caller_address();
            assert(caller == self.owner.read(), Errors::UNAUTHORIZED);
            assert(!relayer.is_zero(), Errors::ZERO_ADDRESS);

            let old_relayer = self.authorized_relayer.read();
            self.authorized_relayer.write(relayer);

            self.emit(RelayerUpdated {
                old_relayer: old_relayer,
                new_relayer: relayer,
            });
        }

        fn set_bridge_contract(ref self: ContractState, bridge: ContractAddress) {
            let caller = get_caller_address();
            assert(caller == self.owner.read(), Errors::UNAUTHORIZED);
            assert(!bridge.is_zero(), Errors::ZERO_ADDRESS);

            let old_bridge = self.bridge_contract.read();
            self.bridge_contract.write(bridge);

            self.emit(BridgeContractUpdated {
                old_bridge: old_bridge,
                new_bridge: bridge,
            });
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _verify_proof(
            self: @ContractState,
            leaf: felt252,
            proof: Array<felt252>,
            root: felt252
        ) -> bool {
            let mut computed_hash = leaf;
            let mut i = 0;

            while i < proof.len() {
                let proof_element = *proof.at(i);
                
                let mut hash_data = ArrayTrait::new();
                if computed_hash <= proof_element {
                    hash_data.append(computed_hash);
                    hash_data.append(proof_element);
                } else {
                    hash_data.append(proof_element);
                    hash_data.append(computed_hash);
                }
                
                computed_hash = poseidon_hash_span(hash_data.span());
                i += 1;
            };

            computed_hash == root
        }
    }
}
