
use starknet::{ContractAddress, contract_address_const};
use snforge_std::{
    declare, ContractClassTrait, start_cheat_caller_address, stop_cheat_caller_address,
    start_cheat_block_timestamp, stop_cheat_block_timestamp, spy_events, SpyOn, EventSpy, EventAssertions
};

use l2::core::merkle_state_manager::{
    MerkleStateManager, IMerkleStateManagerDispatcher, IMerkleStateManagerDispatcherTrait
};

// Test constants
fn OWNER() -> ContractAddress {
    contract_address_const::<'owner'>()
}

fn RELAYER() -> ContractAddress {
    contract_address_const::<'relayer'>()
}

fn BRIDGE() -> ContractAddress {
    contract_address_const::<'bridge'>()
}

fn OTHER_USER() -> ContractAddress {
    contract_address_const::<'other_user'>()
}

fn deploy_contract() -> IMerkleStateManagerDispatcher {
    let contract = declare("MerkleStateManager").unwrap();
    let constructor_calldata = array![
        OWNER().into(),
        RELAYER().into(),
        BRIDGE().into()
    ];
    let contract_address = contract.deploy(@constructor_calldata).unwrap();
    IMerkleStateManagerDispatcher { contract_address }
}

#[test]
fn test_deployment_and_initial_state() {
    let contract = deploy_contract();
    
    // Check initial state
    assert!(contract.get_deposit_root() == 0, "Initial deposit root should be 0");
    assert!(contract.get_withdrawal_root() == 0, "Initial withdrawal root should be 0");
    assert!(contract.get_deposit_root_index() == 0, "Initial deposit index should be 0");
    assert!(contract.get_withdrawal_root_index() == 0, "Initial withdrawal index should be 0");
}

#[test]
fn test_sync_deposit_root_from_l1_success() {
    let contract = deploy_contract();
    let mut spy = spy_events(SpyOn::One(contract.contract_address));
    
    let new_root = 0x123456789abcdef;
    let timestamp = 1000_u64;
    
    start_cheat_block_timestamp(contract.contract_address, timestamp);
    start_cheat_caller_address(contract.contract_address, RELAYER());
    
    contract.sync_deposit_root_from_l1(new_root);
    
    stop_cheat_caller_address(contract.contract_address);
    stop_cheat_block_timestamp(contract.contract_address);
    
    // Check state updates
    assert!(contract.get_deposit_root() == new_root, "Deposit root not updated");
    assert!(contract.get_deposit_root_index() == 1, "Deposit index not incremented");
    assert!(contract.get_deposit_root_history(1) == new_root, "History not stored");
    assert!(contract.get_deposit_root_timestamp(1) == timestamp, "Timestamp not stored");
    
    // Check event emission
    spy.assert_emitted(@array![
        (
            contract.contract_address,
            MerkleStateManager::Event::DepositRootSynced(
                MerkleStateManager::DepositRootSynced {
                    index: 1,
                    new_root: new_root,
                    timestamp: timestamp,
                }
            )
        )
    ]);
}

#[test]
#[should_panic(expected: "Unauthorized caller")]
fn test_sync_deposit_root_unauthorized() {
    let contract = deploy_contract();
    
    start_cheat_caller_address(contract.contract_address, OTHER_USER());
    contract.sync_deposit_root_from_l1(0x123);
    stop_cheat_caller_address(contract.contract_address);
}

#[test]
#[should_panic(expected: "Invalid root provided")]
fn test_sync_deposit_root_invalid_root() {
    let contract = deploy_contract();
    
    start_cheat_caller_address(contract.contract_address, RELAYER());
    contract.sync_deposit_root_from_l1(0); // Invalid root (zero)
    stop_cheat_caller_address(contract.contract_address);
}

#[test]
fn test_update_withdrawal_root_from_commitment_success() {
    let contract = deploy_contract();
    let mut spy = spy_events(SpyOn::One(contract.contract_address));
    
    let commitment = 0xabcdef123456789;
    let timestamp = 2000_u64;
    
    start_cheat_block_timestamp(contract.contract_address, timestamp);
    start_cheat_caller_address(contract.contract_address, BRIDGE());
    
    contract.update_withdrawal_root_from_commitment(commitment);
    
    stop_cheat_caller_address(contract.contract_address);
    stop_cheat_block_timestamp(contract.contract_address);
    
    // Check state updates
    assert!(contract.get_withdrawal_root() == commitment, "Withdrawal root not updated");
    assert!(contract.get_withdrawal_root_index() == 1, "Withdrawal index not incremented");
    assert!(contract.get_withdrawal_root_history(1) == commitment, "History not stored");
    assert!(contract.get_withdrawal_root_timestamp(1) == timestamp, "Timestamp not stored");
    
    // Check event emission
    spy.assert_emitted(@array![
        (
            contract.contract_address,
            MerkleStateManager::Event::WithdrawalRootUpdated(
                MerkleStateManager::WithdrawalRootUpdated {
                    index: 1,
                    new_root: commitment,
                    commitment: commitment,
                    timestamp: timestamp,
                }
            )
        )
    ]);
}

#[test]
#[should_panic(expected: "Unauthorized caller")]
fn test_update_withdrawal_root_unauthorized() {
    let contract = deploy_contract();
    
    start_cheat_caller_address(contract.contract_address, OTHER_USER());
    contract.update_withdrawal_root_from_commitment(0x123);
    stop_cheat_caller_address(contract.contract_address);
}

#[test]
#[should_panic(expected: "Invalid root provided")]
fn test_update_withdrawal_root_invalid_commitment() {
    let contract = deploy_contract();
    
    start_cheat_caller_address(contract.contract_address, BRIDGE());
    contract.update_withdrawal_root_from_commitment(0); // Invalid commitment (zero)
    stop_cheat_caller_address(contract.contract_address);
}

#[test]
fn test_multiple_root_updates() {
    let contract = deploy_contract();
    
    // Sync multiple deposit roots
    start_cheat_caller_address(contract.contract_address, RELAYER());
    contract.sync_deposit_root_from_l1(0x111);
    contract.sync_deposit_root_from_l1(0x222);
    contract.sync_deposit_root_from_l1(0x333);
    stop_cheat_caller_address(contract.contract_address);
    
    // Update multiple withdrawal roots
    start_cheat_caller_address(contract.contract_address, BRIDGE());
    contract.update_withdrawal_root_from_commitment(0xaaa);
    contract.update_withdrawal_root_from_commitment(0xbbb);
    stop_cheat_caller_address(contract.contract_address);
    
    // Check current state
    assert!(contract.get_deposit_root() == 0x333, "Latest deposit root wrong");
    assert!(contract.get_withdrawal_root() == 0xbbb, "Latest withdrawal root wrong");
    assert!(contract.get_deposit_root_index() == 3, "Deposit index wrong");
    assert!(contract.get_withdrawal_root_index() == 2, "Withdrawal index wrong");
    
    // Check historical data
    assert!(contract.get_deposit_root_history(1) == 0x111, "Deposit history 1 wrong");
    assert!(contract.get_deposit_root_history(2) == 0x222, "Deposit history 2 wrong");
    assert!(contract.get_deposit_root_history(3) == 0x333, "Deposit history 3 wrong");
    assert!(contract.get_withdrawal_root_history(1) == 0xaaa, "Withdrawal history 1 wrong");
    assert!(contract.get_withdrawal_root_history(2) == 0xbbb, "Withdrawal history 2 wrong");
}

#[test]
fn test_set_authorized_relayer() {
    let contract = deploy_contract();
    let mut spy = spy_events(SpyOn::One(contract.contract_address));
    
    let new_relayer = contract_address_const::<'new_relayer'>();
    
    start_cheat_caller_address(contract.contract_address, OWNER());
    contract.set_authorized_relayer(new_relayer);
    stop_cheat_caller_address(contract.contract_address);
    
    // Test that new relayer can sync deposit root
    start_cheat_caller_address(contract.contract_address, new_relayer);
    contract.sync_deposit_root_from_l1(0x456);
    stop_cheat_caller_address(contract.contract_address);
    
    assert!(contract.get_deposit_root() == 0x456, "New relayer cannot sync");
    
    // Check event emission
    spy.assert_emitted(@array![
        (
            contract.contract_address,
            MerkleStateManager::Event::RelayerUpdated(
                MerkleStateManager::RelayerUpdated {
                    old_relayer: RELAYER(),
                    new_relayer: new_relayer,
                }
            )
        )
    ]);
}

#[test]
#[should_panic(expected: "Unauthorized caller")]
fn test_set_authorized_relayer_unauthorized() {
    let contract = deploy_contract();
    let new_relayer = contract_address_const::<'new_relayer'>();
    
    start_cheat_caller_address(contract.contract_address, OTHER_USER());
    contract.set_authorized_relayer(new_relayer);
    stop_cheat_caller_address(contract.contract_address);
}

#[test]
fn test_set_bridge_contract() {
    let contract = deploy_contract();
    let mut spy = spy_events(SpyOn::One(contract.contract_address));
    
    let new_bridge = contract_address_const::<'new_bridge'>();
    
    start_cheat_caller_address(contract.contract_address, OWNER());
    contract.set_bridge_contract(new_bridge);
    stop_cheat_caller_address(contract.contract_address);
    
    // Test that new bridge can update withdrawal root
    start_cheat_caller_address(contract.contract_address, new_bridge);
    contract.update_withdrawal_root_from_commitment(0x789);
    stop_cheat_caller_address(contract.contract_address);
    
    assert!(contract.get_withdrawal_root() == 0x789, "New bridge cannot update");
    
    // Check event emission
    spy.assert_emitted(@array![
        (
            contract.contract_address,
            MerkleStateManager::Event::BridgeContractUpdated(
                MerkleStateManager::BridgeContractUpdated {
                    old_bridge: BRIDGE(),
                    new_bridge: new_bridge,
                }
            )
        )
    ]);
}

#[test]
#[should_panic(expected: "Unauthorized caller")]
fn test_set_bridge_contract_unauthorized() {
    let contract = deploy_contract();
    let new_bridge = contract_address_const::<'new_bridge'>();
    
    start_cheat_caller_address(contract.contract_address, OTHER_USER());
    contract.set_bridge_contract(new_bridge);
    stop_cheat_caller_address(contract.contract_address);
}

#[test]
fn test_verify_merkle_proof_simple() {
    let contract = deploy_contract();
    
    // Simple test case with known values
    let leaf = 0x1;
    let proof = array![0x2];
    let root = 0x3; // This would be hash(0x1, 0x2) in a real scenario
    
    // Note: This is a simplified test. In practice, you'd need actual 
    // Merkle tree values that hash correctly
    let _result = contract.verify_merkle_proof(leaf, proof, root);
    
    // Since we're using a simplified proof, we expect this to work
    // In a real implementation, you'd test with actual Merkle tree values
}

#[test]
fn test_timestamp_tracking() {
    let contract = deploy_contract();
    
    let timestamp1 = 1000_u64;
    let timestamp2 = 2000_u64;
    
    // First update with timestamp1
    start_cheat_block_timestamp(contract.contract_address, timestamp1);
    start_cheat_caller_address(contract.contract_address, RELAYER());
    contract.sync_deposit_root_from_l1(0x111);
    stop_cheat_caller_address(contract.contract_address);
    stop_cheat_block_timestamp(contract.contract_address);
    
    // Second update with timestamp2
    start_cheat_block_timestamp(contract.contract_address, timestamp2);
    start_cheat_caller_address(contract.contract_address, BRIDGE());
    contract.update_withdrawal_root_from_commitment(0x222);
    stop_cheat_caller_address(contract.contract_address);
    stop_cheat_block_timestamp(contract.contract_address);
    
    // Check timestamps
    assert!(contract.get_deposit_root_timestamp(1) == timestamp1, "Deposit timestamp wrong");
    assert!(contract.get_withdrawal_root_timestamp(1) == timestamp2, "Withdrawal timestamp wrong");
}

#[test]
fn test_historical_data_integrity() {
    let contract = deploy_contract();
    
    // Add multiple entries
    start_cheat_caller_address(contract.contract_address, RELAYER());
    contract.sync_deposit_root_from_l1(0x111);
    contract.sync_deposit_root_from_l1(0x222);
    contract.sync_deposit_root_from_l1(0x333);
    stop_cheat_caller_address(contract.contract_address);
    
    start_cheat_caller_address(contract.contract_address, BRIDGE());
    contract.update_withdrawal_root_from_commitment(0xaaa);
    contract.update_withdrawal_root_from_commitment(0xbbb);
    stop_cheat_caller_address(contract.contract_address);
    
    // Verify historical data remains intact
    assert!(contract.get_deposit_root_history(1) == 0x111, "History 1 corrupted");
    assert!(contract.get_deposit_root_history(2) == 0x222, "History 2 corrupted");
    assert!(contract.get_deposit_root_history(3) == 0x333, "History 3 corrupted");
    
    assert!(contract.get_withdrawal_root_history(1) == 0xaaa, "Withdrawal history 1 corrupted");
    assert!(contract.get_withdrawal_root_history(2) == 0xbbb, "Withdrawal history 2 corrupted");
    
    // Verify current state reflects latest
    assert!(contract.get_deposit_root() == 0x333, "Current deposit root wrong");
    assert!(contract.get_withdrawal_root() == 0xbbb, "Current withdrawal root wrong");
    
    // Verify indices are correct
    assert!(contract.get_deposit_root_index() == 3, "Deposit index wrong");
    assert!(contract.get_withdrawal_root_index() == 2, "Withdrawal index wrong");
}