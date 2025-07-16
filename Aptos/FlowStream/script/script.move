script {
    use std::signer;
    use std::debug;
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::timestamp;
    use addr::payment_stream;

    // Script for initializing the payment stream system
    fun initialize_payment_stream(admin: &signer) {
        payment_stream::initialize(admin);
        debug::print(&b"Payment stream system initialized successfully!");
    }
}

script {
    use std::signer;
    use std::debug;
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::AptosCoin;
    use addr::payment_stream;

    // Script for creating a new payment stream
    fun create_payment_stream(
        sender: &signer,
        recipient: address,
        rate_per_second: u64,
        duration_secs: u64,
        initial_deposit: u64
    ) {
        // Register for AptosCoin if not already registered
        if (!coin::is_account_registered<AptosCoin>(signer::address_of(sender))) {
            coin::register<AptosCoin>(sender);
        };

        // Create the stream
        payment_stream::create_stream<AptosCoin>(
            sender,
            recipient,
            rate_per_second,
            duration_secs,
            initial_deposit
        );

        debug::print(&b"Payment stream created successfully!");
        
        // Get and display stream info
        let (stream_id, stream_sender, stream_recipient, rate, start_time, end_time, deposited, withdrawn, status) = 
            payment_stream::get_stream_info<AptosCoin>(signer::address_of(sender));
        
        debug::print(&b"Stream ID: ");
        debug::print(&stream_id);
        debug::print(&b"Rate per second: ");
        debug::print(&rate);
        debug::print(&b"Duration: ");
        debug::print(&(end_time - start_time));
        debug::print(&b"Initial deposit: ");
        debug::print(&deposited);
    }
}

script {
    use std::signer;
    use std::debug;
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::AptosCoin;
    use addr::payment_stream;

    // Script for withdrawing streamed tokens
    fun withdraw_streamed_tokens(
        recipient: &signer,
        stream_id: u64,
        stream_owner: address
    ) {
        // Register for AptosCoin if not already registered
        if (!coin::is_account_registered<AptosCoin>(signer::address_of(recipient))) {
            coin::register<AptosCoin>(recipient);
        };

        // Check withdrawable amount before withdrawal
        let withdrawable_before = payment_stream::get_withdrawable_amount<AptosCoin>(stream_owner);
        debug::print(&b"Withdrawable amount: ");
        debug::print(&withdrawable_before);

        if (withdrawable_before > 0) {
            // Withdraw streamed tokens
            payment_stream::withdraw_streamed<AptosCoin>(recipient, stream_id, stream_owner);
            
            debug::print(&b"Withdrawal successful!");
            debug::print(&b"Amount withdrawn: ");
            debug::print(&withdrawable_before);
            
            // Display updated recipient balance
            let recipient_balance = coin::balance<AptosCoin>(signer::address_of(recipient));
            debug::print(&b"New recipient balance: ");
            debug::print(&recipient_balance);
        } else {
            debug::print(&b"No tokens available for withdrawal at this time");
        }
    }
}

script {
    use std::signer;
    use std::debug;
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::AptosCoin;
    use addr::payment_stream;

    // Script for canceling a payment stream
    fun cancel_payment_stream(
        sender: &signer,
        stream_id: u64
    ) {
        let sender_addr = signer::address_of(sender);
        
        // Get stream info before cancellation
        let (_, _, recipient, _, _, _, deposited, withdrawn, _) = 
            payment_stream::get_stream_info<AptosCoin>(sender_addr);
        
        let withdrawable = payment_stream::get_withdrawable_amount<AptosCoin>(sender_addr);
        let refund_amount = deposited - withdrawn - withdrawable;
        
        debug::print(&b"Canceling stream...");
        debug::print(&b"Amount to be sent to recipient: ");
        debug::print(&withdrawable);
        debug::print(&b"Refund amount to sender: ");
        debug::print(&refund_amount);
        
        // Cancel the stream
        payment_stream::cancel_stream<AptosCoin>(sender, stream_id);
        
        debug::print(&b"Stream canceled successfully!");
        
        // Display updated balances
        let sender_balance = coin::balance<AptosCoin>(sender_addr);
        let recipient_balance = coin::balance<AptosCoin>(recipient);
        
        debug::print(&b"Sender balance after cancellation: ");
        debug::print(&sender_balance);
        debug::print(&b"Recipient balance after cancellation: ");
        debug::print(&recipient_balance);
    }
}

script {
    use std::signer;
    use std::debug;
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::AptosCoin;
    use addr::payment_stream;

    // Script for topping up a payment stream
    fun topup_payment_stream(
        sender: &signer,
        stream_id: u64,
        stream_owner: address,
        amount: u64
    ) {
        // Get current stream balance
        let balance_before = payment_stream::get_stream_balance<AptosCoin>(stream_owner);
        
        debug::print(&b"Current stream balance: ");
        debug::print(&balance_before);
        debug::print(&b"Adding top-up amount: ");
        debug::print(&amount);
        
        // Top up the stream
        payment_stream::topup_stream<AptosCoin>(sender, stream_id, stream_owner, amount);
        
        // Get updated balance
        let balance_after = payment_stream::get_stream_balance<AptosCoin>(stream_owner);
        
        debug::print(&b"Stream topped up successfully!");
        debug::print(&b"New stream balance: ");
        debug::print(&balance_after);
        
        // Display sender's remaining balance
        let sender_balance = coin::balance<AptosCoin>(signer::address_of(sender));
        debug::print(&b"Sender's remaining balance: ");
        debug::print(&sender_balance);
    }
}

script {
    use std::signer;
    use std::debug;
    use addr::payment_stream;

    // Script for pausing a payment stream
    fun pause_payment_stream(
        sender: &signer,
        stream_id: u64
    ) {
        let sender_addr = signer::address_of(sender);
        
        debug::print(&b"Pausing stream...");
        
        // Pause the stream
        payment_stream::pause_stream<AptosCoin>(sender, stream_id);
        
        debug::print(&b"Stream paused successfully!");
        
        // Verify stream status
        let (_, _, _, _, _, _, _, _, status) = 
            payment_stream::get_stream_info<AptosCoin>(sender_addr);
        
        debug::print(&b"Stream status (4 = paused): ");
        debug::print(&status);
    }
}

script {
    use std::signer;
    use std::debug;
    use addr::payment_stream;

    // Script for resuming a payment stream
    fun resume_payment_stream(
        sender: &signer,
        stream_id: u64
    ) {
        let sender_addr = signer::address_of(sender);
        
        debug::print(&b"Resuming stream...");
        
        // Resume the stream
        payment_stream::resume_stream<AptosCoin>(sender, stream_id);
        
        debug::print(&b"Stream resumed successfully!");
        
        // Verify stream status
        let (_, _, _, _, _, _, _, _, status) = 
            payment_stream::get_stream_info<AptosCoin>(sender_addr);
        
        debug::print(&b"Stream status (1 = active): ");
        debug::print(&status);
    }
}

script {
    use std::debug;
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::timestamp;
    use addr::payment_stream;

    // Script for querying stream information
    fun query_stream_info(stream_owner: address) {
        debug::print(&b"=== Stream Information ===");
        
        // Get stream info
        let (stream_id, sender, recipient, rate_per_second, start_time, end_time, deposited, withdrawn, status) = 
            payment_stream::get_stream_info<AptosCoin>(stream_owner);
        
        debug::print(&b"Stream ID: ");
        debug::print(&stream_id);
        debug::print(&b"Sender: ");
        debug::print(&sender);
        debug::print(&b"Recipient: ");
        debug::print(&recipient);
        debug::print(&b"Rate per second: ");
        debug::print(&rate_per_second);
        debug::print(&b"Start time: ");
        debug::print(&start_time);
        debug::print(&b"End time: ");
        debug::print(&end_time);
        debug::print(&b"Total deposited: ");
        debug::print(&deposited);
        debug::print(&b"Total withdrawn: ");
        debug::print(&withdrawn);
        debug::print(&b"Status: ");
        debug::print(&status);
        
        // Get current stream balance
        let balance = payment_stream::get_stream_balance<AptosCoin>(stream_owner);
        debug::print(&b"Current stream balance: ");
        debug::print(&balance);
        
        // Get withdrawable amount
        let withdrawable = payment_stream::get_withdrawable_amount<AptosCoin>(stream_owner);
        debug::print(&b"Withdrawable amount: ");
        debug::print(&withdrawable);
        
        // Calculate time information
        let current_time = timestamp::now_seconds();
        debug::print(&b"Current time: ");
        debug::print(&current_time);
        
        if (current_time < start_time) {
            debug::print(&b"Stream hasn't started yet");
        } else if (current_time >= end_time) {
            debug::print(&b"Stream has ended");
        } else {
            let elapsed = current_time - start_time;
            let remaining = end_time - current_time;
            debug::print(&b"Time elapsed (seconds): ");
            debug::print(&elapsed);
            debug::print(&b"Time remaining (seconds): ");
            debug::print(&remaining);
        };
        
        // Status interpretation
        if (status == 1) {
            debug::print(&b"Status: ACTIVE");
        } else if (status == 2) {
            debug::print(&b"Status: COMPLETED");
        } else if (status == 3) {
            debug::print(&b"Status: CANCELLED");
        } else if (status == 4) {
            debug::print(&b"Status: PAUSED");
        } else {
            debug::print(&b"Status: UNKNOWN");
        };
    }
}

script {