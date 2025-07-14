module addr::FlowStream{
    

    use std::signer;
    use std::event;
    use std::error;
    use std::string::String;
    use aptos_framework::timestamp;
    use aptos_framework::coin::{Self, Coin};
    use aptos_std::table::{Self, Table};
    use aptos_std::type_info;

    // Error codes
    const E_STREAM_NOT_FOUND: u64 = 1;
    const E_UNAUTHORIZED: u64 = 2;
    const E_INVALID_PARAMETERS: u64 = 3;
    const E_INSUFFICIENT_BALANCE: u64 = 4;
    const E_STREAM_ENDED: u64 = 5;
    const E_STREAM_NOT_STARTED: u64 = 6;
    const E_ALREADY_WITHDRAWN: u64 = 7;
    const E_INVALID_TIME_RANGE: u64 = 8;

    // Stream status
    const STATUS_ACTIVE: u8 = 1;
    const STATUS_PAUSED: u8 = 2;
    const STATUS_CANCELLED: u8 = 3;
    const STATUS_COMPLETED: u8 = 4;

    // Core Stream resource
    struct Stream<phantom Currency> has key, store {
        id: u64,
        sender: address,
        recipient: address,
        rate_per_second: u64,  // tokens per second (scaled by coin decimals)
        start_time: u64,       // unix timestamp in seconds
        end_time: u64,         // unix timestamp in seconds
        deposited: u64,        // total tokens deposited
        withdrawn: u64,        // total tokens withdrawn by recipient
        status: u8,            // stream status
        last_update: u64,      // last interaction timestamp
        coin_store: Coin<Currency>, // actual token storage
    }

    // Stream manager resource to track all streams
    struct StreamManager has key {
        streams: Table<u64, address>, // stream_id -> stream_owner
        next_stream_id: u64,
        total_streams: u64,
    }

    // Events
    #[event]
    struct StreamCreated has drop, store {
        stream_id: u64,
        sender: address,
        recipient: address,
        token_type: String,
        rate_per_second: u64,
        start_time: u64,
        end_time: u64,
        initial_deposit: u64,
    }

    #[event]
    struct StreamWithdrawn has drop, store {
        stream_id: u64,
        recipient: address,
        amount: u64,
        timestamp: u64,
    }

    #[event]
    struct StreamCancelled has drop, store {
        stream_id: u64,
        sender: address,
        recipient: address,
        refund_amount: u64,
        withdrawn_amount: u64,
        timestamp: u64,
    }

    #[event]
    struct StreamToppedUp has drop, store {
        stream_id: u64,
        sender: address,
        amount: u64,
        new_balance: u64,
        timestamp: u64,
    }

    #[event]
    struct StreamPaused has drop, store {
        stream_id: u64,
        sender: address,
        timestamp: u64,
    }

    #[event]
    struct StreamResumed has drop, store {
        stream_id: u64,
        sender: address,
        timestamp: u64,
    }

    // Initialize the module
    fun init_module(account: &signer) {
        let stream_manager = StreamManager {
            streams: table::new(),
            next_stream_id: 1,
            total_streams: 0,
        };
        move_to(account, stream_manager);
    }

    // Create a new payment stream
    public entry fun create_stream<Currency>(
        sender: &signer,
        recipient: address,
        rate_per_second: u64,
        duration_secs: u64,
        initial_deposit: u64
    ) acquires StreamManager {
        let sender_addr = signer::address_of(sender);
        let current_time = timestamp::now_seconds();
        
        // Validate parameters
        assert!(rate_per_second > 0, error::invalid_argument(E_INVALID_PARAMETERS));
        assert!(duration_secs > 0, error::invalid_argument(E_INVALID_PARAMETERS));
        assert!(initial_deposit > 0, error::invalid_argument(E_INVALID_PARAMETERS));
        assert!(recipient != sender_addr, error::invalid_argument(E_INVALID_PARAMETERS));

        let end_time = current_time + duration_secs;
        assert!(end_time > current_time, error::invalid_argument(E_INVALID_TIME_RANGE));

        // Calculate minimum required deposit
        let total_stream_amount = rate_per_second * duration_secs;
        assert!(initial_deposit >= total_stream_amount, error::invalid_argument(E_INSUFFICIENT_BALANCE));

        // Get stream ID
        let stream_manager = borrow_global_mut<StreamManager>(@addr);
        let stream_id = stream_manager.next_stream_id;
        stream_manager.next_stream_id = stream_id + 1;
        stream_manager.total_streams = stream_manager.total_streams + 1;

        // Transfer coins from sender
        let coins = coin::withdraw<Currency>(sender, initial_deposit);

        // Create the stream
        let stream = Stream<Currency> {
            id: stream_id,
            sender: sender_addr,
            recipient,
            rate_per_second,
            start_time: current_time,
            end_time,
            deposited: initial_deposit,
            withdrawn: 0,
            status: STATUS_ACTIVE,
            last_update: current_time,
            coin_store: coins,
        };

        // Store stream mapping
        table::add(&mut stream_manager.streams, stream_id, sender_addr);

        // Move stream to sender's account
        move_to(sender, stream);

        // Emit event
        event::emit(StreamCreated {
            stream_id,
            sender: sender_addr,
            recipient,
            token_type: type_info::type_name<Currency>(),
            rate_per_second,
            start_time: current_time,
            end_time,
            initial_deposit,
        });
    }

    // Withdraw streamed tokens (called by recipient)
    public entry fun withdraw_streamed<Currency>(
        recipient: &signer,
        stream_id: u64,
        stream_owner: address
    ) acquires Stream {
        let recipient_addr = signer::address_of(recipient);
        let current_time = timestamp::now_seconds();

        // Get stream
        assert!(exists<Stream<Currency>>(stream_owner), error::not_found(E_STREAM_NOT_FOUND));
        let stream = borrow_global_mut<Stream<Currency>>(stream_owner);

        // Validate authorization
        assert!(stream.recipient == recipient_addr, error::permission_denied(E_UNAUTHORIZED));
        assert!(stream.status == STATUS_ACTIVE, error::invalid_state(E_STREAM_ENDED));

        // Calculate withdrawable amount
        let withdrawable = calculate_withdrawable_amount(stream, current_time);
        assert!(withdrawable > 0, error::invalid_argument(E_ALREADY_WITHDRAWN));

        // Update stream state
        stream.withdrawn = stream.withdrawn + withdrawable;
        stream.last_update = current_time;

        // Transfer tokens to recipient
        let coins = coin::extract(&mut stream.coin_store, withdrawable);
        coin::deposit(recipient_addr, coins);

        // Mark as completed if fully withdrawn
        if (stream.withdrawn >= stream.deposited || current_time >= stream.end_time) {
            stream.status = STATUS_COMPLETED;
        };

        // Emit event
        event::emit(StreamWithdrawn {
            stream_id,
            recipient: recipient_addr,
            amount: withdrawable,
            timestamp: current_time,
        });
    }

    // Cancel stream (called by sender)
    public entry fun cancel_stream<Currency>(
        sender: &signer,
        stream_id: u64
    ) acquires Stream {
        let sender_addr = signer::address_of(sender);
        let current_time = timestamp::now_seconds();

        // Get stream
        assert!(exists<Stream<Currency>>(sender_addr), error::not_found(E_STREAM_NOT_FOUND));
        let stream = borrow_global_mut<Stream<Currency>>(sender_addr);

        // Validate authorization
        assert!(stream.sender == sender_addr, error::permission_denied(E_UNAUTHORIZED));
        assert!(stream.status == STATUS_ACTIVE, error::invalid_state(E_STREAM_ENDED));

        // Calculate amounts
        let withdrawable = calculate_withdrawable_amount(stream, current_time);
        let refund_amount = coin::value(&stream.coin_store) - withdrawable;

        // Transfer withdrawable to recipient if any
        if (withdrawable > 0) {
            let recipient_coins = coin::extract(&mut stream.coin_store, withdrawable);
            coin::deposit(stream.recipient, recipient_coins);
            stream.withdrawn = stream.withdrawn + withdrawable;
        };

        // Refund remaining to sender
        if (refund_amount > 0) {
            let refund_coins = coin::extract(&mut stream.coin_store, refund_amount);
            coin::deposit(sender_addr, refund_coins);
        };

        // Update stream status
        stream.status = STATUS_CANCELLED;
        stream.last_update = current_time;

        // Emit event
        event::emit(StreamCancelled {
            stream_id,
            sender: sender_addr,
            recipient: stream.recipient,
            refund_amount,
            withdrawn_amount: withdrawable,
            timestamp: current_time,
        });
    }

    // Top up stream with additional funds
    public entry fun topup_stream<Currency>(
        sender: &signer,
        stream_id: u64,
        stream_owner: address,
        amount: u64
    ) acquires Stream {
        let sender_addr = signer::address_of(sender);
        let current_time = timestamp::now_seconds();

        // Get stream
        assert!(exists<Stream<Currency>>(stream_owner), error::not_found(E_STREAM_NOT_FOUND));
        let stream = borrow_global_mut<Stream<Currency>>(stream_owner);

        // Validate stream is active
        assert!(stream.status == STATUS_ACTIVE, error::invalid_state(E_STREAM_ENDED));
        assert!(amount > 0, error::invalid_argument(E_INVALID_PARAMETERS));

        // Transfer additional coins
        let coins = coin::withdraw<Currency>(sender, amount);
        coin::merge(&mut stream.coin_store, coins);

        // Update deposited amount
        stream.deposited = stream.deposited + amount;
        stream.last_update = current_time;

        // Emit event
        event::emit(StreamToppedUp {
            stream_id,
            sender: sender_addr,
            amount,
            new_balance: coin::value(&stream.coin_store),
            timestamp: current_time,
        });
    }

    // Pause stream (v2 feature)
    public entry fun pause_stream<Currency>(
        sender: &signer,
        stream_id: u64
    ) acquires Stream {
        let sender_addr = signer::address_of(sender);
        let current_time = timestamp::now_seconds();

        // Get stream
        assert!(exists<Stream<Currency>>(sender_addr), error::not_found(E_STREAM_NOT_FOUND));
        let stream = borrow_global_mut<Stream<Currency>>(sender_addr);

        // Validate authorization
        assert!(stream.sender == sender_addr, error::permission_denied(E_UNAUTHORIZED));
        assert!(stream.status == STATUS_ACTIVE, error::invalid_state(E_STREAM_ENDED));

        // Update stream status
        stream.status = STATUS_PAUSED;
        stream.last_update = current_time;

        // Emit event
        event::emit(StreamPaused {
            stream_id,
            sender: sender_addr,
            timestamp: current_time,
        });
    }

    // Resume stream (v2 feature)
    public entry fun resume_stream<Currency>(
        sender: &signer,
        stream_id: u64
    ) acquires Stream {
        let sender_addr = signer::address_of(sender);
        let current_time = timestamp::now_seconds();

        // Get stream
        assert!(exists<Stream<Currency>>(sender_addr), error::not_found(E_STREAM_NOT_FOUND));
        let stream = borrow_global_mut<Stream<Currency>>(sender_addr);

        // Validate authorization
        assert!(stream.sender == sender_addr, error::permission_denied(E_UNAUTHORIZED));
        assert!(stream.status == STATUS_PAUSED, error::invalid_state(E_STREAM_ENDED));

        // Update stream status
        stream.status = STATUS_ACTIVE;
        stream.last_update = current_time;

        // Emit event
        event::emit(StreamResumed {
            stream_id,
            sender: sender_addr,
            timestamp: current_time,
        });
    }

    // View functions

    #[view]
    public fun get_stream_info<Currency>(stream_owner: address): (u64, address, address, u64, u64, u64, u64, u64, u8) acquires Stream {
        assert!(exists<Stream<Currency>>(stream_owner), error::not_found(E_STREAM_NOT_FOUND));
        let stream = borrow_global<Stream<Currency>>(stream_owner);
        (
            stream.id,
            stream.sender,
            stream.recipient,
            stream.rate_per_second,
            stream.start_time,
            stream.end_time,
            stream.deposited,
            stream.withdrawn,
            stream.status
        )
    }

    #[view]
    public fun get_withdrawable_amount<Currency>(stream_owner: address): u64 acquires Stream {
        assert!(exists<Stream<Currency>>(stream_owner), error::not_found(E_STREAM_NOT_FOUND));
        let stream = borrow_global<Stream<Currency>>(stream_owner);
        let current_time = timestamp::now_seconds();
        calculate_withdrawable_amount(stream, current_time)
    }

    #[view]
    public fun get_stream_balance<Currency>(stream_owner: address): u64 acquires Stream {
        assert!(exists<Stream<Currency>>(stream_owner), error::not_found(E_STREAM_NOT_FOUND));
        let stream = borrow_global<Stream<Currency>>(stream_owner);
        coin::value(&stream.coin_store)
    }

    // Helper functions

    fun calculate_withdrawable_amount<Currency>(stream: &Stream<Currency>, current_time: u64): u64 {
        if (stream.status != STATUS_ACTIVE) {
            return 0
        };

        // Stream hasn't started yet
        if (current_time < stream.start_time) {
            return 0
        };

        // Calculate elapsed time
        let elapsed_time = if (current_time >= stream.end_time) {
            stream.end_time - stream.start_time
        } else {
            current_time - stream.start_time
        };

        // Calculate total earned
        let total_earned = elapsed_time * stream.rate_per_second;
        
        // Ensure we don't exceed deposited amount
        let max_withdrawable = if (total_earned > stream.deposited) {
            stream.deposited
        } else {
            total_earned
        };

        // Return amount not yet withdrawn
        if (max_withdrawable > stream.withdrawn) {
            max_withdrawable - stream.withdrawn
        } else {
            0
        }
    }
}

// Utility module for safe math operations
module addr::utils {
    use std::error;

    const E_DIVISION_BY_ZERO: u64 = 100;
    const E_OVERFLOW: u64 = 101;

    // Safe division with proper rounding
    public fun safe_div_round(numerator: u64, denominator: u64): u64 {
        assert!(denominator != 0, error::invalid_argument(E_DIVISION_BY_ZERO));
        (numerator + denominator / 2) / denominator
    }

    // Safe multiplication with overflow check
    public fun safe_mul(a: u64, b: u64): u64 {
        if (a == 0 || b == 0) {
            return 0
        };
        let result = a * b;
        assert!(result / a == b, error::invalid_argument(E_OVERFLOW));
        result
    }

    // Calculate percentage with precision
    public fun calculate_percentage(amount: u64, percentage: u64, precision: u64): u64 {
        safe_div_round(safe_mul(amount, percentage), precision)
    }

    // Time utilities
    public fun seconds_to_hours(seconds: u64): u64 {
        seconds / 3600
    }

    public fun hours_to_seconds(hours: u64): u64 {
        hours * 3600
    }

    public fun days_to_seconds(days: u64): u64 {
        days * 24 * 3600
    }
}