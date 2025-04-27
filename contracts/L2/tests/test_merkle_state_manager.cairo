use snforge_std::ContractClassTrait;
use openzeppelin_utils::serde::SerializedAppend;
use snforge_std::DeclareResultTrait;
use starknet::{ContractAddress, contract_address_const};
use snforge_std::{
    declare, start_cheat_caller_address,
    stop_cheat_caller_address, EventSpyAssertionsTrait, spy_events,
};
use l2::merkle_state_manager::{MerkleStateManager, IMerkleStateManagerDispatcher, IMerkleStateManagerDispatcherTrait};

fn deploy_merkle_state_manager(relayer: ContractAddress) -> (ContractAddress, ContractAddress) {
    let contract_class = declare("MerkleStateManager").unwrap().contract_class();
    let owner = contract_address_const::<'OWNER'>();
    let mut calldata = array![];
    calldata.append_serde(owner);
    calldata.append_serde(relayer);
    let (contract_address, _) = contract_class.deploy(@calldata).unwrap();
    (contract_address, owner)
}

#[test]
fn test_update_withdrawal_root_from_commitment() {
    let relayer = contract_address_const::<'RELAYER'>();
    let (contract_address, _) = deploy_merkle_state_manager(relayer);
    let dispatcher = IMerkleStateManagerDispatcher { contract_address };
    let mut spy = spy_events();

    let commitment = 'COMMITMENT';
    dispatcher.update_withdrawal_root_from_commitment(commitment);

    let expected_event = MerkleStateManager::Event::WithdrawalRootUpdated(
        MerkleStateManager::WithdrawalRootUpdated {
            index: 1,
            new_root: commitment,
            commitment,
        },
    );

    // Assert that the event was emitted
    spy.assert_emitted(@array![(contract_address, expected_event)]);
}

#[test]
fn test_sync_deposit_root_from_l1_owner() {
    let relayer = contract_address_const::<'RELAYER'>();
    let (contract_address, owner) = deploy_merkle_state_manager(relayer);
    let dispatcher = IMerkleStateManagerDispatcher { contract_address };
    let mut spy = spy_events();

    // Start impersonating owner
    start_cheat_caller_address(contract_address, owner);

    let new_root = 'OWNER_ROOT';
    dispatcher.sync_deposit_root_from_l1(new_root);

    let expected_event = MerkleStateManager::Event::DepositRootSynced(
        MerkleStateManager::DepositRootSynced {
            index: 1,
            new_root,
        },
    );

    // Assert that the event was emitted
    spy.assert_emitted(@array![(contract_address, expected_event)]);

    stop_cheat_caller_address(contract_address);
}

#[test]
fn test_sync_deposit_root_from_l1_relayer() {
    let relayer = contract_address_const::<'RELAYER'>();
    let (contract_address, _) = deploy_merkle_state_manager(relayer);
    let dispatcher = IMerkleStateManagerDispatcher { contract_address };
    let mut spy = spy_events();

    // Start impersonating owner
    start_cheat_caller_address(contract_address, relayer);

    let new_root = 'RELAYER_ROOT';
    dispatcher.sync_deposit_root_from_l1(new_root);

    let expected_event = MerkleStateManager::Event::DepositRootSynced(
        MerkleStateManager::DepositRootSynced {
            index: 1,
            new_root,
        },
    );

    // Assert that the event was emitted
    spy.assert_emitted(@array![(contract_address, expected_event)]);

    stop_cheat_caller_address(contract_address);
}

#[test]
#[should_panic(expected: ('Caller not authorized',))]
fn test_sync_deposit_root_from_l1_non_owner() {
    let relayer = contract_address_const::<'RELAYER'>();
    let (contract_address, _) = deploy_merkle_state_manager(relayer);
    let dispatcher = IMerkleStateManagerDispatcher { contract_address };

    let non_owner_address = contract_address_const::<'NON_OWNER'>();

    // Start impersonating owner
    start_cheat_caller_address(contract_address, non_owner_address);

    let new_root = 'NON_OWNER_ROOT';
    dispatcher.sync_deposit_root_from_l1(new_root);

    stop_cheat_caller_address(contract_address);
}
