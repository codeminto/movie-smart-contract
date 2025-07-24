module addr::flow_stream {
    use sui::tx_context::{Self, TxContext};
    use sui::event;
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::table::{Self, Table};
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::type_name;

    // Error codes
    const E_STREAM_NOT_FOUND: u64 = 1;
    const E_UNAUTHORIZED: u64 = 2;
    const E_INVALID_PARAMETERS: u64 = 3;
    const E_INSUFFICIENT_BALANCE: u64 = 4;
    const E_STREAM_ENDED: u64 = 5;
    const E_STREAM_NOT_STARTED: u64 = 6;
    const E_ALREADY_WITHDRAWN: u64 = 7;
    const E_INVALID_TIME_RANGE: u64 = 8;
    const E_STREAM_NOT_PAUSED: u64 = 9;
    const E_STREAM_NOT_ACTIVE: u64 = 10;

    // Stream status
    const STATUS_ACTIVE: u8 = 1;
    const STATUS_PAUSED: u8 = 2;
    const STATUS_CANCELLED: u8 = 3;
    const STATUS_COMPLETED: u8 = 4;

    /// Core Stream resource
    /// This object will be shared after creation.
    struct Stream<phantom Currency> has key, store {
        id: UID,               // Sui object UID
        stream_id_internal: u64, // Internal sequential ID for events/tables
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

    /// Stream manager resource to track all streams
    /// This object will be shared upon module initialization.
    struct StreamManager has key {
        id: UID,               // Sui object UID
        streams: Table<u64, UID>, // stream_id_internal -> stream_object_uid
        next_stream_id: u64,
        total_streams: u64,
    }

    // Events
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

    struct StreamWithdrawn has drop, store {
        stream_id: u64,
        recipient: address,
        amount: u64,
        timestamp: u64,
    }

    struct StreamCancelled has drop, store {
        stream_id: u64,
        sender: address,
        recipient: address,
        refund_amount: u64,
        withdrawn_amount: u64,
        timestamp: u64,
    }

    struct StreamToppedUp has drop, store {
        stream_id: u64,
        sender: address,
        amount: u64,
        new_balance: u64,
        timestamp: u64,
    }

    struct StreamPaused has drop, store {
        stream_id: u64,
        sender: address,
        timestamp: u64,
    }

    struct StreamResumed has drop, store {
        stream_id: u64,
        sender: address,
        timestamp: u64,
    }

    /// Initializes the module, creating and sharing the StreamManager object.
    /// This function is called once during module publication.
    fun init(ctx: &mut TxContext) {
        let stream_manager = StreamManager {
            id: object::new(ctx),
            streams: table::new(ctx),
            next_stream_id: 1,
            total_streams: 0,
        };
        // Share the StreamManager so it can be accessed by anyone
        transfer::share_object(stream_manager);
    }

    /// Creates a new payment stream.
    /// The `Stream` object is created and shared, allowing both sender and recipient to interact with it.
    public entry fun create_stream<Currency>(
        stream_manager: &mut StreamManager, // Shared StreamManager object
        recipient: address,
        rate_per_second: u64,
        duration_secs: u64,
        initial_deposit_coin: Coin<Currency>, // Initial deposit as a Coin object
        ctx: &mut TxContext
    ) {
        let sender_addr = tx_context::sender(ctx);
        let current_time = tx_context::epoch_timestamp_ms(ctx) / 1000; // Convert ms to seconds

        // Validate parameters
        assert!(rate_per_second > 0, E_INVALID_PARAMETERS);
        assert!(duration_secs > 0, E_INVALID_PARAMETERS);
        assert!(coin::value(&initial_deposit_coin) > 0, E_INVALID_PARAMETERS);
        assert!(recipient != sender_addr, E_INVALID_PARAMETERS);

        let end_time = current_time + duration_secs;
        assert!(end_time > current_time, E_INVALID_TIME_RANGE);

        // Calculate minimum required deposit
        let total_stream_amount = rate_per_second * duration_secs;
        assert!(coin::value(&initial_deposit_coin) >= total_stream_amount, E_INSUFFICIENT_BALANCE);

        // Get stream ID from the shared StreamManager
        let stream_id = stream_manager.next_stream_id;
        stream_manager.next_stream_id = stream_id + 1;
        stream_manager.total_streams = stream_manager.total_streams + 1;

        // Create the Stream object
        let stream = Stream<Currency> {
            id: object::new(ctx),
            stream_id_internal: stream_id,
            sender: sender_addr,
            recipient,
            rate_per_second,
            start_time: current_time,
            end_time,
            deposited: coin::value(&initial_deposit_coin),
            withdrawn: 0,
            status: STATUS_ACTIVE,
            last_update: current_time,
            coin_store: initial_deposit_coin, // Store the initial coin directly
        };

        // Store stream mapping in the shared StreamManager's table
        table::add(&mut stream_manager.streams, stream_id, object::id(&stream));

        // Share the Stream object so both sender and recipient can interact with it
        transfer::share_object(stream);

        // Emit event
        event::emit(StreamCreated {
            stream_id,
            sender: sender_addr,
            recipient,
            token_type: type_name::get<Currency>(),
            rate_per_second,
            start_time: current_time,
            end_time,
            initial_deposit: coin::value(&initial_deposit_coin),
        });
    }

    /// Withdraws streamed tokens (called by recipient).
    /// Requires a mutable reference to the shared `Stream` object.
    public entry fun withdraw_streamed<Currency>(
        stream: &mut Stream<Currency>, // Mutable reference to the shared Stream object
        ctx: &mut TxContext
    ) {
        let recipient_addr = tx_context::sender(ctx);
        let current_time = tx_context::epoch_timestamp_ms(ctx) / 1000;

        // Validate authorization
        assert!(stream.recipient == recipient_addr, E_UNAUTHORIZED);
        assert!(stream.status == STATUS_ACTIVE, E_STREAM_NOT_ACTIVE); // Ensure stream is active

        // Calculate withdrawable amount
        let withdrawable = calculate_withdrawable_amount(stream, current_time);
        assert!(withdrawable > 0, E_ALREADY_WITHDRAWN); // No amount to withdraw

        // Update stream state
        stream.withdrawn = stream.withdrawn + withdrawable;
        stream.last_update = current_time;

        // Transfer tokens to recipient
        let coins_to_transfer = coin::take(&mut stream.coin_store, withdrawable);
        transfer::public_transfer(coins_to_transfer, recipient_addr);

        // Mark as completed if fully withdrawn or stream end time reached
        if (stream.withdrawn >= stream.deposited || current_time >= stream.end_time) {
            stream.status = STATUS_COMPLETED;
        };

        // Emit event
        event::emit(StreamWithdrawn {
            stream_id: stream.stream_id_internal,
            recipient: recipient_addr,
            amount: withdrawable,
            timestamp: current_time,
        });
    }

    /// Cancels a stream (called by sender).
    /// Requires a mutable reference to the shared `Stream` object.
    public entry fun cancel_stream<Currency>(
        stream: &mut Stream<Currency>, // Mutable reference to the shared Stream object
        ctx: &mut TxContext
    ) {
        let sender_addr = tx_context::sender(ctx);
        let current_time = tx_context::epoch_timestamp_ms(ctx) / 1000;

        // Validate authorization
        assert!(stream.sender == sender_addr, E_UNAUTHORIZED);
        assert!(stream.status == STATUS_ACTIVE || stream.status == STATUS_PAUSED, E_STREAM_ENDED);

        // Calculate amounts
        let withdrawable = calculate_withdrawable_amount(stream, current_time);
        let refund_amount = coin::value(&stream.coin_store) - withdrawable;

        // Transfer withdrawable to recipient if any
        if (withdrawable > 0) {
            let recipient_coins = coin::take(&mut stream.coin_store, withdrawable);
            transfer::public_transfer(recipient_coins, stream.recipient);
            stream.withdrawn = stream.withdrawn + withdrawable;
        };

        // Refund remaining to sender
        if (refund_amount > 0) {
            let refund_coins = coin::take(&mut stream.coin_store, refund_amount);
            transfer::public_transfer(refund_coins, sender_addr);
        };

        // Update stream status
        stream.status = STATUS_CANCELLED;
        stream.last_update = current_time;

        // Emit event
        event::emit(StreamCancelled {
            stream_id: stream.stream_id_internal,
            sender: sender_addr,
            recipient: stream.recipient,
            refund_amount,
            withdrawn_amount: withdrawable,
            timestamp: current_time,
        });

        // Optionally, delete the stream object if it's no longer needed after cancellation
        // object::delete(stream.id); // This would remove the object from existence
    }

    /// Tops up a stream with additional funds.
    /// Requires a mutable reference to the shared `Stream` object.
    public entry fun topup_stream<Currency>(
        stream: &mut Stream<Currency>, // Mutable reference to the shared Stream object
        amount_coin: Coin<Currency>, // Additional funds as a Coin object
        ctx: &mut TxContext
    ) {
        let sender_addr = tx_context::sender(ctx);
        let current_time = tx_context::epoch_timestamp_ms(ctx) / 1000;

        // Validate authorization
        assert!(stream.sender == sender_addr, E_UNAUTHORIZED);
        // Validate stream is active or paused (can top up a paused stream)
        assert!(stream.status == STATUS_ACTIVE || stream.status == STATUS_PAUSED, E_STREAM_ENDED);
        assert!(coin::value(&amount_coin) > 0, E_INVALID_PARAMETERS);

        // Merge additional coins into the stream's coin store
        coin::join(&mut stream.coin_store, amount_coin);

        // Update deposited amount
        stream.deposited = stream.deposited + coin::value(&amount_coin);
        stream.last_update = current_time;

        // Emit event
        event::emit(StreamToppedUp {
            stream_id: stream.stream_id_internal,
            sender: sender_addr,
            amount: coin::value(&amount_coin),
            new_balance: coin::value(&stream.coin_store),
            timestamp: current_time,
        });
    }

    /// Pauses a stream (called by sender).
    /// Requires a mutable reference to the shared `Stream` object.
    public entry fun pause_stream<Currency>(
        stream: &mut Stream<Currency>, // Mutable reference to the shared Stream object
        ctx: &mut TxContext
    ) {
        let sender_addr = tx_context::sender(ctx);
        let current_time = tx_context::epoch_timestamp_ms(ctx) / 1000;

        // Validate authorization
        assert!(stream.sender == sender_addr, E_UNAUTHORIZED);
        assert!(stream.status == STATUS_ACTIVE, E_STREAM_NOT_ACTIVE);

        // Update stream status
        stream.status = STATUS_PAUSED;
        stream.last_update = current_time;

        // Emit event
        event::emit(StreamPaused {
            stream_id: stream.stream_id_internal,
            sender: sender_addr,
            timestamp: current_time,
        });
    }

    /// Resumes a stream (called by sender).
    /// Requires a mutable reference to the shared `Stream` object.
    public entry fun resume_stream<Currency>(
        stream: &mut Stream<Currency>, // Mutable reference to the shared Stream object
        ctx: &mut TxContext
    ) {
        let sender_addr = tx_context::sender(ctx);
        let current_time = tx_context::epoch_timestamp_ms(ctx) / 1000;

        // Validate authorization
        assert!(stream.sender == sender_addr, E_UNAUTHORIZED);
        assert!(stream.status == STATUS_PAUSED, E_STREAM_NOT_PAUSED);

        // Update stream status
        stream.status = STATUS_ACTIVE;
        stream.last_update = current_time;

        // Emit event
        event::emit(StreamResumed {
            stream_id: stream.stream_id_internal,
            sender: sender_addr,
            timestamp: current_time,
        });
    }

    // --- View functions (public functions that take immutable references) ---

    /// Retrieves information about a specific stream.
    /// Takes an immutable reference to the shared `Stream` object.
    public fun get_stream_info<Currency>(stream: &Stream<Currency>): (u64, address, address, u64, u64, u64, u64, u64, u8) {
        (
            stream.stream_id_internal,
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

    /// Calculates the currently withdrawable amount for a stream.
    /// Takes an immutable reference to the shared `Stream` object.
    public fun get_withdrawable_amount<Currency>(stream: &Stream<Currency>): u64 {
        let current_time = tx_context::epoch_timestamp_ms(tx_context::shared_tx_context()) / 1000; // Use shared context for view
        calculate_withdrawable_amount(stream, current_time)
    }

    /// Retrieves the current balance of tokens held within the stream.
    /// Takes an immutable reference to the shared `Stream` object.
    public fun get_stream_balance<Currency>(stream: &Stream<Currency>): u64 {
        coin::value(&stream.coin_store)
    }

    // --- Helper functions ---

    /// Internal function to calculate the amount of tokens that can be withdrawn.
    fun calculate_withdrawable_amount<Currency>(stream: &Stream<Currency>, current_time: u64): u64 {
        // If stream is not active, no new tokens are being streamed
        if (stream.status != STATUS_ACTIVE) {
            return 0
        };

        // Stream hasn't started yet
        if (current_time < stream.start_time) {
            return 0
        };

        // Calculate elapsed time for which tokens have been streamed
        let elapsed_time = if (current_time >= stream.end_time) {
            // If current time is past or at end time, use full duration
            stream.end_time - stream.start_time
        } else {
            // Otherwise, use time elapsed since start
            current_time - stream.start_time
        };

        // Calculate total earned based on rate and elapsed time
        let total_earned = elapsed_time * stream.rate_per_second;

        // Ensure we don't allow withdrawing more than what was deposited
        let max_withdrawable = if (total_earned > stream.deposited) {
            stream.deposited
        } else {
            total_earned
        };

        // Return the amount that has been earned but not yet withdrawn
        if (max_withdrawable > stream.withdrawn) {
            max_withdrawable - stream.withdrawn
        } else {
            0 // All earned tokens have already been withdrawn
        }
    }
}

/// Utility module for safe math operations.
module addr::utils {
    use sui::tx_context::{Self, TxContext}; // Added for abort

    const E_DIVISION_BY_ZERO: u64 = 100;
    const E_OVERFLOW: u64 = 101;

    /// Safe division with proper rounding (rounds to nearest integer).
    public fun safe_div_round(numerator: u64, denominator: u64): u64 {
        assert!(denominator != 0, E_DIVISION_BY_ZERO);
        (numerator + denominator / 2) / denominator
    }

    /// Safe multiplication with overflow check.
    public fun safe_mul(a: u64, b: u64): u64 {
        if (a == 0 || b == 0) {
            return 0
        };
        let result = a * b;
        // Check for overflow: if result divided by 'a' is not 'b', then overflow occurred
        assert!(result / a == b, E_OVERFLOW);
        result
    }

    /// Calculates a percentage of an amount with a given precision.
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
