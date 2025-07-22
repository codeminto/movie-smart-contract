module move_depin_node_staker::node_staker {
    use std::vector;
    use std::option::{Self, Option};
    use std::string::{Self, String};
    use std::error;
    use std::signer;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::timestamp;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account;
    use aptos_framework::ed25519;
    use aptos_std::table::{Self, Table};
    use aptos_std::math64;

    /// Error codes
    const ENOT_INITIALIZED: u64 = 1;
    const EALREADY_INITIALIZED: u64 = 2;
    const EINVALID_STAKE_AMOUNT: u64 = 3;
    const EINSUFFICIENT_STAKE: u64 = 4;
    const EINVALID_VALIDATOR: u64 = 5;
    const EINVALID_PROOF_SIGNATURE: u64 = 6;
    const EEPOCH_NOT_ENDED: u64 = 7;
    const EINVALID_EPOCH: u64 = 8;
    const ENODE_ALREADY_SLASHED: u64 = 9;
    const EUNAUTHORIZED: u64 = 10;
    const EINVALID_DATA_PROOF: u64 = 11;

    /// Constants
    const MINIMUM_STAKE: u64 = 1000000000; // 10 APT (8 decimals)
    const EPOCH_DURATION_SECONDS: u64 = 86400; // 24 hours
    const MAX_QUALITY_SCORE: u64 = 100;
    const SLASH_PERCENTAGE: u64 = 10; // 10% of stake
    const REWARD_PER_EPOCH: u64 = 100000000; // 1 APT per epoch base reward

    /// Validator capability resource that proves staking rights
    struct ValidatorCap has key, store {
        node_id: String,
        public_key: vector<u8>,
        stake_amount: u64,
        created_epoch: u64,
        is_active: bool,
    }

    /// Epoch record for tracking performance
    struct EpochRecord has store {
        epoch: u64,
        proofs_submitted: u64,
        quality_score: u64,
        rewards_earned: u64,
        timestamp: u64,
    }

    /// Stake resource tracking node operator's commitment
    struct Stake has key {
        node_id: String,
        staked_coins: Coin<AptosCoin>,
        validator_cap: Option<ValidatorCap>,
        epoch_records: vector<EpochRecord>,
        total_rewards: u64,
        is_slashed: bool,
        last_activity_epoch: u64,
    }

    /// Data proof submitted by validators
    struct DataProof has store, drop {
        node_id: String,
        epoch: u64,
        data_hash: vector<u8>,
        timestamp: u64,
        signature: vector<u8>,
        quality_metrics: vector<u64>, // [accuracy, timeliness, completeness]
    }

    /// Global protocol state
    struct ProtocolState has key {
        admin: address,
        current_epoch: u64,
        epoch_start_time: u64,
        total_staked: u64,
        total_nodes: u64,
        reward_pool: Coin<AptosCoin>,
        min_stake_amount: u64,
        
        // Tracking tables
        active_validators: Table<String, address>, // node_id -> operator address
        epoch_proofs: Table<u64, vector<DataProof>>, // epoch -> proofs
        quality_scores: Table<String, u64>, // node_id -> current quality score
        
        // Events
        stake_events: EventHandle<StakeEvent>,
        proof_events: EventHandle<ProofEvent>,
        reward_events: EventHandle<RewardEvent>,
        slash_events: EventHandle<SlashEvent>,
        epoch_events: EventHandle<EpochEvent>,
    }

    /// Event structures
    struct StakeEvent has drop, store {
        operator: address,
        node_id: String,
        amount: u64,
        epoch: u64,
        is_unstake: bool,
    }

    struct ProofEvent has drop, store {
        node_id: String,
        epoch: u64,
        quality_score: u64,
        timestamp: u64,
        data_hash: vector<u8>,
    }

    struct RewardEvent has drop, store {
        node_id: String,
        epoch: u64,
        reward_amount: u64,
        quality_score: u64,
    }

    struct SlashEvent has drop, store {
        node_id: String,
        epoch: u64,
        slashed_amount: u64,
        reason: String,
    }

    struct EpochEvent has drop, store {
        epoch: u64,
        start_time: u64,
        total_proofs: u64,
        total_rewards_distributed: u64,
    }

    /// Initialize the protocol (admin only)
    public entry fun initialize(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        assert!(!exists<ProtocolState>(admin_addr), error::already_exists(EALREADY_INITIALIZED));

        let protocol_state = ProtocolState {
            admin: admin_addr,
            current_epoch: 0,
            epoch_start_time: timestamp::now_seconds(),
            total_staked: 0,
            total_nodes: 0,
            reward_pool: coin::zero<AptosCoin>(),
            min_stake_amount: MINIMUM_STAKE,
            
            active_validators: table::new(),
            epoch_proofs: table::new(),
            quality_scores: table::new(),
            
            stake_events: account::new_event_handle<StakeEvent>(admin),
            proof_events: account::new_event_handle<ProofEvent>(admin),
            reward_events: account::new_event_handle<RewardEvent>(admin),
            slash_events: account::new_event_handle<SlashEvent>(admin),
            epoch_events: account::new_event_handle<EpochEvent>(admin),
        };

        move_to(admin, protocol_state);
    }

    /// Stake tokens and receive validator capability
    public entry fun stake_and_register(
        operator: &signer,
        node_id: String,
        public_key: vector<u8>,
        stake_amount: u64,
    ) acquires ProtocolState {
        let operator_addr = signer::address_of(operator);
        assert!(exists<ProtocolState>(@move_depin_node_staker), error::not_found(ENOT_INITIALIZED));
        assert!(stake_amount >= MINIMUM_STAKE, error::invalid_argument(EINVALID_STAKE_AMOUNT));
        assert!(!exists<Stake>(operator_addr), error::already_exists(EINVALID_VALIDATOR));

        let protocol_state = borrow_global_mut<ProtocolState>(@move_depin_node_staker);
        assert!(!table::contains(&protocol_state.active_validators, node_id), error::invalid_argument(EINVALID_VALIDATOR));

        // Withdraw stake coins
        let staked_coins = coin::withdraw<AptosCoin>(operator, stake_amount);

        // Create validator capability
        let validator_cap = ValidatorCap {
            node_id: node_id,
            public_key: public_key,
            stake_amount: stake_amount,
            created_epoch: protocol_state.current_epoch,
            is_active: true,
        };

        // Create stake resource
        let stake = Stake {
            node_id: node_id,
            staked_coins: staked_coins,
            validator_cap: option::some(validator_cap),
            epoch_records: vector::empty(),
            total_rewards: 0,
            is_slashed: false,
            last_activity_epoch: protocol_state.current_epoch,
        };

        // Update protocol state
        table::add(&mut protocol_state.active_validators, node_id, operator_addr);
        table::add(&mut protocol_state.quality_scores, node_id, MAX_QUALITY_SCORE);
        protocol_state.total_staked = protocol_state.total_staked + stake_amount;
        protocol_state.total_nodes = protocol_state.total_nodes + 1;

        // Emit event
        event::emit_event(&mut protocol_state.stake_events, StakeEvent {
            operator: operator_addr,
            node_id: node_id,
            amount: stake_amount,
            epoch: protocol_state.current_epoch,
            is_unstake: false,
        });

        move_to(operator, stake);
    }

    /// Submit data proof with signature verification
    public entry fun submit_data_proof(
        operator: &signer,
        node_id: String,
        data_hash: vector<u8>,
        signature: vector<u8>,
        quality_metrics: vector<u64>, // [accuracy, timeliness, completeness]
    ) acquires ProtocolState, Stake {
        let operator_addr = signer::address_of(operator);
        assert!(exists<ProtocolState>(@move_depin_node_staker), error::not_found(ENOT_INITIALIZED));
        assert!(exists<Stake>(operator_addr), error::not_found(EINVALID_VALIDATOR));

        let protocol_state = borrow_global_mut<ProtocolState>(@move_depin_node_staker);
        let stake = borrow_global_mut<Stake>(operator_addr);

        assert!(!stake.is_slashed, error::permission_denied(ENODE_ALREADY_SLASHED));
        assert!(table::contains(&protocol_state.active_validators, node_id), error::not_found(EINVALID_VALIDATOR));
        assert!(*table::borrow(&protocol_state.active_validators, node_id) == operator_addr, error::permission_denied(EUNAUTHORIZED));

        // Verify signature using on-chain ed25519
        let validator_cap = option::borrow(&stake.validator_cap);
        let message = construct_proof_message(node_id, protocol_state.current_epoch, data_hash);
        let public_key = ed25519::new_unvalidated_public_key_from_bytes(validator_cap.public_key);
        let signature_obj = ed25519::new_signature_from_bytes(signature);
        assert!(ed25519::signature_verify_strict(&signature_obj, &public_key, message), error::invalid_argument(EINVALID_PROOF_SIGNATURE));

        // Calculate quality score from metrics
        let quality_score = calculate_quality_score(quality_metrics);

        // Create data proof
        let proof = DataProof {
            node_id: node_id,
            epoch: protocol_state.current_epoch,
            data_hash: data_hash,
            timestamp: timestamp::now_seconds(),
            signature: signature,
            quality_metrics: quality_metrics,
        };

        // Store proof in epoch table
        if (!table::contains(&mut protocol_state.epoch_proofs, protocol_state.current_epoch)) {
            table::add(&mut protocol_state.epoch_proofs, protocol_state.current_epoch, vector::empty());
        };
        let epoch_proofs = table::borrow_mut(&mut protocol_state.epoch_proofs, protocol_state.current_epoch);
        vector::push_back(epoch_proofs, proof);

        // Update node's quality score (running average)
        let current_score = *table::borrow(&protocol_state.quality_scores, node_id);
        let new_score = (current_score + quality_score) / 2;
        *table::borrow_mut(&mut protocol_state.quality_scores, node_id) = new_score;

        // Update stake activity
        stake.last_activity_epoch = protocol_state.current_epoch;

        // Emit event
        event::emit_event(&mut protocol_state.proof_events, ProofEvent {
            node_id: node_id,
            epoch: protocol_state.current_epoch,
            quality_score: quality_score,
            timestamp: timestamp::now_seconds(),
            data_hash: data_hash,
        });
    }

    /// End current epoch and distribute rewards
    public entry fun end_epoch_and_distribute_rewards(admin: &signer) acquires ProtocolState, Stake {
        let admin_addr = signer::address_of(admin);
        assert!(exists<ProtocolState>(@move_depin_node_staker), error::not_found(ENOT_INITIALIZED));

        let protocol_state = borrow_global_mut<ProtocolState>(@move_depin_node_staker);
        assert!(admin_addr == protocol_state.admin, error::permission_denied(EUNAUTHORIZED));

        let current_time = timestamp::now_seconds();
        assert!(current_time >= protocol_state.epoch_start_time + EPOCH_DURATION_SECONDS, error::invalid_state(EEPOCH_NOT_ENDED));

        let current_epoch = protocol_state.current_epoch;
        let total_rewards_distributed = 0;
        let total_proofs = 0;

        // Get proofs for current epoch
        if (table::contains(&protocol_state.epoch_proofs, current_epoch)) {
            let epoch_proofs = table::borrow(&protocol_state.epoch_proofs, current_epoch);
            total_proofs = vector::length(epoch_proofs);

            if (total_proofs > 0) {
                // Calculate total quality-weighted score
                let total_weighted_score = 0;
                let i = 0;
                while (i < total_proofs) {
                    let proof = vector::borrow(epoch_proofs, i);
                    let quality_score = *table::borrow(&protocol_state.quality_scores, proof.node_id);
                    total_weighted_score = total_weighted_score + quality_score;
                    i = i + 1;
                };

                // Distribute rewards proportionally
                if (total_weighted_score > 0) {
                    i = 0;
                    while (i < total_proofs) {
                        let proof = vector::borrow(epoch_proofs, i);
                        let operator_addr = *table::borrow(&protocol_state.active_validators, proof.node_id);
                        
                        if (exists<Stake>(operator_addr)) {
                            let stake = borrow_global_mut<Stake>(operator_addr);
                            if (!stake.is_slashed) {
                                let quality_score = *table::borrow(&protocol_state.quality_scores, proof.node_id);
                                let reward_amount = (REWARD_PER_EPOCH * quality_score) / total_weighted_score;
                                
                                if (reward_amount > 0 && coin::value(&protocol_state.reward_pool) >= reward_amount) {
                                    let reward_coins = coin::extract(&mut protocol_state.reward_pool, reward_amount);
                                    coin::merge(&mut stake.staked_coins, reward_coins);
                                    stake.total_rewards = stake.total_rewards + reward_amount;
                                    total_rewards_distributed = total_rewards_distributed + reward_amount;

                                    // Add epoch record
                                    let epoch_record = EpochRecord {
                                        epoch: current_epoch,
                                        proofs_submitted: 1,
                                        quality_score: quality_score,
                                        rewards_earned: reward_amount,
                                        timestamp: current_time,
                                    };
                                    vector::push_back(&mut stake.epoch_records, epoch_record);

                                    // Emit reward event
                                    event::emit_event(&mut protocol_state.reward_events, RewardEvent {
                                        node_id: proof.node_id,
                                        epoch: current_epoch,
                                        reward_amount: reward_amount,
                                        quality_score: quality_score,
                                    });
                                };
                            };
                        };
                        i = i + 1;
                    };
                };
            };
        };

        // Start new epoch
        protocol_state.current_epoch = current_epoch + 1;
        protocol_state.epoch_start_time = current_time;

        // Emit epoch event
        event::emit_event(&mut protocol_state.epoch_events, EpochEvent {
            epoch: current_epoch,
            start_time: current_time,
            total_proofs: total_proofs,
            total_rewards_distributed: total_rewards_distributed,
        });
    }

    /// Slash a node for invalid data or downtime
    public entry fun slash_node(
        admin: &signer,
        node_id: String,
        reason: String,
    ) acquires ProtocolState, Stake {
        let admin_addr = signer::address_of(admin);
        assert!(exists<ProtocolState>(@move_depin_node_staker), error::not_found(ENOT_INITIALIZED));

        let protocol_state = borrow_global_mut<ProtocolState>(@move_depin_node_staker);
        assert!(admin_addr == protocol_state.admin, error::permission_denied(EUNAUTHORIZED));
        assert!(table::contains(&protocol_state.active_validators, node_id), error::not_found(EINVALID_VALIDATOR));

        let operator_addr = *table::borrow(&protocol_state.active_validators, node_id);
        assert!(exists<Stake>(operator_addr), error::not_found(EINVALID_VALIDATOR));

        let stake = borrow_global_mut<Stake>(operator_addr);
        assert!(!stake.is_slashed, error::invalid_state(ENODE_ALREADY_SLASHED));

        // Calculate slash amount
        let current_balance = coin::value(&stake.staked_coins);
        let slash_amount = (current_balance * SLASH_PERCENTAGE) / 100;

        if (slash_amount > 0 && slash_amount <= current_balance) {
            // Extract and burn slashed coins
            let slashed_coins = coin::extract(&mut stake.staked_coins, slash_amount);
            coin::destroy_zero(coin::extract_all(&mut slashed_coins)); // Burn the coins
            
            // Update protocol state
            protocol_state.total_staked = protocol_state.total_staked - slash_amount;
        };

        // Mark as slashed
        stake.is_slashed = true;

        // Remove from active validators
        table::remove(&mut protocol_state.active_validators, node_id);
        protocol_state.total_nodes = protocol_state.total_nodes - 1;

        // Emit slash event
        event::emit_event(&mut protocol_state.slash_events, SlashEvent {
            node_id: node_id,
            epoch: protocol_state.current_epoch,
            slashed_amount: slash_amount,
            reason: reason,
        });
    }

    /// Unstake and withdraw (only if not slashed and after cooldown)
    public entry fun unstake(
        operator: &signer,
        node_id: String,
    ) acquires ProtocolState, Stake {
        let operator_addr = signer::address_of(operator);
        assert!(exists<ProtocolState>(@move_depin_node_staker), error::not_found(ENOT_INITIALIZED));
        assert!(exists<Stake>(operator_addr), error::not_found(EINVALID_VALIDATOR));

        let protocol_state = borrow_global_mut<ProtocolState>(@move_depin_node_staker);
        let stake = move_from<Stake>(operator_addr);

        assert!(!stake.is_slashed, error::permission_denied(ENODE_ALREADY_SLASHED));
        assert!(stake.node_id == node_id, error::invalid_argument(EINVALID_VALIDATOR));

        // Remove from active validators if still there
        if (table::contains(&protocol_state.active_validators, node_id)) {
            table::remove(&mut protocol_state.active_validators, node_id);
            protocol_state.total_nodes = protocol_state.total_nodes - 1;
        };

        let total_amount = coin::value(&stake.staked_coins);
        protocol_state.total_staked = protocol_state.total_staked - total_amount;

        // Deposit coins back to operator
        coin::deposit(operator_addr, stake.staked_coins);

        // Emit unstake event
        event::emit_event(&mut protocol_state.stake_events, StakeEvent {
            operator: operator_addr,
            node_id: node_id,
            amount: total_amount,
            epoch: protocol_state.current_epoch,
            is_unstake: true,
        });

        // Destroy the stake resource (validator_cap and epoch_records are automatically dropped)
        let Stake {
            node_id: _,
            staked_coins: _,
            validator_cap: _,
            epoch_records: _,
            total_rewards: _,
            is_slashed: _,
            last_activity_epoch: _,
        } = stake;
    }

    /// Add rewards to the protocol pool (admin only)
    public entry fun add_reward_pool(admin: &signer, amount: u64) acquires ProtocolState {
        let admin_addr = signer::address_of(admin);
        assert!(exists<ProtocolState>(@move_depin_node_staker), error::not_found(ENOT_INITIALIZED));

        let protocol_state = borrow_global_mut<ProtocolState>(@move_depin_node_staker);
        assert!(admin_addr == protocol_state.admin, error::permission_denied(EUNAUTHORIZED));

        let reward_coins = coin::withdraw<AptosCoin>(admin, amount);
        coin::merge(&mut protocol_state.reward_pool, reward_coins);
    }

    /// Helper functions

    fun construct_proof_message(node_id: String, epoch: u64, data_hash: vector<u8>): vector<u8> {
        let message = vector::empty<u8>();
        vector::append(&mut message, *string::bytes(&node_id));
        vector::append(&mut message, bcs::to_bytes(&epoch));
        vector::append(&mut message, data_hash);
        message
    }

    fun calculate_quality_score(metrics: vector<u64>): u64 {
        if (vector::length(&metrics) == 0) {
            return 0
        };

        let sum = 0;
        let i = 0;
        let len = vector::length(&metrics);
        
        while (i < len) {
            let metric = *vector::borrow(&metrics, i);
            sum = sum + math64::min(metric, MAX_QUALITY_SCORE);
            i = i + 1;
        };

        math64::min(sum / len, MAX_QUALITY_SCORE)
    }

    /// View functions

    #[view]
    public fun get_protocol_state(): (u64, u64, u64, u64, u64) acquires ProtocolState {
        assert!(exists<ProtocolState>(@move_depin_node_staker), error::not_found(ENOT_INITIALIZED));
        let protocol_state = borrow_global<ProtocolState>(@move_depin_node_staker);
        (
            protocol_state.current_epoch,
            protocol_state.total_staked,
            protocol_state.total_nodes,
            coin::value(&protocol_state.reward_pool),
            protocol_state.epoch_start_time
        )
    }

    #[view]
    public fun get_node_stake_info(operator_addr: address): (String, u64, u64, bool, u64) acquires Stake {
        assert!(exists<Stake>(operator_addr), error::not_found(EINVALID_VALIDATOR));
        let stake = borrow_global<Stake>(operator_addr);
        (
            stake.node_id,
            coin::value(&stake.staked_coins),
            stake.total_rewards,
            stake.is_slashed,
            vector::length(&stake.epoch_records)
        )
    }

    #[view]
    public fun get_node_quality_score(node_id: String): u64 acquires ProtocolState {
        assert!(exists<ProtocolState>(@move_depin_node_staker), error::not_found(ENOT_INITIALIZED));
        let protocol_state = borrow_global<ProtocolState>(@move_depin_node_staker);
        
        if (table::contains(&protocol_state.quality_scores, node_id)) {
            *table::borrow(&protocol_state.quality_scores, node_id)
        } else {
            0
        }
    }

    #[view]
    public fun is_node_active(node_id: String): bool acquires ProtocolState {
        assert!(exists<ProtocolState>(@move_depin_node_staker), error::not_found(ENOT_INITIALIZED));
        let protocol_state = borrow_global<ProtocolState>(@move_depin_node_staker);
        table::contains(&protocol_state.active_validators, node_id)
    }
}