use core::starknet::ContractAddress;

#[derive(Drop, Serde, Copy, starknet::Store, PartialEq)]
#[allow(starknet::store_no_default_variant)]
pub enum ProposalStatus {
    Pending,
    PollActive,
    PollPassed,
    PollFailed,
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
    pub status: ProposalStatus // Use ProposalStatus enum instead of u8
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
    fn tally_poll_votes(ref self: TContractState, proposal_id: u256);
    fn tallyBindingVotes(ref self: TContractState, proposal_id: u256);
}

#[starknet::contract]
pub mod DAO {
    use starknet::storage::StorageMapWriteAccess;
    use starknet::storage::StorageMapReadAccess;
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::get_block_timestamp;
    use core::traits::Into;
    use core::array::ArrayTrait;
    use core::starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess, StoragePathEntry, Map};
    use super::{Proposal, ProposalStatus};
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use core::panic_with_felt252;

    #[storage]
    struct Storage {
        xzb_token: ContractAddress,
        proposals: Map<u256, Proposal>,
        has_voted: Map<(u256, ContractAddress), bool>,
        proposal_exists: Map<u256, bool>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        PollVoted: PollVoted,
        PollResultUpdated: PollResultUpdated,
        BindingVoteResult: BindingVoteResult
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
    pub struct PollResultUpdated {
        #[key]
        pub proposal_id: u256,
        pub total_for: u256,
        pub total_against: u256,
        pub new_status: felt252,
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
    fn constructor(ref self: ContractState, xzb_token_address: ContractAddress) {
        self.xzb_token.write(xzb_token_address);
    }

    #[abi(embed_v0)]
    impl DAOImpl of super::IDAO<ContractState> {
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
                status: ProposalStatus::PollActive,
            };
            self.proposals.write(proposal_id, proposal);
            self.proposal_exists.write(proposal_id, true)
        }

        fn tally_poll_votes(ref self: ContractState, proposal_id: u256){
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

        fn tallyBindingVotes(ref self: ContractState, proposal_id: u256){
            //verifies id validity
            let mut proposal = self._validate_proposal_exists(proposal_id);
            
            let votes_for = proposal.vote_for;
            let votes_against = proposal.vote_against;
            let threshold = 2;

            //verifies it is passed the poll phase
            assert(proposal.status == ProposalStatus::PollPassed, 'Not in voting phase');

            //verifies threshold requirement
            if votes_for >= threshold{
                self.proposals.entry(proposal_id).status.write(ProposalStatus::Approved);
                self.emit(
                    BindingVoteResult {
                        proposal_id: proposal_id,
                        approved: true, 
                        total_for: votes_for, 
                        total_against: votes_against 
                    });
            }else if votes_against >= threshold{
                self.proposals.entry(proposal_id).status.write(ProposalStatus::Rejected);
                self.emit(
                    BindingVoteResult {
                        proposal_id: proposal_id,
                        approved: false, 
                        total_for: votes_for, 
                        total_against: votes_against 
                    });
            }else{
                if get_block_timestamp() > proposal.voting_end_time{
                    self.proposals.entry(proposal_id).status.write(ProposalStatus::Rejected);
                self.emit(
                    BindingVoteResult {
                        proposal_id: proposal_id,
                        approved: false, 
                        total_for: votes_for, 
                        total_against: votes_against 
                    });
                }
            }
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
