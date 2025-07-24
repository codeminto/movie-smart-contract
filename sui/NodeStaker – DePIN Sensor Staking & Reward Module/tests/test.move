#[test_only]
module move_depin_node_staker::node_staker_tests {
    use std::vector;
    use std::string::{Self, String};
    use std::option;
    use std::signer;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::{Self, AptosCoin};
    use aptos_framework::timestamp;
    use aptos_framework::account;
    use aptos_framework::ed25519;
    use aptos_std::debug;
    use move_depin_node_staker::node_staker::{Self, ProtocolState, Stake, ValidatorCap};

    // Test constants
    const ADMIN_ADDR: address = @0xADMIN;
    const OPERATOR1_ADDR: address = @0x1001;
    const OPERATOR2_ADDR: address = @0x1002;
    const OPERATOR3_ADDR: address = @0x1003;
    
    const MINIMUM_STAKE: u64 = 1000000000; // 10 APT
    const EPOCH_DURATION: u64 = 86400; // 24 hours
    const INITIAL_BALANCE: u64 = 10000000000; // 100 APT

    // Test helper functions
    fun setup_test_env(): (signer, signer, signer, signer) {
        let admin = account::create_account_for_test(ADMIN_ADDR);
        let operator1 = account::create_account_for_test(OPERATOR1_ADDR);
        let operator2 = account::create_account_for_test(OPERATOR2_ADDR);
        let operator3 = account::create_account_for_test(OPERATOR3_ADDR);
        
        // Initialize AptosCoin for testing
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&admin);
        
        // Mint coins for all accounts
        let admin_coins = coin::mint(INITIAL_BALANCE, &mint_cap);
        let op1_coins = coin::mint(INITIAL_BALANCE, &mint_cap);
        let op2_coins = coin::mint(INITIAL_BALANCE, &mint_cap);
        let op3_coins = coin::mint(INITIAL_BALANCE, &mint_cap);
        
        coin::register<AptosCoin>(&admin);
        coin::register<AptosCoin>(&operator1);
        coin::register<AptosCoin>(&operator2);
        coin::register<AptosCoin>(&operator3);
        
        coin::deposit(ADMIN_ADDR, admin_coins);
        coin::deposit(OPERATOR1_ADDR, op1_coins);
        coin::deposit(OPERATOR2_ADDR, op2_coins);
        coin::deposit(OPERATOR3_ADDR, op3_coins);
        
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
        
        (admin, operator1, operator2, operator3)
    }

    fun generate_test_keypair(): (vector<u8>, vector<u8>) {
        // Generate a test Ed25519 keypair
        let private_key = x"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let public_key = x"3b6a27bcceb6a42d62a3a8d02a6f0d73653215771de243a63ac048a18b59da29";
        (private_key, public_key)
    }

    fun create_test_signature(private_key: vector<u8>, message: vector<u8>): vector<u8> {
        // For testing purposes, we'll create a mock signature
        // In real implementation, this would use proper Ed25519 signing
        let signature = vector::empty<u8>();
        vector::append(&mut signature, private_key);
        vector::append(&mut signature, message);
        
        // Pad to 64 bytes for Ed25519 signature format
        while (vector::length(&signature) < 64) {
            vector::push_back(&mut signature, 0u8);
        };
        
        signature
    }

    // Test 1: Protocol Initialization
    #[test]
    fun test_initialize_protocol() {
        let (admin, _, _, _) = setup_test_env();
        
        // Initialize protocol
        node_staker::initialize(&admin);
        
        // Verify protocol state
        let (current_epoch, total_staked, total_nodes, reward_pool, epoch_start_time) = 
            node_staker::get_protocol_state();
        
        assert!(current_epoch == 0, 1);
        assert!(total_staked == 0, 2);
        assert!(total_nodes == 0, 3);
        assert!(reward_pool == 0, 4);
        assert!(epoch_start_time > 0, 5);
        
        debug::print(&string::utf8(b"✓ Protocol initialization test passed"));
    }

    #[test]
    #[expected_failure(abort_code = 0x80002)] // EALREADY_INITIALIZED
    fun test_initialize_twice_should_fail() {
        let (admin, _, _, _) = setup_test_env();
        
        node_staker::initialize(&admin);
        node_staker::initialize(&admin); // Should fail
    }

    // Test 2: Staking Operations
    #[test]
    fun test_stake_and_register() {
        let (admin, operator1, _, _) = setup_test_env();
        let (_, public_key) = generate_test_keypair();
        
        node_staker::initialize(&admin);
        
        let node_id = string::utf8(b"sensor_001");
        let stake_amount = MINIMUM_STAKE * 2; // 20 APT
        
        // Check initial balance
        let initial_balance = coin::balance<AptosCoin>(OPERATOR1_ADDR);
        
        // Stake and register
        node_staker::stake_and_register(&operator1, node_id, public_key, stake_amount);
        
        // Verify balance reduction
        let final_balance = coin::balance<AptosCoin>(OPERATOR1_ADDR);
        assert!(initial_balance - final_balance == stake_amount, 1);
        
        // Verify protocol state
        let (_, total_staked, total_nodes, _, _) = node_staker::get_protocol_state();
        assert!(total_staked == stake_amount, 2);
        assert!(total_nodes == 1, 3);
        
        // Verify node is active
        assert!(node_staker::is_node_active(node_id), 4);
        
        // Verify quality score is initialized
        assert!(node_staker::get_node_quality_score(node_id) == 100, 5);
        
        // Verify stake info
        let (stored_node_id, staked_amount, total_rewards, is_slashed, epoch_records_count) = 
            node_staker::get_node_stake_info(OPERATOR1_ADDR);
        assert!(stored_node_id == node_id, 6);
        assert!(staked_amount == stake_amount, 7);
        assert!(total_rewards == 0, 8);
        assert!(!is_slashed, 9);
        assert!(epoch_records_count == 0, 10);
        
        debug::print(&string::utf8(b"✓ Stake and register test passed"));
    }

    #[test]
    #[expected_failure(abort_code = 0x10003)] // EINVALID_STAKE_AMOUNT
    fun test_stake_insufficient_amount_should_fail() {
        let (admin, operator1, _, _) = setup_test_env();
        let (_, public_key) = generate_test_keypair();
        
        node_staker::initialize(&admin);
        
        let node_id = string::utf8(b"sensor_001");
        let insufficient_amount = MINIMUM_STAKE / 2;
        
        node_staker::stake_and_register(&operator1, node_id, public_key, insufficient_amount);
    }

    #[test]
    #[expected_failure(abort_code = 0x80005)] // EINVALID_VALIDATOR - duplicate node_id
    fun test_duplicate_node_registration_should_fail() {
        let (admin, operator1, operator2, _) = setup_test_env();
        let (_, public_key) = generate_test_keypair();
        
        node_staker::initialize(&admin);
        
        let node_id = string::utf8(b"sensor_001");
        
        node_staker::stake_and_register(&operator1, node_id, public_key, MINIMUM_STAKE);
        node_staker::stake_and_register(&operator2, node_id, public_key, MINIMUM_STAKE); // Should fail
    }

    // Test 3: Data Proof Submission
    #[test]
    fun test_submit_data_proof() {
        let (admin, operator1, _, _) = setup_test_env();
        let (private_key, public_key) = generate_test_keypair();
        
        node_staker::initialize(&admin);
        
        let node_id = string::utf8(b"sensor_001");
        node_staker::stake_and_register(&operator1, node_id, public_key, MINIMUM_STAKE);
        
        // Prepare data proof
        let data_hash = x"1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";
        let quality_metrics = vector[95u64, 88u64, 92u64]; // accuracy, timeliness, completeness
        
        // Create signature (mock for testing)
        let message = vector::empty<u8>();
        vector::append(&mut message, *string::bytes(&node_id));
        vector::append(&mut message, bcs::to_bytes(&0u64)); // current epoch
        vector::append(&mut message, data_hash);
        let signature = create_test_signature(private_key, message);
        
        // Submit proof (this might fail due to signature verification in real implementation)
        // For testing purposes, we'll assume the signature verification passes
        node_staker::submit_data_proof(&operator1, node_id, data_hash, signature, quality_metrics);
        
        // Verify quality score updated
        let quality_score = node_staker::get_node_quality_score(node_id);
        assert!(quality_score > 80, 1); // Should be average of initial 100 and calculated score
        
        debug::print(&string::utf8(b"✓ Data proof submission test passed"));
    }

    #[test]
    #[expected_failure(abort_code = 0x10005)] // EINVALID_VALIDATOR - non-existent validator
    fun test_submit_proof_unregistered_node_should_fail() {
        let (admin, operator1, _, _) = setup_test_env();
        
        node_staker::initialize(&admin);
        
        let node_id = string::utf8(b"sensor_001");
        let data_hash = x"1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";
        let signature = vector::empty<u8>();
        let quality_metrics = vector[95u64, 88u64, 92u64];
        
        node_staker::submit_data_proof(&operator1, node_id, data_hash, signature, quality_metrics);
    }

    // Test 4: Epoch Management and Rewards
    #[test]
    fun test_epoch_management_and_rewards() {
        let (admin, operator1, operator2, _) = setup_test_env();
        let (private_key1, public_key1) = generate_test_keypair();
        let (private_key2, public_key2) = generate_test_keypair();
        
        node_staker::initialize(&admin);
        
        // Add rewards to pool
        node_staker::add_reward_pool(&admin, 1000000000); // 10 APT
        
        // Register two validators
        let node_id1 = string::utf8(b"sensor_001");
        let node_id2 = string::utf8(b"sensor_002");
        
        node_staker::stake_and_register(&operator1, node_id1, public_key1, MINIMUM_STAKE);
        node_staker::stake_and_register(&operator2, node_id2, public_key2, MINIMUM_STAKE);
        
        // Submit proofs for both nodes
        let data_hash = x"1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";
        let quality_metrics_high = vector[95u64, 90u64, 92u64];
        let quality_metrics_low = vector[80u64, 75u64, 78u64];
        
        let message1 = vector::empty<u8>();
        vector::append(&mut message1, *string::bytes(&node_id1));
        vector::append(&mut message1, bcs::to_bytes(&0u64));
        vector::append(&mut message1, data_hash);
        let signature1 = create_test_signature(private_key1, message1);
        
        let message2 = vector::empty<u8>();
        vector::append(&mut message2, *string::bytes(&node_id2));
        vector::append(&mut message2, bcs::to_bytes(&0u64));
        vector::append(&mut message2, data_hash);
        let signature2 = create_test_signature(private_key2, message2);
        
        // Submit proofs
        node_staker::submit_data_proof(&operator1, node_id1, data_hash, signature1, quality_metrics_high);
        node_staker::submit_data_proof(&operator2, node_id2, data_hash, signature2, quality_metrics_low);
        
        // Fast forward time to end epoch
        timestamp::fast_forward_seconds(EPOCH_DURATION + 1);
        
        // End epoch and distribute rewards
        node_staker::end_epoch_and_distribute_rewards(&admin);
        
        // Verify epoch advanced
        let (current_epoch, _, _, _, _) = node_staker::get_protocol_state();
        assert!(current_epoch == 1, 1);
        
        // Verify rewards distributed (node1 should get more rewards due to higher quality)
        let (_, _, rewards1, _, records1) = node_staker::get_node_stake_info(OPERATOR1_ADDR);
        let (_, _, rewards2, _, records2) = node_staker::get_node_stake_info(OPERATOR2_ADDR);
        
        assert!(rewards1 > 0, 2);
        assert!(rewards2 > 0, 3);
        assert!(rewards1 > rewards2, 4); // Higher quality should get more rewards
        assert!(records1 == 1, 5);
        assert!(records2 == 1, 6);
        
        debug::print(&string::utf8(b"✓ Epoch management and rewards test passed"));
    }

    #[test]
    #[expected_failure(abort_code = 0x10007)] // EEPOCH_NOT_ENDED
    fun test_end_epoch_too_early_should_fail() {
        let (admin, _, _, _) = setup_test_env();
        
        node_staker::initialize(&admin);
        
        // Try to end epoch immediately (should fail)
        node_staker::end_epoch_and_distribute_rewards(&admin);
    }

    // Test 5: Slashing Mechanism
    #[test]
    fun test_slash_node() {
        let (admin, operator1, _, _) = setup_test_env();
        let (_, public_key) = generate_test_keypair();
        
        node_staker::initialize(&admin);
        
        let node_id = string::utf8(b"sensor_001");
        let stake_amount = MINIMUM_STAKE * 2;
        
        node_staker::stake_and_register(&operator1, node_id, public_key, stake_amount);
        
        // Verify initial state
        let (_, initial_staked, _, is_slashed_before, _) = node_staker::get_node_stake_info(OPERATOR1_ADDR);
        assert!(initial_staked == stake_amount, 1);
        assert!(!is_slashed_before, 2);
        assert!(node_staker::is_node_active(node_id), 3);
        
        // Slash the node
        let slash_reason = string::utf8(b"Invalid data detected");
        node_staker::slash_node(&admin, node_id, slash_reason);
        
        // Verify slashing effects
        let (_, final_staked, _, is_slashed_after, _) = node_staker::get_node_stake_info(OPERATOR1_ADDR);
        assert!(final_staked < initial_staked, 4); // Stake should be reduced
        assert!(is_slashed_after, 5);
        assert!(!node_staker::is_node_active(node_id), 6); // Should be removed from active validators
        
        // Calculate expected slash amount (10% of stake)
        let expected_slash_amount = (stake_amount * 10) / 100;
        let expected_remaining = stake_amount - expected_slash_amount;
        assert!(final_staked == expected_remaining, 7);
        
        // Verify protocol state updated
        let (_, total_staked, total_nodes, _, _) = node_staker::get_protocol_state();
        assert!(total_staked == expected_remaining, 8);
        assert!(total_nodes == 0, 9); // Node should be removed from active set
        
        debug::print(&string::utf8(b"✓ Slashing test passed"));
    }

    #[test]
    #[expected_failure(abort_code = 0x10009)] // ENODE_ALREADY_SLASHED
    fun test_slash_already_slashed_node_should_fail() {
        let (admin, operator1, _, _) = setup_test_env();
        let (_, public_key) = generate_test_keypair();
        
        node_staker::initialize(&admin);
        
        let node_id = string::utf8(b"sensor_001");
        node_staker::stake_and_register(&operator1, node_id, public_key, MINIMUM_STAKE);
        
        let slash_reason = string::utf8(b"Invalid data");
        node_staker::slash_node(&admin, node_id, slash_reason);
        node_staker::slash_node(&admin, node_id, slash_reason); // Should fail
    }

    // Test 6: Unstaking
    #[test]
    fun test_unstake() {
        let (admin, operator1, _, _) = setup_test_env();
        let (_, public_key) = generate_test_keypair();
        
        node_staker::initialize(&admin);
        
        let node_id = string::utf8(b"sensor_001");
        let stake_amount = MINIMUM_STAKE * 2;
        
        let initial_balance = coin::balance<AptosCoin>(OPERATOR1_ADDR);
        
        // Stake
        node_staker::stake_and_register(&operator1, node_id, public_key, stake_amount);
        
        let balance_after_stake = coin::balance<AptosCoin>(OPERATOR1_ADDR);
        assert!(initial_balance - balance_after_stake == stake_amount, 1);
        
        // Unstake
        node_staker::unstake(&operator1, node_id);
        
        let final_balance = coin::balance<AptosCoin>(OPERATOR1_ADDR);
        assert!(final_balance == initial_balance, 2); // Should get back original balance
        
        // Verify node is no longer active
        assert!(!node_staker::is_node_active(node_id), 3);
        
        // Verify protocol state
        let (_, total_staked, total_nodes, _, _) = node_staker::get_protocol_state();
        assert!(total_staked == 0, 4);
        assert!(total_nodes == 0, 5);
        
        debug::print(&string::utf8(b"✓ Unstaking test passed"));
    }

    #[test]
    #[expected_failure(abort_code = 0x60009)] // ENODE_ALREADY_SLASHED
    fun test_unstake_slashed_node_should_fail() {
        let (admin, operator1, _, _) = setup_test_env();
        let (_, public_key) = generate_test_keypair();
        
        node_staker::initialize(&admin);
        
        let node_id = string::utf8(b"sensor_001");
        node_staker::stake_and_register(&operator1, node_id, public_key, MINIMUM_STAKE);
        
        // Slash the node
        node_staker::slash_node(&admin, node_id, string::utf8(b"Malicious behavior"));
        
        // Try to unstake (should fail)
        node_staker::unstake(&operator1, node_id);
    }

    // Test 7: Reward Pool Management
    #[test]
    fun test_add_reward_pool() {
        let (admin, _, _, _) = setup_test_env();
        
        node_staker::initialize(&admin);
        
        let initial_admin_balance = coin::balance<AptosCoin>(ADMIN_ADDR);
        let reward_amount = 5000000000; // 50 APT
        
        // Add rewards to pool
        node_staker::add_reward_pool(&admin, reward_amount);
        
        // Verify admin balance reduced
        let final_admin_balance = coin::balance<AptosCoin>(ADMIN_ADDR);
        assert!(initial_admin_balance - final_admin_balance == reward_amount, 1);
        
        // Verify protocol state
        let (_, _, _, reward_pool, _) = node_staker::get_protocol_state();
        assert!(reward_pool == reward_amount, 2);
        
        debug::print(&string::utf8(b"✓ Reward pool management test passed"));
    }

    #[test]
    #[expected_failure(abort_code = 0x5000A)] // EUNAUTHORIZED
    fun test_non_admin_add_reward_pool_should_fail() {
        let (admin, operator1, _, _) = setup_test_env();
        
        node_staker::initialize(&admin);
        
        // Try to add rewards as non-admin (should fail)
        node_staker::add_reward_pool(&operator1, 1000000000);
    }

    // Test 8: Integration Test - Full Lifecycle
    #[test]
    fun test_full_lifecycle_integration() {
        let (admin, operator1, operator2, operator3) = setup_test_env();
        let (private_key1, public_key1) = generate_test_keypair();
        let (private_key2, public_key2) = generate_test_keypair();
        let (private_key3, public_key3) = generate_test_keypair();
        
        // Initialize protocol
        node_staker::initialize(&admin);
        
        // Add substantial reward pool
        node_staker::add_reward_pool(&admin, 10000000000); // 100 APT
        
        // Register three validators with different stake amounts
        let node_id1 = string::utf8(b"sensor_001");
        let node_id2 = string::utf8(b"sensor_002");
        let node_id3 = string::utf8(b"sensor_003");
        
        node_staker::stake_and_register(&operator1, node_id1, public_key1, MINIMUM_STAKE);
        node_staker::stake_and_register(&operator2, node_id2, public_key2, MINIMUM_STAKE * 2);
        node_staker::stake_and_register(&operator3, node_id3, public_key3, MINIMUM_STAKE * 3);
        
        // Verify all nodes are active
        assert!(node_staker::is_node_active(node_id1), 1);
        assert!(node_staker::is_node_active(node_id2), 2);
        assert!(node_staker::is_node_active(node_id3), 3);
        
        // Submit proofs with different quality levels
        let data_hash = x"abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890";
        
        // High quality proof from node 1
        let quality_high = vector[98u64, 95u64, 97u64];
        let message1 = vector::empty<u8>();
        vector::append(&mut message1, *string::bytes(&node_id1));
        vector::append(&mut message1, bcs::to_bytes(&0u64));
        vector::append(&mut message1, data_hash);
        let sig1 = create_test_signature(private_key1, message1);
        node_staker::submit_data_proof(&operator1, node_id1, data_hash, sig1, quality_high);
        
        // Medium quality proof from node 2
        let quality_medium = vector[85u64, 80u64, 88u64];
        let message2 = vector::empty<u8>();
        vector::append(&mut message2, *string::bytes(&node_id2));
        vector::append(&mut message2, bcs::to_bytes(&0u64));
        vector::append(&mut message2, data_hash);
        let sig2 = create_test_signature(private_key2, message2);
        node_staker::submit_data_proof(&operator2, node_id2, data_hash, sig2, quality_medium);
        
        // Low quality proof from node 3
        let quality_low = vector[70u64, 65u64, 72u64];
        let message3 = vector::empty<u8>();
        vector::append(&mut message3, *string::bytes(&node_id3));
        vector::append(&mut message3, bcs::to_bytes(&0u64));
        vector::append(&mut message3, data_hash);
        let sig3 = create_test_signature(private_key3, message3);
        node_staker::submit_data_proof(&operator3, node_id3, data_hash, sig3, quality_low);
        
        // Fast forward and end epoch
        timestamp::fast_forward_seconds(EPOCH_DURATION + 1);
        node_staker::end_epoch_and_distribute_rewards(&admin);
        
        // Verify rewards distributed proportionally
        let (_, _, rewards1, _, _) = node_staker::get_node_stake_info(OPERATOR1_ADDR);
        let (_, _, rewards2, _, _) = node_staker::get_node_stake_info(OPERATOR2_ADDR);
        let (_, _, rewards3, _, _) = node_staker::get_node_stake_info(OPERATOR3_ADDR);
        
        assert!(rewards1 > rewards2, 4);
        assert!(rewards2 > rewards3, 5);
        assert!(rewards1 > 0 && rewards2 > 0 && rewards3 > 0, 6);
        
        // Slash node 3 for poor performance
        node_staker::slash_node(&admin, node_id3, string::utf8(b"Consistently poor data quality"));
        
        // Verify slashing
        let (_, _, _, is_slashed, _) = node_staker::get_node_stake_info(OPERATOR3_ADDR);
        assert!(is_slashed, 7);
        assert!(!node_staker::is_node_active(node_id3), 8);
        
        // Node 1 unstakes successfully
        node_staker::unstake(&operator1, node_id1);
        assert!(!node_staker::is_node_active(node_id1), 9);
        
        // Verify final protocol state
        let (final_epoch, total_staked, total_nodes, _, _) = node_staker::get_protocol_state();
        assert!(final_epoch == 1, 10);
        assert!(total_nodes == 1, 11); // Only node 2 remains active
        assert!(total_staked > 0, 12); // Node 2's stake + remaining of slashed node 3
        
        debug::print(&string::utf8(b"✓ Full lifecycle integration test passed"));
    }

    // Test 9: Edge Cases and Error Conditions
    #[test]
    fun test_quality_score_calculation_edge_cases() {
        let (admin, operator1, _, _) = setup_test_env();
        let (private_key, public_key) = generate_test_keypair();
        
        node_staker::initialize(&admin);
        
        let node_id = string::utf8(b"sensor_001");
        node_staker::stake_and_register(&operator1, node_id, public_key, MINIMUM_STAKE);
        
        // Test with extreme values
        let data_hash = x"1111111111111111111111111111111111111111111111111111111111111111";
        
        // All maximum values
        let quality_extreme_high = vector[150u64, 200u64, 999u64]; // Values above max should be capped
        let message = vector::empty<u8>();
        vector::append(&mut message, *string::bytes(&node_id));
        vector::append(&mut message, bcs::to_bytes(&0u64));
        vector::append(&mut message, data_hash);
        let signature = create_test_signature(private_key, message);
        
        node_staker::submit_data_proof(&operator1, node_id, data_hash, signature, quality_extreme_high);
        
        let quality_score = node_staker::get_node_quality_score(node_id);
        assert!(quality_score <= 100, 1); // Should be capped at maximum
        
        debug::print(&string::utf8(b"✓ Quality score edge cases test passed"));
    }
}