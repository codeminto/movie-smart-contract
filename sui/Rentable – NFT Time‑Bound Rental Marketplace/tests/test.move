#[test_only]
module addr::market_tests {
    use std::signer;
    use std::string;
    use std::vector;
    use std::coin;
    use std::timestamp;
    use aptos_framework::account;
    use aptos_framework::aptos_coin::{Self, AptosCoin};
    use aptos_framework::coin as framework_coin;
    use addr::market;

    // Test constants
    const ADMIN_ADDR: address = @0x1;
    const TREASURY_ADDR: address = @0x2;
    const OWNER_ADDR: address = @0x3;
    const RENTER_ADDR: address = @0x4;
    const OTHER_ADDR: address = @0x5;

    const INITIAL_BALANCE: u64 = 1000000000; // 10 APT
    const PRICE_PER_DAY: u64 = 100000000;    // 1 APT
    const MAX_DURATION: u64 = 30;            // 30 days
    const COLLATERAL: u64 = 200000000;       // 2 APT
    const RENTAL_DURATION: u64 = 7;          // 7 days

    // Test helper functions
    fun setup_test_env(): (signer, signer, signer, signer, signer) {
        let admin = account::create_account_for_test(ADMIN_ADDR);
        let treasury = account::create_account_for_test(TREASURY_ADDR);
        let owner = account::create_account_for_test(OWNER_ADDR);
        let renter = account::create_account_for_test(RENTER_ADDR);
        let other = account::create_account_for_test(OTHER_ADDR);

        // Initialize AptosCoin for testing
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&admin);
        
        // Mint initial coins for test accounts
        coin::register<AptosCoin>(&owner);
        coin::register<AptosCoin>(&renter);
        coin::register<AptosCoin>(&other);
        coin::register<AptosCoin>(&treasury);

        aptos_coin::mint(&admin, OWNER_ADDR, INITIAL_BALANCE);
        aptos_coin::mint(&admin, RENTER_ADDR, INITIAL_BALANCE);
        aptos_coin::mint(&admin, OTHER_ADDR, INITIAL_BALANCE);

        // Clean up capabilities
        framework_coin::destroy_burn_cap(burn_cap);
        framework_coin::destroy_mint_cap(mint_cap);

        (admin, treasury, owner, renter, other)
    }

    fun create_test_nft_id(): string::String {
        string::utf8(b"test_nft_001")
    }

    // Test initialization
    #[test]
    fun test_initialize_marketplace() {
        let (admin, treasury, _, _, _) = setup_test_env();
        
        market::initialize(&admin, TREASURY_ADDR);
        
        // Test that marketplace was initialized
        assert!(market::get_platform_fee() == 250, 1); // 2.5%
        assert!(market::get_collateral_vault_balance(ADMIN_ADDR) == 0, 2);
    }

    #[test]
    #[expected_failure(abort_code = 2)] // E_ALREADY_INITIALIZED
    fun test_initialize_marketplace_twice() {
        let (admin, treasury, _, _, _) = setup_test_env();
        
        market::initialize(&admin, TREASURY_ADDR);
        market::initialize(&admin, TREASURY_ADDR); // Should fail
    }

    // Test marketplace administration
    #[test]
    fun test_pause_unpause_marketplace() {
        let (admin, treasury, _, _, _) = setup_test_env();
        
        market::initialize(&admin, TREASURY_ADDR);
        
        // Pause marketplace
        market::pause_marketplace(&admin);
        
        // Unpause marketplace
        market::unpause_marketplace(&admin);
    }

    #[test]
    #[expected_failure(abort_code = 15)] // E_UNAUTHORIZED
    fun test_pause_marketplace_unauthorized() {
        let (admin, treasury, _, _, other) = setup_test_env();
        
        market::initialize(&admin, TREASURY_ADDR);
        
        // Try to pause as non-admin
        market::pause_marketplace(&other);
    }

    #[test]
    fun test_update_platform_fee() {
        let (admin, treasury, _, _, _) = setup_test_env();
        
        market::initialize(&admin, TREASURY_ADDR);
        
        // Update platform fee
        market::update_platform_fee(&admin, 500); // 5%
    }

    // Test listing functionality
    #[test]
    fun test_list_nft_for_rent() {
        let (admin, treasury, owner, _, _) = setup_test_env();
        
        market::initialize(&admin, TREASURY_ADDR);
        
        let nft_id = create_test_nft_id();
        
        // List NFT for rent
        market::list_for_rent(
            &owner,
            nft_id,
            PRICE_PER_DAY,
            MAX_DURATION,
            COLLATERAL,
            ADMIN_ADDR
        );
        
        // Verify listing
        let (listing_owner, price, max_duration, collateral, is_active) = 
            market::get_listing(nft_id, ADMIN_ADDR);
        
        assert!(listing_owner == OWNER_ADDR, 1);
        assert!(price == PRICE_PER_DAY, 2);
        assert!(max_duration == MAX_DURATION, 3);
        assert!(collateral == COLLATERAL, 4);
        assert!(is_active == true, 5);
    }

    #[test]
    #[expected_failure(abort_code = 4)] // E_INVALID_PRICE
    fun test_list_nft_invalid_price() {
        let (admin, treasury, owner, _, _) = setup_test_env();
        
        market::initialize(&admin, TREASURY_ADDR);
        
        let nft_id = create_test_nft_id();
        
        // Try to list with invalid price
        market::list_for_rent(
            &owner,
            nft_id,
            0, // Invalid price
            MAX_DURATION,
            COLLATERAL,
            ADMIN_ADDR
        );
    }

    #[test]
    #[expected_failure(abort_code = 5)] // E_INVALID_DURATION
    fun test_list_nft_invalid_duration() {
        let (admin, treasury, owner, _, _) = setup_test_env();
        
        market::initialize(&admin, TREASURY_ADDR);
        
        let nft_id = create_test_nft_id();
        
        // Try to list with invalid duration
        market::list_for_rent(
            &owner,
            nft_id,
            PRICE_PER_DAY,
            400, // Invalid duration (> 365 days)
            COLLATERAL,
            ADMIN_ADDR
        );
    }

    #[test]
    #[expected_failure(abort_code = 14)] // E_PAUSED
    fun test_list_nft_when_paused() {
        let (admin, treasury, owner, _, _) = setup_test_env();
        
        market::initialize(&admin, TREASURY_ADDR);
        market::pause_marketplace(&admin);
        
        let nft_id = create_test_nft_id();
        
        // Try to list when marketplace is paused
        market::list_for_rent(
            &owner,
            nft_id,
            PRICE_PER_DAY,
            MAX_DURATION,
            COLLATERAL,
            ADMIN_ADDR
        );
    }

    // Test rental functionality
    #[test]
    fun test_rent_nft() {
        let (admin, treasury, owner, renter, _) = setup_test_env();
        
        market::initialize(&admin, TREASURY_ADDR);
        
        let nft_id = create_test_nft_id();
        
        // List NFT for rent
        market::list_for_rent(
            &owner,
            nft_id,
            PRICE_PER_DAY,
            MAX_DURATION,
            COLLATERAL,
            ADMIN_ADDR
        );
        
        let initial_owner_balance = coin::balance<AptosCoin>(OWNER_ADDR);
        let initial_renter_balance = coin::balance<AptosCoin>(RENTER_ADDR);
        let initial_treasury_balance = coin::balance<AptosCoin>(TREASURY_ADDR);
        
        // Rent NFT
        market::rent_nft(
            &renter,
            nft_id,
            RENTAL_DURATION,
            ADMIN_ADDR
        );
        
        // Check balances
        let total_cost = PRICE_PER_DAY * RENTAL_DURATION;
        let platform_fee = (total_cost * 250) / 10000; // 2.5%
        let owner_payment = total_cost - platform_fee;
        
        assert!(coin::balance<AptosCoin>(OWNER_ADDR) == initial_owner_balance + owner_payment, 1);
        assert!(coin::balance<AptosCoin>(TREASURY_ADDR) == initial_treasury_balance + platform_fee, 2);
        assert!(coin::balance<AptosCoin>(RENTER_ADDR) == initial_renter_balance - total_cost - COLLATERAL, 3);
        
        // Check collateral vault
        assert!(market::get_collateral_vault_balance(ADMIN_ADDR) == COLLATERAL, 4);
        
        // Check rental info
        let (rental_renter, rental_owner, rental_start, rental_end, is_active) = 
            market::get_rental_info(nft_id, ADMIN_ADDR);
        
        assert!(rental_renter == RENTER_ADDR, 5);
        assert!(rental_owner == OWNER_ADDR, 6);
        assert!(is_active == true, 7);
        assert!(rental_end > rental_start, 8);
        
        // Check that listing is now inactive
        let (_, _, _, _, listing_active) = market::get_listing(nft_id, ADMIN_ADDR);
        assert!(listing_active == false, 9);
    }

    #[test]
    #[expected_failure(abort_code = 6)] // E_LISTING_NOT_FOUND
    fun test_rent_nonexistent_nft() {
        let (admin, treasury, _, renter, _) = setup_test_env();
        
        market::initialize(&admin, TREASURY_ADDR);
        
        let nft_id = create_test_nft_id();
        
        // Try to rent non-existent NFT
        market::rent_nft(
            &renter,
            nft_id,
            RENTAL_DURATION,
            ADMIN_ADDR
        );
    }

    #[test]
    #[expected_failure(abort_code = 12)] // E_CANNOT_RENT_OWN_NFT
    fun test_rent_own_nft() {
        let (admin, treasury, owner, _, _) = setup_test_env();
        
        market::initialize(&admin, TREASURY_ADDR);
        
        let nft_id = create_test_nft_id();
        
        // List NFT for rent
        market::list_for_rent(
            &owner,
            nft_id,
            PRICE_PER_DAY,
            MAX_DURATION,
            COLLATERAL,
            ADMIN_ADDR
        );
        
        // Try to rent own NFT
        market::rent_nft(
            &owner,
            nft_id,
            RENTAL_DURATION,
            ADMIN_ADDR
        );
    }

    #[test]
    #[expected_failure(abort_code = 16)] // E_INSUFFICIENT_BALANCE
    fun test_rent_nft_insufficient_balance() {
        let (admin, treasury, owner, _, _) = setup_test_env();
        let poor_renter = account::create_account_for_test(@0x999);
        coin::register<AptosCoin>(&poor_renter);
        
        market::initialize(&admin, TREASURY_ADDR);
        
        let nft_id = create_test_nft_id();
        
        // List expensive NFT
        market::list_for_rent(
            &owner,
            nft_id,
            INITIAL_BALANCE, // Very expensive
            MAX_DURATION,
            COLLATERAL,
            ADMIN_ADDR
        );
        
        // Try to rent with insufficient balance
        market::rent_nft(
            &poor_renter,
            nft_id,
            RENTAL_DURATION,
            ADMIN_ADDR
        );
    }

    // Test early return functionality
    #[test]
    fun test_return_nft_early() {
        let (admin, treasury, owner, renter, _) = setup_test_env();
        
        market::initialize(&admin, TREASURY_ADDR);
        
        let nft_id = create_test_nft_id();
        
        // List and rent NFT
        market::list_for_rent(
            &owner,
            nft_id,
            PRICE_PER_DAY,
            MAX_DURATION,
            COLLATERAL,
            ADMIN_ADDR
        );
        
        market::rent_nft(
            &renter,
            nft_id,
            RENTAL_DURATION,
            ADMIN_ADDR
        );
        
        let balance_before_return = coin::balance<AptosCoin>(RENTER_ADDR);
        
        // Return NFT early (immediately)
        market::return_nft_early(
            &renter,
            nft_id,
            ADMIN_ADDR
        );
        
        // Check that renter got refund and collateral back
        let balance_after_return = coin::balance<AptosCoin>(RENTER_ADDR);
        let expected_refund = (RENTAL_DURATION - 1) * PRICE_PER_DAY + COLLATERAL;
        
        assert!(balance_after_return == balance_before_return + expected_refund, 1);
        
        // Check that collateral vault is empty
        assert!(market::get_collateral_vault_balance(ADMIN_ADDR) == 0, 2);
        
        // Check that listing is active again
        let (_, _, _, _, listing_active) = market::get_listing(nft_id, ADMIN_ADDR);
        assert!(listing_active == true, 3);
        
        // Check that rental is inactive
        let (_, _, _, _, rental_active) = market::get_rental_info(nft_id, ADMIN_ADDR);
        assert!(rental_active == false, 4);
    }

    #[test]
    #[expected_failure(abort_code = 10)] // E_RENTAL_NOT_FOUND
    fun test_return_nft_not_rented() {
        let (admin, treasury, owner, renter, _) = setup_test_env();
        
        market::initialize(&admin, TREASURY_ADDR);
        
        let nft_id = create_test_nft_id();
        
        // Try to return NFT that wasn't rented
        market::return_nft_early(
            &renter,
            nft_id,
            ADMIN_ADDR
        );
    }

    #[test]
    #[expected_failure(abort_code = 11)] // E_NOT_RENTER
    fun test_return_nft_not_renter() {
        let (admin, treasury, owner, renter, other) = setup_test_env();
        
        market::initialize(&admin, TREASURY_ADDR);
        
        let nft_id = create_test_nft_id();
        
        // List and rent NFT
        market::list_for_rent(
            &owner,
            nft_id,
            PRICE_PER_DAY,
            MAX_DURATION,
            COLLATERAL,
            ADMIN_ADDR
        );
        
        market::rent_nft(
            &renter,
            nft_id,
            RENTAL_DURATION,
            ADMIN_ADDR
        );
        
        // Try to return NFT as someone else
        market::return_nft_early(
            &other,
            nft_id,
            ADMIN_ADDR
        );
    }

    // Test expired rental claim
    #[test]
    fun test_claim_expired_nft() {
        let (admin, treasury, owner, renter, _) = setup_test_env();
        
        market::initialize(&admin, TREASURY_ADDR);
        
        let nft_id = create_test_nft_id();
        
        // List and rent NFT
        market::list_for_rent(
            &owner,
            nft_id,
            PRICE_PER_DAY,
            MAX_DURATION,
            COLLATERAL,
            ADMIN_ADDR
        );
        
        market::rent_nft(
            &renter,
            nft_id,
            RENTAL_DURATION,
            ADMIN_ADDR
        );
        
        // Fast forward time to expire the rental
        let rental_duration_seconds = RENTAL_DURATION * 86400; // 7 days in seconds
        timestamp::fast_forward_seconds(rental_duration_seconds + 1);
        
        // Check that rental is expired
        assert!(market::is_rental_expired(nft_id, ADMIN_ADDR) == true, 1);
        
        // Claim expired NFT
        market::claim_expired_nft(
            &owner,
            nft_id,
            ADMIN_ADDR
        );
        
        // Check that listing is active again
        let (_, _, _, _, listing_active) = market::get_listing(nft_id, ADMIN_ADDR);
        assert!(listing_active == true, 2);
        
        // Check that rental is inactive
        let (_, _, _, _, rental_active) = market::get_rental_info(nft_id, ADMIN_ADDR);
        assert!(rental_active == false, 3);
    }

    #[test]
    #[expected_failure(abort_code = 3)] // E_NOT_OWNER
    fun test_claim_expired_nft_not_owner() {
        let (admin, treasury, owner, renter, other) = setup_test_env();
        
        market::initialize(&admin, TREASURY_ADDR);
        
        let nft_id = create_test_nft_id();
        
        // List and rent NFT
        market::list_for_rent(
            &owner,
            nft_id,
            PRICE_PER_DAY,
            MAX_DURATION,
            COLLATERAL,
            ADMIN_ADDR
        );
        
        market::rent_nft(
            &renter,
            nft_id,
            RENTAL_DURATION,
            ADMIN_ADDR
        );
        
        // Fast forward time
        let rental_duration_seconds = RENTAL_DURATION * 86400;
        timestamp::fast_forward_seconds(rental_duration_seconds + 1);
        
        // Try to claim as non-owner
        market::claim_expired_nft(
            &other,
            nft_id,
            ADMIN_ADDR
        );
    }

    // Test view functions
    #[test]
    fun test_view_functions() {
        let (admin, treasury, owner, renter, _) = setup_test_env();
        
        market::initialize(&admin, TREASURY_ADDR);
        
        let nft_id = create_test_nft_id();
        
        // Initially no rental should exist
        assert!(market::is_rental_expired(nft_id, ADMIN_ADDR) == false, 1);
        
        // List NFT
        market::list_for_rent(
            &owner,
            nft_id,
            PRICE_PER_DAY,
            MAX_DURATION,
            COLLATERAL,
            ADMIN_ADDR
        );
        
        // Test listing view
        let (listing_owner, price, max_duration, collateral, is_active) = 
            market::get_listing(nft_id, ADMIN_ADDR);
        
        assert!(listing_owner == OWNER_ADDR, 2);
        assert!(price == PRICE_PER_DAY, 3);
        assert!(max_duration == MAX_DURATION, 4);
        assert!(collateral == COLLATERAL, 5);
        assert!(is_active == true, 6);
        
        // Test platform fee
        assert!(market::get_platform_fee() == 250, 7);
        
        // Test collateral vault balance
        assert!(market::get_collateral_vault_balance(ADMIN_ADDR) == 0, 8);
    }

    // Test edge cases
    #[test]
    fun test_relist_after_rental_completion() {
        let (admin, treasury, owner, renter, _) = setup_test_env();
        
        market::initialize(&admin, TREASURY_ADDR);
        
        let nft_id = create_test_nft_id();
        
        // List, rent, and return NFT
        market::list_for_rent(
            &owner,
            nft_id,
            PRICE_PER_DAY,
            MAX_DURATION,
            COLLATERAL,
            ADMIN_ADDR
        );
        
        market::rent_nft(
            &renter,
            nft_id,
            RENTAL_DURATION,
            ADMIN_ADDR
        );
        
        market::return_nft_early(
            &renter,
            nft_id,
            ADMIN_ADDR
        );
        
        // Should be able to list again with different parameters
        market::list_for_rent(
            &owner,
            nft_id,
            PRICE_PER_DAY * 2, // Different price
            MAX_DURATION / 2,  // Different duration
            COLLATERAL / 2,    // Different collateral
            ADMIN_ADDR
        );
        
        // Verify new listing parameters
        let (_, price, max_duration, collateral, is_active) = 
            market::get_listing(nft_id, ADMIN_ADDR);
        
        assert!(price == PRICE_PER_DAY * 2, 1);
        assert!(max_duration == MAX_DURATION / 2, 2);
        assert!(collateral == COLLATERAL / 2, 3);
        assert!(is_active == true, 4);
    }

    #[test]
    fun test_zero_collateral_rental() {
        let (admin, treasury, owner, renter, _) = setup_test_env();
        
        market::initialize(&admin, TREASURY_ADDR);
        
        let nft_id = create_test_nft_id();
        
        // List NFT with zero collateral
        market::list_for_rent(
            &owner,
            nft_id,
            PRICE_PER_DAY,
            MAX_DURATION,
            0, // Zero collateral
            ADMIN_ADDR
        );
        
        let initial_vault_balance = market::get_collateral_vault_balance(ADMIN_ADDR);
        
        // Rent NFT
        market::rent_nft(
            &renter,
            nft_id,
            RENTAL_DURATION,
            ADMIN_ADDR
        );
        
        // Vault balance should remain the same
        assert!(market::get_collateral_vault_balance(ADMIN_ADDR) == initial_vault_balance, 1);
        
        // Return NFT early
        market::return_nft_early(
            &renter,
            nft_id,
            ADMIN_ADDR
        );
        
        // Vault balance should still be the same
        assert!(market::get_collateral_vault_balance(ADMIN_ADDR) == initial_vault_balance, 2);
    }
}