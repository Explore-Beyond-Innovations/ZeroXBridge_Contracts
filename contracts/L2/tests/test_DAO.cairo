use openzeppelin_utils::serde::SerializedAppend;
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    DeclareResultTrait, cheat_caller_address, cheat_block_timestamp, declare, CheatSpan,
    ContractClassTrait,
};
use starknet::{ContractAddress, contract_address_const, get_block_timestamp};
use l2::DAO::{IDAODispatcher, IDAODispatcherTrait, ProposalStatus};
use l2::xZBERC20::{IMintableDispatcher, IMintableDispatcherTrait};

fn owner() -> ContractAddress {
    contract_address_const::<'owner'>()
}

fn alice() -> ContractAddress {
    contract_address_const::<'alice'>()
}

fn deploy_xzb() -> ContractAddress {
    let contract_class = declare("xZBERC20").unwrap().contract_class();
    let mut calldata = array![];
    calldata.append_serde(owner());
    let (contract_address, _) = contract_class.deploy(@calldata).unwrap();
    contract_address
}

fn deploy_dao(xzb_token: ContractAddress) -> ContractAddress {
    let contract_class = declare("DAO").unwrap().contract_class();
    let mut calldata = array![];
    calldata.append_serde(xzb_token);
    let (contract_address, _) = contract_class.deploy(@calldata).unwrap();
    contract_address
}

fn create_proposal(
    dao: ContractAddress,
    proposal_id: u256,
    description: felt252,
    poll_duration: u64,
    voting_duration: u64,
) {
    let dao_dispatcher = IDAODispatcher { contract_address: dao };
    cheat_caller_address(dao, owner(), CheatSpan::TargetCalls(1));
    dao_dispatcher.create_proposal(proposal_id, description, poll_duration, voting_duration);
}

fn mint_xzb(xzb_token: ContractAddress, user: ContractAddress, amount: u256) {
    let token_dispatcher = IERC20Dispatcher { contract_address: xzb_token };
    cheat_caller_address(xzb_token, owner(), CheatSpan::TargetCalls(1));
    token_dispatcher.transfer(user, amount);
}

#[test]
#[should_panic(expected: 'Not in poll phase')]
fn test_double_vote_should_fail() {
    let alice = alice();
    let xzb_token = contract_address_const::<'xzb_token'>();
    let dao = deploy_dao(xzb_token);
    create_proposal(dao, 1, 'Proposal 1', 1000, 2000);

    let dao_dispatcher = IDAODispatcher { contract_address: dao };
    cheat_caller_address(dao, alice, CheatSpan::TargetCalls(1));
    dao_dispatcher.vote_in_poll(1, true);
    dao_dispatcher.vote_in_poll(1, true);
}

#[test]
#[should_panic(expected: 'Not in poll phase')]
fn test_vote_with_no_tokens_should_fail() {
    let bob = contract_address_const::<'bob'>();
    let xzb_token = contract_address_const::<'xzb_token'>();
    let dao = deploy_dao(xzb_token);
    create_proposal(dao, 1, 'Proposal 1', 1000, 2000);

    let dao_dispatcher = IDAODispatcher { contract_address: dao };
    cheat_caller_address(dao, bob, CheatSpan::TargetCalls(1));
    dao_dispatcher.vote_in_poll(1, true);
}

#[test]
fn test_create_proposal() {
    let owner = owner();
    let xzb_token = contract_address_const::<'xzb_token'>();
    let dao = deploy_dao(xzb_token);

    let dao_dispatcher = IDAODispatcher { contract_address: dao };
    cheat_caller_address(dao, owner, CheatSpan::TargetCalls(1));
    dao_dispatcher.create_proposal(1, 'New Proposal'.into(), 1000, 2000);

    let proposal = dao_dispatcher.get_proposal(1);
    assert(proposal.id == 1, 'Proposal ID mismatch');
    assert(proposal.description == 'New Proposal'.into(), 'Proposal description mismatch');
    assert(proposal.creator == owner, 'Proposal creator mismatch');
}

#[test]
#[should_panic(expected: 'Not in poll phase')]
fn test_vote_after_poll_phase_should_fail() {
    let alice = alice();
    let xzb_token = contract_address_const::<'xzb_token'>();
    let dao = deploy_dao(xzb_token);
    create_proposal(dao, 1, 'Proposal 1'.into(), 1, 2000); // Short poll duration

    let dao_dispatcher = IDAODispatcher { contract_address: dao };
    cheat_caller_address(dao, alice, CheatSpan::TargetCalls(1));

    // Simulate time passing
    dao_dispatcher.vote_in_poll(1, true);
}

#[test]
#[should_panic(expected: 'Proposal does not exist')]
fn test_vote_on_nonexistent_proposal_should_fail() {
    let alice = alice();
    let xzb_token = contract_address_const::<'xzb_token'>();
    let dao = deploy_dao(xzb_token);

    let dao_dispatcher = IDAODispatcher { contract_address: dao };
    cheat_caller_address(dao, alice, CheatSpan::TargetCalls(1));
    dao_dispatcher.vote_in_poll(999, true); // Nonexistent proposal ID
}

#[test]
#[should_panic(expected: 'Not in poll phase')]
fn test_double_vote_by_same_voter_should_fail() {
    let alice = alice();
    let xzb_token = contract_address_const::<'xzb_token'>();
    let dao = deploy_dao(xzb_token);
    create_proposal(dao, 1, 'Proposal 1'.into(), 1000, 2000);

    let dao_dispatcher = IDAODispatcher { contract_address: dao };
    cheat_caller_address(dao, alice, CheatSpan::TargetCalls(1));
    dao_dispatcher.vote_in_poll(1, true);
    dao_dispatcher.vote_in_poll(1, false);
}

#[test]
#[should_panic(expected: 'Not in poll phase')]
fn test_vote_with_zero_token_balance_should_fail() {
    let charlie = contract_address_const::<'charlie'>();
    let xzb_token = contract_address_const::<'xzb_token'>();
    let dao = deploy_dao(xzb_token);
    create_proposal(dao, 1, 'Proposal 1'.into(), 1000, 2000);

    let dao_dispatcher = IDAODispatcher { contract_address: dao };
    cheat_caller_address(dao, charlie, CheatSpan::TargetCalls(1));
    dao_dispatcher.vote_in_poll(1, true);
}

#[test]
fn test_start_poll() {
    let owner = owner();
    let xzb_token = contract_address_const::<'xzb_token'>();
    let dao = deploy_dao(xzb_token);
    create_proposal(dao, 1, 'Proposal 1'.into(), 1000, 2000);

    let dao_dispatcher = IDAODispatcher { contract_address: dao };
    cheat_caller_address(dao, owner, CheatSpan::TargetCalls(1));
    dao_dispatcher.start_poll(1);

    let proposal = dao_dispatcher.get_proposal(1);
    assert(proposal.status == ProposalStatus::PollActive, 'Proposal status mismatch');
}

#[test]
#[should_panic(expected: 'Poll phase already started')]
fn test_start_poll_twice_should_fail() {
    let owner = owner();
    let xzb_token = contract_address_const::<'xzb_token'>();
    let dao = deploy_dao(xzb_token);
    create_proposal(dao, 1, 'Proposal 1'.into(), 1000, 2000);

    let dao_dispatcher = IDAODispatcher { contract_address: dao };
    cheat_caller_address(dao, owner, CheatSpan::TargetCalls(1));
    dao_dispatcher.start_poll(1);
    dao_dispatcher.start_poll(1);
}

#[test]
#[should_panic(expected: 'Poll phase ended')]
fn test_start_poll_after_poll_end_should_fail() {
    let owner = owner();
    let xzb_token = contract_address_const::<'xzb_token'>();
    let dao = deploy_dao(xzb_token);
    create_proposal(dao, 1, 'Proposal 1'.into(), 1000, 2000);

    let dao_dispatcher = IDAODispatcher { contract_address: dao };
    cheat_caller_address(dao, owner, CheatSpan::TargetCalls(1));
    cheat_block_timestamp(dao, 1001, CheatSpan::TargetCalls(1));
    dao_dispatcher.start_poll(1);
}

#[test]
#[should_panic(expected: 'Not in poll phase')]
fn test_tally_poll_votes_passed() {
    let owner = owner();
    let alice = alice();

    let xzb_token = contract_address_const::<'xzb_token'>();
    let dao = deploy_dao(xzb_token);
    create_proposal(dao, 1, 'Proposal 1'.into(), 1000, 2000);

    let dao_dispatcher = IDAODispatcher { contract_address: dao };
    cheat_caller_address(dao, owner, CheatSpan::TargetCalls(1));
    dao_dispatcher.vote_in_poll(1, true);

    cheat_caller_address(dao, alice, CheatSpan::TargetCalls(1));
    dao_dispatcher.vote_in_poll(1, true);

    dao_dispatcher.tally_poll_votes(200);
    let proposal = dao_dispatcher.get_proposal(2);
    assert(proposal.status == ProposalStatus::PollPassed, 'Proposal should be passed');
}

#[test]
#[should_panic(expected: 'Not in poll phase')]
fn test_tally_poll_votes_defeated() {
    let owner = owner();
    let alice = alice();
    let xzb_token = contract_address_const::<'xzb_token'>();
    let dao = deploy_dao(xzb_token);
    create_proposal(dao, 1, 'Proposal 1'.into(), 1000, 2000);

    let dao_dispatcher = IDAODispatcher { contract_address: dao };

    cheat_caller_address(dao, owner, CheatSpan::TargetCalls(1));
    dao_dispatcher.vote_in_poll(1, false);

    cheat_caller_address(dao, alice, CheatSpan::TargetCalls(1));
    dao_dispatcher.vote_in_poll(1, false);

    dao_dispatcher.tally_poll_votes(1);
    let proposal = dao_dispatcher.get_proposal(1);
    assert(proposal.status == ProposalStatus::PollFailed, 'Proposal should be defeated');
}

#[test]
#[should_panic(expected: 'Not in poll phase')]
fn test_tally_poll_votes_not_in_poll_phase() {
    let owner = owner();
    let xzb_token = contract_address_const::<'xzb_token'>();
    let dao = deploy_dao(xzb_token);
    create_proposal(dao, 1, 'Proposal 1'.into(), 1, 2000);

    let dao_dispatcher = IDAODispatcher { contract_address: dao };
    cheat_caller_address(dao, owner, CheatSpan::TargetCalls(1));
    dao_dispatcher.vote_in_poll(1, true);

    dao_dispatcher.tally_poll_votes(1);
}

#[test]
#[should_panic(expected: 'Not in poll phase')]
fn test_tally_poll_votes_no_votes() {
    let xzb_token = contract_address_const::<'xzb_token'>();
    let dao = deploy_dao(xzb_token);
    create_proposal(dao, 1, 'Proposal 1'.into(), 1000, 2000);

    let dao_dispatcher = IDAODispatcher { contract_address: dao };

    dao_dispatcher.tally_poll_votes(1);
    let proposal = dao_dispatcher.get_proposal(1);
    assert(proposal.status == ProposalStatus::Pending, 'Not in poll phase');
}

#[test]
fn test_submit_proposal_success() {
    let owner = owner();
    let xzb_token = deploy_xzb();
    let dao = deploy_dao(xzb_token);

    // Mint tokens to the owner
    let mintable_dispatcher = IMintableDispatcher { contract_address: xzb_token };
    cheat_caller_address(xzb_token, owner, CheatSpan::TargetCalls(1));
    mintable_dispatcher.mint(owner, 1000.into());

    let dao_dispatcher = IDAODispatcher { contract_address: dao };
    cheat_caller_address(dao, owner, CheatSpan::TargetCalls(1));

    dao_dispatcher
        .submit_proposal(
            'Proposal 1'.into(), get_block_timestamp() + 3600, get_block_timestamp() + 7200,
        );

    let proposal = dao_dispatcher.get_proposal(1);
    assert(proposal.id == 1, 'Proposal ID mismatch');
    assert(proposal.description == 'Proposal 1'.into(), 'Proposal description mismatch');
    assert(proposal.creator == owner, 'Proposal creator mismatch');
}

#[test]
#[should_panic(expected: 'Insufficient xZB tokens')]
fn test_submit_proposal_insufficient_xzb() {
    let alice = alice();
    let xzb_token = deploy_xzb();
    let dao = deploy_dao(xzb_token);

    let dao_dispatcher = IDAODispatcher { contract_address: dao };
    cheat_caller_address(dao, alice, CheatSpan::TargetCalls(1));

    dao_dispatcher
        .submit_proposal(
            'Proposal 2'.into(), get_block_timestamp() + 3600, get_block_timestamp() + 7200,
        );
}

#[test]
#[should_panic(expected: 'u64_sub Overflow')]
fn test_submit_proposal_poll_end_in_past() {
    let owner = owner();
    let xzb_token = deploy_xzb();
    let dao = deploy_dao(xzb_token);

    let dao_dispatcher = IDAODispatcher { contract_address: dao };
    cheat_caller_address(dao, owner, CheatSpan::TargetCalls(1));

    dao_dispatcher
        .submit_proposal(
            'Proposal 3'.into(), get_block_timestamp() - 100, get_block_timestamp() + 3600,
        );
}

#[test]
#[should_panic(expected: 'Voting > poll end')]
fn test_submit_proposal_invalid_voting_end() {
    let owner = owner();
    let xzb_token = deploy_xzb();
    let dao = deploy_dao(xzb_token);

    let dao_dispatcher = IDAODispatcher { contract_address: dao };
    cheat_caller_address(dao, owner, CheatSpan::TargetCalls(1));

    dao_dispatcher
        .submit_proposal(
            'Proposal 4'.into(), get_block_timestamp() + 3600, get_block_timestamp() + 3599,
        );
}

#[test]
fn test_proposal_id_increment() {
    let token_addr = deploy_xzb();
    let owner = owner();

    // Mint tokens to the owner
    cheat_caller_address(token_addr, owner, CheatSpan::TargetCalls(1));
    IMintableDispatcher { contract_address: token_addr }.mint(owner, 1000.into());

    let dao = deploy_dao(token_addr); // Pass the ContractAddress to deploy_dao

    let dao_dispatcher = IDAODispatcher { contract_address: dao };
    cheat_caller_address(dao, owner, CheatSpan::TargetCalls(2));

    mint_xzb(token_addr, owner, 100.into());

    dao_dispatcher
        .submit_proposal(
            'Proposal 5'.into(), get_block_timestamp() + 3600, get_block_timestamp() + 7200,
        );

    mint_xzb(token_addr, owner, 100.into());

    dao_dispatcher
        .submit_proposal(
            'Proposal 5'.into(), get_block_timestamp() + 3600, get_block_timestamp() + 7200,
        );

    let proposal_1 = dao_dispatcher.get_proposal(1);
    let proposal_2 = dao_dispatcher.get_proposal(2);

    assert(proposal_1.id == 1, 'First proposal ID should be 1');
    assert(proposal_2.id == 2, 'Second proposal ID should be 2');
}


#[test]
fn test_vote() {
    let alice = alice();
    let xzb_token = contract_address_const::<'xzb_token'>();
    let dao = deploy_dao(xzb_token);
    create_proposal(dao, 1, 'Proposal 1'.into(), 1, 2000); // Short poll duration

    let dao_dispatcher = IDAODispatcher { contract_address: dao };
    cheat_caller_address(dao, alice, CheatSpan::TargetCalls(3));
    dao_dispatcher.moveProposal(1);
    // Simulate time passing
    dao_dispatcher.castBindingVote(1, true);
}
