#[test_only]
module addr::payment_stream_tests {
    use std::signer;
    use std::error;
    use std::string;
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::timestamp;
    use aptos_framework::account;
    use aptos_std::type_info;
    use addr::payment_stream::{Self, Stream, StreamManager};
    use addr::utils;

    // Test constants
    const SENDER_ADDR: address = @0x100;
    const RECIPIENT_ADDR: address = @0x200;
    const STREAM_MANAGER_ADDR: address = @addr;
    const INITIAL_BALANCE: u64 = 1000000; // 1M coins
    const RATE_PER_SECOND: u64 = 100;
    const DURATION_SECS: u64 = 3600; // 1 hour
    const INITIAL_DEPOSIT: u64 = 360000; // RATE_PER_SECOND * DURATION_SECS

    // Error constants (matching the main contract)
    const E_STREAM_NOT_FOUND: u64 = 1;
    const E_UNAUTHORIZED: u64 = 2;
    const E_INSUFFICIENT_BALANCE: u64 = 3;
    const E_INVALID_PARAMETERS: u64 = 4;
    const E_STREAM_ENDED: u64 = 5;
    const E_ALREADY_WITHDRAWN: u64 = 6;
    const E_INVALID_TIME_RANGE: u64 = 7;

    // Test helper functions
    fun setup_test_env(): (signer, signer, signer) {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        let sender = account::create_account_for_test(SENDER_ADDR);
        let recipient = account::create_account_for_test(RECIPIENT_ADDR);
        let stream_manager = account::create_account_for_test(STREAM_MANAGER_ADDR);

        // Initialize timestamp
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        // Initialize coin store and fund accounts
        coin::register<AptosCoin>(&sender);
        coin::register<AptosCoin>(&recipient);
        
        // Mint coins for testing
        let coins = coin::mint_for_testing<AptosCoin>(INITIAL_BALANCE);
        coin::deposit(SENDER_ADDR, coins);

        // Initialize stream manager
        payment_stream::initialize(&stream_manager);

        (sender, recipient, stream_manager)
    }

    fun fast_forward_time(seconds: u64) {
        let current_time = timestamp::now_seconds();
        timestamp::update_global_time_for_test(current_time + seconds);
    }

    // Test 1: Successful stream creation
    #[test]
    fun test_create_stream_success() {
        let (sender, _recipient, _stream_manager) = setup_test_env();
        
        payment_stream::create_stream<AptosCoin>(
            &sender,
            RECIPIENT_ADDR,
            RATE_PER_SECOND,
            DURATION_SECS,
            INITIAL_DEPOSIT
        );

        // Verify stream was created
        let (stream_id, stream_sender, stream_recipient, rate, start_time, end_time, deposited, withdrawn, status) = 
            payment_stream::get_stream_info<AptosCoin>(SENDER_ADDR);
        
        assert!(stream_id == 1, 0);
        assert!(stream_sender == SENDER_ADDR, 1);
        assert!(stream_recipient == RECIPIENT_ADDR, 2);
        assert!(rate == RATE_PER_SECOND, 3);
        assert!(deposited == INITIAL_DEPOSIT, 4);
        assert!(withdrawn == 0, 5);
        assert!(status == 1, 6); // STATUS_ACTIVE

        // Verify sender's balance was deducted
        let sender_balance = coin::balance<AptosCoin>(SENDER_ADDR);
        assert!(sender_balance == INITIAL_BALANCE - INITIAL_DEPOSIT, 7);
    }

    // Test 2: Stream creation with invalid parameters
    #[test]
    #[expected_failure(abort_code = 0x10004)] // E_INVALID_PARAMETERS
    fun test_create_stream_invalid_rate() {
        let (sender, _recipient, _stream_manager) = setup_test_env();
        
        payment_stream::create_stream<AptosCoin>(
            &sender,
            RECIPIENT_ADDR,
            0, // Invalid rate
            DURATION_SECS,
            INITIAL_DEPOSIT
        );
    }

    // Test 3: Stream creation with insufficient deposit
    #[test]
    #[expected_failure(abort_code = 0x10003)] // E_INSUFFICIENT_BALANCE
    fun test_create_stream_insufficient_deposit() {
        let (sender, _recipient, _stream_manager) = setup_test_env();
        
        payment_stream::create_stream<AptosCoin>(
            &sender,
            RECIPIENT_ADDR,
            RATE_PER_SECOND,
            DURATION_SECS,
            100 // Insufficient deposit
        );
    }

    // Test 4: Stream creation with same sender and recipient
    #[test]
    #[expected_failure(abort_code = 0x10004)] // E_INVALID_PARAMETERS
    fun test_create_stream_same_sender_recipient() {
        let (sender, _recipient, _stream_manager) = setup_test_env();
        
        payment_stream::create_stream<AptosCoin>(
            &sender,
            SENDER_ADDR, // Same as sender
            RATE_PER_SECOND,
            DURATION_SECS,
            INITIAL_DEPOSIT
        );
    }

    // Test 5: Successful withdrawal
    #[test]
    fun test_withdraw_streamed_success() {
        let (sender, recipient, _stream_manager) = setup_test_env();
        
        // Create stream
        payment_stream::create_stream<AptosCoin>(
            &sender,
            RECIPIENT_ADDR,
            RATE_PER_SECOND,
            DURATION_SECS,
            INITIAL_DEPOSIT
        );

        // Fast forward time by 1800 seconds (30 minutes)
        fast_forward_time(1800);

        // Withdraw streamed tokens
        payment_stream::withdraw_streamed<AptosCoin>(&recipient, 1, SENDER_ADDR);

        // Verify recipient received tokens
        let recipient_balance = coin::balance<AptosCoin>(RECIPIENT_ADDR);
        let expected_amount = RATE_PER_SECOND * 1800; // 30 minutes worth
        assert!(recipient_balance == expected_amount, 0);

        // Verify stream state updated
        let (_id, _sender, _recipient, _rate, _start, _end, _deposited, withdrawn, _status) = 
            payment_stream::get_stream_info<AptosCoin>(SENDER_ADDR);
        assert!(withdrawn == expected_amount, 1);
    }

    // Test 6: Unauthorized withdrawal
    #[test]
    #[expected_failure(abort_code = 0x50002)] // E_UNAUTHORIZED
    fun test_withdraw_unauthorized() {
        let (sender, _recipient, _stream_manager) = setup_test_env();
        let unauthorized = account::create_account_for_test(@0x300);
        coin::register<AptosCoin>(&unauthorized);
        
        // Create stream
        payment_stream::create_stream<AptosCoin>(
            &sender,
            RECIPIENT_ADDR,
            RATE_PER_SECOND,
            DURATION_SECS,
            INITIAL_DEPOSIT
        );

        fast_forward_time(1800);

        // Try to withdraw with unauthorized account
        payment_stream::withdraw_streamed<AptosCoin>(&unauthorized, 1, SENDER_ADDR);
    }

    // Test 7: Withdrawal with no available amount
    #[test]
    #[expected_failure(abort_code = 0x10006)] // E_ALREADY_WITHDRAWN
    fun test_withdraw_no_amount_available() {
        let (sender, recipient, _stream_manager) = setup_test_env();
        
        // Create stream
        payment_stream::create_stream<AptosCoin>(
            &sender,
            RECIPIENT_ADDR,
            RATE_PER_SECOND,
            DURATION_SECS,
            INITIAL_DEPOSIT
        );

        // Try to withdraw immediately (no time passed)
        payment_stream::withdraw_streamed<AptosCoin>(&recipient, 1, SENDER_ADDR);
    }

    // Test 8: Successful stream cancellation
    #[test]
    fun test_cancel_stream_success() {
        let (sender, _recipient, _stream_manager) = setup_test_env();
        
        // Create stream
        payment_stream::create_stream<AptosCoin>(
            &sender,
            RECIPIENT_ADDR,
            RATE_PER_SECOND,
            DURATION_SECS,
            INITIAL_DEPOSIT
        );

        // Fast forward time by 1800 seconds
        fast_forward_time(1800);

        let initial_sender_balance = coin::balance<AptosCoin>(SENDER_ADDR);
        let initial_recipient_balance = coin::balance<AptosCoin>(RECIPIENT_ADDR);

        // Cancel stream
        payment_stream::cancel_stream<AptosCoin>(&sender, 1);

        // Verify recipient received streamed amount
        let recipient_balance = coin::balance<AptosCoin>(RECIPIENT_ADDR);
        let expected_recipient_amount = RATE_PER_SECOND * 1800;
        assert!(recipient_balance == initial_recipient_balance + expected_recipient_amount, 0);

        // Verify sender got refund
        let sender_balance = coin::balance<AptosCoin>(SENDER_ADDR);
        let expected_refund = INITIAL_DEPOSIT - expected_recipient_amount;
        assert!(sender_balance == initial_sender_balance + expected_refund, 1);

        // Verify stream status is cancelled
        let (_id, _sender, _recipient, _rate, _start, _end, _deposited, _withdrawn, status) = 
            payment_stream::get_stream_info<AptosCoin>(SENDER_ADDR);
        assert!(status == 3, 2); // STATUS_CANCELLED
    }

    // Test 9: Unauthorized cancellation
    #[test]
    #[expected_failure(abort_code = 0x50002)] // E_UNAUTHORIZED
    fun test_cancel_stream_unauthorized() {
        let (sender, recipient, _stream_manager) = setup_test_env();
        
        // Create stream
        payment_stream::create_stream<AptosCoin>(
            &sender,
            RECIPIENT_ADDR,
            RATE_PER_SECOND,
            DURATION_SECS,
            INITIAL_DEPOSIT
        );

        // Try to cancel with recipient account
        payment_stream::cancel_stream<AptosCoin>(&recipient, 1);
    }

    // Test 10: Successful stream top-up
    #[test]
    fun test_topup_stream_success() {
        let (sender, _recipient, _stream_manager) = setup_test_env();
        
        // Create stream
        payment_stream::create_stream<AptosCoin>(
            &sender,
            RECIPIENT_ADDR,
            RATE_PER_SECOND,
            DURATION_SECS,
            INITIAL_DEPOSIT
        );

        let topup_amount = 100000;
        
        // Top up stream
        payment_stream::topup_stream<AptosCoin>(&sender, 1, SENDER_ADDR, topup_amount);

        // Verify stream balance increased
        let stream_balance = payment_stream::get_stream_balance<AptosCoin>(SENDER_ADDR);
        assert!(stream_balance == INITIAL_DEPOSIT + topup_amount, 0);

        // Verify deposited amount updated
        let (_id, _sender, _recipient, _rate, _start, _end, deposited, _withdrawn, _status) = 
            payment_stream::get_stream_info<AptosCoin>(SENDER_ADDR);
        assert!(deposited == INITIAL_DEPOSIT + topup_amount, 1);
    }

    // Test 11: Pause and resume stream
    #[test]
    fun test_pause_resume_stream() {
        let (sender, recipient, _stream_manager) = setup_test_env();
        
        // Create stream
        payment_stream::create_stream<AptosCoin>(
            &sender,
            RECIPIENT_ADDR,
            RATE_PER_SECOND,
            DURATION_SECS,
            INITIAL_DEPOSIT
        );

        // Pause stream
        payment_stream::pause_stream<AptosCoin>(&sender, 1);

        // Verify stream is paused
        let (_id, _sender, _recipient, _rate, _start, _end, _deposited, _withdrawn, status) = 
            payment_stream::get_stream_info<AptosCoin>(SENDER_ADDR);
        assert!(status == 4, 0); // STATUS_PAUSED

        // Resume stream
        payment_stream::resume_stream<AptosCoin>(&sender, 1);

        // Verify stream is active again
        let (_id, _sender, _recipient, _rate, _start, _end, _deposited, _withdrawn, status) = 
            payment_stream::get_stream_info<AptosCoin>(SENDER_ADDR);
        assert!(status == 1, 1); // STATUS_ACTIVE
    }

    // Test 12: View functions
    #[test]
    fun test_view_functions() {
        let (sender, _recipient, _stream_manager) = setup_test_env();
        
        // Create stream
        payment_stream::create_stream<AptosCoin>(
            &sender,
            RECIPIENT_ADDR,
            RATE_PER_SECOND,
            DURATION_SECS,
            INITIAL_DEPOSIT
        );

        // Test get_stream_info
        let (stream_id, stream_sender, stream_recipient, rate, start_time, end_time, deposited, withdrawn, status) = 
            payment_stream::get_stream_info<AptosCoin>(SENDER_ADDR);
        
        assert!(stream_id == 1, 0);
        assert!(stream_sender == SENDER_ADDR, 1);
        assert!(stream_recipient == RECIPIENT_ADDR, 2);
        assert!(rate == RATE_PER_SECOND, 3);
        assert!(deposited == INITIAL_DEPOSIT, 4);
        assert!(withdrawn == 0, 5);
        assert!(status == 1, 6); // STATUS_ACTIVE

        // Test get_stream_balance
        let balance = payment_stream::get_stream_balance<AptosCoin>(SENDER_ADDR);
        assert!(balance == INITIAL_DEPOSIT, 7);

        // Test get_withdrawable_amount (initially 0)
        let withdrawable = payment_stream::get_withdrawable_amount<AptosCoin>(SENDER_ADDR);
        assert!(withdrawable == 0, 8);

        // Fast forward time and test withdrawable amount
        fast_forward_time(1800); // 30 minutes
        let withdrawable_after = payment_stream::get_withdrawable_amount<AptosCoin>(SENDER_ADDR);
        assert!(withdrawable_after == RATE_PER_SECOND * 1800, 9);
    }

    // Test 13: Stream completion
    #[test]
    fun test_stream_completion() {
        let (sender, recipient, _stream_manager) = setup_test_env();
        
        // Create stream
        payment_stream::create_stream<AptosCoin>(
            &sender,
            RECIPIENT_ADDR,
            RATE_PER_SECOND,
            DURATION_SECS,
            INITIAL_DEPOSIT
        );

        // Fast forward beyond end time
        fast_forward_time(DURATION_SECS + 100);

        // Withdraw all available tokens
        payment_stream::withdraw_streamed<AptosCoin>(&recipient, 1, SENDER_ADDR);

        // Verify stream is completed
        let (_id, _sender, _recipient, _rate, _start, _end, _deposited, _withdrawn, status) = 
            payment_stream::get_stream_info<AptosCoin>(SENDER_ADDR);
        assert!(status == 2, 0); // STATUS_COMPLETED

        // Verify recipient received full amount
        let recipient_balance = coin::balance<AptosCoin>(RECIPIENT_ADDR);
        assert!(recipient_balance == INITIAL_DEPOSIT, 1);
    }

    // Test 14: Utils module tests
    #[test]
    fun test_utils_functions() {
        // Test safe_div_round
        let result = utils::safe_div_round(100, 3);
        assert!(result == 33, 0); // 100/3 = 33.33, rounded to 33

        // Test safe_mul
        let result = utils::safe_mul(123, 456);
        assert!(result == 56088, 1);

        // Test calculate_percentage
        let result = utils::calculate_percentage(1000, 15, 100); // 15% of 1000
        assert!(result == 150, 2);

        // Test time conversion functions
        assert!(utils::seconds_to_hours(7200) == 2, 3);
        assert!(utils::hours_to_seconds(2) == 7200, 4);
        assert!(utils::days_to_seconds(1) == 86400, 5);
    }

    // Test 15: Edge case - multiple streams
    #[test]
    fun test_multiple_streams() {
        let (sender, _recipient, _stream_manager) = setup_test_env();
        let recipient2 = account::create_account_for_test(@0x400);
        coin::register<AptosCoin>(&recipient2);

        // Create first stream
        payment_stream::create_stream<AptosCoin>(
            &sender,
            RECIPIENT_ADDR,
            RATE_PER_SECOND,
            DURATION_SECS,
            INITIAL_DEPOSIT
        );

        // Move stream to sender's account, then create second stream
        let sender2 = account::create_account_for_test(@0x500);
        coin::register<AptosCoin>(&sender2);
        let coins = coin::mint_for_testing<AptosCoin>(INITIAL_BALANCE);
        coin::deposit(@0x500, coins);

        payment_stream::create_stream<AptosCoin>(
            &sender2,
            @0x400,
            RATE_PER_SECOND * 2,
            DURATION_SECS,
            INITIAL_DEPOSIT * 2
        );

        // Verify both streams exist with correct IDs
        let (stream_id1, _, _, _, _, _, _, _, _) = payment_stream::get_stream_info<AptosCoin>(SENDER_ADDR);
        let (stream_id2, _, _, _, _, _, _, _, _) = payment_stream::get_stream_info<AptosCoin>(@0x500);
        
        assert!(stream_id1 == 1, 0);
        assert!(stream_id2 == 2, 1);
    }
}