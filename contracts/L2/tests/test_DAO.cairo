use openzeppelin_utils::serde::SerializedAppend;
use snforge_std::DeclareResultTrait;
use starknet::{ContractAddress, contract_address_const};
use snforge_std::{cheat_caller_address, declare, CheatSpan, ContractClassTrait, start_cheat_block_timestamp, spy_events, EventSpyAssertionsTrait,EventSpyTrait,Event};
use testing_events::contract::{SpyEventsChecker, ISpyEventsCheckerDispatcher, ISpyEventsCheckerDispatcherTrait};
use l2::DAO::{IDAODispatcher, IDAODispatcherTrait, ProposalStatus};

fn owner() -> ContractAddress {
    contract_address_const::<'owner'>()
}

fn alice() -> ContractAddress {
    contract_address_const::<'alice'>()
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
#[should_panic(expected: 'Not in voting phase')]
fn test_tally_binding_votes_not_voting_phase(){
    let xzb_token = contract_address_const::<'xzb_token'>();
    let dao = deploy_dao(xzb_token);
    create_proposal(dao, 1, 'Proposal 1'.into(), 1000, 2000);
    let dao_dispatcher = IDAODispatcher { contract_address: dao };
    
    dao_dispatcher.tallyBindingVotes(1);
}


#[test]
fn test_tally_binding_votes_rejected_threshold_met(){
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

    start_cheat_block_timestamp(dao, 1000);

    let mut spy = spy_events();
    dao_dispatcher.tallyBindingVotes(1);

    spy
        .assert_emitted(
            @array![ // Ad. 2
                (
                    dao,
                    SpyEventsChecker::Event::BindingVoteResult(
                        SpyEventsChecker::BindingVoteResult { 
                            proposal_id: 1,
                            approved: false,
                            total_for: 1,
                            total_against: 1
                        }
                    )
                )
            ]
        );
  
    let proposal = dao_dispatcher.get_proposal(1);
    assert(proposal.status == ProposalStatus::Rejected, 'Proposal was not rejected');
}

#[test]
fn test_tally_binding_votes_rejected_threshold_not_met(){
    let owner = owner();
    let alice = alice();
    let xzb_token = contract_address_const::<'xzb_token'>();
    let dao = deploy_dao(xzb_token);
    create_proposal(dao, 1, 'Proposal 1'.into(), 1000, 2000);
    let dao_dispatcher = IDAODispatcher { contract_address: dao };

    cheat_caller_address(dao, owner, CheatSpan::TargetCalls(1));
    dao_dispatcher.vote_in_poll(1, false);

    cheat_caller_address(dao, alice, CheatSpan::TargetCalls(1));
    dao_dispatcher.vote_in_poll(1, true);

    start_cheat_block_timestamp(dao, 2000);

    let mut spy = spy_events();

    dao_dispatcher.tallyBindingVotes(1);

    spy
        .assert_emitted(
            @array![ // Ad. 2
                (
                    dao,
                    SpyEventsChecker::Event::BindingVoteResult(
                        SpyEventsChecker::BindingVoteResult { 
                            proposal_id: 1,
                            approved: false,
                            total_for: 1,
                            total_against: 1
                        }
                    )
                )
            ]
        );
    

    let proposal = dao_dispatcher.get_proposal(1);
    assert(proposal.status == ProposalStatus::Rejected, 'Proposal was not rejected');
}

#[test]
fn test_tally_binding_votes_approved(){
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

    start_cheat_block_timestamp(dao, 1000);

    let mut spy = spy_events();

    dao_dispatcher.tallyBindingVotes(1);

    spy
        .assert_emitted(
            @array![ // Ad. 2
                (
                    dao,
                    SpyEventsChecker::Event::BindingVoteResult(
                        SpyEventsChecker::BindingVoteResult { 
                            proposal_id: 1,
                            approved: false,
                            total_for: 1,
                            total_against: 1
                        }
                    )
                )
            ]
        );

    let proposal = dao_dispatcher.get_proposal(1);
    assert(proposal.status == ProposalStatus::Approved, 'Proposal was not approved');
}

