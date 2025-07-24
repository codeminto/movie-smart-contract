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
