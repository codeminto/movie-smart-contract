module rentable::market {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::clock::{Self, Clock};
    use sui::table::{Self, Table};
    use sui::event;
    use sui::balance::{Self, Balance};
    use sui::pay;
    use std::option::{Self, Option};
    use std::vector;

    // Error codes
    const E_NOT_OWNER: u64 = 1;
    const E_INVALID_DURATION: u64 = 2;
    const E_INVALID_PRICE: u64 = 3;
    const E_LISTING_NOT_FOUND: u64 = 4;
    const E_INSUFFICIENT_PAYMENT: u64 = 5;
    const E_RENTAL_EXPIRED: u64 = 6;
    const E_RENTAL_NOT_EXPIRED: u64 = 7;
    const E_UNAUTHORIZED: u64 = 8;
    const E_ALREADY_RENTED: u64 = 9;
    const E_INVALID_COLLATERAL: u64 = 10;

    // Constants
    const PLATFORM_FEE_BPS: u64 = 250; // 2.5%
    const DAY_IN_MS: u64 = 86400000; // 24 hours in milliseconds

    // Core structures
    struct Marketplace has key {
        id: UID,
        listings: Table<ID, Listing>,
        platform_balance: Balance<SUI>,
        admin: address,
        paused: bool,
        platform_fee_bps: u64,
    }

    struct Listing has store {
        owner: address,
        nft_id: ID,
        price_per_day: u64,
        max_duration: u64,
        collateral_required: u64,
        is_rented: bool,
        renter: Option<address>,
        rental_start: Option<u64>,
        rental_end: Option<u64>,
    }

    struct RentalNFT<T: key + store> has key {
        id: UID,
        original_nft: T,
        original_id: ID,
        expires_at: u64,
        renter: address,
        listing_id: ID,
    }

    struct AdminCap has key {
        id: UID,
    }

    // Events
    struct Listed has copy, drop {
        listing_id: ID,
        owner: address,
        nft_id: ID,
        price_per_day: u64,
        max_duration: u64,
        collateral_required: u64,
    }

    struct Rented has copy, drop {
        listing_id: ID,
        renter: address,
        nft_id: ID,
        rental_start: u64,
        rental_end: u64,
        total_paid: u64,
    }

    struct Returned has copy, drop {
        listing_id: ID,
        renter: address,
        nft_id: ID,
        refund_amount: u64,
        early_return: bool,
    }

    struct ExpiredAutoReturn has copy, drop {
        listing_id: ID,
        original_owner: address,
        nft_id: ID,
    }

    // Initialize the marketplace
    fun init(ctx: &mut TxContext) {
        let admin_cap = AdminCap {
            id: object::new(ctx),
        };

        let marketplace = Marketplace {
            id: object::new(ctx),
            listings: table::new(ctx),
            platform_balance: balance::zero(),
            admin: tx_context::sender(ctx),
            paused: false,
            platform_fee_bps: PLATFORM_FEE_BPS,
        };

        transfer::share_object(marketplace);
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    // List NFT for rent
    public entry fun list_for_rent<T: key + store>(
        marketplace: &mut Marketplace,
        nft: T,
        price_per_day: u64,
        max_duration: u64,
        collateral_required: u64,
        ctx: &mut TxContext
    ) {
        assert!(!marketplace.paused, E_UNAUTHORIZED);
        assert!(price_per_day > 0, E_INVALID_PRICE);
        assert!(max_duration > 0, E_INVALID_DURATION);

        let nft_id = object::id(&nft);
        let listing_id = object::id_from_address(tx_context::fresh_object_address(ctx));

        let listing = Listing {
            owner: tx_context::sender(ctx),
            nft_id,
            price_per_day,
            max_duration,
            collateral_required,
            is_rented: false,
            renter: option::none(),
            rental_start: option::none(),
            rental_end: option::none(),
        };

        table::add(&mut marketplace.listings, listing_id, listing);
        
        // Transfer NFT to marketplace for safekeeping
        transfer::public_transfer(nft, object::uid_to_address(&marketplace.id));

        event::emit(Listed {
            listing_id,
            owner: tx_context::sender(ctx),
            nft_id,
            price_per_day,
            max_duration,
            collateral_required,
        });
    }

    // Rent NFT
    public entry fun rent<T: key + store>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        nft: T,
        duration_days: u64,
        payment: Coin<SUI>,
        collateral: Option<Coin<SUI>>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!marketplace.paused, E_UNAUTHORIZED);
        assert!(table::contains(&marketplace.listings, listing_id), E_LISTING_NOT_FOUND);
        
        let listing = table::borrow_mut(&mut marketplace.listings, listing_id);
        assert!(!listing.is_rented, E_ALREADY_RENTED);
        assert!(duration_days > 0 && duration_days <= listing.max_duration, E_INVALID_DURATION);

        let current_time = clock::timestamp_ms(clock);
        let rental_end = current_time + (duration_days * DAY_IN_MS);
        let total_cost = listing.price_per_day * duration_days;
        let platform_fee = (total_cost * marketplace.platform_fee_bps) / 10000;
        let owner_payment = total_cost - platform_fee;

        assert!(coin::value(&payment) >= total_cost, E_INSUFFICIENT_PAYMENT);

        // Handle collateral if required
        if (listing.collateral_required > 0) {
            assert!(option::is_some(&collateral), E_INVALID_COLLATERAL);
            let collateral_coin = option::extract(&mut collateral);
            assert!(coin::value(&collateral_coin) >= listing.collateral_required, E_INVALID_COLLATERAL);
            // Hold collateral (simplified - in practice, store in escrow)
            transfer::public_transfer(collateral_coin, object::uid_to_address(&marketplace.id));
        };

        // Process payment
        let payment_balance = coin::into_balance(payment);
        let platform_fee_balance = balance::split(&mut payment_balance, platform_fee);
        balance::join(&mut marketplace.platform_balance, platform_fee_balance);

        // Pay owner
        let owner_payment_coin = coin::from_balance(payment_balance, ctx);
        transfer::public_transfer(owner_payment_coin, listing.owner);

        // Update listing
        listing.is_rented = true;
        listing.renter = option::some(tx_context::sender(ctx));
        listing.rental_start = option::some(current_time);
        listing.rental_end = option::some(rental_end);

        // Create rental NFT wrapper
        let rental_nft = RentalNFT {
            id: object::new(ctx),
            original_nft: nft,
            original_id: object::id(&nft),
            expires_at: rental_end,
            renter: tx_context::sender(ctx),
            listing_id,
        };

        let rental_id = object::id(&rental_nft);
        transfer::transfer(rental_nft, tx_context::sender(ctx));

        event::emit(Rented {
            listing_id,
            renter: tx_context::sender(ctx),
            nft_id: object::id(&nft),
            rental_start: current_time,
            rental_end,
            total_paid: total_cost,
        });

        // Clean up empty collateral option
        option::destroy_none(collateral);
    }

    // Return NFT early
    public entry fun return_early<T: key + store>(
        marketplace: &mut Marketplace,
        rental_nft: RentalNFT<T>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let RentalNFT {
            id,
            original_nft,
            original_id,
            expires_at,
            renter,
            listing_id,
        } = rental_nft;

        assert!(renter == tx_context::sender(ctx), E_UNAUTHORIZED);
        assert!(table::contains(&marketplace.listings, listing_id), E_LISTING_NOT_FOUND);

        let current_time = clock::timestamp_ms(clock);
        let listing = table::borrow_mut(&mut marketplace.listings, listing_id);
        
        // Calculate refund
        let rental_start = *option::borrow(&listing.rental_start);
        let days_used = (current_time - rental_start) / DAY_IN_MS + 1; // Round up
        let days_rented = (expires_at - rental_start) / DAY_IN_MS;
        let refund_days = days_rented - days_used;
        let refund_amount = refund_days * listing.price_per_day;

        // Reset listing
        listing.is_rented = false;
        listing.renter = option::none();
        listing.rental_start = option::none();
        listing.rental_end = option::none();

        // Return original NFT to owner
        transfer::public_transfer(original_nft, listing.owner);

        // Refund unused days (simplified - in practice, deduct platform fee)
        if (refund_amount > 0) {
            let refund_coin = coin::from_balance(
                balance::split(&mut marketplace.platform_balance, refund_amount),
                ctx
            );
            transfer::public_transfer(refund_coin, renter);
        };

        object::delete(id);

        event::emit(Returned {
            listing_id,
            renter,
            nft_id: original_id,
            refund_amount,
            early_return: true,
        });
    }

    // Auto-return expired rental
    public entry fun auto_return_expired<T: key + store>(
        marketplace: &mut Marketplace,
        rental_nft: RentalNFT<T>,
        clock: &Clock,
    ) {
        let RentalNFT {
            id,
            original_nft,
            original_id,
            expires_at,
            renter: _,
            listing_id,
        } = rental_nft;

        let current_time = clock::timestamp_ms(clock);
        assert!(current_time >= expires_at, E_RENTAL_NOT_EXPIRED);
        assert!(table::contains(&marketplace.listings, listing_id), E_LISTING_NOT_FOUND);

        let listing = table::borrow_mut(&mut marketplace.listings, listing_id);
        let original_owner = listing.owner;

        // Reset listing
        listing.is_rented = false;
        listing.renter = option::none();
        listing.rental_start = option::none();
        listing.rental_end = option::none();

        // Return original NFT to owner
        transfer::public_transfer(original_nft, original_owner);

        object::delete(id);

        event::emit(ExpiredAutoReturn {
            listing_id,
            original_owner,
            nft_id: original_id,
        });
    }

    // Remove listing
    public entry fun remove_listing(
        marketplace: &mut Marketplace,
        listing_id: ID,
        ctx: &mut TxContext
    ) {
        assert!(!marketplace.paused, E_UNAUTHORIZED);
        assert!(table::contains(&marketplace.listings, listing_id), E_LISTING_NOT_FOUND);
        
        let listing = table::borrow(&marketplace.listings, listing_id);
        assert!(listing.owner == tx_context::sender(ctx), E_NOT_OWNER);
        assert!(!listing.is_rented, E_ALREADY_RENTED);

        table::remove(&mut marketplace.listings, listing_id);
    }

    // Admin functions
    public entry fun pause_marketplace(
        _: &AdminCap,
        marketplace: &mut Marketplace,
    ) {
        marketplace.paused = true;
    }

    public entry fun unpause_marketplace(
        _: &AdminCap,
        marketplace: &mut Marketplace,
    ) {
        marketplace.paused = false;
    }

    public entry fun update_platform_fee(
        _: &AdminCap,
        marketplace: &mut Marketplace,
        new_fee_bps: u64,
    ) {
        marketplace.platform_fee_bps = new_fee_bps;
    }

    public entry fun withdraw_platform_fees(
        _: &AdminCap,
        marketplace: &mut Marketplace,
        ctx: &mut TxContext
    ) {
        let amount = balance::value(&marketplace.platform_balance);
        if (amount > 0) {
            let fees = coin::from_balance(
                balance::split(&mut marketplace.platform_balance, amount),
                ctx
            );
            transfer::public_transfer(fees, marketplace.admin);
        }
    }

    // View functions
    public fun get_listing_info(
        marketplace: &Marketplace,
        listing_id: ID,
    ): (address, ID, u64, u64, u64, bool) {
        let listing = table::borrow(&marketplace.listings, listing_id);
        (
            listing.owner,
            listing.nft_id,
            listing.price_per_day,
            listing.max_duration,
            listing.collateral_required,
            listing.is_rented
        )
    }

    public fun get_rental_info<T: key + store>(
        rental_nft: &RentalNFT<T>
    ): (ID, u64, address, ID) {
        (
            rental_nft.original_id,
            rental_nft.expires_at,
            rental_nft.renter,
            rental_nft.listing_id
        )
    }

    public fun is_rental_expired<T: key + store>(
        rental_nft: &RentalNFT<T>,
        clock: &Clock
    ): bool {
        clock::timestamp_ms(clock) >= rental_nft.expires_at
    }

    public fun marketplace_is_paused(marketplace: &Marketplace): bool {
        marketplace.paused
    }

    // Test helpers (for testing only)
    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }

    #[test_only]
    public fun create_test_listing(
        marketplace: &mut Marketplace,
        owner: address,
        nft_id: ID,
        price_per_day: u64,
        max_duration: u64,
        collateral_required: u64,
        ctx: &mut TxContext
    ): ID {
        let listing_id = object::id_from_address(tx_context::fresh_object_address(ctx));
        let listing = Listing {
            owner,
            nft_id,
            price_per_day,
            max_duration,
            collateral_required,
            is_rented: false,
            renter: option::none(),
            rental_start: option::none(),
            rental_end: option::none(),
        };
        table::add(&mut marketplace.listings, listing_id, listing);
        listing_id
    }
}

// Wrapper module for rental NFT management
module rentable::wrapper {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::clock::{Self, Clock};

    // Re-export the RentalNFT type for external use
     use rentable::market::RentalNFT;

    // Utility functions for working with rental NFTs
    public fun unwrap_if_expired<T: key + store>(
        rental_nft: RentalNFT<T>,
        clock: &Clock,
    ): T {
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time >= rentable::market::get_rental_info(&rental_nft).1, 0);
        
        let RentalNFT {
            id,
            original_nft,
            original_id: _,
            expires_at: _,
            renter: _,
            listing_id: _,
        } = rental_nft;
        
        object::delete(id);
        original_nft
    }

    public fun get_wrapped_nft_id<T: key + store>(rental_nft: &RentalNFT<T>): ID {
        let (original_id, _, _, _) = rentable::market::get_rental_info(rental_nft);
        original_id
    }

    public fun get_expiry_time<T: key + store>(rental_nft: &RentalNFT<T>): u64 {
        let (_, expires_at, _, _) = rentable::market::get_rental_info(rental_nft);
        expires_at
    }
}

// Admin module for marketplace management
module rentable::admin {
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;

    // Re-export admin functions
     use rentable::market::{
        pause_marketplace,
        unpause_marketplace,
        update_platform_fee,
        withdraw_platform_fees,
        AdminCap
    };

    // Additional admin utilities
    public fun transfer_admin_cap(
        admin_cap: AdminCap,
        new_admin: address,
    ) {
        transfer::transfer(admin_cap, new_admin);
    }

    public fun create_additional_admin_cap(
        _: &AdminCap,
        ctx: &mut TxContext
    ): AdminCap {
        AdminCap {
            id: object::new(ctx),
        }
    }
}