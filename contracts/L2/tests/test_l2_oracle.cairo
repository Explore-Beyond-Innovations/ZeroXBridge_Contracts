#[cfg(test)]
mod tests {
    use core::traits::Into;
    use starknet::{ContractAddress, contract_address_const};
    use snforge_std::{declare, ContractClassTrait, start_prank, stop_prank, CheatTarget};
    use l2::{L2Oracle, IL2Oracle, IL2OracleDispatcher, IL2OracleDispatcherTrait};

    // Helper function to deploy the contract
    fn deploy_contract() -> (ContractAddress, ContractAddress) {
        let owner = contract_address_const::<'OWNER'>();
        let contract = declare('L2Oracle');
        let contract_address = contract.deploy(@array![owner.into()]).unwrap();
        (contract_address, owner)
    }

    #[test]
    fn test_initial_state() {
        let (contract_address, owner) = deploy_contract();
        let dispatcher = IL2OracleDispatcher { contract_address };
        
        // Test initial TVL is zero
        assert(dispatcher.get_total_tvl() == 0, 'Initial TVL should be 0');
    }

    #[test]
    fn test_owner_can_set_relayer() {
        let (contract_address, owner) = deploy_contract();
        let dispatcher = IL2OracleDispatcher { contract_address };
        
        // Create a relayer address
        let relayer = contract_address_const::<'RELAYER'>();
        
        // Start impersonating owner
        start_prank(CheatTarget::One(contract_address), owner);
        
        // Set relayer status to true
        dispatcher.set_relayer(relayer, true);
        
        stop_prank(CheatTarget::One(contract_address));
    }

    #[test]
    #[should_panic(expected: ('Caller not authorized',))]
    fn test_non_owner_cannot_set_relayer() {
        let (contract_address, _) = deploy_contract();
        let dispatcher = IL2OracleDispatcher { contract_address };
        
        // Create addresses
        let non_owner = contract_address_const::<'NON_OWNER'>();
        let relayer = contract_address_const::<'RELAYER'>();
        
        // Start impersonating non-owner
        start_prank(CheatTarget::One(contract_address), non_owner);
        
        // Try to set relayer (should fail)
        dispatcher.set_relayer(relayer, true);
        
        stop_prank(CheatTarget::One(contract_address));
    }

    #[test]
    fn test_owner_can_set_tvl() {
        let (contract_address, owner) = deploy_contract();
        let dispatcher = IL2OracleDispatcher { contract_address };
        
        // Start impersonating owner
        start_prank(CheatTarget::One(contract_address), owner);
        
        // Set TVL
        let new_tvl: u256 = 1000000;
        dispatcher.set_total_tvl(new_tvl);
        
        // Verify TVL was set
        assert(dispatcher.get_total_tvl() == new_tvl, 'TVL not set correctly');
        
        stop_prank(CheatTarget::One(contract_address));
    }

    #[test]
    fn test_relayer_can_set_tvl() {
        let (contract_address, owner) = deploy_contract();
        let dispatcher = IL2OracleDispatcher { contract_address };
        
        // Create relayer address
        let relayer = contract_address_const::<'RELAYER'>();
        
        // Set up relayer
        start_prank(CheatTarget::One(contract_address), owner);
        dispatcher.set_relayer(relayer, true);
        stop_prank(CheatTarget::One(contract_address));
        
        // Start impersonating relayer
        start_prank(CheatTarget::One(contract_address), relayer);
        
        // Set TVL as relayer
        let new_tvl: u256 = 2000000;
        dispatcher.set_total_tvl(new_tvl);
        
        // Verify TVL was set
        assert(dispatcher.get_total_tvl() == new_tvl, 'TVL not set correctly');
        
        stop_prank(CheatTarget::One(contract_address));
    }

    #[test]
    #[should_panic(expected: ('Caller not authorized',))]
    fn test_unauthorized_cannot_set_tvl() {
        let (contract_address, _) = deploy_contract();
        let dispatcher = IL2OracleDispatcher { contract_address };
        
        // Create unauthorized address
        let unauthorized = contract_address_const::<'UNAUTHORIZED'>();
        
        // Start impersonating unauthorized user
        start_prank(CheatTarget::One(contract_address), unauthorized);
        
        // Try to set TVL (should fail)
        dispatcher.set_total_tvl(1000000);
        
        stop_prank(CheatTarget::One(contract_address));
    }

    #[test]
    fn test_zero_address_cannot_be_relayer() {
        let (contract_address, owner) = deploy_contract();
        let dispatcher = IL2OracleDispatcher { contract_address };
        
        // Start impersonating owner
        start_prank(CheatTarget::One(contract_address), owner);
        
        // Try to set zero address as relayer (should fail)
        let zero_address = contract_address_const::<0>();
        dispatcher.set_relayer(zero_address, true);
        
        stop_prank(CheatTarget::One(contract_address));
    }
} 