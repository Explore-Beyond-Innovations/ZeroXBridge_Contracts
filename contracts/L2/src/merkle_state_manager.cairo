#[starknet::interface]
pub trait IMerkleStateManager<TContractState> {
    fn update_withdrawal_root_from_commitment(ref self: TContractState, commitment: felt252);
    fn sync_deposit_root_from_l1(ref self: TContractState, new_root: felt252);
}

#[starknet::contract]
pub mod MerkleStateManager {
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess, Map, StorageMapWriteAccess};
    use starknet::{get_block_timestamp, get_caller_address, ContractAddress};
    use openzeppelin_access::ownable::OwnableComponent;

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;

    impl InternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        deposit_root: felt252,
        withdrawal_root: felt252,
        deposit_root_index: u64,
        withdrawal_root_index: u64,
        deposit_root_history: Map<u64, felt252>,
        withdrawal_root_history: Map<u64, felt252>,
        deposit_root_timestamp: Map<u64, u64>,
        withdrawal_root_timestamp: Map<u64, u64>,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        relayer: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, relayer: ContractAddress) {
        self.ownable.initializer(owner);
        self.relayer.write(relayer);
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        WithdrawalRootUpdated: WithdrawalRootUpdated,
        DepositRootSynced: DepositRootSynced,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct WithdrawalRootUpdated {
        pub index: u64,
        pub new_root: felt252,
        pub commitment: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct DepositRootSynced {
        pub index: u64,
        pub new_root: felt252,
    }

    #[abi(embed_v0)]
    impl MerkleStateManagerImpl of super::IMerkleStateManager<ContractState> {
        fn update_withdrawal_root_from_commitment(ref self: ContractState, commitment: felt252) {
            let current_index = self.withdrawal_root_index.read();
            let new_index = current_index + 1;

            self.withdrawal_root.write(commitment);
            self.withdrawal_root_index.write(new_index);
            self.withdrawal_root_history.write(new_index, commitment);
            self.withdrawal_root_timestamp.write(new_index, get_block_timestamp());

            self.emit(WithdrawalRootUpdated {
                index: new_index,
                new_root: commitment,
                commitment,
            });
        }
        fn sync_deposit_root_from_l1(ref self: ContractState, new_root: felt252) {
            let caller = get_caller_address();
            let is_authorized = self.ownable.owner() == caller || self.relayer.read() == caller;
            assert(is_authorized, 'Caller not authorized');

            let current_index = self.deposit_root_index.read();
            let new_index = current_index + 1;

            self.deposit_root.write(new_root);
            self.deposit_root_index.write(new_index);
            self.deposit_root_history.write(new_index, new_root);
            self.deposit_root_timestamp.write(new_index, get_block_timestamp());

            self.emit(DepositRootSynced {
                index: new_index,
                new_root,
            });
        }
    }
}
