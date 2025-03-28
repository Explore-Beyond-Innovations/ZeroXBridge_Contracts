use snforge_std::{
    declare, spy_events, ContractClassTrait, DeclareResultTrait, EventSpyAssertionsTrait, CheatSpan,
    cheat_caller_address, EventSpyTrait,
};

use l2::ZeroXBridgeL2::{IZeroXBridgeL2Dispatcher, IZeroXBridgeL2DispatcherTrait};
use l2::ZeroXBridgeL2::ZeroXBridgeL2::{Event, BurnEvent, BurnData, MintData, MintEvent};
use l2::xZBERC20::{IMintableDispatcher, IMintableDispatcherTrait};
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use starknet::{ContractAddress, contract_address_const};
use core::integer::u256;
use core::pedersen::PedersenTrait;
use core::hash::{HashStateTrait, HashStateExTrait};
use openzeppelin_utils::serde::SerializedAppend;

/// Security bits for testing
const SECURITY_BITS: u32 = 48;

fn alice() -> ContractAddress {
    contract_address_const::<'alice'>()
}

fn mocked_facts_registry() -> ContractAddress {
    contract_address_const::<0x02fd1f617a9caeeeadd0cd7da2d99391ee9dd9ad6c5cd1960e3034ffdfad3ae1>()
}

fn owner() -> ContractAddress {
    contract_address_const::<'owner'>()
}

fn deploy_xzb() -> ContractAddress {
    let contract_class = declare("xZBERC20").unwrap().contract_class();
    let mut calldata = array![];
    calldata.append_serde(owner());
    let (contract_address, _) = contract_class.deploy(@calldata).unwrap();
    contract_address
}

fn deploy_bridge(xzb_addr: ContractAddress) -> ContractAddress {
    let contract_class = declare("ZeroXBridgeL2").unwrap().contract_class();
    let mut calldata = array![];
    calldata.append_serde(xzb_addr);
    calldata.append_serde(mocked_facts_registry());
    calldata.append_serde(SECURITY_BITS);
    let (contract_address, _) = contract_class.deploy(@calldata).unwrap();
    contract_address
}

#[test]
fn test_burn_xzb_for_unlock_happy_path() {
    let token_addr = deploy_xzb();
    let bridge_addr = deploy_bridge(token_addr);
    let alice_addr = alice();
    let owner_addr = owner();

    // Mint tokens to Alice.
    cheat_caller_address(token_addr, owner_addr, CheatSpan::TargetCalls(1));
    IMintableDispatcher { contract_address: token_addr }.mint(alice_addr, 1000);

    // Burn tokens through bridge with alice as caller.
    let mut spy = spy_events();
    cheat_caller_address(bridge_addr, alice_addr, CheatSpan::TargetCalls(1));
    cheat_caller_address(token_addr, alice_addr, CheatSpan::TargetCalls(1));
    let amount: u256 = u256 { low: 500, high: 0 };
    IZeroXBridgeL2Dispatcher { contract_address: bridge_addr }.burn_xzb_for_unlock(amount);

    // Compute expected commitment hash.
    let data_to_hash = BurnData {
        caller: alice_addr.try_into().unwrap(), amount_low: 500, amount_high: 0,
    };
    let expected_hash = PedersenTrait::new(0).update_with(data_to_hash).finalize();

    // Build expected event value.
    let expected_event = (
        bridge_addr,
        Event::BurnEvent(
            BurnEvent {
                user: alice_addr.try_into().unwrap(),
                amount_low: 500,
                amount_high: 0,
                commitment_hash: expected_hash,
            },
        ),
    );

    // Assert that the expected event was emitted.
    spy.assert_emitted(@array![expected_event]);
}

#[test]
fn test_burn_xzb_updates_balance() {
    // Verify that burning xZB tokens updates the user's balance correctly.
    let token_addr = deploy_xzb();
    let bridge_addr = deploy_bridge(token_addr);
    let alice_addr = alice();
    let owner_addr = owner();

    // Mint tokens to Alice.
    cheat_caller_address(token_addr, owner_addr, CheatSpan::TargetCalls(1));
    IMintableDispatcher { contract_address: token_addr }.mint(alice_addr, 1000);

    // Check initial balance.
    let erc20 = IERC20Dispatcher { contract_address: token_addr };
    let initial_balance = erc20.balance_of(alice_addr);

    // Burn tokens through bridge.
    cheat_caller_address(bridge_addr, alice_addr, CheatSpan::TargetCalls(1));
    cheat_caller_address(token_addr, alice_addr, CheatSpan::TargetCalls(1));
    let amount: u256 = u256 { low: 500, high: 0 };
    IZeroXBridgeL2Dispatcher { contract_address: bridge_addr }.burn_xzb_for_unlock(amount);

    // Check balance after burn.
    let final_balance = erc20.balance_of(alice_addr);
    assert(initial_balance - final_balance == 500, 'Token balance not reduced');
}

#[test]
fn test_commitment_hash_consistency() {
    // Verify that for a fixed caller and burn amount, the commitment hash is consistent.
    let token_addr = deploy_xzb();
    let bridge_addr = deploy_bridge(token_addr);
    let alice_addr = alice();
    let owner_addr = owner();

    // Mint tokens to Alice.
    cheat_caller_address(token_addr, owner_addr, CheatSpan::TargetCalls(1));
    IMintableDispatcher { contract_address: token_addr }.mint(alice_addr, 1000);

    // Burn tokens via bridge.
    let mut spy = spy_events();
    // Burn tokens through bridge.
    cheat_caller_address(bridge_addr, alice_addr, CheatSpan::TargetCalls(1));
    cheat_caller_address(token_addr, alice_addr, CheatSpan::TargetCalls(1));
    let amount: u256 = u256 { low: 500, high: 0 };
    IZeroXBridgeL2Dispatcher { contract_address: bridge_addr }.burn_xzb_for_unlock(amount);

    // Compute expected hash using BurnData.
    let data_to_hash = BurnData {
        caller: alice_addr.try_into().unwrap(), amount_low: 500, amount_high: 0,
    };
    let expected = PedersenTrait::new(0).update_with(data_to_hash).finalize();
    println!("Expected commitment hash: {:?}", expected);
    // Retrieve the emitted event and compare commitment hash.
    let events = spy.get_events();
    let (_emitter, evt) = events.events.at(1);
    assert(evt.data.at(3) == @expected, 'hash does not match');
}

#[test]
#[should_panic(expected: 'ERC20: insufficient balance')]
fn test_burn_xzb_insufficient_balance() {
    // Test that burning more tokens than available triggers an error.
    let token_addr = deploy_xzb();
    let bridge_addr = deploy_bridge(token_addr);
    let alice_addr = alice();
    let owner_addr = owner();

    // Mint fewer tokens than we attempt to burn.
    cheat_caller_address(token_addr, owner_addr, CheatSpan::TargetCalls(1));
    IMintableDispatcher { contract_address: token_addr }.mint(alice_addr, 300);

    // Attempt to burn 500 tokens when balance is only 300.
    cheat_caller_address(bridge_addr, alice_addr, CheatSpan::TargetCalls(1));
    cheat_caller_address(token_addr, alice_addr, CheatSpan::TargetCalls(1));
    let amount: u256 = u256 { low: 500, high: 0 };
    IZeroXBridgeL2Dispatcher { contract_address: bridge_addr }.burn_xzb_for_unlock(amount);
}

#[test]
#[fork("SEPOLIA_LATEST")]
fn test_process_mint_proof_happy_path() {
    // Setup environment
    let token_addr = deploy_xzb();
    let bridge_addr = deploy_bridge(token_addr);
    let recipient_addr = alice();
    let owner = owner();

    // Create test data
    let amount: u256 = u256 { low: 500, high: 0 };

    // Create mock proof array (recipient, amount_low, amount_high)
    let mut proof = array![];
    proof.append(recipient_addr.into());
    proof.append(amount.low.into());
    proof.append(amount.high.into());

    // Create commitment hash from mint data
    let mint_data = MintData {
        recipient: recipient_addr.into(),
        amount_low: amount.low.into(),
        amount_high: amount.high.into(),
    };
    let commitment_hash = PedersenTrait::new(0).update_with(mint_data).finalize();

    // Create spy to track events
    let mut spy = spy_events();

    // Mock integrity verification to return true
    // Note: In real tests, you would need to either:
    // 1. Use real integrity verification with valid proofs
    // 2. Mock the integrity dependency more thoroughly
    // For this example, we'll assume integrity verification passes

    // Process the mint proof

    cheat_caller_address(token_addr, owner, CheatSpan::TargetCalls(1));
    cheat_caller_address(bridge_addr, owner, CheatSpan::TargetCalls(1));
    IZeroXBridgeL2Dispatcher { contract_address: bridge_addr }
        .process_mint_proof(proof, commitment_hash);

    // Build expected event
    let expected_event = (
        bridge_addr,
        Event::MintEvent(
            MintEvent {
                recipient: recipient_addr,
                amount_low: amount.low.into(),
                amount_high: amount.high.into(),
                commitment_hash,
            },
        ),
    );

    // Assert event was emitted
    spy.assert_emitted(@array![expected_event]);

    // Verify tokens were minted correctly
    let erc20 = IERC20Dispatcher { contract_address: token_addr };
    let balance = erc20.balance_of(recipient_addr);
    assert(balance == amount, 'Tokens not minted correctly');
}

#[test]
#[fork("SEPOLIA_LATEST")]
#[should_panic(expected: 'Commitment already processed')]
fn test_duplicate_commitment_rejection() {
    // Setup environment
    let token_addr = deploy_xzb();
    let bridge_addr = deploy_bridge(token_addr);
    let recipient_addr = alice();
    let owner = owner();

    // Create test data
    let amount: u256 = u256 { low: 500, high: 0 };

    // Create mock proof
    let mut proof = array![];
    proof.append(recipient_addr.into());
    proof.append(amount.low.into());
    proof.append(amount.high.into());
    // Create commitment hash from mint data
    let mint_data = MintData {
        recipient: recipient_addr.into(),
        amount_low: amount.low.into(),
        amount_high: amount.high.into(),
    };
    let commitment_hash = PedersenTrait::new(0).update_with(mint_data).finalize();

    // Process the mint proof first time (should succeed)

    cheat_caller_address(token_addr, owner, CheatSpan::TargetCalls(2));
    cheat_caller_address(bridge_addr, owner, CheatSpan::TargetCalls(2));
    IZeroXBridgeL2Dispatcher { contract_address: bridge_addr }
        .process_mint_proof(proof.clone(), commitment_hash);

    // Try to process the same proof again (should fail)
    IZeroXBridgeL2Dispatcher { contract_address: bridge_addr }
        .process_mint_proof(proof, commitment_hash);
}

#[test]
#[fork("SEPOLIA_LATEST")]
#[should_panic(expected: 'Proof too short')]
fn test_insufficient_proof_data() {
    // Setup environment
    let token_addr = deploy_xzb();
    let bridge_addr = deploy_bridge(token_addr);
    let owner = owner();
    let recipient_addr = alice();

    // Create an incomplete proof (less than 3 elements)
    let mut proof = array![];
    proof.append(123);
    proof.append(456);
    // Missing third element

    // Create test data
    let amount: u256 = u256 { low: 500, high: 0 };

    // Create commitment hash from mint data
    let mint_data = MintData {
        recipient: recipient_addr.into(),
        amount_low: amount.low.into(),
        amount_high: amount.high.into(),
    };
    let commitment_hash = PedersenTrait::new(0).update_with(mint_data).finalize();

    cheat_caller_address(token_addr, owner, CheatSpan::TargetCalls(1));
    cheat_caller_address(bridge_addr, owner, CheatSpan::TargetCalls(1));
    IZeroXBridgeL2Dispatcher { contract_address: bridge_addr }
        .process_mint_proof(proof, commitment_hash);
}
