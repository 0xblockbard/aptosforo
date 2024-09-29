
/*
* Basic FA oracle token module to be used as main currency protocol token powering the oracles/markets/asserters
*/

module optimistic_oracle_addr::oracle_token {

    use std::event;
    use std::signer;
    use std::option::{Self};
    use std::string::{Self, utf8};

    use aptos_framework::function_info;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::dispatchable_fungible_asset;
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::fungible_asset::{Self, MintRef, TransferRef, BurnRef, Metadata, FungibleAsset, FungibleStore };

    // -----------------------------------
    // Seeds
    // -----------------------------------

    const ASSET_SYMBOL : vector<u8>   = b"OO";

    // -----------------------------------
    // Constants
    // -----------------------------------

    const ASSET_NAME: vector<u8>      = b"Oracle Token";
    const ASSET_ICON: vector<u8>      = b"http://example.com/favicon.ico";
    const ASSET_WEBSITE: vector<u8>   = b"http://example.com";

    // -----------------------------------
    // Errors
    // note: my preference for this convention for better clarity and readability
    // (e.g. ERROR_MAX_TRANSACTION_AMOUNT_EXCEEDED vs EMaxTransactionAmountExceeded)
    // -----------------------------------

    const ERROR_NOT_ADMIN: u64                                          = 1;
    const ERROR_SEND_NOT_ALLOWED: u64                                   = 19;
    const ERROR_RECEIVE_NOT_ALLOWED: u64                                = 20;
    const ERROR_MAX_TRANSACTION_AMOUNT_EXCEEDED: u64                    = 21;

    // -----------------------------------
    // Structs
    // -----------------------------------

    /* Resources */
    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct Management has key {
        extend_ref: ExtendRef,
        mint_ref: MintRef,
        burn_ref: BurnRef,
        transfer_ref: TransferRef,
    }

    struct AdminInfo has key {
        admin_address: address,
    }

    // -----------------------------------
    // Events
    // -----------------------------------

    /* Events */
    #[event]
    struct Mint has drop, store {
        minter: address,
        to: address,
        amount: u64,
    }

    #[event]
    struct Burn has drop, store {
        minter: address,
        from: address,
        amount: u64,
    }

    // -----------------------------------
    // Views
    // -----------------------------------

    /* View Functions */
    #[view]
    public fun metadata_address(): address {
        object::create_object_address(&@optimistic_oracle_addr, ASSET_SYMBOL)
    }

    #[view]
    public fun metadata(): Object<Metadata> {
        object::address_to_object(metadata_address())
    }

    #[view]
    public fun token_store(): Object<FungibleStore> {
        primary_fungible_store::ensure_primary_store_exists(@optimistic_oracle_addr, metadata())
    }

    // -----------------------------------
    // Init
    // -----------------------------------

    /* Initialization - Asset Creation, Register Dispatch Functions */
    fun init_module(admin: &signer) {
        
        // Create the fungible asset metadata object.
        let constructor_ref = &object::create_named_object(admin, ASSET_SYMBOL);

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            constructor_ref,
            option::none(),
            utf8(ASSET_NAME),
            utf8(ASSET_SYMBOL),
            8,
            utf8(ASSET_ICON),
            utf8(ASSET_WEBSITE),
        );

        // Generate a signer for the asset metadata object.
        let metadata_object_signer = &object::generate_signer(constructor_ref);

        // Generate asset management refs and move to the metadata object.
        move_to(metadata_object_signer, Management {
            extend_ref: object::generate_extend_ref(constructor_ref),
            mint_ref: fungible_asset::generate_mint_ref(constructor_ref),
            burn_ref: fungible_asset::generate_burn_ref(constructor_ref),
            transfer_ref: fungible_asset::generate_transfer_ref(constructor_ref),
        });

        // set AdminInfo
        move_to(metadata_object_signer, AdminInfo {
            admin_address: signer::address_of(admin),
        });

        // Override the withdraw function.
        let withdraw = function_info::new_function_info(
            admin,
            string::utf8(b"oracle_token"),
            string::utf8(b"withdraw"),
        );

        // Override the deposit function.
        let deposit = function_info::new_function_info(
            admin,
            string::utf8(b"oracle_token"),
            string::utf8(b"deposit"),
        );

        dispatchable_fungible_asset::register_dispatch_functions(
            constructor_ref,
            option::some(withdraw),
            option::some(deposit),
            option::none(),
        );
    }

    // -----------------------------------
    // Functions
    // -----------------------------------

    /* Dispatchable Hooks */
    /// Withdraw function override 
    public fun withdraw<T: key>(
        store: Object<T>,
        amount: u64,
        transfer_ref: &TransferRef,
    ) : FungibleAsset {
        
        // Withdraw the remaining amount from the input store and return it.
        fungible_asset::withdraw_with_ref(transfer_ref, store, amount)
    }


    /// Deposit function override 
    public fun deposit<T: key>(
        store: Object<T>,
        fa: FungibleAsset,
        transfer_ref: &TransferRef,
    ) {
        // Deposit the remaining amount from the input store and return it.
        fungible_asset::deposit_with_ref(transfer_ref, store, fa);
    }

    /* Minting and Burning */
    /// Mint new assets to the specified account.
    public entry fun mint(admin: &signer, to: address, amount: u64) acquires Management, AdminInfo {

        let token_signer_addr = get_token_signer_addr();

        // verify signer is the admin
        let admin_info = borrow_global<AdminInfo>(token_signer_addr);
        assert!(signer::address_of(admin) == admin_info.admin_address, ERROR_NOT_ADMIN);
        
        let management = borrow_global<Management>(metadata_address());
        let assets = fungible_asset::mint(&management.mint_ref, amount);

        fungible_asset::deposit_with_ref(&management.transfer_ref, primary_fungible_store::ensure_primary_store_exists(to, metadata()), assets);

        event::emit(Mint {
            minter: signer::address_of(admin),
            to,
            amount,
        });
    }


    // For testnet only - allow any beta-testers to mint tokens on their own
    public entry fun public_mint(user: &signer, amount: u64) acquires Management {
        
        let management = borrow_global<Management>(metadata_address());
        let assets = fungible_asset::mint(&management.mint_ref, amount);
        let user_addr = signer::address_of(user);

        fungible_asset::deposit_with_ref(&management.transfer_ref, primary_fungible_store::ensure_primary_store_exists(user_addr, metadata()), assets);

        event::emit(Mint {
            minter: user_addr,
            to: user_addr,
            amount,
        });
    }


    /// Burn assets from the specified account.
    public entry fun burn(admin: &signer, from: address, amount: u64) acquires Management, AdminInfo {

        let token_signer_addr = get_token_signer_addr();

        // verify signer is the admin
        let admin_info = borrow_global<AdminInfo>(token_signer_addr);
        assert!(signer::address_of(admin) == admin_info.admin_address, ERROR_NOT_ADMIN);

        // Withdraw the assets from the account and burn them.
        let management = borrow_global<Management>(metadata_address());
        let assets = withdraw(primary_fungible_store::ensure_primary_store_exists(from, metadata()), amount, &management.transfer_ref);
        fungible_asset::burn(&management.burn_ref, assets);

        event::emit(Burn {
            minter: signer::address_of(admin),
            from,
            amount,
        });
    }

    /* Transfer */
    /// Transfer assets from one account to another.
    public entry fun transfer(from: &signer, to: address, amount: u64) acquires Management {

        // Withdraw the assets from the sender's store and deposit them to the recipient's store.
        let management = borrow_global<Management>(metadata_address());
        let from_store = primary_fungible_store::ensure_primary_store_exists(signer::address_of(from), metadata());
        let to_store   = primary_fungible_store::ensure_primary_store_exists(to, metadata());
        let assets     = withdraw(from_store, amount, &management.transfer_ref);
        
        fungible_asset::deposit_with_ref(&management.transfer_ref, to_store, assets);
    }

    // -----------------------------------
    // Helpers
    // -----------------------------------

    fun get_token_signer_addr() : address {
        object::create_object_address(&@optimistic_oracle_addr, ASSET_SYMBOL)
    }

    // -----------------------------------
    // Unit Tests
    // -----------------------------------
    
    #[test_only]
    public fun setup_test(admin : &signer)  {
        init_module(admin)
    }

    #[test(source = @0xa11ce, destination = @0xb0b, mod_account = @optimistic_oracle_addr)]
    public entry fun test_end_to_end(
        source: signer,
        destination: signer,
        mod_account: signer
    ) acquires Management, AdminInfo {

        let source_addr      = signer::address_of(&source);
        let destination_addr = signer::address_of(&destination);
        aptos_framework::account::create_account_for_test(source_addr);
        aptos_framework::account::create_account_for_test(destination_addr);
        aptos_framework::account::create_account_for_test(signer::address_of(&mod_account));

        setup_test(&mod_account);

        // test mint and burn
        mint(&mod_account, destination_addr, 10);
        burn(&mod_account, destination_addr, 5);

        // test transfer
        transfer(&destination, source_addr, 2);

        // test view token store works
        token_store();
    }

    #[test(source = @0xa11ce, destination = @0xb0b, mod_account = @optimistic_oracle_addr)]
    #[expected_failure(abort_code = ERROR_NOT_ADMIN, location = Self)]
    public entry fun test_non_admin_cannot_mint(
        source: signer,
        destination: signer,
        mod_account: signer
    ) acquires Management, AdminInfo {

        let source_addr      = signer::address_of(&source);
        let destination_addr = signer::address_of(&destination);
        aptos_framework::account::create_account_for_test(source_addr);
        aptos_framework::account::create_account_for_test(destination_addr);
        aptos_framework::account::create_account_for_test(signer::address_of(&mod_account));

        setup_test(&mod_account);

        mint(&source, destination_addr, 10);
    }

    #[test(source = @0xa11ce, destination = @0xb0b, mod_account = @optimistic_oracle_addr)]
    #[expected_failure(abort_code = ERROR_NOT_ADMIN, location = Self)]
    public entry fun test_non_admin_cannot_burn(
        source: signer,
        destination: signer,
        mod_account: signer
    ) acquires Management, AdminInfo {

        let source_addr      = signer::address_of(&source);
        let destination_addr = signer::address_of(&destination);
        aptos_framework::account::create_account_for_test(source_addr);
        aptos_framework::account::create_account_for_test(destination_addr);
        aptos_framework::account::create_account_for_test(signer::address_of(&mod_account));

        setup_test(&mod_account);

        mint(&mod_account, destination_addr, 10);
        burn(&source, destination_addr, 5);
    }

    #[test(source = @0xa11ce, destination = @0xb0b, mod_account = @optimistic_oracle_addr)]
    public entry fun test_public_mint_anyone_can_mint(
        source: signer,
        destination: signer,
        mod_account: signer
    ) acquires Management {

        let source_addr      = signer::address_of(&source);
        let destination_addr = signer::address_of(&destination);
        aptos_framework::account::create_account_for_test(source_addr);
        aptos_framework::account::create_account_for_test(destination_addr);
        aptos_framework::account::create_account_for_test(signer::address_of(&mod_account));

        setup_test(&mod_account);

        public_mint(&mod_account, 10);
    }


}
