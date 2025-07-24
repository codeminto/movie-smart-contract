/// File: bridge/vault.move
module addr::vault {
    use sui::tx_context::{Self, TxContext};
    use sui::event;
    use sui::coin::{Self, Coin, TreasuryCap}; // TreasuryCap is for mint/burn, not directly used in Vault for its own coin
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::vector;
    use sui::string::{Self, String};
    use sui::hash; // For hashing in Merkle proof verification (if done internally)

    // Error codes
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_INSUFFICIENT_BALANCE: u64 = 2;
    const E_INVALID_PROOF: u64 = 3;
    const E_ALREADY_PROCESSED: u64 = 4;
    const E_VAULT_ALREADY_INITIALIZED: u64 = 5;
    const E_VAULT_NOT_INITIALIZED: u64 = 6;
    const E_INVALID_THRESHOLD: u64 = 7;
    const E_CHAIN_NOT_SUPPORTED: u64 = 8;
    const E_INVALID_SIGNATURE_COUNT: u64 = 9;

    // Events
    struct TokenLocked has drop, store {
        sender: address,
        recipient: address,
        amount: u64,
        token_type: vector<u8>, // Using vector<u8> for simplicity, could be String
        dest_chain_id: u64,
        nonce: u64,
        timestamp: u64,
    }

    struct TokenReleased has drop, store {
        recipient: address,
        amount: u64,
        token_type: vector<u8>,
        source_chain_id: u64,
        nonce: u64,
        timestamp: u64,
    }

    struct MessageSent has drop, store {
        sender: address,
        dest_chain_id: u64,
        payload: vector<u8>,
        nonce: u64,
        timestamp: u64,
    }

    /// Vault resource
    /// This object will be shared upon initialization.
    struct Vault<phantom CoinType> has key, store {
        id: UID,
        // Multisig configuration
        relayers: vector<address>,
        threshold: u8,

        // State tracking
        nonce: u64,
        processed_nonces: vector<u64>, // Using vector for simplicity, consider sui::table for large sets

        // Chain configuration
        supported_chains: vector<u64>,
        // Coin storage for locked tokens
        locked_coins: Coin<CoinType>,
    }

    // Relayer signature for multisig (simplified, in real scenario this would involve actual crypto signatures)
    struct RelayerSignature has drop, store {
        relayer: address,
        signature: vector<u8>, // Placeholder for actual signature bytes
    }

    // Cross-chain transaction data (for release)
    struct CrossChainTx has drop, store {
        recipient: address,
        amount: u64,
        token_type: vector<u8>,
        source_chain_id: u64,
        nonce: u64,
        block_hash: vector<u8>,
    }

    /// Initializes the vault, creating and sharing the Vault object.
    /// This function is called once during module publication or by a designated admin.
    public entry fun init_vault<CoinType>(
        relayers: vector<address>,
        threshold: u8,
        supported_chains: vector<u64>,
        ctx: &mut TxContext
    ) {
        // Assert that the Vault for this CoinType does not already exist at the sender's address
        // In Sui, objects have unique IDs, so we create and share it.
        // If you want a global singleton Vault per CoinType, you'd need a manager object.
        // For simplicity, this creates a new Vault object and shares it.
        // To prevent multiple initializations, one might check if a `VaultManager` object exists.
        // For this conversion, we assume `init_vault` is called only once per desired CoinType.

        assert!(threshold > 0 && threshold <= (vector::length(&relayers) as u8), E_INVALID_THRESHOLD);

        let vault = Vault<CoinType> {
            id: object::new(ctx),
            relayers,
            threshold,
            nonce: 0,
            processed_nonces: vector::empty(),
            supported_chains,
            locked_coins: coin::zero(ctx), // Initialize with an empty coin
        };
        transfer::share_object(vault);
    }

    /// Lock tokens for cross-chain transfer.
    /// The sender transfers their coins to the Vault's shared object.
    public entry fun lock_tokens<CoinType>(
        vault: &mut Vault<CoinType>, // Mutable reference to the shared Vault object
        recipient: address,
        amount_coin: Coin<CoinType>, // The Coin object to be locked
        dest_chain_id: u64,
        ctx: &mut TxContext
    ) {
        let sender_addr = tx_context::sender(ctx);

        assert!(vector::contains(&vault.supported_chains, &dest_chain_id), E_CHAIN_NOT_SUPPORTED);
        assert!(coin::value(&amount_coin) > 0, E_INSUFFICIENT_BALANCE); // Ensure a non-zero amount is locked

        // Merge the incoming coins into the vault's locked_coins
        coin::join(&mut vault.locked_coins, amount_coin);

        // Increment nonce and emit event
        vault.nonce = vault.nonce + 1;
        let token_type = string::to_bytes(type_name::get<CoinType>()); // Derive token type from CoinType

        event::emit(TokenLocked {
            sender: sender_addr,
            recipient,
            amount: coin::value(&vault.locked_coins), // Amount actually deposited
            token_type,
            dest_chain_id,
            nonce: vault.nonce,
            timestamp: tx_context::epoch_timestamp_ms(ctx) / 1000,
        });
    }

    /// Release tokens after proof verification.
    /// This function is called by a relayer after verifying a cross-chain event.
    public entry fun release_tokens<CoinType>(
        vault: &mut Vault<CoinType>, // Mutable reference to the shared Vault object
        tx_data: CrossChainTx,
        proof: lightclient::MerkleProof, // Assuming lightclient module is also converted and available
        signatures: vector<RelayerSignature>,
        ctx: &mut TxContext
    ) {
        let relayer_addr = tx_context::sender(ctx); // The relayer is the sender of this transaction

        // Check if already processed
        assert!(!vector::contains(&vault.processed_nonces, &tx_data.nonce), E_ALREADY_PROCESSED);

        // Verify multisig (simplified: checks count, not actual signatures)
        // In a real implementation, you would verify each signature against a hash of tx_data
        // using `sui::signature` or other cryptographic primitives.
        verify_multisig(vault, &tx_data, &signatures);

        // Verify Merkle proof
        // This assumes lightclient::verify_merkle_proof is implemented correctly in the lightclient module.
        assert!(lightclient::verify_merkle_proof(&proof, tx_data.block_hash), E_INVALID_PROOF);

        // Mark as processed
        vector::push_back(&mut vault.processed_nonces, tx_data.nonce);

        // Release tokens from the vault's locked_coins
        assert!(coin::value(&vault.locked_coins) >= tx_data.amount, E_INSUFFICIENT_BALANCE);
        let coins_to_release = coin::take(&mut vault.locked_coins, tx_data.amount);
        transfer::public_transfer(coins_to_release, tx_data.recipient);

        // Emit event
        event::emit(TokenReleased {
            recipient: tx_data.recipient,
            amount: tx_data.amount,
            token_type: tx_data.token_type,
            source_chain_id: tx_data.source_chain_id,
            nonce: tx_data.nonce,
            timestamp: tx_context::epoch_timestamp_ms(ctx) / 1000,
        });
    }

    /// Send an arbitrary message across chains.
    /// This function would typically be used for generic cross-chain communication,
    /// not necessarily token transfers.
    public entry fun send_message(
        vault: &mut Vault<u64>, // Assuming a generic Vault for messages, or define a specific message Vault
        dest_chain_id: u64,
        payload: vector<u8>,
        ctx: &mut TxContext
    ) {
        let sender_addr = tx_context::sender(ctx);

        assert!(vector::contains(&vault.supported_chains, &dest_chain_id), E_CHAIN_NOT_SUPPORTED);

        vault.nonce = vault.nonce + 1;

        event::emit(MessageSent {
            sender: sender_addr,
            dest_chain_id,
            payload,
            nonce: vault.nonce,
            timestamp: tx_context::epoch_timestamp_ms(ctx) / 1000,
        });
    }

    /// Helper function to verify multisig signatures.
    /// This is a simplified check for the number of valid signatures.
    /// In a production system, actual cryptographic signature verification would be required.
    fun verify_multisig<CoinType>(
        vault: &Vault<CoinType>,
        tx_data: &CrossChainTx, // The data that was signed
        signatures: &vector<RelayerSignature>
    ) {
        let valid_sigs = 0u8;
        let i = 0;

        while (i < vector::length(signatures)) {
            let sig = vector::borrow(signatures, i);
            if (vector::contains(&vault.relayers, &sig.relayer)) {
                // TODO: In a real implementation, verify sig.signature against a hash of tx_data
                // using Sui's cryptographic functions (e.g., `sui::signature::ed25519_verify`).
                // This would involve hashing the `tx_data` struct's fields into a message.
                valid_sigs = valid_sigs + 1;
            };
            i = i + 1;
        };

        assert!(valid_sigs >= vault.threshold, E_NOT_AUTHORIZED);
    }

    // --- View functions (public functions that take immutable references) ---

    /// Retrieves vault configuration information.
    public fun get_vault_info<CoinType>(vault: &Vault<CoinType>): (vector<address>, u8, u64) {
        (vault.relayers, vault.threshold, vault.nonce)
    }

    /// Checks if a given nonce has already been processed by the vault.
    public fun is_nonce_processed<CoinType>(vault: &Vault<CoinType>, nonce: u64): bool {
        vector::contains(&vault.processed_nonces, &nonce)
    }
}

/// File: bridge/mint.move
module addr::mint {
    use sui::tx_context::{Self, TxContext};
    use sui::event;
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::vector;
    use sui::string::{Self, String};
    use sui::type_name;
    use addr::lightclient; // Assuming lightclient module is in the same package

    // Error codes
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_INVALID_PROOF: u64 = 2;
    const E_ALREADY_PROCESSED: u64 = 3;
    const E_MINT_ALREADY_INITIALIZED: u64 = 4;
    const E_MINT_NOT_INITIALIZED: u64 = 5;
    const E_INVALID_THRESHOLD: u64 = 6;
    const E_INSUFFICIENT_SIGNATURES: u64 = 7;

    /// Wrapped coin marker struct.
    /// This is a phantom type, the actual coin type will be `Coin<WrappedCoin>`.
    struct WrappedCoin has drop {}

    /// Mint controller resource.
    /// This object will be shared upon initialization and holds the TreasuryCap.
    struct MintController has key, store {
        id: UID,
        mint_cap: TreasuryCap<WrappedCoin>, // Sui uses TreasuryCap for both minting and burning
        relayers: vector<address>,
        threshold: u8,
        processed_nonces: vector<u64>, // Using vector for simplicity, consider sui::table for large sets
    }

    // Events
    struct TokenMinted has drop, store {
        recipient: address,
        amount: u64,
        source_chain_id: u64,
        nonce: u64,
        timestamp: u64,
    }

    struct TokenBurned has drop, store {
        sender: address,
        amount: u64,
        dest_chain_id: u64,
        nonce: u64,
        timestamp: u64,
    }

    // Cross-chain mint data
    struct MintData has drop, store {
        recipient: address,
        amount: u64,
        source_chain_id: u64,
        nonce: u64,
        block_hash: vector<u8>,
    }

    /// Initializes the wrapped coin and the MintController.
    /// This function is called once during module publication.
    public entry fun init(
        name: vector<u8>, // Coin name
        symbol: vector<u8>, // Coin symbol
        decimals: u8,
        relayers: vector<address>,
        threshold: u8,
        ctx: &mut TxContext
    ) {
        assert!(threshold > 0 && threshold <= (vector::length(&relayers) as u8), E_INVALID_THRESHOLD);

        // Create the currency and get its TreasuryCap
        let mint_cap = coin::create_currency<WrappedCoin>(
            object::id_from_address(tx_context::sender(ctx)), // Supply the publisher's address as the object ID for the TreasuryCap
            name,
            symbol,
            decimals,
            ctx
        );

        let controller = MintController {
            id: object::new(ctx),
            mint_cap,
            relayers,
            threshold,
            processed_nonces: vector::empty(),
        };
        transfer::share_object(controller); // Share the MintController
    }

    /// Mints new wrapped tokens after verifying a cross-chain event.
    public entry fun mint_wrapped(
        controller: &mut MintController, // Mutable reference to the shared MintController
        mint_data: MintData,
        proof: lightclient::MerkleProof, // Merkle proof from the source chain
        signatures: vector<vector<u8>>, // Placeholder for relayer signatures
        ctx: &mut TxContext
    ) {
        let relayer_addr = tx_context::sender(ctx); // The relayer is the sender of this transaction

        // Check if already processed
        assert!(!vector::contains(&controller.processed_nonces, &mint_data.nonce), E_ALREADY_PROCESSED);

        // Verify multisig (simplified: checks count, not actual signatures)
        // In a real implementation, you would verify each signature against a hash of mint_data
        // using Sui's cryptographic functions (e.g., `sui::signature::ed25519_verify`).
        assert!(vector::length(&signatures) >= (controller.threshold as u64), E_INSUFFICIENT_SIGNATURES);
        // TODO: Add actual signature verification against `controller.relayers`

        // Verify Merkle proof
        assert!(lightclient::verify_merkle_proof(&proof, mint_data.block_hash), E_INVALID_PROOF);

        // Mark as processed
        vector::push_back(&mut controller.processed_nonces, mint_data.nonce);

        // Mint tokens using the TreasuryCap
        let coins = coin::mint(&mut controller.mint_cap, mint_data.amount, ctx);
        transfer::public_transfer(coins, mint_data.recipient);

        // Emit event
        event::emit(TokenMinted {
            recipient: mint_data.recipient,
            amount: mint_data.amount,
            source_chain_id: mint_data.source_chain_id,
            nonce: mint_data.nonce,
            timestamp: tx_context::epoch_timestamp_ms(ctx) / 1000,
        });
    }

    /// Burns wrapped tokens to unlock native tokens on the source chain.
    public entry fun burn_wrapped(
        controller: &mut MintController, // Mutable reference to the shared MintController
        amount_coin: Coin<WrappedCoin>, // The Coin object to be burned
        dest_chain_id: u64,
        ctx: &mut TxContext
    ) {
        let sender_addr = tx_context::sender(ctx);
        let amount = coin::value(&amount_coin);

        // Burn tokens using the TreasuryCap
        coin::burn(&mut controller.mint_cap, amount_coin);

        // Generate nonce (simplified - in a real bridge, this nonce would likely be
        // a commitment to the burn transaction on this chain, to be used for unlocking on the destination)
        let nonce = vector::length(&controller.processed_nonces) + 1; // This is a very simplistic nonce

        // Emit event
        event::emit(TokenBurned {
            sender: sender_addr,
            amount,
            dest_chain_id,
            nonce,
            timestamp: tx_context::epoch_timestamp_ms(ctx) / 1000,
        });
    }

    // --- View functions (public functions that take immutable references) ---

    /// Retrieves controller configuration information.
    public fun get_controller_info(controller: &MintController): (vector<address>, u8) {
        (controller.relayers, controller.threshold)
    }

    /// Checks if a given nonce has already been processed by the mint controller.
    public fun is_nonce_processed(controller: &MintController, nonce: u64): bool {
        vector::contains(&controller.processed_nonces, &nonce)
    }
}

/// File: bridge/lightclient.move
module addr::lightclient {
    use sui::tx_context::{Self, TxContext};
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::vector;
    use sui::hash; // For SHA3-256 hashing

    // Error codes
    const E_INVALID_HEADER: u64 = 1;
    const E_INVALID_PROOF: u64 = 2;
    const E_PROOF_VERIFICATION_FAILED: u64 = 3;
    const E_CLIENT_NOT_INITIALIZED: u64 = 4;
    const E_INVALID_BLOCK_NUMBER: u64 = 5;
    const E_INVALID_PARENT_HASH: u64 = 6;
    const E_EMPTY_PROOF: u64 = 7;

    // Block header structure
    struct BlockHeader has drop, store, copy {
        parent_hash: vector<u8>,
        state_root: vector<u8>,
        tx_root: vector<u8>,
        block_number: u64,
        timestamp: u64,
        hash: vector<u8>, // Hash of this header
    }

    // Merkle proof structure
    struct MerkleProof has drop, store, copy {
        leaf: vector<u8>,
        proof_path: vector<vector<u8>>,
        indices: vector<bool>, // true for right, false for left
        root: vector<u8>,      // Expected Merkle root
    }

    /// Light client state.
    /// This object will be shared upon initialization.
    struct LightClient has key, store {
        id: UID,
        current_header: BlockHeader,
        trusted_headers: vector<BlockHeader>, // Headers that have been verified and are part of the chain
        finalized_headers: vector<BlockHeader>, // Headers considered finalized (e.g., after N confirmations)
    }

    /// Initializes the light client with a genesis header.
    /// This function is called once during module publication.
    public entry fun init_light_client(
        genesis_header: BlockHeader,
        ctx: &mut TxContext
    ) {
        let client = LightClient {
            id: object::new(ctx),
            current_header: genesis_header,
            trusted_headers: vector::singleton(genesis_header),
            finalized_headers: vector::empty(),
        };
        transfer::share_object(client);
    }

    /// Updates the light client with a new block header.
    /// Relayers would submit new headers along with a proof (e.g., ZK proof or multisig).
    public entry fun update_header(
        client: &mut LightClient, // Mutable reference to the shared LightClient object
        new_header: BlockHeader,
        proof_bytes: vector<u8>, // Placeholder for ZK proof or signature proof
        ctx: &mut TxContext
    ) {
        let relayer_addr = tx_context::sender(ctx); // The relayer is the sender of this transaction

        // Verify header validity
        assert!(new_header.block_number > client.current_header.block_number, E_INVALID_BLOCK_NUMBER);
        assert!(new_header.parent_hash == client.current_header.hash, E_INVALID_PARENT_HASH);

        // Verify proof (simplified - in a real implementation, this would involve
        // verifying a ZK proof or a multisig signature from validators on the source chain).
        assert!(vector::length(&proof_bytes) > 0, E_EMPTY_PROOF); // Just checks if proof is non-empty
        // TODO: Add actual ZK proof verification or threshold signature verification here.

        // Update state
        client.current_header = new_header;
        vector::push_back(&mut client.trusted_headers, new_header);

        // Finalize old headers (simplified finality rule: e.g., after 10 blocks)
        if (vector::length(&client.trusted_headers) > 10) {
            let old_header = vector::remove(&mut client.trusted_headers, 0);
            vector::push_back(&mut client.finalized_headers, old_header);
        };
    }

    /// Verifies a Merkle proof against a block's transaction root.
    /// This function is public and can be called by other modules (e.g., `vault`, `mint`).
    public fun verify_merkle_proof(proof: &MerkleProof, expected_root: vector<u8>): bool {
        let computed_root = compute_merkle_root(proof);
        computed_root == expected_root // Check if the computed root matches the expected root
    }

    /// Computes the Merkle root from a Merkle proof.
    public fun compute_merkle_root(proof: &MerkleProof): vector<u8> {
        let current = proof.leaf;
        let i = 0;

        while (i < vector::length(&proof.proof_path)) {
            let sibling = *vector::borrow(&proof.proof_path, i);
            let is_right = *vector::borrow(&proof.indices, i);

            let combined = vector::empty<u8>();
            if (is_right) {
                // Current is left child, sibling is right child
                vector::append(&mut combined, current);
                vector::append(&mut combined, sibling);
            } else {
                // Current is right child, sibling is left child
                vector::append(&mut combined, sibling);
                vector::append(&mut combined, current);
            };
            current = hash::sha3_256(combined); // Hash the combined bytes
            i = i + 1;
        };

        current
    }

    /// Verifies transaction inclusion in a block's transaction root using a Merkle proof.
    public fun verify_transaction_inclusion(
        tx_hash: vector<u8>,
        proof: MerkleProof, // Proof for the transaction hash
        block_header: &BlockHeader // The block header containing the transaction root
    ): bool {
        // Create a copy of the proof and set its leaf to the transaction hash
        let mut proof_copy = proof;
        proof_copy.leaf = tx_hash;
        compute_merkle_root(&proof_copy) == block_header.tx_root
    }

    // --- View functions (public functions that take immutable references) ---

    /// Retrieves the current header known by the light client.
    public fun get_current_header(client: &LightClient): BlockHeader {
        client.current_header
    }

    /// Checks if a block header with a given hash has been finalized by the light client.
    public fun is_header_finalized(client: &LightClient, block_hash: vector<u8>): bool {
        let i = 0;
        while (i < vector::length(&client.finalized_headers)) {
            let header = vector::borrow(&client.finalized_headers, i);
            if (header.hash == block_hash) {
                return true
            };
            i = i + 1;
        };
        false
    }

    // --- Utility functions (for creating structs) ---

    /// Utility function to create a BlockHeader struct.
    public fun create_block_header(
        parent_hash: vector<u8>,
        state_root: vector<u8>,
        tx_root: vector<u8>,
        block_number: u64,
        timestamp: u64
    ): BlockHeader {
        // Compute block hash by concatenating and hashing relevant fields
        let hash_input = vector::empty<u8>();
        vector::append(&mut hash_input, parent_hash);
        vector::append(&mut hash_input, state_root);
        vector::append(&mut hash_input, tx_root);

        // Append block_number and timestamp as bytes
        // Note: Sui does not have a direct u64 to bytes conversion in std.
        // This is a manual byte conversion (little-endian assumed).
        let block_num_bytes = vector::empty<u8>();
        let i = 0;
        while (i < 8) {
            vector::push_back(&mut block_num_bytes, ((block_number >> (i * 8)) & 0xFF) as u8);
            i = i + 1;
        };
        vector::append(&mut hash_input, block_num_bytes);

        let timestamp_bytes = vector::empty<u8>();
        let j = 0;
        while (j < 8) {
            vector::push_back(&mut timestamp_bytes, ((timestamp >> (j * 8)) & 0xFF) as u8);
            j = j + 1;
        };
        vector::append(&mut hash_input, timestamp_bytes);

        let hash = hash::sha3_256(hash_input);

        BlockHeader {
            parent_hash,
            state_root,
            tx_root,
            block_number,
            timestamp,
            hash,
        }
    }

    /// Utility function to create a MerkleProof struct.
    public fun create_merkle_proof(
        leaf: vector<u8>,
        proof_path: vector<vector<u8>>,
        indices: vector<bool>,
        root: vector<u8>
    ): MerkleProof {
        MerkleProof {
            leaf,
            proof_path,
            indices,
            root,
        }
    }
}

/// File: move_depin_node_staker/node_staker.move
module addr::node_staker {
    use sui::tx_context::{Self, TxContext};
    use sui::event;
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::vector;
    use sui::string::{Self, String};
    use sui::sui::SUI; // Assuming SUI as the native coin for staking
    use sui::bcs;
    use sui::signature; // For ed25519 verification
    use sui::table::{Self, Table};
    use sui::option::{Self, Option};
    use sui::math; // For min/max

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
    const E_STAKE_EXISTS: u64 = 12; // New error for existing stake
    const E_NO_VALIDATOR_CAP: u64 = 13; // New error if validator_cap is None

    /// Constants
    const MINIMUM_STAKE: u64 = 1000000000; // 1 SUI (9 decimals)
    const EPOCH_DURATION_SECONDS: u64 = 86400; // 24 hours
    const MAX_QUALITY_SCORE: u64 = 100;
    const SLASH_PERCENTAGE: u64 = 10; // 10% of stake
    const REWARD_PER_EPOCH: u64 = 100000000; // 0.1 SUI per epoch base reward (adjusted for 9 decimals)

    /// Validator capability resource that proves staking rights
    struct ValidatorCap has store {
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
    struct Stake has key, store {
        id: UID, // Sui object UID
        node_id: String,
        staked_coins: Coin<SUI>,
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
    struct ProtocolState has key, store {
        id: UID, // Sui object UID
        admin: address,
        current_epoch: u64,
        epoch_start_time: u64,
        total_staked: u64,
        total_nodes: u64,
        reward_pool: Coin<SUI>,
        min_stake_amount: u64,
        
        // TreasuryCap for burning slashed coins and minting rewards (if using a custom coin)
        // For SUI, we don't have a TreasuryCap here, we just transfer to/from the admin or burn to null.
        // If we were minting a custom token, this would be TreasuryCap<CustomToken>.
        // For SUI, we will transfer slashed SUI to the admin for re-distribution or burning.
        
        // Tracking tables
        active_validators: Table<String, address>, // node_id -> operator address
        epoch_proofs: Table<u64, vector<DataProof>>, // epoch -> proofs (vector of proofs for that epoch)
        quality_scores: Table<String, u64>, // node_id -> current quality score
        
        // Events (no longer EventHandle, just marker structs)
        // stake_events: EventHandle<StakeEvent>, // Removed
        // proof_events: EventHandle<ProofEvent>, // Removed
        // reward_events: EventHandle<RewardEvent>, // Removed
        // slash_events: EventHandle<SlashEvent>, // Removed
        // epoch_events: EventHandle<EpochEvent>, // Removed
    }

    /// Event structures (no change to struct definition, just how they are emitted)
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

    /// Initialize the protocol (admin only).
    /// Creates and shares the ProtocolState object.
    public entry fun initialize(ctx: &mut TxContext) {
        let admin_addr = tx_context::sender(ctx);
        // In Sui, we typically create and share a singleton.
        // To prevent re-initialization, one might check if a manager object exists.
        // For this conversion, we assume `initialize` is called only once.

        let protocol_state = ProtocolState {
            id: object::new(ctx),
            admin: admin_addr,
            current_epoch: 0,
            epoch_start_time: tx_context::epoch_timestamp_ms(ctx) / 1000,
            total_staked: 0,
            total_nodes: 0,
            reward_pool: coin::zero<SUI>(ctx), // Initialize with an empty SUI coin
            min_stake_amount: MINIMUM_STAKE,
            
            active_validators: table::new(ctx),
            epoch_proofs: table::new(ctx),
            quality_scores: table::new(ctx),
            
            // Event handles are removed in Sui, events are emitted directly
        };

        transfer::share_object(protocol_state);
    }

    /// Stake tokens and register as a node.
    /// The operator transfers their SUI coins to a new Stake object, which they own.
    public entry fun stake_and_register(
        protocol_state: &mut ProtocolState, // Shared ProtocolState object
        node_id: String,
        public_key: vector<u8>,
        stake_amount_coin: Coin<SUI>, // The SUI Coin object to be staked
        ctx: &mut TxContext,
    ) {
        let operator_addr = tx_context::sender(ctx);
        let stake_amount = coin::value(&stake_amount_coin);

        assert!(stake_amount >= protocol_state.min_stake_amount, EINVALID_STAKE_AMOUNT);
        // Check if operator already has a Stake object (Sui objects are owned)
        // This check is implicitly handled by `transfer::transfer` if the object with the same ID already exists
        // However, if we want to prevent an address from having multiple Stake objects, we need a different pattern.
        // For simplicity, we assume one Stake object per operator address.
        // A more robust solution would be a Table<address, UID> mapping operator to their Stake object.
        // For now, we'll rely on the `exists` check in view functions.
        
        // Check if node_id is already active
        assert!(!table::contains(&protocol_state.active_validators, string::copy(&node_id)), EINVALID_VALIDATOR);

        // Create validator capability
        let validator_cap = ValidatorCap {
            node_id: string::copy(&node_id), // Copy string for the struct
            public_key,
            stake_amount,
            created_epoch: protocol_state.current_epoch,
            is_active: true,
        };

        // Create stake resource (owned by the operator)
        let stake = Stake {
            id: object::new(ctx),
            node_id: node_id, // Transfer ownership of String
            staked_coins: stake_amount_coin, // Take ownership of the Coin
            validator_cap: option::some(validator_cap),
            epoch_records: vector::empty(),
            total_rewards: 0,
            is_slashed: false,
            last_activity_epoch: protocol_state.current_epoch,
        };

        // Update protocol state
        table::add(&mut protocol_state.active_validators, string::copy(&stake.node_id), operator_addr);
        table::add(&mut protocol_state.quality_scores, string::copy(&stake.node_id), MAX_QUALITY_SCORE);
        protocol_state.total_staked = protocol_state.total_staked + stake_amount;
        protocol_state.total_nodes = protocol_state.total_nodes + 1;

        // Emit event
        event::emit(StakeEvent {
            operator: operator_addr,
            node_id: string::copy(&stake.node_id),
            amount: stake_amount,
            epoch: protocol_state.current_epoch,
            is_unstake: false,
        });

        transfer::transfer(stake, operator_addr); // Transfer ownership of the Stake object to the operator
    }

    /// Submit data proof with signature verification.
    /// The operator provides their Stake object as a mutable reference.
    public entry fun submit_data_proof(
        protocol_state: &mut ProtocolState, // Shared ProtocolState object
        stake: &mut Stake, // Mutable reference to the operator's Stake object
        data_hash: vector<u8>,
        signature: vector<u8>,
        quality_metrics: vector<u64>, // [accuracy, timeliness, completeness]
        ctx: &mut TxContext,
    ) {
        let operator_addr = tx_context::sender(ctx);

        assert!(!stake.is_slashed, ENODE_ALREADY_SLASHED);
        assert!(table::contains(&protocol_state.active_validators, string::copy(&stake.node_id)), EINVALID_VALIDATOR);
        assert!(*table::borrow(&protocol_state.active_validators, string::copy(&stake.node_id)) == operator_addr, EUNAUTHORIZED);

        // Verify signature using Sui's ed25519
        let validator_cap = option::borrow(&stake.validator_cap);
        assert!(option::is_some(&stake.validator_cap), E_NO_VALIDATOR_CAP); // Ensure validator_cap exists
        let message = construct_proof_message(string::copy(&stake.node_id), protocol_state.current_epoch, data_hash);
        assert!(signature::ed25519_verify(signature, validator_cap.public_key, message), EINVALID_PROOF_SIGNATURE);

        // Calculate quality score from metrics
        let quality_score = calculate_quality_score(quality_metrics);

        // Create data proof
        let proof = DataProof {
            node_id: string::copy(&stake.node_id),
            epoch: protocol_state.current_epoch,
            data_hash: data_hash,
            timestamp: tx_context::epoch_timestamp_ms(ctx) / 1000,
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
        let current_score = *table::borrow(&protocol_state.quality_scores, string::copy(&stake.node_id));
        let new_score = (current_score + quality_score) / 2;
        *table::borrow_mut(&mut protocol_state.quality_scores, string::copy(&stake.node_id)) = new_score;

        // Update stake activity
        stake.last_activity_epoch = protocol_state.current_epoch;

        // Emit event
        event::emit(ProofEvent {
            node_id: string::copy(&stake.node_id),
            epoch: protocol_state.current_epoch,
            quality_score: quality_score,
            timestamp: tx_context::epoch_timestamp_ms(ctx) / 1000,
            data_hash: data_hash,
        });
    }

    /// End current epoch and update protocol state.
    /// This function is called by the admin. Individual reward claims are handled separately.
    public entry fun end_epoch_and_distribute_rewards(
        protocol_state: &mut ProtocolState, // Shared ProtocolState object
        ctx: &mut TxContext,
    ) {
        let admin_addr = tx_context::sender(ctx);
        assert!(admin_addr == protocol_state.admin, EUNAUTHORIZED);

        let current_time = tx_context::epoch_timestamp_ms(ctx) / 1000;
        assert!(current_time >= protocol_state.epoch_start_time + EPOCH_DURATION_SECONDS, EEPOCH_NOT_ENDED);

        let current_epoch = protocol_state.current_epoch;
        let total_rewards_distributed = 0; // This will now track rewards *transferred from pool*, not necessarily claimed
        let total_proofs = 0;

        // Get proofs for current epoch
        if (table::contains(&protocol_state.epoch_proofs, current_epoch)) {
            let epoch_proofs = table::borrow(&protocol_state.epoch_proofs, current_epoch);
            total_proofs = vector::length(epoch_proofs);

            // The reward distribution logic here is simplified.
            // Instead of directly distributing to individual stakes,
            // we calculate the total rewards to be made available for this epoch.
            // Individual nodes will call `claim_rewards`.
            // For now, we'll just move the REWARD_PER_EPOCH into the pool.
            // In a real system, `REWARD_PER_EPOCH` might come from a separate source
            // or be calculated based on network performance.

            // Add REWARD_PER_EPOCH to the reward pool (if not already added for this epoch)
            // This is a simplified model. A more complex system might have a separate
            // reward generation mechanism.
            // Revert: The `reward_pool` is a `Coin<SUI>`, so admin needs to deposit into it.
            // We cannot 'mint' SUI here. The `add_reward_pool` function is for this.
            // This means `REWARD_PER_EPOCH` should be a target for rewards, not something minted here.

            // For now, we'll assume `REWARD_PER_EPOCH` is a target amount, and the actual distribution
            // will depend on the `reward_pool` balance.
            // The actual distribution will happen in `claim_rewards`.
            // Here, we just advance the epoch and record total proofs.
        };

        // Start new epoch
        protocol_state.current_epoch = current_epoch + 1;
        protocol_state.epoch_start_time = current_time;

        // Emit epoch event
        event::emit(EpochEvent {
            epoch: current_epoch,
            start_time: current_time,
            total_proofs: total_proofs,
            total_rewards_distributed: total_rewards_distributed, // This will be 0 for now, as rewards are claimed separately
        });
    }

    /// Claim rewards for a specific epoch.
    /// This function is called by the node operator.
    public entry fun claim_rewards(
        protocol_state: &mut ProtocolState, // Shared ProtocolState object
        stake: &mut Stake, // Mutable reference to the operator's Stake object
        epoch_to_claim: u64,
        ctx: &mut TxContext,
    ) {
        let operator_addr = tx_context::sender(ctx);
        assert!(string::equal(&stake.node_id, table::borrow(&protocol_state.active_validators, string::copy(&stake.node_id))), EUNAUTHORIZED);
        assert!(!stake.is_slashed, ENODE_ALREADY_SLASHED);
        assert!(epoch_to_claim < protocol_state.current_epoch, EINVALID_EPOCH); // Can only claim for past epochs

        // Check if epoch proofs exist for the claimed epoch
        assert!(table::contains(&protocol_state.epoch_proofs, epoch_to_claim), EINVALID_EPOCH);
        let epoch_proofs = table::borrow(&protocol_state.epoch_proofs, epoch_to_claim);
        let total_proofs = vector::length(epoch_proofs);
        assert!(total_proofs > 0, EINVALID_EPOCH); // No proofs for this epoch

        // Find the proof submitted by this node in the target epoch
        let i = 0;
        let found_proof = false;
        let node_quality_score = 0;
        while (i < total_proofs) {
            let proof = vector::borrow(epoch_proofs, i);
            if (string::equal(&proof.node_id, &stake.node_id)) {
                node_quality_score = *table::borrow(&protocol_state.quality_scores, string::copy(&stake.node_id));
                found_proof = true;
                break;
            };
            i = i + 1;
        };
        assert!(found_proof, EINVALID_DATA_PROOF); // Node did not submit proof for this epoch

        // Calculate total quality-weighted score for the epoch
        let total_weighted_score = 0;
        i = 0;
        while (i < total_proofs) {
            let proof = vector::borrow(epoch_proofs, i);
            let quality_score = *table::borrow(&protocol_state.quality_scores, string::copy(&proof.node_id));
            total_weighted_score = total_weighted_score + quality_score;
            i = i + 1;
        };
        assert!(total_weighted_score > 0, EINVALID_EPOCH); // Should not happen if proofs exist

        // Calculate reward amount for this node
        let reward_amount = (REWARD_PER_EPOCH * node_quality_score) / total_weighted_score;
        assert!(reward_amount > 0, EINSUFFICIENT_STAKE); // No reward calculated

        // Check if already claimed for this epoch (by checking epoch_records)
        i = 0;
        let already_claimed = false;
        while (i < vector::length(&stake.epoch_records)) {
            let record = vector::borrow(&stake.epoch_records, i);
            if (record.epoch == epoch_to_claim) {
                already_claimed = true;
                break;
            };
            i = i + 1;
        };
        assert!(!already_claimed, EALREADY_PROCESSED); // Already claimed for this epoch

        // Transfer rewards from the protocol pool to the stake's coins
        assert!(coin::value(&protocol_state.reward_pool) >= reward_amount, EINSUFFICIENT_STAKE);
        let reward_coins = coin::take(&mut protocol_state.reward_pool, reward_amount);
        coin::join(&mut stake.staked_coins, reward_coins);
        stake.total_rewards = stake.total_rewards + reward_amount;

        // Add epoch record
        let epoch_record = EpochRecord {
            epoch: epoch_to_claim,
            proofs_submitted: 1, // Assuming one proof per node per epoch for simplicity
            quality_score: node_quality_score,
            rewards_earned: reward_amount,
            timestamp: tx_context::epoch_timestamp_ms(ctx) / 1000,
        };
        vector::push_back(&mut stake.epoch_records, epoch_record);

        // Emit reward event
        event::emit(RewardEvent {
            node_id: string::copy(&stake.node_id),
            epoch: epoch_to_claim,
            reward_amount: reward_amount,
            quality_score: node_quality_score,
        });
    }


    /// Slash a node for invalid data or downtime.
    /// This function is called by the admin.
    public entry fun slash_node(
        protocol_state: &mut ProtocolState, // Shared ProtocolState object
        stake: &mut Stake, // Mutable reference to the operator's Stake object
        reason: String,
        ctx: &mut TxContext,
    ) {
        let admin_addr = tx_context::sender(ctx);
        assert!(admin_addr == protocol_state.admin, EUNAUTHORIZED);
        assert!(table::contains(&protocol_state.active_validators, string::copy(&stake.node_id)), EINVALID_VALIDATOR);
        assert!(!stake.is_slashed, ENODE_ALREADY_SLASHED);

        // Calculate slash amount
        let current_balance = coin::value(&stake.staked_coins);
        let slash_amount = (current_balance * SLASH_PERCENTAGE) / 100;

        if (slash_amount > 0 && slash_amount <= current_balance) {
            // Extract slashed coins and transfer to admin (or burn if a custom token with TreasuryCap)
            let slashed_coins = coin::take(&mut stake.staked_coins, slash_amount);
            transfer::public_transfer(slashed_coins, admin_addr); // Transfer to admin for handling

            // Update protocol state
            protocol_state.total_staked = protocol_state.total_staked - slash_amount;
        };

        // Mark as slashed
        stake.is_slashed = true;

        // Remove from active validators
        table::remove(&mut protocol_state.active_validators, string::copy(&stake.node_id));
        protocol_state.total_nodes = protocol_state.total_nodes - 1;

        // Emit slash event
        event::emit(SlashEvent {
            node_id: string::copy(&stake.node_id),
            epoch: protocol_state.current_epoch,
            slashed_amount: slash_amount,
            reason: reason,
        });
    }

    /// Unstake and withdraw (only if not slashed).
    /// The operator consumes their Stake object.
    public entry fun unstake(
        protocol_state: &mut ProtocolState, // Shared ProtocolState object
        stake: Stake, // Consume the Stake object
        ctx: &mut TxContext,
    ) {
        let operator_addr = tx_context::sender(ctx);
        assert!(!stake.is_slashed, ENODE_ALREADY_SLASHED); // Cannot unstake if slashed

        // Remove from active validators if still there
        if (table::contains(&protocol_state.active_validators, string::copy(&stake.node_id))) {
            table::remove(&mut protocol_state.active_validators, string::copy(&stake.node_id));
            protocol_state.total_nodes = protocol_state.total_nodes - 1;
        };

        let total_amount = coin::value(&stake.staked_coins);
        protocol_state.total_staked = protocol_state.total_staked - total_amount;

        // Deposit coins back to operator
        transfer::public_transfer(stake.staked_coins, operator_addr);

        // Emit unstake event
        event::emit(StakeEvent {
            operator: operator_addr,
            node_id: string::copy(&stake.node_id),
            amount: total_amount,
            epoch: protocol_state.current_epoch,
            is_unstake: true,
        });

        // The Stake object is consumed by the function, so it's automatically deleted.
        // object::delete(stake.id); // Not needed as it's consumed
    }

    /// Add rewards to the protocol pool (admin only).
    /// The admin transfers SUI coins to the protocol's reward pool.
    public entry fun add_reward_pool(
        protocol_state: &mut ProtocolState, // Shared ProtocolState object
        reward_coins: Coin<SUI>, // The SUI Coin object to add to the pool
        ctx: &mut TxContext,
    ) {
        let admin_addr = tx_context::sender(ctx);
        assert!(admin_addr == protocol_state.admin, EUNAUTHORIZED);
        assert!(coin::value(&reward_coins) > 0, EINVALID_STAKE_AMOUNT); // Use a more general error for invalid amount

        coin::join(&mut protocol_state.reward_pool, reward_coins);
    }

    /// Helper functions

    fun construct_proof_message(node_id: String, epoch: u64, data_hash: vector<u8>): vector<u8> {
        let message = vector::empty<u8>();
        vector::append(&mut message, string::bytes(&node_id));
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
            sum = sum + math::min(metric, MAX_QUALITY_SCORE);
            i = i + 1;
        };

        math::min(sum / len, MAX_QUALITY_SCORE)
    }

    /// View functions (public functions that take immutable references)

    /// Retrieves global protocol state information.
    public fun get_protocol_state(protocol_state: &ProtocolState): (u64, u64, u64, u64, u64) {
        (
            protocol_state.current_epoch,
            protocol_state.total_staked,
            protocol_state.total_nodes,
            coin::value(&protocol_state.reward_pool),
            protocol_state.epoch_start_time
        )
    }

    /// Retrieves information about a node's stake.
    public fun get_node_stake_info(stake: &Stake): (String, u64, u64, bool, u64) {
        (
            string::copy(&stake.node_id), // Copy string for return
            coin::value(&stake.staked_coins),
            stake.total_rewards,
            stake.is_slashed,
            vector::length(&stake.epoch_records)
        )
    }

    /// Retrieves a node's current quality score.
    public fun get_node_quality_score(protocol_state: &ProtocolState, node_id: String): u64 {
        if (table::contains(&protocol_state.quality_scores, string::copy(&node_id))) {
            *table::borrow(&protocol_state.quality_scores, string::copy(&node_id))
        } else {
            0
        }
    }

    /// Checks if a node is currently active.
    public fun is_node_active(protocol_state: &ProtocolState, node_id: String): bool {
        table::contains(&protocol_state.active_validators, string::copy(&node_id))
    }
}
