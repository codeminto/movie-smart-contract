module addr::governance {
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::object::{Self, UID};
    use sui::option::{Self, Option};
    use sui::string::{Self, String};
    use sui::event;

    // Error codes
    const E_NOT_INITIALIZED: u64 = 1;
    const E_ALREADY_INITIALIZED: u64 = 2;
    const E_NOT_AUTHORIZED: u64 = 3;
    const E_INVALID_PROPOSAL: u64 = 4;
    const E_PROPOSAL_NOT_FOUND: u64 = 5;
    const E_VOTING_ENDED: u64 = 6;
    const E_VOTING_NOT_ENDED: u64 = 7;
    const E_PROPOSAL_NOT_SUCCEEDED: u64 = 8;
    const E_TIMELOCK_NOT_EXPIRED: u64 = 9;
    const E_PROPOSAL_ALREADY_EXECUTED: u64 = 10;
    const E_INSUFFICIENT_VOTING_POWER: u64 = 11;
    const E_INVALID_VOTING_PERIOD: u64 = 12;
    const E_INVALID_TIMELOCK_DELAY: u64 = 13;
    const E_PROPOSAL_VETOED: u64 = 14;

    // Proposal states
    const PROPOSAL_STATE_DRAFT: u8 = 0;
    const PROPOSAL_STATE_ACTIVE: u8 = 1;
    const PROPOSAL_STATE_SUCCEEDED: u8 = 2;
    const PROPOSAL_STATE_QUEUED: u8 = 3;
    const PROPOSAL_STATE_EXECUTED: u8 = 4;
    const PROPOSAL_STATE_FAILED: u8 = 5;
    const PROPOSAL_STATE_VETOED: u8 = 6;

    // Voting strategies
    const STRATEGY_SIMPLE_MAJORITY: u8 = 0;
    const STRATEGY_QUADRATIC: u8 = 1;
    const STRATEGY_WEIGHTED: u8 = 2;

    // Minimum voting period (1 day in seconds)
    const MIN_VOTING_PERIOD: u64 = 86400;
    // Minimum timelock delay (1 hour in seconds)
    const MIN_TIMELOCK_DELAY: u64 = 3600;

    /// Core DAO object containing configuration and capabilities
    struct DAO has key, store {
        id: UID,
        name: String,
        config: DAOConfig,
        treasury: Treasury,
        proposal_counter: u64,
        total_voting_power: u64,
        upgrade_authority: Option<address>, // In Sui, module upgrades are more direct
    }

    /// DAO configuration parameters
    struct DAOConfig has store, copy, drop {
        voting_period: u64,
        timelock_delay: u64,
        quorum_threshold: u64, // basis points (e.g., 2500 = 25%)
        proposal_threshold: u64, // minimum voting power to create proposal
        voting_strategy: u8,
        veto_enabled: bool,
        veto_authority: Option<address>,
    }

    /// Treasury holding multi-asset vault
    struct Treasury has store {
        aptos_balance: Coin<SUI>,
        // In Sui, you'd generally manage different coin types
        // as separate Coin<T> objects, or use dynamic fields
        // if the types are not known at compile time.
    }

    /// Individual proposal
    struct Proposal has key, store {
        id: UID, // Sui UID for the proposal object
        dao_id: object::ID, // ID of the DAO this proposal belongs to
        proposer: address,
        title: String,
        description: String,
        start_time_ms: u64, // Storing in milliseconds for consistency with Sui's timestamp
        end_time_ms: u64,
        execution_time_ms: u64,
        state: u8,
        for_votes: u64,
        against_votes: u64,
        abstain_votes: u64,
        actions: vector<ProposalAction>,
        executed: bool,
        vetoed: bool,
    }

    /// Action to be executed if proposal passes
    struct ProposalAction has store, copy, drop {
        target: address,
        function_name: String,
        args: vector<u8>,
        value: u64, // Amount of SUI to transfer
    }

    /// Vote delegation mapping (Shared Object)
    struct DelegationMap has key {
        id: UID,
        dao_id: object::ID,
        delegations: Table<address, address>, // delegator -> delegate
    }

    /// Voting power tracking (Shared Object)
    struct VotingPowerMap has key {
        id: UID,
        dao_id: object::ID,
        power: Table<address, u64>,
    }

    /// Individual vote record (Stored in ProposalVotes Table within ProposalStorage)
    struct Vote has store, drop { // `drop` for flexibility, not strictly required if only stored
        voter: address,
        proposal_id: object::ID,
        support: u8, // 0 = against, 1 = for, 2 = abstain
        voting_power: u64,
        timestamp_ms: u64,
    }

    /// Proposal storage (Shared Object)
    struct ProposalStorage has key {
        id: UID,
        dao_id: object::ID,
        proposals: Table<object::ID, Proposal>, // proposal_id (UID) -> Proposal
        votes: Table<object::ID, Table<address, Vote>>, // proposal_id (UID) -> voter_address -> vote
    }

    // Events
    struct ProposalCreatedEvent has drop, store {
        proposal_id: object::ID,
        dao_id: object::ID,
        proposer: address,
        title: String,
        start_time_ms: u64,
        end_time_ms: u64,
    }

    struct VoteCastEvent has drop, store {
        proposal_id: object::ID,
        dao_id: object::ID,
        voter: address,
        support: u8,
        voting_power: u64,
        timestamp_ms: u64,
    }

    struct ProposalExecutedEvent has drop, store {
        proposal_id: object::ID,
        dao_id: object::ID,
        executor: address,
        timestamp_ms: u64,
    }

    /// Initializer function for the module, run once on publish.
    /// Creates and shares initial instances of global resources.
    fun init(otw: governance, ctx: &mut TxContext) {
        let _ = otw; // OTW (One Time Witness) is consumed to ensure `init` is called once.
        // No initial DAO creation here, as `initialize_dao` is an entry function.
        // The objects created by `initialize_dao` will be explicitly shared.
    }

    /// Initialize a new DAO
    public entry fun initialize_dao(
        name: String,
        voting_period: u64, // in seconds
        timelock_delay: u64, // in seconds
        quorum_threshold: u64,
        proposal_threshold: u64,
        voting_strategy: u8,
        veto_enabled: bool,
        veto_authority: Option<address>,
        ctx: &mut TxContext,
    ) {
        // Sui object ID is unique, so we don't need a specific ID counter here
        // The DAO object's ID will serve as its unique identifier.

        assert!(voting_period >= MIN_VOTING_PERIOD, E_INVALID_VOTING_PERIOD);
        assert!(timelock_delay >= MIN_TIMELOCK_DELAY, E_INVALID_TIMELOCK_DELAY);

        let dao_id = tx_context::new_id(ctx);
        let dao_addr = object::id_to_address(&dao_id);

        let config = DAOConfig {
            voting_period,
            timelock_delay,
            quorum_threshold,
            proposal_threshold,
            voting_strategy,
            veto_enabled,
            veto_authority,
        };

        let treasury = Treasury {
            aptos_balance: coin::zero(ctx),
        };

        let dao = DAO {
            id: dao_id,
            name,
            config,
            treasury,
            proposal_counter: 0,
            total_voting_power: 0,
            upgrade_authority: option::some(tx_context::sender(ctx)), // Initial deployer is upgrade authority
        };

        // Initialize supporting shared data structures
        let delegation_map = DelegationMap {
            id: tx_context::new_id(ctx),
            dao_id: object::id(&dao),
            delegations: table::new(ctx),
        };

        let voting_power_map = VotingPowerMap {
            id: tx_context::new_id(ctx),
            dao_id: object::id(&dao),
            power: table::new(ctx),
        };

        let proposal_storage = ProposalStorage {
            id: tx_context::new_id(ctx),
            dao_id: object::id(&dao),
            proposals: table::new(ctx),
            votes: table::new(ctx),
        };

        // Share the created objects for public access and modification
        transfer::share_object(dao);
        transfer::share_object(delegation_map);
        transfer::share_object(voting_power_map);
        transfer::share_object(proposal_storage);
    }

    /// Create a new proposal
    public entry fun create_proposal(
        dao: &mut DAO,
        voting_power_map: &VotingPowerMap, // Immutable reference is fine for reading
        proposal_storage: &mut ProposalStorage,
        title: String,
        description: String,
        actions: vector<ProposalAction>,
        ctx: &mut TxContext,
    ) {
        let proposer = tx_context::sender(ctx);

        // Check if proposer has enough voting power
        let voting_power = get_voting_power(voting_power_map, proposer);
        assert!(voting_power >= dao.config.proposal_threshold, E_INSUFFICIENT_VOTING_POWER);

        dao.proposal_counter = dao.proposal_counter + 1;
        let proposal_uid = tx_context::new_id(ctx);

        let now_ms = tx_context::epoch_timestamp_ms(ctx); // Using milliseconds
        let start_time_ms = now_ms;
        let end_time_ms = now_ms + dao.config.voting_period * 1000; // Convert seconds to milliseconds

        let proposal = Proposal {
            id: proposal_uid,
            dao_id: object::id(dao),
            proposer,
            title,
            description,
            start_time_ms,
            end_time_ms,
            execution_time_ms: 0,
            state: PROPOSAL_STATE_ACTIVE,
            for_votes: 0,
            against_votes: 0,
            abstain_votes: 0,
            actions,
            executed: false,
            vetoed: false,
        };

        // Use object::id(&proposal) as the key for the proposal table
        table::add(&mut proposal_storage.proposals, object::id(&proposal), proposal);
        table::add(&mut proposal_storage.votes, object::id(&proposal), table::new(ctx));

        // Emit event
        event::emit(ProposalCreatedEvent {
            proposal_id: object::id(&proposal),
            dao_id: object::id(dao),
            proposer,
            title,
            start_time_ms,
            end_time_ms,
        });
    }

    /// Cast a vote on a proposal
    public entry fun cast_vote(
        dao: &DAO, // Read-only access to DAO config
        voting_power_map: &VotingPowerMap,
        delegation_map: &DelegationMap,
        proposal_storage: &mut ProposalStorage, // Mutable to update proposal votes
        proposal_id: object::ID, // Pass the ID of the proposal object
        support: u8, // 0 = against, 1 = for, 2 = abstain
        ctx: &mut TxContext,
    ) {
        let voter = tx_context::sender(ctx);

        assert!(table::contains(&proposal_storage.proposals, proposal_id), E_PROPOSAL_NOT_FOUND);
        
        let proposal = table::borrow_mut(&mut proposal_storage.proposals, proposal_id);
        let now_ms = tx_context::epoch_timestamp_ms(ctx);
        
        assert!(now_ms >= proposal.start_time_ms, E_VOTING_NOT_ENDED); // Adjusted for being able to vote *after* start
        assert!(now_ms <= proposal.end_time_ms, E_VOTING_ENDED);
        assert!(proposal.state == PROPOSAL_STATE_ACTIVE, E_INVALID_PROPOSAL);

        // Get effective voting power (including delegations)
        let effective_voting_power = get_effective_voting_power(voting_power_map, delegation_map, voter);
        assert!(effective_voting_power > 0, E_INSUFFICIENT_VOTING_POWER);

        // Apply voting strategy
        let adjusted_power = apply_voting_strategy(dao.config.voting_strategy, effective_voting_power);

        // Record the vote
        let vote = Vote {
            voter,
            proposal_id,
            support,
            voting_power: adjusted_power,
            timestamp_ms: now_ms,
        };

        let proposal_votes = table::borrow_mut(&mut proposal_storage.votes, proposal_id);
        
        // If voter already voted, subtract their previous vote
        if (table::contains(proposal_votes, voter)) {
            let previous_vote = table::borrow(proposal_votes, voter);
            if (previous_vote.support == 0) {
                proposal.against_votes = proposal.against_votes - previous_vote.voting_power;
            } else if (previous_vote.support == 1) {
                proposal.for_votes = proposal.for_votes - previous_vote.voting_power;
            } else {
                proposal.abstain_votes = proposal.abstain_votes - previous_vote.voting_power;
            };
        };

        // Add new vote
        if (support == 0) {
            proposal.against_votes = proposal.against_votes + adjusted_power;
        } else if (support == 1) {
            proposal.for_votes = proposal.for_votes + adjusted_power;
        } else {
            proposal.abstain_votes = proposal.abstain_votes + adjusted_power;
        };

        table::upsert(proposal_votes, voter, vote);

        // Emit event
        event::emit(VoteCastEvent {
            proposal_id,
            dao_id: object::id(dao),
            voter,
            support,
            voting_power: adjusted_power,
            timestamp_ms: now_ms,
        });
    }

    /// Queue a succeeded proposal for execution
    public entry fun queue_proposal(
        dao: &mut DAO, // Mutable to update total_voting_power if needed (though not in this func)
        proposal_storage: &mut ProposalStorage,
        proposal_id: object::ID,
        ctx: &mut TxContext,
    ) {
        let _caller = tx_context::sender(ctx); // Caller is not used for auth here, any user can queue

        assert!(table::contains(&proposal_storage.proposals, proposal_id), E_PROPOSAL_NOT_FOUND);
        
        let proposal = table::borrow_mut(&mut proposal_storage.proposals, proposal_id);
        let now_ms = tx_context::epoch_timestamp_ms(ctx);

        assert!(now_ms > proposal.end_time_ms, E_VOTING_NOT_ENDED); // Voting period must have ended
        assert!(proposal.state == PROPOSAL_STATE_ACTIVE, E_INVALID_PROPOSAL);

        // Check if proposal succeeded
        let total_votes = proposal.for_votes + proposal.against_votes + proposal.abstain_votes;
        // Quorum check: total_votes >= (total_voting_power * quorum_threshold / 10000)
        let quorum_met = (total_votes * 10000) >= (dao.total_voting_power * dao.config.quorum_threshold);
        let majority_reached = proposal.for_votes > proposal.against_votes;

        if (quorum_met && majority_reached) {
            proposal.state = PROPOSAL_STATE_SUCCEEDED; // Set to succeeded first
            proposal.execution_time_ms = now_ms + dao.config.timelock_delay * 1000; // Convert seconds to milliseconds
            proposal.state = PROPOSAL_STATE_QUEUED; // Then set to queued
        } else {
            proposal.state = PROPOSAL_STATE_FAILED;
        };
    }

    /// Execute a queued proposal
    public entry fun execute_proposal(
        dao: &mut DAO, // Mutable for treasury interactions
        proposal_storage: &mut ProposalStorage,
        proposal_id: object::ID,
        ctx: &mut TxContext,
    ) {
        let executor = tx_context::sender(ctx);

        assert!(table::contains(&proposal_storage.proposals, proposal_id), E_PROPOSAL_NOT_FOUND);
        
        let proposal = table::borrow_mut(&mut proposal_storage.proposals, proposal_id);
        let now_ms = tx_context::epoch_timestamp_ms(ctx);

        assert!(proposal.state == PROPOSAL_STATE_QUEUED, E_PROPOSAL_NOT_SUCCEEDED);
        assert!(now_ms >= proposal.execution_time_ms, E_TIMELOCK_NOT_EXPIRED);
        assert!(!proposal.executed, E_PROPOSAL_ALREADY_EXECUTED);
        assert!(!proposal.vetoed, E_PROPOSAL_VETOED);

        // Execute proposal actions
        let i = 0;
        let actions_len = vector::length(&proposal.actions);
        while (i < actions_len) {
            let action = vector::borrow(&proposal.actions, i);
            // In a real Sui implementation, this is where you'd perform actions:
            // e.g., transfer::public_transfer(&mut dao.treasury.aptos_balance, action.target, action.value, ctx);
            // This would require the DAO to own the `Coin<SUI>` object or have the capability to move it.
            // For complex cross-contract calls, you would need to use dynamic object fields and
            // potentially a "proxy" pattern or directly call entry functions on other modules.
            // This example simplifies by just acknowledging the action.

            // Example of a SUI transfer if the DAO owns the SUI:
            // if (action.value > 0) {
            //    let coin_to_transfer = coin::split(&mut dao.treasury.aptos_balance, action.value, ctx);
            //    transfer::public_transfer(coin_to_transfer, action.target);
            // };

            i = i + 1;
        };

        proposal.executed = true;
        proposal.state = PROPOSAL_STATE_EXECUTED;

        // Emit event
        event::emit(ProposalExecutedEvent {
            proposal_id,
            dao_id: object::id(dao),
            executor,
            timestamp_ms: now_ms,
        });
    }

    /// Veto a proposal (only by veto authority)
    public entry fun veto_proposal(
        dao: &DAO, // Read-only access to DAO config
        proposal_storage: &mut ProposalStorage,
        proposal_id: object::ID,
        ctx: &mut TxContext,
    ) {
        let caller = tx_context::sender(ctx);

        assert!(dao.config.veto_enabled, E_NOT_AUTHORIZED);
        assert!(option::contains(&dao.config.veto_authority, &caller), E_NOT_AUTHORIZED);

        assert!(table::contains(&proposal_storage.proposals, proposal_id), E_PROPOSAL_NOT_FOUND);
        
        let proposal = table::borrow_mut(&mut proposal_storage.proposals, proposal_id);
        assert!(proposal.state == PROPOSAL_STATE_QUEUED, E_INVALID_PROPOSAL);

        proposal.vetoed = true;
        proposal.state = PROPOSAL_STATE_VETOED;
    }

    /// Delegate voting power to another address
    public entry fun delegate_voting_power(
        delegation_map: &mut DelegationMap,
        delegate: address,
        ctx: &mut TxContext,
    ) {
        let delegator = tx_context::sender(ctx);
        table::upsert(&mut delegation_map.delegations, delegator, delegate);
    }

    /// Set voting power for an address (typically called by token contract or DAO itself)
    public entry fun set_voting_power(
        dao: &mut DAO, // Mutable to update total_voting_power
        voting_power_map: &mut VotingPowerMap,
        voter: address,
        power: u64,
        ctx: &mut TxContext,
    ) {
        let caller = tx_context::sender(ctx);

        // Access control: only the DAO itself or a designated admin can set voting power
        // For simplicity, here we assert the caller is the DAO's ID, which means
        // this function would likely be called internally by a DAO proposal, or by
        // a trusted governance token minter.
        assert!(object::id(dao) == object::id_from_address(caller), E_NOT_AUTHORIZED); // This is an oversimplification.
                                                                                        // A more robust solution would be a capability granted to the
                                                                                        // governance token contract or a specific admin address.

        let old_power = get_voting_power(voting_power_map, voter);
        dao.total_voting_power = dao.total_voting_power - old_power + power;
        
        table::upsert(&mut voting_power_map.power, voter, power);
    }

    /// Deposit funds to treasury
    public entry fun deposit_to_treasury(
        dao: &mut DAO,
        coin: Coin<SUI>, // The `Coin<SUI>` object is directly passed by the sender
        _ctx: &mut TxContext, // TxContext is not directly used here, but typically needed for coin ops
    ) {
        coin::join(&mut dao.treasury.aptos_balance, coin);
    }

    // Helper functions

    fun get_voting_power(voting_power_map: &VotingPowerMap, voter: address): u64 {
        if (table::contains(&voting_power_map.power, voter)) {
            *table::borrow(&voting_power_map.power, voter)
        } else {
            0
        }
    }

    fun get_effective_voting_power(
        voting_power_map: &VotingPowerMap,
        delegation_map: &DelegationMap,
        voter: address,
    ): u64 {
        let base_power = get_voting_power(voting_power_map, voter);
        
        // Add delegated power
        // This is a simplified implementation - in practice, you'd want to prevent cycles
        // For true delegation, you'd iterate through who 'voter' delegates *to*
        // and add their power. Or, more commonly, voters delegate *their* power to someone.
        // A simple recursive check could be:
        let delegate_addr = voter;
        let delegated_to_me_power = 0;
        let mut i = 0;
        let max_delegation_depth = 5; // Prevent infinite loops in complex delegation chains

        // A better delegation model in Sui would involve each delegator directly
        // updating the delegatee's effective power, or a snapshot system.
        // For now, let's keep it simple and assume direct delegation lookup.
        while (table::contains(&delegation_map.delegations, delegate_addr) && i < max_delegation_depth) {
            delegate_addr = *table::borrow(&delegation_map.delegations, delegate_addr);
            // In a pull-based system (where you calculate on demand), this would be complex.
            // A simpler approach for delegation is to have `delegate_voting_power` function
            // directly update the `VotingPowerMap` of the delegatee.
            // For the sake of direct translation, we'll keep this as a placeholder,
            // but note its complexity in a live system.
            i = i + 1;
        };
        // This currently just returns the base power, as a full delegation graph traversal
        // is non-trivial for an on-demand helper function like this without more state.
        base_power + delegated_to_me_power
    }

    fun apply_voting_strategy(strategy: u8, voting_power: u64): u64 {
        if (strategy == STRATEGY_SIMPLE_MAJORITY) {
            voting_power
        } else if (strategy == STRATEGY_QUADRATIC) {
            // Quadratic voting implementation would require a square root function.
            // Sui Move doesn't have a native `sqrt` for u64 directly. You'd need a library
            // implementation for integer square root, or approximate it.
            // For now, it returns original voting_power to avoid compilation issues.
            voting_power // In practice, you'd implement proper quadratic voting
        } else if (strategy == STRATEGY_WEIGHTED) {
            // Weighted voting with additional factors
            voting_power
        } else {
            voting_power
        }
    }

    // View functions (Sui doesn't have `#[view]` attribute like Aptos.
    // Instead, you'd use Sui's "query" capabilities via RPC to read shared object data.)

    /// Get DAO configuration
    public fun get_dao_config(dao: &DAO): DAOConfig {
        dao.config
    }

    /// Get a proposal by its ID
    public fun get_proposal(proposal_storage: &ProposalStorage, proposal_id: object::ID): Proposal {
        assert!(table::contains(&proposal_storage.proposals, proposal_id), E_PROPOSAL_NOT_FOUND);
        *table::borrow(&proposal_storage.proposals, proposal_id)
    }

    /// Get a specific vote for a proposal
    public fun get_proposal_vote(proposal_storage: &ProposalStorage, proposal_id: object::ID, voter: address): Vote {
        assert!(table::contains(&proposal_storage.votes, proposal_id), E_PROPOSAL_NOT_FOUND);
        let votes = table::borrow(&proposal_storage.votes, proposal_id);
        assert!(table::contains(votes, voter), E_PROPOSAL_NOT_FOUND); // More specific error
        *table::borrow(votes, voter)
    }

    /// Get treasury balance
    public fun get_treasury_balance(dao: &DAO): u64 {
        coin::value(&dao.treasury.aptos_balance)
    }

    /// Get voting power for an address
    public fun get_voting_power_for_address(voting_power_map: &VotingPowerMap, voter: address): u64 {
        get_voting_power(voting_power_map, voter)
    }

    /// Get delegate for an address
    public fun get_delegate(delegation_map: &DelegationMap, delegator: address): Option<address> {
        if (table::contains(&delegation_map.delegations, delegator)) {
            option::some(*table::borrow(&delegation_map.delegations, delegator))
        } else {
            option::none()
        }
    }
}