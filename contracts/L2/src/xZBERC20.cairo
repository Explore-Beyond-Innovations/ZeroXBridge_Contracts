// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts for Cairo ^0.20.0

#[derive(Drop, Copy, Serde, starknet::Store)]
pub enum ProposalStatus {
    None,
    NonBindingPoll,
    BindingVote,
    Executed,
    Failed
}

#[starknet::interface]
pub trait ExecutiveAction<TContractState> {
    fn startBindingVote(
        ref self: TContractState, 
        proposal_id: u256, 
        executive_action: ContractAddress
    );
}

use starknet::ContractAddress;

#[starknet::interface]
pub trait IMintable<TContractState> {
    fn mint(ref self: TContractState, recipient: ContractAddress, amount: u256);
}

#[starknet::interface]
pub trait IBurnable<TContractState> {
    fn burn(ref self: TContractState, amount: u256);
}

pub const MINTER_ROLE: felt252 = selector!("MINTER_ROLE");
pub const UPGRADER_ROLE: felt252 = selector!("UPGRADER_ROLE");

#[starknet::contract]
pub mod xZBERC20 {
    use openzeppelin_access::accesscontrol::{AccessControlComponent, DEFAULT_ADMIN_ROLE};
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin_token::erc20::{ERC20Component, ERC20HooksEmptyImpl};
    use openzeppelin_upgrades::UpgradeableComponent;
    use openzeppelin_upgrades::interface::IUpgradeable;
    use starknet::{ClassHash, ContractAddress, get_caller_address};

    use super::{IBurnable, IMintable};
    use super::{MINTER_ROLE, UPGRADER_ROLE};

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);
    component!(path: AccessControlComponent, storage: accesscontrol, event: AccessControlEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);


    // External
    #[abi(embed_v0)]
    impl ERC20MixinImpl = ERC20Component::ERC20MixinImpl<ContractState>;
    #[abi(embed_v0)]
    impl AccessControlMixinImpl =
        AccessControlComponent::AccessControlMixinImpl<ContractState>;

    // Internal
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;
    impl AccessControlInternalImpl = AccessControlComponent::InternalImpl<ContractState>;
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
        #[substorage(v0)]
        accesscontrol: AccessControlComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        proposal_status: LegacyMap::<u256, ProposalStatus>,
        proposal_actions: LegacyMap::<u256, ContractAddress>,
        non_binding_threshold: u256,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event,
        #[flat]
        AccessControlEvent: AccessControlComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        BindingVoteStarted: BindingVoteStarted,
    }

    #[derive(Drop, starknet::Event)]
    pub struct BindingVoteStarted {
        proposal_id: u256,
        executive_action: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.erc20.initializer("xZB", "XZB");
        self.accesscontrol.initializer();

        self.accesscontrol._grant_role(DEFAULT_ADMIN_ROLE, owner);
        self.accesscontrol._grant_role(UPGRADER_ROLE, owner);
        self.accesscontrol._grant_role(MINTER_ROLE, owner);
    }

    #[abi(embed_v0)]
    impl MintableImpl of IMintable<ContractState> {
        fn mint(ref self: ContractState, recipient: ContractAddress, amount: u256) {
            self.accesscontrol.assert_only_role(MINTER_ROLE);
            self.erc20.mint(recipient, amount);
        }
    }

    #[abi(embed_v0)]
    impl BurnableImpl of IBurnable<ContractState> {
        fn burn(ref self: ContractState, amount: u256) {
            let burner = get_caller_address();
            self.erc20.burn(burner, amount);
        }
    }

    //
    // Upgradeable
    //

    #[abi(embed_v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.accesscontrol.assert_only_role(UPGRADER_ROLE);
            self.upgradeable.upgrade(new_class_hash);
        }
    }
}
