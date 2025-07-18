module addr::market {
    use std::signer;
    use std::vector;
    use std::string::String;
    use std::timestamp;
    use std::coin;
    use std::table::{Self, Table};
    use std::event;
    use aptos_framework::account;
    use aptos_framework::aptos_coin::AptosCoin;

    // Error codes
    const E_NOT_INITIALIZED: u64 = 1;
    const E_ALREADY_INITIALIZED: u64 = 2;
    const E_NOT_OWNER: u64 = 3;
    const E_INVALID_PRICE: u64 = 4;
    const E_INVALID_DURATION: u64 = 5;
    const E_LISTING_NOT_FOUND: u64 = 6;
    const E_ALREADY_RENTED: u64 = 7;
    const E_INSUFFICIENT_PAYMENT: u64 = 8;
    const E_RENTAL_EXPIRED: u64 = 9;
    const E_RENTAL_NOT_FOUND: u64 = 10;
    const E_NOT_RENTER: u64 = 11;
    const E_CANNOT_RENT_OWN_NFT: u64 = 12;
    const E_INVALID_COLLATERAL: u64 = 13;
    const E_PAUSED: u64 = 14;
    const E_UNAUTHORIZED: u64 = 15;
    const E_INSUFFICIENT_BALANCE: u64 = 16;

    // Constants
    const SECONDS_PER_DAY: u64 = 86400;
    const PLATFORM_FEE_BASIS_POINTS: u64 = 250; // 2.5%
    const MAX_DURATION_DAYS: u64 = 365;

    // Core structs - Added drop ability
    struct Listing has store, drop {
        owner: address,
        nft_id: String,
        price_per_day: u64,
        max_duration_days: u64,
        collateral_required: u64,
        is_active: bool,
        created_at: u64,
    }

    struct RentalRecord has store, drop {
        renter: address,
        original_owner: address,
        nft_id: String,
        rental_start: u64,
        rental_end: u64,
        daily_price: u64,
        total_paid: u64,
        collateral_paid: u64,
        is_active: bool,
    }

    struct RentalCapability has key, store {
        nft_id: String,
        expires_at: u64,
        original_owner: address,
    }

    struct MarketplaceConfig has key {
        admin: address,
        is_paused: bool,
        platform_fee_basis_points: u64,
        treasury: address,
    }

    struct MarketplaceData has key {
        listings: Table<String, Listing>,
        rentals: Table<String, RentalRecord>,
        user_rentals: Table<address, vector<String>>,
        listing_counter: u64,
    }

    // Resource to hold collateral funds
    struct CollateralVault has key {
        vault: coin::Coin<AptosCoin>,
    }

    // Events
    #[event]
    struct ListedEvent has drop, store {
        owner: address,
        nft_id: String,
        price_per_day: u64,
        max_duration_days: u64,
        collateral_required: u64,
        timestamp: u64,
    }

    #[event]
    struct RentedEvent has drop, store {
        renter: address,
        owner: address,
        nft_id: String,
        rental_duration_days: u64,
        total_cost: u64,
        collateral: u64,
        rental_start: u64,
        rental_end: u64,
    }

    #[event]
    struct ReturnedEvent has drop, store {
        renter: address,
        owner: address,
        nft_id: String,
        return_time: u64,
        refund_amount: u64,
        collateral_returned: u64,
    }

    #[event]
    struct ExpiredAutoReturnEvent has drop, store {
        renter: address,
        owner: address,
        nft_id: String,
        expiry_time: u64,
    }

    // Initialize the marketplace
    public entry fun initialize(admin: &signer, treasury: address) {
        let admin_addr = signer::address_of(admin);
        assert!(!exists<MarketplaceConfig>(admin_addr), E_ALREADY_INITIALIZED);

        move_to(admin, MarketplaceConfig {
            admin: admin_addr,
            is_paused: false,
            platform_fee_basis_points: PLATFORM_FEE_BASIS_POINTS,
            treasury,
        });

        move_to(admin, MarketplaceData {
            listings: table::new(),
            rentals: table::new(),
            user_rentals: table::new(),
            listing_counter: 0,
        });

        // Initialize collateral vault
        move_to(admin, CollateralVault {
            vault: coin::zero<AptosCoin>(),
        });
    }

    // Admin functions
    public entry fun pause_marketplace(admin: &signer) acquires MarketplaceConfig {
        let admin_addr = signer::address_of(admin);
        assert!(exists<MarketplaceConfig>(admin_addr), E_NOT_INITIALIZED);
        
        let config = borrow_global_mut<MarketplaceConfig>(admin_addr);
        assert!(config.admin == admin_addr, E_UNAUTHORIZED);
        config.is_paused = true;
    }

    public entry fun unpause_marketplace(admin: &signer) acquires MarketplaceConfig {
        let admin_addr = signer::address_of(admin);
        assert!(exists<MarketplaceConfig>(admin_addr), E_NOT_INITIALIZED);
        
        let config = borrow_global_mut<MarketplaceConfig>(admin_addr);
        assert!(config.admin == admin_addr, E_UNAUTHORIZED);
        config.is_paused = false;
    }

    public entry fun update_platform_fee(admin: &signer, new_fee_basis_points: u64) acquires MarketplaceConfig {
        let admin_addr = signer::address_of(admin);
        assert!(exists<MarketplaceConfig>(admin_addr), E_NOT_INITIALIZED);
        
        let config = borrow_global_mut<MarketplaceConfig>(admin_addr);
        assert!(config.admin == admin_addr, E_UNAUTHORIZED);
        config.platform_fee_basis_points = new_fee_basis_points;
    }

    // Core marketplace functions
    public entry fun list_for_rent(
        owner: &signer,
        nft_id: String,
        price_per_day: u64,
        max_duration_days: u64,
        collateral_required: u64,
        marketplace_admin: address,
    ) acquires MarketplaceConfig, MarketplaceData {
        let owner_addr = signer::address_of(owner);
        assert!(exists<MarketplaceData>(marketplace_admin), E_NOT_INITIALIZED);
        
        let config = borrow_global<MarketplaceConfig>(marketplace_admin);
        assert!(!config.is_paused, E_PAUSED);
        assert!(price_per_day > 0, E_INVALID_PRICE);
        assert!(max_duration_days > 0 && max_duration_days <= MAX_DURATION_DAYS, E_INVALID_DURATION);

        let marketplace_data = borrow_global_mut<MarketplaceData>(marketplace_admin);
        
        // Check if NFT is already listed or rented
        if (table::contains(&marketplace_data.listings, nft_id)) {
            let existing_listing = table::borrow(&marketplace_data.listings, nft_id);
            assert!(!existing_listing.is_active, E_ALREADY_RENTED);
        };

        let listing = Listing {
            owner: owner_addr,
            nft_id,
            price_per_day,
            max_duration_days,
            collateral_required,
            is_active: true,
            created_at: timestamp::now_seconds(),
        };

        table::upsert(&mut marketplace_data.listings, nft_id, listing);

        event::emit(ListedEvent {
            owner: owner_addr,
            nft_id,
            price_per_day,
            max_duration_days,
            collateral_required,
            timestamp: timestamp::now_seconds(),
        });
    }

    public entry fun rent_nft(
        renter: &signer,
        nft_id: String,
        rental_duration_days: u64,
        marketplace_admin: address,
    ) acquires MarketplaceConfig, MarketplaceData, CollateralVault {
        let renter_addr = signer::address_of(renter);
        assert!(exists<MarketplaceConfig>(marketplace_admin), E_NOT_INITIALIZED);
        
        let config = borrow_global<MarketplaceConfig>(marketplace_admin);
        assert!(!config.is_paused, E_PAUSED);

        let marketplace_data = borrow_global_mut<MarketplaceData>(marketplace_admin);
        assert!(table::contains(&marketplace_data.listings, nft_id), E_LISTING_NOT_FOUND);

        let listing = table::borrow_mut(&mut marketplace_data.listings, nft_id);
        assert!(listing.is_active, E_ALREADY_RENTED);
        assert!(listing.owner != renter_addr, E_CANNOT_RENT_OWN_NFT);
        assert!(rental_duration_days <= listing.max_duration_days, E_INVALID_DURATION);

        let total_cost = listing.price_per_day * rental_duration_days;
        let platform_fee = (total_cost * config.platform_fee_basis_points) / 10000;
        let owner_payment = total_cost - platform_fee;

        // Check if renter has sufficient balance
        let renter_balance = coin::balance<AptosCoin>(renter_addr);
        let required_balance = total_cost + listing.collateral_required;
        assert!(renter_balance >= required_balance, E_INSUFFICIENT_BALANCE);

        // Transfer payment from renter
        coin::transfer<AptosCoin>(renter, listing.owner, owner_payment);
        if (platform_fee > 0) {
            coin::transfer<AptosCoin>(renter, config.treasury, platform_fee);
        };
        
        // Handle collateral - deposit into vault
        if (listing.collateral_required > 0) {
            let collateral_coin = coin::withdraw<AptosCoin>(renter, listing.collateral_required);
            let vault = borrow_global_mut<CollateralVault>(marketplace_admin);
            coin::merge(&mut vault.vault, collateral_coin);
        };

        let rental_start = timestamp::now_seconds();
        let rental_end = rental_start + (rental_duration_days * SECONDS_PER_DAY);

        // Create rental record
        let rental = RentalRecord {
            renter: renter_addr,
            original_owner: listing.owner,
            nft_id,
            rental_start,
            rental_end,
            daily_price: listing.price_per_day,
            total_paid: total_cost,
            collateral_paid: listing.collateral_required,
            is_active: true,
        };

        table::upsert(&mut marketplace_data.rentals, nft_id, rental);

        // Update user rentals tracking
        if (!table::contains(&marketplace_data.user_rentals, renter_addr)) {
            table::add(&mut marketplace_data.user_rentals, renter_addr, vector::empty<String>());
        };
        let user_rentals = table::borrow_mut(&mut marketplace_data.user_rentals, renter_addr);
        vector::push_back(user_rentals, nft_id);

        // Mark listing as inactive
        listing.is_active = false;

        // Create rental capability for the renter
        move_to(renter, RentalCapability {
            nft_id,
            expires_at: rental_end,
            original_owner: listing.owner,
        });

        event::emit(RentedEvent {
            renter: renter_addr,
            owner: listing.owner,
            nft_id,
            rental_duration_days,
            total_cost,
            collateral: listing.collateral_required,
            rental_start,
            rental_end,
        });
    }

    public entry fun return_nft_early(
        renter: &signer,
        nft_id: String,
        marketplace_admin: address,
    ) acquires MarketplaceData, RentalCapability, CollateralVault {
        let renter_addr = signer::address_of(renter);
        assert!(exists<MarketplaceData>(marketplace_admin), E_NOT_INITIALIZED);
        assert!(exists<RentalCapability>(renter_addr), E_RENTAL_NOT_FOUND);

        let marketplace_data = borrow_global_mut<MarketplaceData>(marketplace_admin);
        
        assert!(table::contains(&marketplace_data.rentals, nft_id), E_RENTAL_NOT_FOUND);
        let rental = table::borrow_mut(&mut marketplace_data.rentals, nft_id);
        assert!(rental.renter == renter_addr, E_NOT_RENTER);
        assert!(rental.is_active, E_RENTAL_NOT_FOUND);

        let current_time = timestamp::now_seconds();
        let days_remaining = if (current_time < rental.rental_end) {
            (rental.rental_end - current_time) / SECONDS_PER_DAY
        } else {
            0
        };
        
        let refund_amount = if (days_remaining > 0) {
            days_remaining * rental.daily_price
        } else {
            0
        };

        // Process refund and return collateral from vault
        let vault = borrow_global_mut<CollateralVault>(marketplace_admin);
        let total_return = refund_amount + rental.collateral_paid;
        
        if (total_return > 0) {
            let return_coin = coin::extract(&mut vault.vault, total_return);
            coin::deposit(renter_addr, return_coin);
        };

        // Clean up rental
        rental.is_active = false;
        
        // Reactivate listing
        let listing = table::borrow_mut(&mut marketplace_data.listings, nft_id);
        listing.is_active = true;

        // Remove rental capability
        let RentalCapability { nft_id: _, expires_at: _, original_owner } = move_from<RentalCapability>(renter_addr);

        event::emit(ReturnedEvent {
            renter: renter_addr,
            owner: original_owner,
            nft_id,
            return_time: current_time,
            refund_amount,
            collateral_returned: rental.collateral_paid,
        });
    }

    public entry fun claim_expired_nft(
        owner: &signer,
        nft_id: String,
        marketplace_admin: address,
    ) acquires MarketplaceData {
        let owner_addr = signer::address_of(owner);
        assert!(exists<MarketplaceConfig>(marketplace_admin), E_NOT_INITIALIZED);
        
        let marketplace_data = borrow_global_mut<MarketplaceData>(marketplace_admin);
        assert!(table::contains(&marketplace_data.rentals, nft_id), E_RENTAL_NOT_FOUND);
        
        let rental = table::borrow_mut(&mut marketplace_data.rentals, nft_id);
        assert!(rental.original_owner == owner_addr, E_NOT_OWNER);
        assert!(rental.is_active, E_RENTAL_NOT_FOUND);
        
        let current_time = timestamp::now_seconds();
        assert!(current_time >= rental.rental_end, E_RENTAL_NOT_FOUND);

        // Mark rental as inactive
        rental.is_active = false;

        // Reactivate listing
        let listing = table::borrow_mut(&mut marketplace_data.listings, nft_id);
        listing.is_active = true;

        event::emit(ExpiredAutoReturnEvent {
            renter: rental.renter,
            owner: owner_addr,
            nft_id,
            expiry_time: rental.rental_end,
        });
    }

    // View functions
    #[view]
    public fun get_listing(nft_id: String, marketplace_admin: address): (address, u64, u64, u64, bool) acquires MarketplaceData {
        let marketplace_data = borrow_global<MarketplaceData>(marketplace_admin);
        assert!(table::contains(&marketplace_data.listings, nft_id), E_LISTING_NOT_FOUND);
        
        let listing = table::borrow(&marketplace_data.listings, nft_id);
        (listing.owner, listing.price_per_day, listing.max_duration_days, listing.collateral_required, listing.is_active)
    }

    #[view]
    public fun get_rental_info(nft_id: String, marketplace_admin: address): (address, address, u64, u64, bool) acquires MarketplaceData {
        let marketplace_data = borrow_global<MarketplaceData>(marketplace_admin);
        assert!(table::contains(&marketplace_data.rentals, nft_id), E_RENTAL_NOT_FOUND);
        
        let rental = table::borrow(&marketplace_data.rentals, nft_id);
        (rental.renter, rental.original_owner, rental.rental_start, rental.rental_end, rental.is_active)
    }

    #[view]
    public fun is_rental_expired(nft_id: String, marketplace_admin: address): bool acquires MarketplaceData {
        let marketplace_data = borrow_global<MarketplaceData>(marketplace_admin);
        if (!table::contains(&marketplace_data.rentals, nft_id)) {
            return false
        };
        
        let rental = table::borrow(&marketplace_data.rentals, nft_id);
        timestamp::now_seconds() >= rental.rental_end
    }

    #[view]
    public fun get_platform_fee(): u64 {
        PLATFORM_FEE_BASIS_POINTS
    }

    #[view]
    public fun get_collateral_vault_balance(marketplace_admin: address): u64 acquires CollateralVault {
        let vault = borrow_global<CollateralVault>(marketplace_admin);
        coin::value(&vault.vault)
    }

    // Helper functions
    fun calculate_total_cost(price_per_day: u64, duration_days: u64): u64 {
        price_per_day * duration_days
    }

    fun calculate_platform_fee(total_cost: u64, fee_basis_points: u64): u64 {
        (total_cost * fee_basis_points) / 10000
    }

   
}