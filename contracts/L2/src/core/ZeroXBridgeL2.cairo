#[starknet::contract]
pub mod ZeroXBridgeL2 {
    use openzeppelin_access::ownable::OwnableComponent;
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin_upgrades::UpgradeableComponent;
    use openzeppelin_upgrades::interface::IUpgradeable;
    use starknet::{
        ContractAddress, get_caller_address, ClassHash, get_block_timestamp, get_contract_address,
    };
    use l2::interfaces::IxZBErc20::{IXZBERC20Dispatcher, IXZBERC20DispatcherTrait};
    use openzeppelin_token::erc20::interface::{IERC20DispatcherTrait, IERC20Dispatcher};
    use l2::interfaces::IL2Oracle::{IL2OracleDispatcher, IL2OracleDispatcherTrait};

    use core::option::Option;
    use core::poseidon::PoseidonTrait;
    use core::array::ArrayTrait;
    use starknet::storage::{
        StoragePointerReadAccess, StoragePointerWriteAccess, Map, StorageMapReadAccess,
        StorageMapWriteAccess, Vec, VecTrait, MutableVecTrait,
    };
    use core::hash::{HashStateTrait, HashStateExTrait};

    use l2::interfaces::IProofRegistry::{IProofRegistryDispatcher, IProofRegistryDispatcherTrait};
    use l2::interfaces::IZeroXBridgeL2::{IDynamicRate, IZeroXBridgeL2};
    use l2::interfaces::IMerkleManager::IMerkleManager;

    use starknet::eth_address::EthAddress;
    use starknet::eth_signature::verify_eth_signature;
    use starknet::secp256_trait::Signature;
    use cairo_lib::data_structures::mmr::mmr::MMR;
    use cairo_lib::data_structures::mmr::mmr::MMRTrait;


    const PRECISION: u256 = 1_000_000_000_000_000_000; // 18 decimals for precision

    // Ownable Component
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);


    // Ownable Mixin
    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;


    #[derive(Drop, Serde, Copy, starknet::Store)]
    pub struct Rates {
        pub min_rate: u256,
        pub max_rate: u256,
    }

    #[storage]
    struct Storage {
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        xzb_token: ContractAddress,
        oracle_address: ContractAddress,
        proof_registry_address: ContractAddress,
        verified_commitments: Map<felt252, bool>,
        verified_roots: Map<felt252, felt252>,
        burn_nonce: Map<ContractAddress, felt252>,
        rates: Rates,
        mmr_root: felt252,
        mmr_last_pos: felt252,
        node_index_to_root: Map<usize, felt252>,
        commitment_hash_to_index: Map<felt252, felt252>,
        last_peaks: Vec<felt252>,
        leaves_count: felt252,
    }

    #[derive(Drop, Hash)]
    pub struct BurnData {
        pub caller: felt252,
        pub amount: u256,
        pub nonce: felt252,
        pub time_stamp: felt252,
    }

    #[derive(Debug, Drop, Hash)]
    pub struct MintData {
        pub recipient: felt252,
        pub amount: felt252,
        pub nonce: felt252,
        pub time_stamp: felt252,
    }


    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        BurnEvent: BurnEvent,
        MintEvent: MintEvent,
        RateUpdated: RateUpdated,
        OracleUpdated: OracleUpdated,
        XZBTokenUpdated: XZBTokenUpdated,
        RateLimitsUpdated: RateLimitsUpdated,
        WithdrawalHashAppended: WithdrawalHashAppended,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
    }

    #[derive(Drop, Debug, starknet::Event)]
    struct RateUpdated {
        #[key]
        new_rate: u256,
        tvl: u256,
    }

    #[derive(Drop, Debug, starknet::Event)]
    struct OracleUpdated {
        #[key]
        oracle: ContractAddress,
    }

    #[derive(Drop, Debug, starknet::Event)]
    struct XZBTokenUpdated {
        #[key]
        xzb_token: ContractAddress,
    }

    #[derive(Drop, Debug, starknet::Event)]
    struct RateLimitsUpdated {
        min_rate: u256,
        max_rate: u256,
    }

    #[derive(Drop, Debug, starknet::Event)]
    pub struct BurnEvent {
        pub user: ContractAddress,
        pub amount: u256,
        pub nonce: felt252,
        pub commitment_hash: felt252,
    }

    #[derive(Drop, Debug, starknet::Event)]
    pub struct MintEvent {
        pub recipient: ContractAddress,
        pub amount: u256,
        pub nonce: felt252,
        pub commitment_hash: felt252,
    }

    #[derive(Drop, Debug, starknet::Event)]
    pub struct WithdrawalHashAppended {
        pub index: felt252,
        pub commitment_hash: felt252,
        pub root_hash: felt252,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        token: ContractAddress,
        proof_registry_address: ContractAddress,
        oracle_address: ContractAddress,
        min_rate: u256,
        max_rate: u256,
    ) {
        self.ownable.initializer(owner);
        self.xzb_token.write(token);
        self.proof_registry_address.write(proof_registry_address);
        self.oracle_address.write(oracle_address);
        let rates = Rates { min_rate, max_rate };
        self.rates.write(rates);
        self.mmr_root.write(0);
        self.mmr_last_pos.write(0);
        self.leaves_count.write(0);
    }

    #[abi(embed_v0)]
    impl MintBurnXzbImpl of IZeroXBridgeL2<ContractState> {
        fn mint_and_claim_xzb(
            ref self: ContractState,
            proof: Array<felt252>,
            commitment_hash: felt252,
            eth_address: felt252,
            r: u256,
            s: u256,
            y_parity: bool,
        ) {
            // Always check proof length first to avoid out-of-bounds and undefined behavior
            assert(proof.len() >= 4, 'Proof too short');

            // Then verify the signature for security
            let msg_hash: u256 = commitment_hash.into();
            let signature = Signature { r, s, y_parity };
            let eth_address: EthAddress = eth_address.try_into().unwrap();

            verify_eth_signature(msg_hash, signature, eth_address);

            // Now check for duplicate commitment
            assert(
                !self.verified_commitments.read(commitment_hash), 'Commitment already processed',
            );

            let recipient_felt = *proof.at(0);
            let amount = *proof.at(1);
            let nonce = *proof.at(2);
            let time_stamp = *proof.at(3);

            let mint_data = MintData { recipient: recipient_felt, amount, nonce, time_stamp };
            let computed_hash = PoseidonTrait::new().update_with(mint_data).finalize();

            let usd_amount: u256 = amount.into();

            assert(computed_hash == commitment_hash, 'Proof does not match commitment');

            let proof_registry = IProofRegistryDispatcher {
                contract_address: self.proof_registry_address.read(),
            };

            let merkle_root = proof_registry.get_verified_merkle_root(commitment_hash);

            self.verified_commitments.write(commitment_hash, true);
            self.verified_roots.write(commitment_hash, merkle_root);

            let recipient: ContractAddress = recipient_felt.try_into().unwrap();

            let mint_rate = self.get_dynamic_rate();

            let mint_amount = (usd_amount * mint_rate) / PRECISION;

            let token_addr = self.xzb_token.read();
            IXZBERC20Dispatcher { contract_address: token_addr }.mint(recipient, mint_amount);

            self
                .emit(
                    Event::MintEvent(
                        MintEvent { recipient, amount: usd_amount, nonce, commitment_hash },
                    ),
                );
        }


        fn burn_xzb_for_unlock(ref self: ContractState, amount: u256) {
            let caller = get_caller_address();
            let token_addr = self.xzb_token.read();
            let protocol = get_contract_address();

            let mint_rate = self.get_dynamic_rate();
            let burn_amount_usd = (amount * PRECISION) / mint_rate;

            assert(burn_amount_usd > 0, 'Burn amount less than zero');

            // Transfer xZB tokens to the bridge
            IERC20Dispatcher { contract_address: token_addr }
                .transfer_from(caller, protocol, amount);

            // Burn the xZB tokens
            IXZBERC20Dispatcher { contract_address: token_addr }.burn(amount);

            let current_nonce = self.burn_nonce.read(caller);

            let data_to_hash = BurnData {
                caller: caller.try_into().unwrap(),
                amount: burn_amount_usd,
                nonce: current_nonce,
                time_stamp: get_block_timestamp().into(),
            };

            let commitment_hash = PoseidonTrait::new().update_with(data_to_hash).finalize();

            // Append the withdrawal hash to the Merkle tree
            self.append_withdrawal_hash(commitment_hash);

            self.burn_nonce.write(caller, current_nonce + 1);

            self
                .emit(
                    BurnEvent {
                        user: caller,
                        amount: burn_amount_usd,
                        nonce: current_nonce,
                        commitment_hash: commitment_hash,
                    },
                );
        }
    }

    #[abi(embed_v0)]
    impl DynamicRateImpl of IDynamicRate<ContractState> {
        fn get_dynamic_rate(self: @ContractState) -> u256 {
            // Get current total TVL from oracle
            let oracle_dispatcher = IL2OracleDispatcher {
                contract_address: self.oracle_address.read(),
            };
            let total_tvl = oracle_dispatcher.get_total_tvl();

            assert(total_tvl > 0, 'TVL cannot be zero');

            // Get current xZB supply
            let xzb_supply = self.get_current_xzb_supply();

            // Calculate new protocol rate
            let raw_rate = (xzb_supply * PRECISION) / total_tvl;

            let rates = self.rates.read();

            // Apply rate limits
            let min_rate = rates.min_rate;
            let max_rate = rates.max_rate;

            let final_rate = if raw_rate == 0 {
                1 * PRECISION
            } else if raw_rate < min_rate {
                min_rate
            } else if raw_rate > max_rate {
                max_rate
            } else {
                raw_rate
            };

            final_rate
        }

        fn get_current_xzb_supply(self: @ContractState) -> u256 {
            let xzb_token = self.xzb_token.read();

            // Create dispatcher to call the ERC20 contract
            let xzb_dispatcher = IERC20Dispatcher { contract_address: xzb_token };

            // Get total supply from the token contract
            xzb_dispatcher.total_supply()
        }

        fn set_rates(ref self: ContractState, min_rate: Option<u256>, max_rate: Option<u256>) {
            self.ownable.assert_only_owner();
            let mut current_rates = self.rates.read();

            match min_rate {
                Option::Some(new_min) => { current_rates.min_rate = new_min; },
                Option::None => {},
            }

            match max_rate {
                Option::Some(new_max) => { current_rates.max_rate = new_max; },
                Option::None => {},
            }

            assert(current_rates.min_rate < current_rates.max_rate, 'Min rate must be < max rate');

            self.rates.write(current_rates);

            self
                .emit(
                    Event::RateLimitsUpdated(
                        RateLimitsUpdated {
                            min_rate: current_rates.min_rate, max_rate: current_rates.max_rate,
                        },
                    ),
                );
        }

        fn set_oracle(ref self: ContractState, oracle: ContractAddress) {
            self.ownable.assert_only_owner();
            self.oracle_address.write(oracle);
            self.emit(Event::OracleUpdated(OracleUpdated { oracle }));
        }

        fn set_xzb_token(ref self: ContractState, xzb_token: ContractAddress) {
            self.ownable.assert_only_owner();
            self.xzb_token.write(xzb_token);
            self.emit(Event::XZBTokenUpdated(XZBTokenUpdated { xzb_token }));
        }
    }

    #[abi(embed_v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.upgradeable.upgrade(new_class_hash);
        }
    }

    #[abi(embed_v0)]
    impl MerkleImpl of IMerkleManager<ContractState> {
        fn get_root_hash(self: @ContractState) -> felt252 {
            self.mmr_root.read()
        }

        fn get_element_count(self: @ContractState) -> felt252 {
            self.mmr_last_pos.read()
        }

        fn get_commitment_index(self: @ContractState, commitment_hash: felt252) -> felt252 {
            let index = self.commitment_hash_to_index.read(commitment_hash);
            assert(index != 0, 'Commitment not found');
            index
        }

        fn get_last_peaks(self: @ContractState) -> Array<felt252> {
            let mut peaks = array![];
            for i in 0..self.last_peaks.len() {
                peaks.append(self.last_peaks.at(i).read());
            };
            peaks
        }

        fn get_leaves_count(self: @ContractState) -> felt252 {
            self.leaves_count.read()
        }

        fn verify_proof(
            self: @ContractState,
            index: usize,
            commitment_hash: felt252,
            peaks: Array<felt252>,
            proof: Array<felt252>,
        ) -> Result<bool, felt252> {
            let mut mmr: MMR = Default::default();
            mmr.root = self.mmr_root.read();
            mmr.last_pos = self.mmr_last_pos.read().try_into().unwrap();
            
            MMRTrait::verify_proof(@mmr, index, commitment_hash, peaks.span(), proof.span())
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn append_withdrawal_hash(ref self: ContractState, commitment_hash: felt252) {
            let mut mmr: MMR = Default::default();
            mmr.root = self.mmr_root.read();
            mmr.last_pos = self.mmr_last_pos.read().try_into().unwrap();
            
            let last_peaks = self.get_last_peaks();
            let mut leaves_count = self.leaves_count.read();

            match MMRTrait::append(ref mmr, commitment_hash, last_peaks.span()) {
                Result::Ok((
                    root_hash, peaks,
                )) => {
                    // Store the new root and last position
                    self.mmr_root.write(root_hash);
                    self.mmr_last_pos.write(mmr.last_pos.into());
                    self.node_index_to_root.write(mmr.last_pos, root_hash);
                    
                    // Calculate the correct MMR leaf index using the helper function
                    let correct_leaf_index = Self::leaf_count_to_mmr_index(leaves_count);
                    self.commitment_hash_to_index.write(commitment_hash, correct_leaf_index);
                    
                    leaves_count += 1;
                    self.leaves_count.write(leaves_count);

                    let last_peaks_len = last_peaks.len();
                    let peaks_len = peaks.len();

                    if last_peaks_len > peaks_len {
                        // Overwrite up to peaks_len, then set the rest to 0
                        for i in 0..peaks_len {
                            let mut storage_ptr = self.last_peaks.at(i.into());
                            storage_ptr.write(*peaks.at(i));
                        };
                        for i in peaks_len..last_peaks_len {
                            let mut storage_ptr = self.last_peaks.at(i.into());
                            storage_ptr.write(0);
                        };
                    } else {
                        // Overwrite up to last_peaks_len, then append the rest
                        for i in 0..last_peaks_len {
                            let mut storage_ptr = self.last_peaks.at(i.into());
                            storage_ptr.write(*peaks.at(i));
                        };
                        for i in last_peaks_len..peaks_len {
                            self.last_peaks.append().write(*peaks.at(i));
                        };
                    }

                    self
                        .emit(
                            Event::WithdrawalHashAppended(
                                WithdrawalHashAppended {
                                    index: correct_leaf_index,
                                    commitment_hash: commitment_hash,
                                    root_hash: root_hash,
                                },
                            ),
                        );
                },
                Result::Err(err) => { panic(array![err]) },
            }
        }

        fn leaf_count_to_mmr_index(leaf_count: felt252) -> felt252 {
            if leaf_count == 0 {
                return 0;
            }

            // Convert to u64 for arithmetic operations
            let mut internal_nodes: u64 = 0;
            let mut temp: u64 = leaf_count.try_into().unwrap();

            while temp > 0 {
                temp = temp / 2; // Right shift equivalent for division by 2
                internal_nodes += temp;
            };

            leaf_count + internal_nodes.into()
        }
    }
}
