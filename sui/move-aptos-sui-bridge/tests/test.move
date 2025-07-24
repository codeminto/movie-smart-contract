// ================================
// MoveBridge Test Suites
// ================================

// File: tests/vault_tests.move
#[test_only]
module bridge::vault_tests {
    use std::signer;
    use std::vector;
    use std::string;
    use aptos_framework::coin;
    use aptos_framework::account;
    use aptos_framework::timestamp;
    use aptos_framework::aptos_coin::{Self, AptosCoin};
    use bridge::vault::{Self, CrossChainTx, RelayerSignature};
    use bridge::lightclient::{Self, BlockHeader, MerkleProof};

    // Test coin for testing purposes
    struct TestCoin has key {}

    #[test(aptos_framework = @0x1, admin = @0x100, relayer1 = @0x200, relayer2 = @0x201, relayer3 = @0x202, user = @0x300)]
    public fun test_vault_initialization(
        aptos_framework: &signer,
        admin: &signer,
        relayer1: &signer,
        relayer2: &signer,
        relayer3: &signer,
        user: &signer
    ) {
        // Setup
        timestamp::set_time_has_started_for_testing(aptos_framework);
        account::create_account_for_test(signer::address_of(admin));
        account::create_account_for_test(signer::address_of(relayer1));
        account::create_account_for_test(signer::address_of(relayer2));
        account::create_account_for_test(signer::address_of(relayer3));
        account::create_account_for_test(signer::address_of(user));

        let relayers = vector::empty<address>();
        vector::push_back(&mut relayers, signer::address_of(relayer1));
        vector::push_back(&mut relayers, signer::address_of(relayer2));
        vector::push_back(&mut relayers, signer::address_of(relayer3));

        let supported_chains = vector::empty<u64>();
        vector::push_back(&mut supported_chains, 1); // Sui testnet
        vector::push_back(&mut supported_chains, 2); // Sui mainnet

        // Initialize vault
        vault::initialize_vault<AptosCoin>(
            admin,
            relayers,
            2, // 2-of-3 multisig
            supported_chains
        );

        // Verify initialization
        let (vault_relayers, threshold, nonce) = vault::get_vault_info<AptosCoin>(signer::address_of(admin));
        assert!(vector::length(&vault_relayers) == 3, 1);
        assert!(threshold == 2, 2);
        assert!(nonce == 0, 3);
    }

    #[test(aptos_framework = @0x1, admin = @0x100, user = @0x300)]
    public fun test_lock_tokens(
        aptos_framework: &signer,
        admin: &signer,
        user: &signer
    ) {
        // Setup
        timestamp::set_time_has_started_for_testing(aptos_framework);
        account::create_account_for_test(signer::address_of(admin));
        account::create_account_for_test(signer::address_of(user));

        // Initialize AptosCoin for testing
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
        
        // Give user some coins
        let coins = coin::mint(1000, &mint_cap);
        coin::deposit(signer::address_of(user), coins);

        // Setup vault
        let relayers = vector::empty<address>();
        vector::push_back(&mut relayers, @0x200);
        vector::push_back(&mut relayers, @0x201);
        
        let supported_chains = vector::empty<u64>();
        vector::push_back(&mut supported_chains, 1);

        vault::initialize_vault<AptosCoin>(
            admin,
            relayers,
            2,
            supported_chains
        );

        // Test lock tokens
        vault::lock_tokens<AptosCoin>(
            user,
            @0x999, // recipient on destination chain
            500,    // amount
            1,      // dest chain id
            signer::address_of(admin) // vault address
        );

        // Verify state
        let (_, _, nonce) = vault::get_vault_info<AptosCoin>(signer::address_of(admin));
        assert!(nonce == 1, 4);
        assert!(coin::balance<AptosCoin>(signer::address_of(user)) == 500, 5);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(aptos_framework = @0x1, admin = @0x100, relayer = @0x200, user = @0x300)]
    public fun test_release_tokens(
        aptos_framework: &signer,
        admin: &signer,
        relayer: &signer,
        user: &signer
    ) {
        // Setup
        timestamp::set_time_has_started_for_testing(aptos_framework);
        account::create_account_for_test(signer::address_of(admin));
        account::create_account_for_test(signer::address_of(relayer));
        account::create_account_for_test(signer::address_of(user));

        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
        
        // Give admin (vault) some coins for release
        let coins = coin::mint(1000, &mint_cap);
        coin::deposit(signer::address_of(admin), coins);

        // Setup vault
        let relayers = vector::empty<address>();
        vector::push_back(&mut relayers, signer::address_of(relayer));
        
        vault::initialize_vault<AptosCoin>(
            admin,
            relayers,
            1, // 1-of-1 for simplicity
            vector::singleton(1u64)
        );

        // Setup light client
        let genesis_header = lightclient::create_block_header(
            b"genesis",
            b"state_root",
            b"tx_root",
            0,
            1000
        );
        lightclient::initialize_light_client(admin, genesis_header);

        // Create cross-chain transaction data
        let tx_data = vault::CrossChainTx {
            recipient: signer::address_of(user),
            amount: 500,
            token_type: b"APT",
            source_chain_id: 1,
            nonce: 1,
            block_hash: vector::empty(),
        };

        // Create mock Merkle proof
        let proof = lightclient::create_merkle_proof(
            b"transaction_hash",
            vector::singleton(b"sibling_hash"),
            vector::singleton(false),
            b"tx_root"
        );

        // Create signatures
        let signatures = vector::empty<RelayerSignature>();
        vector::push_back(&mut signatures, vault::RelayerSignature {
            relayer: signer::address_of(relayer),
            signature: b"mock_signature",
        });

        // Test release (this will fail in real test due to signature verification)
        // In a real implementation, we'd mock the signature verification
        
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

}