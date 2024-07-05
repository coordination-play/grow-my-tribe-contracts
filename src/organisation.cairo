
use starknet::{ContractAddress, ClassHash};

#[derive(Drop, Serde, starknet::Store)]
struct Campaign {
    name: felt252,
    metadata: felt252,
    start_time: u64,
    duration: u64,
    total_points_allocated: u32,
    token_address: ContractAddress,
    token_amount: u256,
    
}

#[derive(Copy, Drop, Serde, starknet::Store)]
struct Rules {
    views_weightage: u32,
    like_weightage: u32,
    reply_weightage: u32,
    retweet_weightage: u32,
    followers_threshold: u32,
    max_mentions: u32,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
struct UserPoints {
    alloted: u32,
    claimed: bool,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
struct ImpressionData {
    user: ContractAddress,
    points: u32,
}

#[derive(Drop, Serde, Copy, starknet::Store)]
enum State {
    Pending,
    Active,
    Ended,
    Allocated,
}

#[starknet::interface]
trait IERC20<TContractState> {
    fn balance_of(self: @TContractState, account: ContractAddress) -> u256;
    fn allowance(self: @TContractState, owner: ContractAddress, spender: ContractAddress) -> u256;
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn transfer_from(ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;

}

#[starknet::interface]
trait IRegistry<TContractState> {
    fn update_points(ref self: TContractState, contributor: ContractAddress, updated_points: u32 );
}

#[starknet::interface]
trait IOrganisation<TContractState> {
    fn name(self: @TContractState) -> felt252;
    fn metadata(self: @TContractState) -> felt252;
    fn get_campaign(self: @TContractState, campaign_id: u32) -> Campaign;
    fn get_campaign_reward(self: @TContractState, user: ContractAddress, campaign_id: u32) -> (u256, bool);
    fn get_all_campaigns(self: @TContractState) -> (u32, Array::<Campaign>);
    fn state(self: @TContractState, campaign_id: u32) -> State;

    // external functions
    fn create_campaign(ref self: TContractState, name: felt252, metadata: felt252, start_time: u64, duration: u64, token_address: ContractAddress, token_amount: u256, rules: Rules );
    fn settle_campaign(ref self: TContractState, campaign_id: u32, contributions: Array::<ImpressionData> );
    fn claim(ref self: TContractState, campaign_id: u32);

}

#[starknet::contract]
mod Organisation {
    use core::num::traits::zero::Zero;
    use starknet::{ContractAddress, ClassHash, SyscallResult, SyscallResultTrait, get_caller_address, get_contract_address, get_block_timestamp, contract_address_const};
    use core::integer::BoundedInt;

    use super::{Campaign, Rules, UserPoints, State, ImpressionData, IRegistryDispatcher, IRegistryDispatcherTrait, IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin::access::ownable::OwnableComponent;

    component!(path: OwnableComponent, storage: ownable_storage, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;
    
    #[storage]
    struct Storage {
        _name: felt252, // @dev name of the Organisation
        _metadata: felt252, // @dev metadata of the Organisation
        _registry: ContractAddress, 
        _all_campaigns: LegacyMap::<u32, Campaign>, // @dev registry of all campaigns
        _num_of_campaigns: u32,
        // break into two mapping after indexing, single mapping can load data on ui faster.
        _campaign_points: LegacyMap::<(ContractAddress, u32), UserPoints>, 
        _total_points: LegacyMap::<ContractAddress, u32>, // total points earned across all campaigns
        #[substorage(v0)]
        ownable_storage: OwnableComponent::Storage
    }

    
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        CampaignStarted: CampaignStarted,
        CampaignEnded: CampaignEnded,
        ContributionUpdated: ContributionUpdated,
        #[flat]
        OwnableEvent: OwnableComponent::Event
    }

    // @notice An event emitted whenever contribution is updated
    #[derive(Drop, starknet::Event)]
    struct ContributionUpdated {
        contributor: ContractAddress,
        campaign_id: u32,
        points_earned: u32
    }

    #[derive(Drop, starknet::Event)]
    struct CampaignStarted {
        campaign_id: u32,
        name: felt252,
        metadata: felt252,
        start_time: u64,
        duration: u64,
        token_address: ContractAddress,
        token_amount: u256,
        rules: Rules,
    }

    #[derive(Drop, starknet::Event)]
    struct CampaignEnded {
        campaign_id: u32,
        total_points_alloted: u32
    }

    #[constructor]
    fn constructor(ref self: ContractState, name: felt252, metadata: felt252, owner: ContractAddress, registry: ContractAddress) {
        self._name.write(name);
        self._metadata.write(metadata);
        self._registry.write(registry);

        self.ownable_storage.initializer(owner)
    }

    #[abi(embed_v0)]
    impl Organisation of super::IOrganisation<ContractState> {
        fn name(self: @ContractState) -> felt252 {
            self._name.read()
        }

        fn metadata(self: @ContractState) -> felt252 {
            self._metadata.read()
        }

        fn get_campaign(self: @ContractState, campaign_id: u32) -> Campaign { 
            self._all_campaigns.read(campaign_id)
        }

        fn get_all_campaigns(self: @ContractState) -> (u32, Array::<Campaign>) { 
            let mut all_campaigns_array = ArrayTrait::<Campaign>::new();
            let num_campaigns = self._num_of_campaigns.read();
            let mut current_index = 1; // campaign index starts from 1, instead of zero
            loop {
                if current_index == num_campaigns + 1 {
                    break true;
                }
                let campaign = self._all_campaigns.read(current_index);
               
                all_campaigns_array.append(campaign);
                current_index += 1;
            };
            (num_campaigns, all_campaigns_array)
        }

       
        fn get_campaign_reward(self: @ContractState, user: ContractAddress, campaign_id: u32) -> (u256, bool) {
            let campaign_state = self.state(campaign_id);
            match campaign_state {
                State::Allocated => {
                    let campaign = self._all_campaigns.read(campaign_id);
                    let points = self._campaign_points.read((user, campaign_id));
                    let reward = (campaign.token_amount * points.alloted.into() ) / campaign.total_points_allocated.into();

                    (reward, points.claimed)
                },
                _ => {return (0, false) ;},                
            }
            

        }

        fn state(self: @ContractState, campaign_id: u32) -> State {
            let campaign = self._all_campaigns.read(campaign_id);
            let block_timestamp = get_block_timestamp();
            if (campaign.start_time > block_timestamp) {
                return State::Pending;
            } else if (campaign.start_time + campaign.duration < block_timestamp) {
                return State::Active;
            } else if (campaign.total_points_allocated != 0) {
                return State::Allocated;
            } else {
                return State::Ended;
            }
        }

        fn create_campaign(ref self: ContractState, name: felt252, metadata: felt252, start_time: u64, duration: u64, token_address: ContractAddress, token_amount: u256, rules: Rules ) {
            self.ownable_storage.assert_only_owner();
            // let caller = get_caller_address();
            // let current_contract = get_contract_address();

            let campaign = Campaign { name: name, metadata: metadata, start_time: start_time, duration: duration, token_address: token_address, token_amount: token_amount, total_points_allocated: 0};
            let id = self._num_of_campaigns.read();
            self._all_campaigns.write(id+1, campaign);
            self._num_of_campaigns.write(id+1);

            // let token_disaptcher = IERC20Dispatcher {contract_address : token_address};
            // token_disaptcher.transfer_from(caller, current_contract, token_amount);

            self.emit(CampaignStarted{campaign_id: id+1, name: name, metadata: metadata, start_time: start_time, duration: duration, token_address: token_address, token_amount: token_amount, rules: rules})
        }


        fn claim(ref self: ContractState, campaign_id: u32) {
            let campaign_state = self.state(campaign_id);
            match campaign_state {
                State::Allocated => {
                    let caller = get_caller_address();
                    let campaign = self._all_campaigns.read(campaign_id);
                    let mut points = self._campaign_points.read((caller, campaign_id));
                    assert (points.claimed != true, 'already claimed');
                    let claimable_amount = (campaign.token_amount * points.alloted.into() ) / campaign.total_points_allocated.into();

                    let token_disaptcher = IERC20Dispatcher {contract_address : campaign.token_address};
                    token_disaptcher.transfer(caller, claimable_amount);
                    points.claimed = true;
                    self._campaign_points.write((caller, campaign_id), points);

                    
                },
                _ => {core::panic_with_felt252('invalid_state');},
            }
            
        }

        fn settle_campaign(ref self: ContractState, campaign_id: u32, contributions: Array::<ImpressionData> ) {
            self.ownable_storage.assert_only_owner();
            let mut campaign = self._all_campaigns.read(campaign_id);
            let campaign_state = self.state(campaign_id);
            match campaign_state {
                State::Ended => {
                    let mut current_index = 0;
                    let mut total_cum = 0_u32;

                    loop {
                        if (current_index == contributions.len()) {
                            break;
                        }
                        let contribution: ImpressionData = *contributions[current_index];

                        
                        total_cum += contribution.points;
                        let user_contibution = UserPoints {alloted: contribution.points, claimed: false};
                        self._campaign_points.write((contribution.user, campaign_id), user_contibution);

                        current_index += 1;

                        let user_total_points = self._total_points.read(contribution.user);
                        self._total_points.write(contribution.user, user_total_points + contribution.points);

                        let registry = self._registry.read();
                        let registry_dispatcher = IRegistryDispatcher {contract_address: registry};
                        registry_dispatcher.update_points(contribution.user, user_total_points + contribution.points);

                        self.emit(ContributionUpdated{contributor: contribution.user, campaign_id: campaign_id, points_earned: contribution.points});

                    };
                    campaign.total_points_allocated = total_cum;
                    self._all_campaigns.write(campaign_id, campaign);
                    self.emit(CampaignEnded{campaign_id: campaign_id, total_points_alloted: total_cum})
                },
                _ => {core::panic_with_felt252('invalid_state');},
            
            }
            
        }
    }


}