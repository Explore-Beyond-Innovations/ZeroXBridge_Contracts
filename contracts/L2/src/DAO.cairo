use core::starknet::ContractAddress;
use starknet::storage::Map;

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
    BindingVoteActive,
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
    pub status: ProposalStatus,
    pub executive_action_address: ContractAddress,
}

#[derive(Drop, Copy, Serde, Default, PartialEq, starknet::Store)]
pub enum BindingVote {
    For: u256,
    Against: u256,
    #[default]
    None,
}

#[generate_trait]
pub impl BindingVoteImpl of BindingVoteTrait {
    // Converts the BindingVote Enum to an Optional (support, vote_weight)
    // used for retrieving the binding vote from the voter
    // returns none if the voter didn't participate
    fn get_vote(self: @BindingVote) -> Option<(bool, u256)> {
        let mut return_val = Option::None;
        if let BindingVote::For(val) = self {
            return_val = Option::Some((true, *val));
        }

        if let BindingVote::Against(val) = self {
            return_val = Option::Some((false, *val));
        }

        return_val
    }
}

#[starknet::storage_node]
pub struct ProposalBindingData {
    pub in_phase: bool,
    pub votes_count: u256, // total weight
    pub voters_count: u256, // total voters
    pub voters: Map<ContractAddress, BindingVote>,
    pub votes: (u256, u256) // (for, against)
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

    fn cast_binding_vote(ref self: TContractState, proposal_id: u256, support: bool);

    // move proposal to voting phase
    fn move_proposal(ref self: TContractState, proposal_id: u256);

    fn update_proposal_status(
        ref self: TContractState, proposal_id: u256, new_status: ProposalStatus,
    );
    fn start_binding_vote(
        ref self: TContractState, proposal_id: u256, execute_action_address: ContractAddress,
    );
    fn tally_binding_votes(ref self: TContractState, proposal_id: u256);
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
    use core::starknet::storage::{
        StoragePointerReadAccess, StoragePointerWriteAccess, Map, StoragePathEntry,
    };
    use super::{Proposal, ProposalStatus, ProposalBindingData, BindingVote, BindingVoteTrait};
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use core::panic_with_felt252;


    #[storage]
    struct Storage {
        xzb_token: ContractAddress,
        proposals: Map<u256, Proposal>,
        has_voted: Map<(u256, ContractAddress), bool>,
        proposal_exists: Map<u256, bool>,
        next_proposal_id: u256,
        poll_votes_count: u32,
        proposal_binding_data: Map<
            u256, ProposalBindingData,
        >, // proposal id, proposal binding vote data
        binding_vote_threshold: u256,
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
        BindingVoteResult: BindingVoteResult,
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
        pub executive_action_address: ContractAddress,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct BindingVoteResult {
        #[key]
        pub proposal_id: u256,
        pub approved: bool,
        pub total_for: u256,
        pub total_against: u256,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, xzb_token_address: ContractAddress, binding_vote_threshold: u256,
    ) {
        self.xzb_token.write(xzb_token_address);
        self.next_proposal_id.write(1.into());
        self.binding_vote_threshold.write(binding_vote_threshold);
    }

    #[abi(embed_v0)]
    impl DAOImpl of super::IDAO<ContractState> {
        // for testing purposes only
        fn update_proposal_status(
            ref self: ContractState, proposal_id: u256, new_status: ProposalStatus,
        ) {
            let mut proposal = self.proposals.read(proposal_id);
            proposal.status = new_status;
            self.proposals.write(proposal_id, proposal);
        }

        fn cast_binding_vote(ref self: ContractState, proposal_id: u256, support: bool) {
            let caller = get_caller_address();
            let proposal_binding_data = self.proposal_binding_data.entry(proposal_id);
            let in_phase = proposal_binding_data.in_phase.read();
            assert!(in_phase, "Proposal not in voting phase");

            let binding_vote = proposal_binding_data.voters.entry(caller).read();
            assert!(binding_vote.get_vote().is_none(), "Binding Vote Already casted");

            let vote_weight = self._get_voter_weight(caller);
            assert(vote_weight > 0, 'No voting power');
            let (mut votes_for, mut votes_against) = proposal_binding_data.votes.read();

            let binding_vote = match support {
                true => {
                    votes_for += vote_weight;
                    BindingVote::For(vote_weight)
                },
                _ => {
                    votes_against += vote_weight;
                    BindingVote::Against(vote_weight)
                },
            };

            proposal_binding_data.voters.entry(caller).write(binding_vote);
            proposal_binding_data.votes.write((votes_for, votes_against));
            proposal_binding_data
                .votes_count
                .write(proposal_binding_data.votes_count.read() + vote_weight);
            proposal_binding_data.voters_count.write(proposal_binding_data.voters_count.read() + 1);

            self
                .emit(
                    Event::BindingVoteCast(
                        BindingVoteCast { proposal_id, voter: caller, support, vote_weight },
                    ),
                )
        }

        // This function is deprecated. Use startBindingVote() instead.
        fn move_proposal(ref self: ContractState, proposal_id: u256) {
            self.proposal_binding_data.entry(proposal_id).in_phase.write(true);
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
                        PollVoted { proposal_id, voter: caller, support, vote_weight },
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

        fn start_binding_vote(
            ref self: ContractState, proposal_id: u256, execute_action_address: ContractAddress,
        ) {
            // Verify proposal eligibility
            let mut proposal = self._validate_proposal_exists(proposal_id);
            assert(proposal.status == ProposalStatus::PollPassed, 'Proposal not in passed state');

            // Update proposal status
            proposal.status = ProposalStatus::BindingVoteActive;

            // Record executive action address
            proposal.executive_action_address = execute_action_address;

            self.proposals.write(proposal_id, proposal);
            self.proposal_binding_data.entry(proposal_id).in_phase.write(true);

            self
                .emit(
                    Event::BindingVoteStarted(
                        BindingVoteStarted {
                            proposal_id: proposal_id,
                            executive_action_address: execute_action_address,
                            timestamp: get_block_timestamp(),
                        },
                    ),
                );
        }

        fn tally_binding_votes(ref self: ContractState, proposal_id: u256) {
            let mut proposal = self._validate_proposal_exists(proposal_id);
            assert(proposal.status == ProposalStatus::BindingVoteActive, 'Binding vote not active');
            let proposal_binding_data = self.proposal_binding_data.entry(proposal_id);

            assert(proposal_binding_data.in_phase.read(), 'Proposal not in voting phase');

            let threshold = self.binding_vote_threshold.read();
            let votes_count = proposal_binding_data.votes_count.read();
            assert(votes_count >= threshold, 'Votes threshold not reached');

            let (votes_for, votes_against) = proposal_binding_data.votes.read();

            // the votes are tallied in such a way that a tie would lead to a loss
            let approved = votes_for > votes_against;
            proposal.status = match approved {
                true => ProposalStatus::Approved,
                _ => ProposalStatus::Rejected,
            };

            self.proposals.entry(proposal_id).write(proposal);

            let event = BindingVoteResult {
                proposal_id, approved, total_for: votes_for, total_against: votes_against,
            };

            self.emit(event);
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
    }
}
