use core::starknet::ContractAddress;

// Define the ExecutiveAction interface
#[starknet::interface]
pub trait IExecutiveAction<TContractState> {
    fn execute(ref self: TContractState);
}

#[derive(Drop, Serde, Copy, starknet::Store, PartialEq)]
#[allow(starknet::store_no_default_variant)]
pub enum ProposalStatus {
    Pending,
    PollActive,
    PollPassed,
    PollFailed,
    BindingVoteActive, // New status for binding vote phase
    Approved,
    Executed,
    Rejected,
}

#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct Proposal {
    pub id: u256,
    pub description: felt252,
    pub creator: ContractAddress,
    pub creation_time: u64,
    pub poll_end_time: u64,
    pub voting_end_time: u64,
    pub vote_for: u256,
    pub vote_against: u256,
    pub status: ProposalStatus, // Use ProposalStatus enum instead of u8
    pub executive_action_address: ContractAddress,
}

#[derive(Drop, Serde, Copy, starknet::Store)]
struct BindingVoteData {
    pub votesFor: u32,
    pub votesAgainst: u32,
}

#[starknet::interface]
pub trait IDAO<TContractState> {
    fn vote_in_poll(ref self: TContractState, proposal_id: u256, support: bool);
    fn get_proposal(self: @TContractState, proposal_id: u256) -> Proposal;
    fn has_voted(self: @TContractState, proposal_id: u256, voter: ContractAddress) -> bool;

    fn create_proposal(
        ref self: TContractState,
        proposal_id: u256,
        description: felt252,
        poll_duration: u64,
        voting_duration: u64,
    );


    fn submit_proposal(
        ref self: TContractState, description: felt252, poll_end_time: u64, voting_end_time: u64,
    );

    fn start_poll(ref self: TContractState, proposal_id: u256);
    fn tally_poll_votes(ref self: TContractState, proposal_id: u256);

    fn castBindingVote(ref self: TContractState, proposal_id: u256, support: bool);

    // move proposal to voting phase
    fn moveProposal(ref self: TContractState, proposal_id: u256);
    fn startBindingVote(ref self: TContractState, proposal_id: u256, execute_action_address: ContractAddress);
}

#[starknet::contract]
pub mod DAO {
    use starknet::event::EventEmitter;
    use starknet::storage::StorageMapWriteAccess;
    use starknet::storage::StorageMapReadAccess;
    use starknet::{ContractAddress, contract_address_const};
    use starknet::get_caller_address;
    use starknet::get_block_timestamp;
    use core::traits::Into;
    use core::array::ArrayTrait;
    use core::starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess, Map};
    use super::{Proposal, ProposalStatus, BindingVoteData};
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use core::panic_with_felt252;
    use super::IExecutiveAction;

    #[storage]
    struct Storage {
        xzb_token: ContractAddress,
        proposals: Map<u256, Proposal>,
        has_voted: Map<(u256, ContractAddress), bool>,
        proposal_exists: Map<u256, bool>,
        next_proposal_id: u256,
        pollVotesCount: u32,
        bindingVoteProposals: Map<u256, bool>, // proposal, inVotingPhase
        bindingVoteCasted: Map<(u256, ContractAddress), bool>, // (proposal id, caller), hasVoted 
        bindingVotesCount: u256, // total binding votes for a proposal
        bindingVotesCountMap: Map<u256, BindingVoteData> //proposal id to the binding vote data
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        PollVoted: PollVoted,
        ProposalSubmitted: ProposalSubmitted,
        PollStarted: PollStarted,
        PollResultUpdated: PollResultUpdated,
        BindingVoteCast: BindingVoteCast,
        BindingVoteStarted: BindingVoteStarted,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PollVoted {
        #[key]
        pub proposal_id: u256,
        #[key]
        pub voter: ContractAddress,
        pub support: bool,
        pub vote_weight: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct BindingVoteCast {
        #[key]
        pub proposal_id: u256,
        #[key]
        pub voter: ContractAddress,
        pub support: bool,
        pub vote_weight: u256,
    }


    #[derive(Drop, starknet::Event)]
    struct ProposalSubmitted {
        #[key]
        proposal_id: u256,
        creator: ContractAddress,
        description: felt252,
        poll_end_time: u64,
        voting_end_time: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PollStarted {
        #[key]
        pub proposal_id: u256,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PollResultUpdated {
        #[key]
        pub proposal_id: u256,
        pub total_for: u256,
        pub total_against: u256,
        pub new_status: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct BindingVoteStarted {
        #[key]
        pub proposal_id: u256,
        #[key]
        pub executive_action_address: ContractAddress,
        pub timestamp: u64,
    }

    #[constructor]
    fn constructor(ref self: ContractState, xzb_token_address: ContractAddress) {
        self.xzb_token.write(xzb_token_address);
        self.next_proposal_id.write(1.into());
    }

    #[abi(embed_v0)]
    impl DAOImpl of super::IDAO<ContractState> {
        fn castBindingVote(ref self: ContractState, proposal_id: u256, support: bool) {
            let caller = get_caller_address();
            let mut proposal = self._validate_proposal_exists(proposal_id);
            
            // Check that the proposal is in the binding vote phase
            assert(proposal.status == ProposalStatus::BindingVoteActive, 'Not in binding vote phase');
            
            let binding_vote_proposal = self.bindingVoteProposals.read(proposal_id);
            let bindingVoteCasted = self.bindingVoteCasted.read((proposal_id, caller));
            
            assert!(binding_vote_proposal == true, "Proposal not in voting phase");
            assert!(bindingVoteCasted == false, "Binding Vote Already casted");
            
            let vote_weight = self._get_voter_weight(caller);
            assert(vote_weight > 0, 'No voting power');
            
            let oldBindingVotesCountMap = self.bindingVotesCountMap.read(proposal_id);

            let newBindingVotesCountMap = self
                ._update_proposal_votes(oldBindingVotesCountMap, support, vote_weight);

            self.pollVotesCount.write(self.pollVotesCount.read() + 1);
            self.bindingVotesCountMap.write(proposal_id, newBindingVotesCountMap);
            self.bindingVoteCasted.write((proposal_id, caller), true);
            self.bindingVotesCount.write(self.bindingVotesCount.read() + 1);

            self
                .emit(
                    Event::BindingVoteCast(
                        BindingVoteCast {
                            proposal_id: proposal_id,
                            voter: caller,
                            support: support,
                            vote_weight: vote_weight,
                        },
                    ),
                )
        }

        // This function is deprecated. Use startBindingVote instead.
        fn moveProposal(ref self: ContractState, proposal_id: u256) {
            self.bindingVoteProposals.write(proposal_id, true);
        }

        fn vote_in_poll(ref self: ContractState, proposal_id: u256, support: bool) {
            let caller = get_caller_address();
            let mut proposal = self._validate_proposal_exists(proposal_id);
            assert(self._is_in_poll_phase(proposal_id), 'Not in poll phase');
            assert(!self.has_voted.read((proposal_id, caller)), 'Already voted');
            assert(proposal.id == proposal_id, 'Proposal does not exist');
            assert(proposal.status == ProposalStatus::PollPassed, 'Not in poll phase');
            let current_time = get_block_timestamp();
            assert(current_time <= proposal.poll_end_time, 'Poll phase ended');
            assert(!self.has_voted.read((proposal_id, caller)), 'Already voted');
            let vote_weight = self._get_voter_weight(caller);
            assert(vote_weight > 0, 'No voting power');
            self._update_vote_counts(proposal_id, support, vote_weight);
            if support {
                proposal.vote_for += vote_weight;
            } else {
                proposal.vote_against += vote_weight;
            }
            self.proposals.write(proposal_id, proposal);
            self.has_voted.write((proposal_id, caller), true);
            self
                .emit(
                    Event::PollVoted(
                        PollVoted {
                            proposal_id: proposal_id,
                            voter: caller,
                            support: support,
                            vote_weight: vote_weight,
                        },
                    ),
                );
        }

        fn get_proposal(self: @ContractState, proposal_id: u256) -> Proposal {
            let proposal = self.proposals.read(proposal_id);
            assert(proposal.id == proposal_id, 'Proposal does not exist');
            proposal
        }

        fn has_voted(self: @ContractState, proposal_id: u256, voter: ContractAddress) -> bool {
            self.has_voted.read((proposal_id, voter))
        }

        fn create_proposal(
            ref self: ContractState,
            proposal_id: u256,
            description: felt252,
            poll_duration: u64,
            voting_duration: u64,
        ) {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            let proposal = Proposal {
                id: proposal_id,
                description: description,
                creator: caller,
                creation_time: current_time,
                poll_end_time: current_time + poll_duration,
                voting_end_time: current_time + poll_duration + voting_duration,
                vote_for: 0.into(),
                vote_against: 0.into(),
                status: ProposalStatus::Pending,
                executive_action_address: contract_address_const::<0x0>(),
            };
            self.proposals.write(proposal_id, proposal);
            self.proposal_exists.write(proposal_id, true)
        }

        fn submit_proposal(
            ref self: ContractState, description: felt252, poll_end_time: u64, voting_end_time: u64,
        ) {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();

            assert(poll_end_time > current_time, 'Poll end > now');
            assert(voting_end_time > poll_end_time, 'Voting > poll end');

            let balance = self._get_voter_weight(caller);
            assert(balance > 0, 'Insufficient xZB tokens');

            let proposal_id = self.next_proposal_id.read();
            self.next_proposal_id.write(proposal_id + 1.into());

            let proposal = Proposal {
                id: proposal_id,
                description: description,
                creator: caller,
                creation_time: current_time,
                poll_end_time: poll_end_time,
                voting_end_time: voting_end_time,
                vote_for: 0.into(),
                vote_against: 0.into(),
                status: ProposalStatus::Pending,
                executive_action_address: contract_address_const::<0x0>(),
            };

            self.proposals.write(proposal_id, proposal);
            self.proposal_exists.write(proposal_id, true);

            self
                .emit(
                    Event::ProposalSubmitted(
                        ProposalSubmitted {
                            proposal_id: proposal_id,
                            creator: caller,
                            description: description,
                            poll_end_time: poll_end_time,
                            voting_end_time: voting_end_time,
                        },
                    ),
                );
        }

        fn start_poll(ref self: ContractState, proposal_id: u256) {
            let mut proposal = self._validate_proposal_exists(proposal_id);
            assert(proposal.status == ProposalStatus::Pending, 'Poll phase already started');
            let current_time = get_block_timestamp();
            assert(current_time < proposal.poll_end_time, 'Poll phase ended');
            proposal.status = ProposalStatus::PollActive;
            self.proposals.write(proposal_id, proposal);
            self
                .emit(
                    Event::PollStarted(
                        PollStarted { proposal_id, timestamp: get_block_timestamp() },
                    ),
                );
        }

        fn tally_poll_votes(ref self: ContractState, proposal_id: u256) {
            let mut proposal = self._validate_proposal_exists(proposal_id);

            if proposal.status != ProposalStatus::PollActive {
                panic_with_felt252('Not in poll phase');
            }

            let total_for = proposal.vote_for;
            let total_against = proposal.vote_against;

            let threshold: u256 = 100.into();

            if total_for >= threshold {
                proposal.status = ProposalStatus::PollPassed;
                self.proposals.write(proposal_id, proposal);

                // Emit the PollResultUpdated event
                self
                    .emit(
                        Event::PollResultUpdated(
                            PollResultUpdated {
                                proposal_id: proposal_id,
                                total_for: total_for,
                                total_against: total_against,
                                new_status: 'PollPassed'.into(),
                            },
                        ),
                    );
            } else if total_against >= threshold {
                proposal.status = ProposalStatus::PollFailed;
                self.proposals.write(proposal_id, proposal);

                // Emit the PollResultUpdated event
                self
                    .emit(
                        Event::PollResultUpdated(
                            PollResultUpdated {
                                proposal_id: proposal_id,
                                total_for: total_for,
                                total_against: total_against,
                                new_status: 'PollDefeated'.into(),
                            },
                        ),
                    );
            }
        }

        fn startBindingVote(ref self: ContractState, proposal_id: u256, execute_action_address: ContractAddress) {
            // Verify proposal eligibility
            let mut proposal = self._validate_proposal_exists(proposal_id);
            assert(proposal.status == ProposalStatus::PollPassed, 'Proposal not in passed state');
            
            // Update proposal status
            proposal.status = ProposalStatus::BindingVoteActive;
            
            // Record executive action address
            proposal.executive_action_address = execute_action_address;
            
            self.proposals.write(proposal_id, proposal);
            self.bindingVoteProposals.write(proposal_id, true);
            
            // Initialize binding vote data for this proposal
            let binding_vote_data = BindingVoteData { votesFor: 0, votesAgainst: 0 };
            self.bindingVotesCountMap.write(proposal_id, binding_vote_data);
 
            self.emit(
                Event::BindingVoteStarted(
                    BindingVoteStarted {
                        proposal_id: proposal_id,
                        executive_action_address: execute_action_address,
                        timestamp: get_block_timestamp(),
                    },
                ),
            );
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalTrait {
        fn _get_voter_weight(self: @ContractState, voter: ContractAddress) -> u256 {
            let xzb_token = self.xzb_token.read();
            let token_dispatcher = IERC20Dispatcher { contract_address: xzb_token };
            let balance = token_dispatcher.balance_of(voter);
            balance
        }

        fn _is_in_poll_phase(self: @ContractState, proposal_id: u256) -> bool {
            let proposal = self.proposals.read(proposal_id);
            let current_time = get_block_timestamp();
            proposal.status == ProposalStatus::PollPassed && current_time <= proposal.poll_end_time
        }

        fn _validate_proposal_exists(self: @ContractState, proposal_id: u256) -> Proposal {
            assert(self.proposal_exists.read(proposal_id), 'Proposal does not exist');
            let proposal = self.proposals.read(proposal_id);
            proposal
        }

        fn _update_vote_counts(
            ref self: ContractState, proposal_id: u256, support: bool, vote_weight: u256,
        ) {
            let mut proposal = self.proposals.read(proposal_id);
            if support {
                proposal.vote_for += vote_weight;
            } else {
                proposal.vote_against += vote_weight;
            }
            self.proposals.write(proposal_id, proposal);
        }

        fn _update_proposal_votes(
            ref self: ContractState,
            old_binding_votes_count_map: BindingVoteData,
            support: bool,
            vote_weight: u256,
        ) -> BindingVoteData {
            match support {
                true => BindingVoteData {
                    votesFor: old_binding_votes_count_map.votesFor
                        + vote_weight.try_into().unwrap(),
                    votesAgainst: old_binding_votes_count_map.votesAgainst,
                },
                false => BindingVoteData {
                    votesFor: old_binding_votes_count_map.votesFor,
                    votesAgainst: old_binding_votes_count_map.votesAgainst
                        + vote_weight.try_into().unwrap(),
                },
            }
        }
    }
}
