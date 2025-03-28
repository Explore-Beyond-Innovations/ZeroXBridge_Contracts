#[starknet::interface]
pub trait IZeroXBridgeL2<TContractState> {
    fn burn_xzb_for_unlock(ref self: TContractState, amount: core::integer::u256);
    /// The proof structure assumes the first three elements contain recipient, amount_low, and
    /// amount_high.
    fn process_mint_proof(
        ref self: TContractState, proof: Array<felt252>, commitment_hash: felt252,
    );
}

#[starknet::contract]
pub mod ZeroXBridgeL2 {
    use integrity::IntegrityWithConfigTrait;
    use integrity::IntegrityTrait;
    use starknet::{ContractAddress, get_caller_address};
    use l2::xZBERC20::{
        IBurnableDispatcher, IBurnableDispatcherTrait, IMintableDispatcher,
        IMintableDispatcherTrait,
    };
    use core::pedersen::PedersenTrait;
    use starknet::storage::{
        StoragePointerReadAccess, StoragePointerWriteAccess, Map, StorageMapReadAccess,
        StorageMapWriteAccess,
    };
    use core::hash::{HashStateTrait, HashStateExTrait};
    use integrity::{Integrity, IntegrityWithConfig, VerifierConfiguration};

    #[storage]
    struct Storage {
        xzb_token: ContractAddress,
        facts_registery_address: ContractAddress,
        security_bits: u32,
        verified_commitments: Map<felt252, bool>,
    }

    #[derive(Drop, Hash)]
    pub struct BurnData {
        pub caller: felt252,
        pub amount_low: felt252,
        pub amount_high: felt252,
    }

    #[derive(Drop, Hash)]
    pub struct MintData {
        pub recipient: felt252,
        pub amount_low: felt252,
        pub amount_high: felt252,
    }

    #[event]
    #[derive(Drop, Debug, starknet::Event)]
    pub enum Event {
        BurnEvent: BurnEvent,
        MintEvent: MintEvent,
    }

    #[derive(Drop, Debug, starknet::Event)]
    pub struct BurnEvent {
        pub user: ContractAddress,
        pub amount_low: felt252,
        pub amount_high: felt252,
        pub commitment_hash: felt252,
    }

    #[derive(Drop, Debug, starknet::Event)]
    pub struct MintEvent {
        pub recipient: ContractAddress,
        pub amount_low: felt252,
        pub amount_high: felt252,
        pub commitment_hash: felt252,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        token: ContractAddress,
        facts_registery_address: ContractAddress,
        security_bits: u32,
    ) {
        self.xzb_token.write(token);
        self.facts_registery_address.write(facts_registery_address);
        self.security_bits.write(security_bits);
    }

    #[abi(embed_v0)]
    impl BurnXzbImpl of super::IZeroXBridgeL2<ContractState> {
        fn burn_xzb_for_unlock(ref self: ContractState, amount: core::integer::u256) {
            let caller = get_caller_address();
            let token_addr = self.xzb_token.read();

            IBurnableDispatcher { contract_address: token_addr }.burn(amount);

            let data_to_hash = BurnData {
                caller: caller.try_into().unwrap(),
                amount_low: amount.low.try_into().unwrap(),
                amount_high: amount.high.try_into().unwrap(),
            };
            let commitment_hash = PedersenTrait::new(0).update_with(data_to_hash).finalize();

            self
                .emit(
                    BurnEvent {
                        user: caller,
                        amount_low: amount.low.into(),
                        amount_high: amount.high.into(),
                        commitment_hash: commitment_hash,
                    },
                );
        }

        fn process_mint_proof(
            ref self: ContractState, proof: Array<felt252>, commitment_hash: felt252,
        ) {
            assert(
                !self.verified_commitments.read(commitment_hash), 'Commitment already processed',
            );

            let facts_registery = self.facts_registery_address.read();
            let integrity = Integrity::from_address(facts_registery);

            let config = VerifierConfiguration {
                layout: 'recursive_with_poseidon',
                hasher: 'keccak_160_lsb',
                stone_version: 'stone6',
                memory_verification: 'relaxed',
            };

            let integrity_with_config = integrity.with_config(config, self.security_bits.read());
            assert(integrity_with_config.is_fact_hash_valid(commitment_hash), 'Invalid proof');

            self.verified_commitments.write(commitment_hash, true);
            assert(proof.len() >= 3, 'Proof too short');

            let recipient_felt = *proof.at(0);
            let amount_low = *proof.at(1);
            let amount_high = *proof.at(2);

            let recipient: ContractAddress = recipient_felt.try_into().unwrap();
            let amount = core::integer::u256 {
                low: amount_low.try_into().unwrap(), high: amount_high.try_into().unwrap(),
            };

            let mint_data = MintData { recipient: recipient_felt, amount_low, amount_high };

            // At this point, the process should have went like this:
            // (before calling the process_mint_proof)
            // - 1. User generates a STARK proof with the `stone-prover`
            // - 2. User serializes the proof into calldata alongside with the verifier config
            // (reference:
            // https://github.com/HerodotusDev/integrity/?tab=readme-ov-file#monolith-proof)
            // - 3. Register the proof on Integrity's FactRegistry contract, verifier verifies that
            // the proof is valid
            // (https://github.com/HerodotusDev/integrity/blob/main/deployed_contracts.md)
            //      and it computes our serialized calldata into a verification hash and stores it.
            // (calling the process_mint_proof)
            // - 4. Now that we have registered our fact, we call Inegrity's `is_fact_hash_valid()`
            // function with our commitment hash,
            //      if it is valid it finds a matching verification hash for it, it will return
            //      `true`
            // - 5. lastly, in this code we assert that the commitment hash matches what we want to
            // prove (L145)

            let computed_hash = PedersenTrait::new(0).update_with(mint_data).finalize();
            assert(computed_hash == commitment_hash, 'Proof does not match commitment');

            let token_addr = self.xzb_token.read();
            IMintableDispatcher { contract_address: token_addr }.mint(recipient, amount);

            self
                .emit(
                    Event::MintEvent(
                        MintEvent { recipient, amount_low, amount_high, commitment_hash },
                    ),
                );
        }
    }
}
