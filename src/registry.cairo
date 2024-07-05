
use starknet::{ContractAddress, ClassHash};
// removed copy
#[derive(Drop, Serde, starknet::Store)]
struct Organisation {
    // @notice name of the organisation
    name: felt252,
    // @notice organisation metadata
    metadata: felt252,
    // @notice organisation contract address
    organisation: ContractAddress
}

#[starknet::interface]
trait IOrganisation<TContractState> {
    fn owner(self: @TContractState) -> ContractAddress;
    fn name(self: @TContractState) -> felt252;
    fn metadata(self: @TContractState) -> felt252;
}

#[starknet::interface]
trait IRegistry<TContractState> {
    // view functions
    fn get_all_organisations(self: @TContractState) -> (u32, Array::<ContractAddress>);
    fn get_all_organisations_details(self: @TContractState) -> (u32, Array::<Organisation>);
    fn get_num_of_organisations(self: @TContractState) -> u32;
    fn get_organisation_contract_class_hash(self: @TContractState) -> ClassHash;

    // external functions
    fn create_organisation(ref self: TContractState, name: felt252, metadata: felt252 ) -> ContractAddress;
    fn update_points(ref self: TContractState, contributor: ContractAddress, updated_points: u256 );
    fn replace_organisation_contract_hash(ref self: TContractState, new_organisation_contract_class: ClassHash);
    // fn upgrade(ref self: TContractState, new_class_hash: ClassHash);
}

#[starknet::contract]
mod Registry {
    use core::num::traits::zero::Zero;
    use starknet::{ContractAddress, ClassHash, SyscallResult, SyscallResultTrait, get_caller_address, get_contract_address, get_block_timestamp, contract_address_const};
    use core::integer::BoundedInt;
    use starknet::syscalls::{replace_class_syscall, deploy_syscall};

    // use core::zeroable::Zeroable;
    use super::{Organisation, IOrganisationDispatcher, IOrganisationDispatcherTrait};


    // use openzeppelin::upgrades::upgradeable::UpgradeableComponent;
    use openzeppelin::access::ownable::OwnableComponent;

    // for debugging
    // use core::debug::PrintTrait;

    // component!(path: UpgradeableComponent, storage: upgradeable_storage, event: UpgradeableEvent);
    component!(path: OwnableComponent, storage: ownable_storage, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;

    // impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        _all_organisations: LegacyMap::<u32, ContractAddress>, // @dev registry of all organisations
        _num_of_organisations: u32,
        _organisation_contract_class_hash: ClassHash,
        _organisation_points: LegacyMap::<(ContractAddress, ContractAddress), u256>, 
        _total_points: LegacyMap::<ContractAddress, u256>, 
        #[substorage(v0)]
        ownable_storage: OwnableComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        OrganisationCreated: OrganisationCreated,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        // #[flat]
        // UpgradeableEvent: UpgradeableComponent::Event,
    }

    // @dev Emitted each time an organisation is created via create_organisation
    #[derive(Drop, starknet::Event)]
    struct OrganisationCreated {
        name: felt252, 
        organisation: ContractAddress,
        metadata: felt252,
        id: u32
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, organisation_class_hash: ClassHash) {
        self._organisation_contract_class_hash.write(organisation_class_hash);

        self.ownable_storage.initializer(owner)
    }

    #[abi(embed_v0)]
    impl Registry of super::IRegistry<ContractState> {
        // @notice Get all the organisations registered
        // @return all_organisations_len Length of `all_organisations` array
        // @return all_organisations Array of contract addresses of the registered organisations
        fn get_all_organisations(self: @ContractState) -> (u32, Array::<ContractAddress>) { 
            let mut all_organisations_array = ArrayTrait::<ContractAddress>::new();
            let num_organisations = self._num_of_organisations.read();
            let mut current_index = 1; // organisation index starts from 1, instead of zero
            loop {
                if current_index == num_organisations + 1 {
                    break true;
                }
                all_organisations_array.append(self._all_organisations.read(current_index));
                current_index += 1;
            };
            (num_organisations, all_organisations_array)
        }

        // @notice Get all the organisations registered
        // @return all_organisations_len Length of `all_organisations` array
        // @return all_organisations Array of Organisations of the registered organisations
        // @Notice This function is required for frontend until indexer is live
        fn get_all_organisations_details(self: @ContractState) -> (u32, Array::<Organisation>) { 
            let mut all_organisations_array = ArrayTrait::<Organisation>::new();
            let num_organisations = self._num_of_organisations.read();
            let mut current_index = 1; // organisation index starts from 1, instead of zero
            loop {
                if current_index == num_organisations + 1 {
                    break true;
                }
                let organisation = self._all_organisations.read(current_index);
                let organisation_dispatcher = IOrganisationDispatcher {contract_address: organisation};
                let name = organisation_dispatcher.name();
                let metadata = organisation_dispatcher.metadata();
                let org = Organisation {name: name, metadata: metadata, organisation: organisation};
                all_organisations_array.append(org);
                current_index += 1;
            };
            (num_organisations, all_organisations_array)
        }

        // @notice Get the number of organisations
        // @return num_of_organisations
        fn get_num_of_organisations(self: @ContractState) -> u32 {
           self._num_of_organisations.read()
        }

        // @notice Get the class hash of the organisation contract which is deployed for each organisation.
        // @return class_hash
        fn get_organisation_contract_class_hash(self: @ContractState) -> ClassHash {
            self._organisation_contract_class_hash.read()
        }


        fn create_organisation(ref self: ContractState, name: felt252, metadata: felt252 ) -> ContractAddress {
            assert(!name.is_zero(), 'NAME_NOT_DEFINED');
            let caller = get_caller_address();
            let registry = get_contract_address();
            
            let organisation_contract_class_hash = self._organisation_contract_class_hash.read();

            let mut constructor_calldata = Default::default();
            Serde::serialize(@name, ref constructor_calldata);
            Serde::serialize(@metadata, ref constructor_calldata);
            Serde::serialize(@caller, ref constructor_calldata);
            Serde::serialize(@registry, ref constructor_calldata);

            let syscall_result = deploy_syscall(
                organisation_contract_class_hash, 0, constructor_calldata.span(), false
            );
            let (organisation, _) = syscall_result.unwrap_syscall();

            let num_organisations = self._num_of_organisations.read();
            self._all_organisations.write(num_organisations + 1, organisation);
            self._num_of_organisations.write(num_organisations + 1);

            self.emit(OrganisationCreated {name: name, organisation: organisation, metadata: metadata, id: num_organisations + 1});

            organisation

        }
        // No need to store after indexer is live
        fn update_points(ref self: ContractState, contributor: ContractAddress, updated_points: u256 ) {
            let organisation = get_caller_address();
            let org_points = self._organisation_points.read((contributor, organisation));
            let total_points = self._total_points.read(contributor);
            self._organisation_points.write((contributor, organisation), updated_points);
            self._total_points.write(contributor, total_points - org_points + updated_points);

        }

        // @notice This replaces _organisation_contract_class_hash used to deploy new organisations
        // @dev Only owner can call
        // @param new_organisation_contract_class New _organisation_contract_class_hash
        fn replace_organisation_contract_hash(ref self: ContractState, new_organisation_contract_class: ClassHash) {
            self.ownable_storage.assert_only_owner();
            assert(!new_organisation_contract_class.is_zero(), 'must be non zero');
            self._organisation_contract_class_hash.write(new_organisation_contract_class);
        }

        // // @notice This is used upgrade (Will push a upgrade without this to finalize)
        // // @dev Only owner can call
        // // @param new_implementation_class New implementation hash
        // fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
        //     self.ownable_storage.assert_only_owner();
        //     self.upgradeable_storage._upgrade(new_class_hash);
        // }
    }
}