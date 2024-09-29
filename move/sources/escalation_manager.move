//
// Based on the Full Policy Escalation Manager on UMA Protocol
// By: 0xblockbard
//
module optimistic_oracle_addr::escalation_manager {

    use std::signer;
    use std::event;
    use std::vector;
    
    use aptos_std::aptos_hash;
    use aptos_std::smart_table::{Self, SmartTable};

    use aptos_framework::object;

    // -----------------------------------
    // Seeds
    // -----------------------------------

    const APP_OBJECT_SEED: vector<u8> = b"ESCALATION_MANAGER";

    // -----------------------------------
    // Errors
    // - errors count continue from optimistic oracle module
    // -----------------------------------

    const ERROR_NOT_ADMIN : u64                             = 1;
    const ERROR_ARBITRATION_RESOLUTION_NOT_FOUND: u64       = 2;
    const ERROR_RESOLUTION_ALREADY_RESOLVED: u64            = 3;
    const ERROR_ARBITRATION_RESOLUTION_NOT_SET: u64         = 4;

    // -----------------------------------
    // Constants
    // -----------------------------------

    const NUMERICAL_TRUE: u8 = 1; // Numerical representation of true.

    // -----------------------------------
    // Structs
    // -----------------------------------

    /// Assertion Policy Struct
    struct AssertionPolicy has key {
        block_assertion: bool,
        validate_asserters: bool,
        validate_disputers: bool
    }

    struct ArbitrationResolution has store, drop {
        value_set: bool,
        resolution: bool
    }

    struct ArbitrationResolutionTable has key {
        arbitration_resolutions: SmartTable<vector<u8>, ArbitrationResolution>
    }

    // note: we do not have whitelisted asserting callers here as compared to UMA as we do not have price data
    struct WhitelistedTable has key, store {
        whitelisted_asserters: SmartTable<address, bool>,
        whitelisted_dispute_callers: SmartTable<address, bool>,
    }

    // AdminInfo Struct
    struct AdminInfo has key {
        admin_address: address,
    }

    // -----------------------------------
    // Events
    // -----------------------------------

    #[event]
    struct ArbitrationResolutionSetEvent has drop, store {
        request_id: vector<u8>,
        identifier: vector<u8>,
        ancillary_data: vector<u8>,
        resolution: bool
    }

    #[event]
    struct AsserterWhitelistSetEvent has drop, store {
        asserter: address,
        whitelisted: bool
    }

    #[event]
    struct DisputeCallerWhitelistSetEvent has drop, store {
        dispute_caller: address,
        whitelisted: bool
    }

    // -----------------------------------
    // Functions
    // -----------------------------------

    /// init module 
    fun init_module(admin : &signer) {

        let constructor_ref = object::create_named_object(
            admin,
            APP_OBJECT_SEED,
        );
        let manager_signer   = &object::generate_signer(&constructor_ref);

        // Set AdminInfo
        move_to(manager_signer, AdminInfo {
            admin_address: signer::address_of(admin),
        });

        // set default assertion policy
        move_to(manager_signer, AssertionPolicy {
            block_assertion       : false,
            validate_asserters    : true,
            validate_disputers    : true
        });

        // init assertion table struct
        move_to(manager_signer, ArbitrationResolutionTable {
            arbitration_resolutions: smart_table::new(),
        });

        // init whitelisted table struct
        move_to(manager_signer, WhitelistedTable {
            whitelisted_asserters: smart_table::new(),
            whitelisted_dispute_callers: smart_table::new(),
        });

    }

    // ---------------
    // Admin functions 
    // ---------------

    public entry fun set_assertion_policy(
        admin: &signer,
        block_assertion: bool,
        validate_asserters: bool,
        validate_disputers: bool
    ) acquires AssertionPolicy, AdminInfo {

        // get manager signer address
        let manager_signer_addr = get_escalation_manager_addr();

        // verify signer is the admin
        let admin_info = borrow_global<AdminInfo>(manager_signer_addr);
        assert!(signer::address_of(admin) == admin_info.admin_address, ERROR_NOT_ADMIN);

        // // update the configuration
        let assertion_policy = borrow_global_mut<AssertionPolicy>(manager_signer_addr);
        assertion_policy.block_assertion      = block_assertion;
        assertion_policy.validate_asserters   = validate_asserters;
        assertion_policy.validate_disputers   = validate_disputers;
    }

    
    public entry fun set_whitelisted_asserter(
        admin: &signer,
        asserter: address,
        value: bool
    ) acquires WhitelistedTable, AdminInfo {

        // get manager signer address
        let manager_signer_addr = get_escalation_manager_addr();

        // verify signer is the admin
        let admin_info = borrow_global<AdminInfo>(manager_signer_addr);
        assert!(signer::address_of(admin) == admin_info.admin_address, ERROR_NOT_ADMIN);

        let whitelisted_table  = borrow_global_mut<WhitelistedTable>(manager_signer_addr);

        // add or update whitelisted asserter
        smart_table::upsert(
            &mut whitelisted_table.whitelisted_asserters, 
            asserter, 
            value
        );

        // emit event for asserter whitelist set
        event::emit(AsserterWhitelistSetEvent {
            asserter,
            whitelisted: value
        });

    }


    public entry fun set_whitelisted_dispute_caller(
        admin: &signer,
        dispute_caller: address,
        value: bool
    ) acquires WhitelistedTable, AdminInfo {

        // get manager signer address
        let manager_signer_addr = get_escalation_manager_addr();

        // verify signer is the admin
        let admin_info = borrow_global<AdminInfo>(manager_signer_addr);
        assert!(signer::address_of(admin) == admin_info.admin_address, ERROR_NOT_ADMIN);

        let whitelisted_table  = borrow_global_mut<WhitelistedTable>(manager_signer_addr);

        // add or update whitelisted asserter
        smart_table::upsert(
            &mut whitelisted_table.whitelisted_dispute_callers, 
            dispute_caller, 
            value
        );

        // emit event for dispute caller whitelist set
        event::emit(DisputeCallerWhitelistSetEvent {
            dispute_caller,
            whitelisted: value
        });
    }

    // ---------------
    // General functions
    // ---------------

    /**
     * @notice Set the arbitration resolution for a given identifier, time, and ancillary data.
     * @param identifier uniquely identifies the price requested.
     * @param asserter_bytes asserter address as vector
     * @param ancillaryData arbitrary data appended to a price request to give the voters more info from the caller.
     * @param arbitrationResolution true if the assertion should be resolved as true, false otherwise.
     * @dev The owner should use this function whenever a dispute arises and it should be arbitrated by the Escalation
     * Manager; it is up to the owner to determine how to resolve the dispute. See the requestPrice implementation in
     * BaseEscalationManager, which escalates a dispute to the Escalation Manager for resolution.
     */
    public entry fun set_arbitration_resolution(
        admin: &signer,
        time: vector<u8>,
        identifier: vector<u8>,
        ancillary_data: vector<u8>,
        arbitration_resolution: bool,
        override: bool
    ) acquires ArbitrationResolutionTable, AdminInfo {

        let manager_signer_addr            = get_escalation_manager_addr();
        let arbitration_resolutions_table  = borrow_global_mut<ArbitrationResolutionTable>(manager_signer_addr);

        // verify signer is the admin
        let admin_info = borrow_global<AdminInfo>(manager_signer_addr);
        assert!(signer::address_of(admin) == admin_info.admin_address, ERROR_NOT_ADMIN);

        // get request id
        let request_id = get_request_id(time, identifier, ancillary_data);

        // check if arbitration resolution has already been set for request id
        if (override == false){
            if (smart_table::contains(&arbitration_resolutions_table.arbitration_resolutions, request_id)) {
                abort ERROR_RESOLUTION_ALREADY_RESOLVED
            };
        };

        // add arbitration resolution (update if override set to true) 
        // note: UMA protocol has no override 
        smart_table::upsert(
            &mut arbitration_resolutions_table.arbitration_resolutions, 
            request_id, 
            ArbitrationResolution {
                value_set: true,
                resolution: arbitration_resolution
            },
        );

        // emit event for assertion disputed
        event::emit(ArbitrationResolutionSetEvent {
            request_id,
            identifier,
            ancillary_data,
            resolution: arbitration_resolution
        });

    }

    // -----------------------------------
    // Views
    // -----------------------------------

    #[view]
    public fun get_resolution(time: vector<u8>, identifier: vector<u8>, ancillary_data: vector<u8>) : u8 acquires ArbitrationResolutionTable {
        
        let manager_signer_addr            = get_escalation_manager_addr();
        let arbitration_resolutions_table  = borrow_global<ArbitrationResolutionTable>(manager_signer_addr);

        // get request id
        let request_id = get_request_id(time, identifier, ancillary_data);

        // get the contribution amount for the specific contributor
        if (!smart_table::contains(&arbitration_resolutions_table.arbitration_resolutions, request_id)) {
            abort ERROR_ARBITRATION_RESOLUTION_NOT_FOUND
        };

        let arbitration_resolution_ref = smart_table::borrow(&arbitration_resolutions_table.arbitration_resolutions, request_id);

        let resolution = 0;
        if(arbitration_resolution_ref.resolution == true){
            resolution = NUMERICAL_TRUE;
        };

        resolution
    }


    #[view]
    public fun get_assertion_policy(): (
        bool, bool, bool
    ) acquires AssertionPolicy {

        let manager_signer_addr = get_escalation_manager_addr();
        let assertion_policy = borrow_global_mut<AssertionPolicy>(manager_signer_addr);
                
        // return assertion_policy values
        (
            assertion_policy.block_assertion,
            assertion_policy.validate_asserters,
            assertion_policy.validate_disputers
        )
    }


    #[view]
    public fun is_dispute_allowed(dispute_caller: address): (bool) acquires WhitelistedTable {

        let manager_signer_addr = get_escalation_manager_addr();
        let whitelisted_table   = borrow_global_mut<WhitelistedTable>(manager_signer_addr);

        let allowed_bool: bool = false;
        if (smart_table::contains(&whitelisted_table.whitelisted_dispute_callers, dispute_caller)) {
            allowed_bool = *smart_table::borrow(&whitelisted_table.whitelisted_dispute_callers, dispute_caller);
        };

        allowed_bool
    }


    #[view]
    public fun is_assert_allowed(asserter: address): (bool) acquires WhitelistedTable {

        let manager_signer_addr = get_escalation_manager_addr();
        let whitelisted_table   = borrow_global_mut<WhitelistedTable>(manager_signer_addr);

        let allowed_bool: bool = false;
        if (smart_table::contains(&whitelisted_table.whitelisted_asserters, asserter)) {
            allowed_bool = *smart_table::borrow(&whitelisted_table.whitelisted_asserters, asserter);
        };

        allowed_bool
    }


    // note: originally used as an inline function, however due to the test coverage bug we use a view instead to reach 100% test coverage
    #[view] 
    public fun get_request_id(time: vector<u8>, identifier: vector<u8>, ancillary_data: vector<u8>): vector<u8> {
        let request_vector = vector::empty<u8>();
        vector::append(&mut request_vector, time);
        vector::append(&mut request_vector, identifier);
        vector::append(&mut request_vector, ancillary_data);
        aptos_hash::keccak256(request_vector)
    }

    // -----------------------------------
    // Helpers
    // -----------------------------------

    fun get_escalation_manager_addr(): address {
        object::create_object_address(&@escalation_manager_addr, APP_OBJECT_SEED)
    }

    // -----------------------------------
    // Unit Tests
    // -----------------------------------

    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::timestamp;

    #[test_only]
    public fun setup_test(
        aptos_framework : &signer, 
        escalation_manager : &signer,
        user_one : &signer,
        user_two : &signer,
    ) : (address, address, address) {

        init_module(escalation_manager);

        timestamp::set_time_has_started_for_testing(aptos_framework);

        // get addresses
        let escalation_manager_addr     = signer::address_of(escalation_manager);
        let user_one_addr               = signer::address_of(user_one);
        let user_two_addr               = signer::address_of(user_two);

        // create accounts
        account::create_account_for_test(escalation_manager_addr);
        account::create_account_for_test(user_one_addr);
        account::create_account_for_test(user_two_addr);

        (escalation_manager_addr, user_one_addr, user_two_addr)
    }

    #[view]
    #[test_only]
    public fun test_ArbitrationResolutionSetEvent(
        request_id : vector<u8>, 
        identifier : vector<u8>,
        ancillary_data : vector<u8>,
        resolution : bool,
    ): ArbitrationResolutionSetEvent {
        let event = ArbitrationResolutionSetEvent{
            request_id,
            identifier,
            ancillary_data,
            resolution
        };
        return event
    }

    
    #[view]
    #[test_only]
    public fun test_AsserterWhitelistSetEvent(
        asserter : address,
        whitelisted : bool,
    ): AsserterWhitelistSetEvent {
        let event = AsserterWhitelistSetEvent{
            asserter,
            whitelisted
        };
        return event
    }


    #[view]
    #[test_only]
    public fun test_DisputeCallerWhitelistSetEvent(
        dispute_caller : address,
        whitelisted : bool,
    ): DisputeCallerWhitelistSetEvent {
        let event = DisputeCallerWhitelistSetEvent{
            dispute_caller,
            whitelisted
        };
        return event
    }

}