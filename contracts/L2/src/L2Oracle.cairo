use starknet::ContractAddress;
use starknet::storage::Map;

#[starknet::interface]
trait IL2Oracle<TContractState> {
    fn get_total_tvl(self: @TContractState) -> u256;
    fn set_total_tvl(ref self: TContractState, tvl: u256);
    fn set_relayer(ref self: TContractState, relayer: ContractAddress, status: bool);
}


#[starknet::contract]
pub mod L2Oracle {
    use starknet::{ContractAddress, get_caller_address};
    use zeroable::Zeroable;
    use openzeppelin::access::ownable::OwnableComponent;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess, StoragePathEntry, Map,}

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;

    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;


    #[storage]
    struct Storage {
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        total_tvl: u256,
        relayers: Map<ContractAddress, bool>
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        TotalTVLUpdated: TotalTVLUpdated,
        RelayerStatusUpdated: RelayerStatusUpdated
    }

    #[derive(Drop, starknet::Event)]
    struct TotalTVLUpdated {
        new_tvl: u256
    }

    #[derive(Drop, starknet::Event)]
    struct RelayerStatusUpdated {
        relayer: ContractAddress,
        status: bool
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.ownable.initializer(owner);
        self.total_tvl.write(0);
    }

    #[abi(embed_v0)]
    impl L2Oracle of super::IL2Oracle<ContractState> {
        fn get_total_tvl(self: @ContractState) -> u256 {
            self.total_tvl.read()
        }

        fn set_total_tvl(ref self: ContractState, tvl: u256) {
            // Check if caller is owner or authorized relayer
            let caller = get_caller_address();
            assert(
                self.ownable.owner() == caller || self.relayers.read(caller),
                'Caller not authorized'
            );
            
            self.total_tvl.write(tvl);
            self.emit(TotalTVLUpdated { new_tvl: tvl });
        }

        fn set_relayer(ref self: ContractState, relayer: ContractAddress, status: bool) {
            // Only owner can set relayer status
            self.ownable.assert_only_owner();
            assert(!relayer.is_zero(), 'Invalid relayer address');
            
            self.relayers.write(relayer, status);
            self.emit(RelayerStatusUpdated { relayer, status });
        }
    }
}
