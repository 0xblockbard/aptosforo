//
// Reference of UMA's optimistic oracle adapted for use on Aptos
// This is the foundation of the prediction market contract for handling truth assertions
// By: 0xblockbard
//

module aptosforo_addr::optimistic_oracle {

    use aptosforo_addr::escalation_manager;

    use std::bcs;
    use std::event;
    use std::vector;
    use std::signer;
    use std::timestamp; 
    use std::option::{Self, Option};

    use aptos_std::aptos_hash;
    use aptos_std::smart_table::{Self, SmartTable};
    
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::fungible_asset::{Metadata};

    // -----------------------------------
    // Seeds
    // -----------------------------------

    const APP_OBJECT_SEED: vector<u8> = b"ORACLE";

    // -----------------------------------
    // Errors
    // -----------------------------------

    const ERROR_NOT_ADMIN : u64                             = 1;
    const ERROR_ASSERT_IS_BLOCKED: u64                      = 2;
    const ERROR_NOT_WHITELISTED_ASSERTER: u64               = 3;
    const ERROR_NOT_WHITELISTED_DISPUTER: u64               = 4;
    const ERROR_BURNED_BOND_PERCENTAGE_EXCEEDS_HUNDRED: u64 = 5;
    const ERROR_BURNED_BOND_PERCENTAGE_IS_ZERO: u64         = 6;
    const ERROR_ASSERTION_IS_EXPIRED: u64                   = 7;
    const ERROR_ASSERTION_ALREADY_DISPUTED: u64             = 8;
    const ERROR_MINIMUM_BOND_NOT_REACHED: u64               = 9;
    const ERROR_MINIMUM_LIVENESS_NOT_REACHED: u64           = 10;
    const ERROR_ASSERTION_ALREADY_SETTLED: u64              = 11;
    const ERROR_ASSERTION_NOT_EXPIRED: u64                  = 12;
    const ERROR_ASSERTION_ALREADY_EXISTS: u64               = 13;

    // -----------------------------------
    // Constants
    // -----------------------------------

    const NUMERICAL_TRUE: u8                    = 1; // Numerical representation of true

    const DEFAULT_MIN_LIVENESS: u64             = 10000;
    const DEFAULT_FEE: u64                      = 1000;
    const DEFAULT_BURNED_BOND_PERCENTAGE: u64   = 1000;
    const DEFAULT_TREASURY_ADDRESS: address     = @aptosforo_addr;
    
    // -----------------------------------
    // Structs
    // -----------------------------------

    /// Assertion Struct
    struct Assertion has key, store {
        asserter: address,
        settled: bool,
        settlement_resolution: bool,
        liveness: u64,
        assertion_time: u64,
        expiration_time: u64,
        identifier: vector<u8>,
        bond: u64,
        disputer: Option<address>
    }

    struct AssertionTable has key, store {
        assertions: SmartTable<vector<u8>, Assertion> // assertion_id: vector<u8>
    }

    struct AssertionRegistry has key, store {
        assertion_to_asserter: SmartTable<vector<u8>, address>
    }

    /// AdminProperties Struct 
    struct AdminProperties has key, store {
        default_fee: u64,
        burned_bond_percentage: u64,
        min_liveness: u64,
        treasury_address: address,
        currency_metadata: option::Option<Object<Metadata>>,
    }

    // Oracle Struct
    struct OracleSigner has key, store {
        extend_ref : object::ExtendRef,
    }

    // AdminInfo Struct
    struct AdminInfo has key {
        admin_address: address,
    }

    // -----------------------------------
    // Events
    // -----------------------------------

    #[event]
    struct AssertionMadeEvent has drop, store {
        assertion_id: vector<u8>,
        claim: vector<u8>,
        identifier: vector<u8>,
        asserter: address,
        liveness: u64,
        start_time: u64,
        end_time: u64,
        bond: u64
    }

    #[event]
    struct AssertionDisputedEvent has drop, store {
        assertion_id: vector<u8>,
        disputer: address
    }

    #[event]
    struct AssertionSettledEvent has drop, store {
        assertion_id: vector<u8>,
        bond_recipient: address,
        disputed: bool,
        settlement_resolution: bool,
        settle_caller: address
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
        let extend_ref       = object::generate_extend_ref(&constructor_ref);
        let oracle_signer = &object::generate_signer(&constructor_ref);

        // Set OracleSigner
        move_to(oracle_signer, OracleSigner {
            extend_ref,
        });

        // Set AdminInfo
        move_to(oracle_signer, AdminInfo {
            admin_address: signer::address_of(admin),
        });

        // set default AdminProperties
        move_to(oracle_signer, AdminProperties {
            min_liveness            : DEFAULT_MIN_LIVENESS,
            default_fee             : DEFAULT_FEE,
            burned_bond_percentage  : DEFAULT_BURNED_BOND_PERCENTAGE,
            treasury_address        : DEFAULT_TREASURY_ADDRESS,
            currency_metadata       : option::none()
        });

        // init AssertionRegistry struct
        move_to(oracle_signer, AssertionRegistry {
            assertion_to_asserter: smart_table::new(),
        });
        
    }

    // ---------------
    // Admin functions 
    // ---------------

    public entry fun set_admin_properties(
        admin : &signer,
        currency_metadata: Object<Metadata>,
        min_liveness: u64,
        default_fee: u64,
        treasury_address: address,
        burned_bond_percentage : u64
    ) acquires AdminProperties, AdminInfo {

        // get oracle signer address
        let oracle_signer_addr = get_oracle_signer_addr();

        // verify signer is the admin
        let admin_info = borrow_global<AdminInfo>(oracle_signer_addr);
        assert!(signer::address_of(admin) == admin_info.admin_address, ERROR_NOT_ADMIN);

        // validation checks
        assert!(burned_bond_percentage <= 10000, ERROR_BURNED_BOND_PERCENTAGE_EXCEEDS_HUNDRED);
        assert!(burned_bond_percentage >0 , ERROR_BURNED_BOND_PERCENTAGE_IS_ZERO);

        // // update admin properties
        let admin_properties = borrow_global_mut<AdminProperties>(oracle_signer_addr);
        admin_properties.min_liveness             = min_liveness;
        admin_properties.default_fee              = default_fee;
        admin_properties.burned_bond_percentage   = burned_bond_percentage;
        admin_properties.treasury_address         = treasury_address;
        admin_properties.currency_metadata        = option::some(currency_metadata);

    }

    // ---------------
    // General functions
    // ---------------

    /**
     * @notice Asserts a truth about the world, using a custom configuration.
     * @dev The caller must approve this contract to spend at least bond amount of currency.
     * @param claim the truth claim being asserted. This is an assertion about the world, and is verified by disputers.
     * @param asserter account that receives bonds back at settlement. This could be msg.sender or
     * any other account that the caller wants to receive the bond at settlement time.
     * @param liveness time to wait before the assertion can be resolved. Assertion can be disputed in this time.
     * @param currency bond currency pulled from the caller and held in escrow until the assertion is resolved.
     * @param bond amount of currency to pull from the caller and hold in escrow until the assertion is resolved. This
     * must be >= getMinimumBond(address(currency)).
     * @param identifier: to use for price requests in the event of a dispute. Must be pre-approved.
     * @return assertionId unique identifier for this assertion.
     */
    public entry fun assert_truth(
        asserter: &signer,
        claim: vector<u8>,
        liveness: u64,
        bond: u64,
        identifier: vector<u8>
    ) acquires AdminProperties, AssertionTable, AssertionRegistry {

        let oracle_signer_addr  = get_oracle_signer_addr();
        let assertion_registry  = borrow_global_mut<AssertionRegistry>(oracle_signer_addr);
        let admin_properties    = borrow_global<AdminProperties>(oracle_signer_addr);
        let asserter_addr       = signer::address_of(asserter);

        // check if creator has AssertionTable
        if (!exists<AssertionTable>(asserter_addr)) {
            move_to(asserter, AssertionTable {
                assertions: smart_table::new(),
            });
        };
        let assertions_table = borrow_global_mut<AssertionTable>(asserter_addr);

        let (block_assertion, validate_asserters, _) = escalation_manager::get_assertion_policy();
        if(block_assertion){
            // assertion is blocked
            abort ERROR_ASSERT_IS_BLOCKED
        } else {
            // assertion is not blocked
            if(validate_asserters){
                // require asserters to be whitelisted 
                let whitelistedBool     = escalation_manager::is_assert_allowed(signer::address_of(asserter));
                assert!(whitelistedBool, ERROR_NOT_WHITELISTED_ASSERTER);
            };
        };
        
        // set unique assertion id based on input
        let current_timestamp = timestamp::now_microseconds();
        let assertion_id = get_assertion_id_helper(
            asserter_addr,
            claim, 
            current_timestamp,
            bond,
            liveness,
            identifier
        );

        // verify assertion does not exist
        if (smart_table::contains(&assertions_table.assertions, assertion_id)) {
            abort ERROR_ASSERTION_ALREADY_EXISTS
        };

        // verify bond is greater than minimum bond 
        let minimum_bond = (admin_properties.default_fee * 10000) / admin_properties.burned_bond_percentage;
        assert!(bond >= minimum_bond, ERROR_MINIMUM_BOND_NOT_REACHED);

        // verify liveness is greater than minimum liveness 
        assert!(liveness >= admin_properties.min_liveness, ERROR_MINIMUM_LIVENESS_NOT_REACHED);

        let expiration_time = current_timestamp + liveness;

        // create assertion
        let assertion = Assertion {
            asserter: signer::address_of(asserter),
            settled: false,
            settlement_resolution: false,
            liveness,
            assertion_time: current_timestamp,
            expiration_time,
            identifier,
            bond,
            disputer: option::none()
        }; 

        // transfer bond from asserter
        let currency_metadata = option::destroy_some(admin_properties.currency_metadata);
        primary_fungible_store::transfer(asserter, currency_metadata, oracle_signer_addr, bond);

        // store new assertion
        smart_table::add(&mut assertions_table.assertions, assertion_id, assertion);

        // update assertion registry
        smart_table::add(&mut assertion_registry.assertion_to_asserter, assertion_id, asserter_addr);

        // emit event for assertion made
        event::emit(AssertionMadeEvent {
            assertion_id,
            claim,
            identifier,
            asserter: signer::address_of(asserter), 
            liveness,
            start_time: current_timestamp,
            end_time: expiration_time,
            bond
        });

    }


    /**
     * @notice Disputes an assertion. We follow a centralised model for dispute resolution where only whitelisted 
     * disputers can resolve the dispute.
     * @param assertionId unique identifier for the assertion to dispute.
     * @param disputer to transfer bond for making a dispute and will receive bonds back at settlement.
     */
    public entry fun dispute_assertion(
        disputer : &signer,
        assertion_id : vector<u8>,
    ) acquires AdminProperties, AssertionTable, AssertionRegistry {

        let oracle_signer_addr  = get_oracle_signer_addr();
        let assertion_registry  = borrow_global_mut<AssertionRegistry>(oracle_signer_addr);
        let admin_properties    = borrow_global<AdminProperties>(oracle_signer_addr);
        let current_timestamp   = timestamp::now_microseconds();

        // get asserter address from registry
        let asserter_addr       = *smart_table::borrow(&assertion_registry.assertion_to_asserter, assertion_id);
        
        // find assertion by id
        let assertion_table     = borrow_global_mut<AssertionTable>(asserter_addr);
        let assertion           = smart_table::borrow_mut(&mut assertion_table.assertions, assertion_id);

        let (_, _, validate_disputers) = escalation_manager::get_assertion_policy();

        // require dispute callers to be whitelisted 
        if(validate_disputers){
            let whitelistedBool = escalation_manager::is_dispute_allowed(signer::address_of(disputer));
            assert!(whitelistedBool, ERROR_NOT_WHITELISTED_DISPUTER);
        };

        // verify assertion is not expired        
        assert!(assertion.expiration_time > current_timestamp, ERROR_ASSERTION_IS_EXPIRED);

        if(option::is_some(&assertion.disputer)){
            abort ERROR_ASSERTION_ALREADY_DISPUTED
        };

        assertion.disputer = option::some(signer::address_of(disputer));

        // transfer bond from disputer
        let currency_metadata = option::destroy_some(admin_properties.currency_metadata);
        primary_fungible_store::transfer(disputer, currency_metadata, oracle_signer_addr, assertion.bond);

        // emit event for assertion disputed
        event::emit(AssertionDisputedEvent {
            assertion_id,
            disputer: signer::address_of(disputer)
        });

    }


    /**
     * @notice Resolves an assertion. If the assertion has not been disputed, the assertion is resolved as true and the
     * asserter receives the bond. If the assertion has been disputed, the assertion is resolved depending on the
     * result. Based on the result, the asserter or disputer receives the bond. If the assertion was disputed then an
     * amount of the bond is sent to a treasury as a fee based on the burnedBondPercentage. The remainder of
     * the bond is returned to the asserter or disputer.
     * @param assertionId unique identifier for the assertion to resolve.
     */
    public entry fun settle_assertion(
        settle_caller: &signer,
        assertion_id: vector<u8>
    ) acquires AssertionTable, AssertionRegistry, OracleSigner, AdminProperties {

        let oracle_signer_addr = get_oracle_signer_addr();
        let oracle_signer      = get_oracle_signer(oracle_signer_addr);
        let assertion_registry = borrow_global_mut<AssertionRegistry>(oracle_signer_addr);
        let admin_properties   = borrow_global<AdminProperties>(oracle_signer_addr);
        let currency_metadata  = option::destroy_some(admin_properties.currency_metadata);
        let current_timestamp  = timestamp::now_microseconds();

        // get asserter address from registry
        let asserter_addr       = *smart_table::borrow(&assertion_registry.assertion_to_asserter, assertion_id);
        
        // find assertion by id
        let assertion_table     = borrow_global_mut<AssertionTable>(asserter_addr);
        let assertion           = smart_table::borrow_mut(&mut assertion_table.assertions, assertion_id);

        // verify assertion not already settled
        assert!(!assertion.settled, ERROR_ASSERTION_ALREADY_SETTLED);

        // set settled to true
        assertion.settled = true;

        if(!option::is_some(&assertion.disputer)){
            // no dispute, settle with the asserter 

            // verify assertion has expired
            assert!(assertion.expiration_time <= current_timestamp, ERROR_ASSERTION_NOT_EXPIRED);
            assertion.settlement_resolution = true;

            // transfer bond back to asserter
            primary_fungible_store::transfer(&oracle_signer, currency_metadata, assertion.asserter, assertion.bond);

            // emit event for assertion settled
            event::emit(AssertionSettledEvent {
                assertion_id,
                bond_recipient: assertion.asserter,
                disputed: false,
                settlement_resolution: assertion.settlement_resolution,
                settle_caller: signer::address_of(settle_caller)
            });

        } else {
            // there is a dispute

            // get resolution from the escalation manager, reverts if resolution not settled yet
            let time            = bcs::to_bytes<u64>(&assertion.assertion_time); 
            let ancillary_data  = stamp_assertion(assertion_id, assertion.asserter);
            let resolution      = escalation_manager::get_resolution(time, assertion.identifier, ancillary_data);

            // set assertion settlement resolution
            assertion.settlement_resolution = resolution == NUMERICAL_TRUE;

            let bond_recipient;
            let settlement_resolution = false;
            if(resolution == NUMERICAL_TRUE){
                bond_recipient = assertion.asserter;
                settlement_resolution = true;
            } else {
                bond_recipient = option::destroy_some(assertion.disputer);
            };

            // Calculate oracle fee and the remaining amount of bonds to send to the correct party (asserter or disputer).
            let oracle_fee = (admin_properties.burned_bond_percentage * assertion.bond) / 10000;
            let bond_recipient_amount = (assertion.bond * 2) - oracle_fee; 

            // transfer bond to treasury and bond recipient
            primary_fungible_store::transfer(&oracle_signer, currency_metadata, admin_properties.treasury_address, oracle_fee);
            primary_fungible_store::transfer(&oracle_signer, currency_metadata, bond_recipient, bond_recipient_amount);

            // emit event for assertion settled
            event::emit(AssertionSettledEvent {
                assertion_id,
                bond_recipient,
                disputed: true,
                settlement_resolution,
                settle_caller: signer::address_of(settle_caller)
            });
            
        };
        
    }

    // -----------------------------------
    // Views
    // -----------------------------------

    #[view]
    public fun get_admin_properties(): (
        u64, u64, u64, address, Object<Metadata>
    ) acquires AdminProperties {

        let oracle_signer_addr = get_oracle_signer_addr();
        let admin_properties   = borrow_global_mut<AdminProperties>(oracle_signer_addr);

        // return admin_properties values
        (
            admin_properties.default_fee,
            admin_properties.burned_bond_percentage,
            admin_properties.min_liveness,
            admin_properties.treasury_address,
            option::destroy_some(admin_properties.currency_metadata)
        )
    }

    #[view]
    public fun get_assertion_id(
        asserter: address,
        claim: vector<u8>, 
        time: u64,
        bond: u64, 
        liveness: u64,
        identifier: vector<u8>
    ) : vector<u8> {
        get_assertion_id_helper(
            asserter,
            claim, 
            time,
            bond,
            liveness,
            identifier
        )
    }

    #[view]
    public fun get_assertion(assertion_id: vector<u8>) : (
        address, bool, bool, u64, u64, u64, vector<u8>, u64, Option<address>
    ) acquires AssertionRegistry, AssertionTable {

        let oracle_signer_addr     = get_oracle_signer_addr();
        let assertion_registry_ref = borrow_global<AssertionRegistry>(oracle_signer_addr);
        
        // get asserter address from registry
        let asserter_addr          = *smart_table::borrow(&assertion_registry_ref.assertion_to_asserter, assertion_id);
        
        // find assertion by id
        let assertion_table_ref    = borrow_global<AssertionTable>(asserter_addr);
        let assertion_ref          = smart_table::borrow(&assertion_table_ref.assertions, assertion_id);
        
        // return the necessary fields from the assertion
        (
            assertion_ref.asserter,
            assertion_ref.settled,
            assertion_ref.settlement_resolution,
            assertion_ref.liveness,
            assertion_ref.assertion_time,
            assertion_ref.expiration_time,
            assertion_ref.identifier,
            assertion_ref.bond,
            assertion_ref.disputer
        )
    }

    // Returns the unique identifier for this assertion. This identifier is used to identify the assertion.
    // note: originally used as an inline function, however due to the test coverage bug we use a view instead to reach 100% test coverage
    #[view]
    public fun get_assertion_id_helper(
        asserter: address,
        claim: vector<u8>, 
        time: u64,
        bond: u64, 
        liveness: u64,
        identifier: vector<u8>
    ): vector<u8> {
        
        let asserter_bytes = bcs::to_bytes<address>(&asserter);
        let time_bytes     = bcs::to_bytes<u64>(&time);
        let bond_bytes     = bcs::to_bytes<u64>(&bond);
        let liveness_bytes = bcs::to_bytes<u64>(&liveness);
        
        let assertion_id_vector = vector::empty<u8>();
        vector::append(&mut assertion_id_vector, asserter_bytes);
        vector::append(&mut assertion_id_vector, claim);
        vector::append(&mut assertion_id_vector, time_bytes);
        vector::append(&mut assertion_id_vector, bond_bytes);
        vector::append(&mut assertion_id_vector, liveness_bytes);
        vector::append(&mut assertion_id_vector, identifier);
        aptos_hash::keccak256(assertion_id_vector)
    }


    // stamp assertion - i.e. ancillary data
    // Returns ancillary data for the Oracle request containing assertionId and asserter.
    // note: originally used as an inline function, however due to the test coverage bug we use a view instead to reach 100% test coverage
    #[view]
    public fun stamp_assertion(assertion_id: vector<u8>, asserter: address) : vector<u8> {
        let ancillary_data_vector = vector::empty<u8>();
        vector::append(&mut ancillary_data_vector, b"assertionId: ");
        vector::append(&mut ancillary_data_vector, assertion_id);
        vector::append(&mut ancillary_data_vector, b",ooAsserter:");
        vector::append(&mut ancillary_data_vector, bcs::to_bytes<address>(&asserter));
        ancillary_data_vector
    }

    // -----------------------------------
    // Helpers
    // -----------------------------------

    fun get_oracle_signer_addr(): address {
        object::create_object_address(&@aptosforo_addr, APP_OBJECT_SEED)
    }

    fun get_oracle_signer(oracle_signer_addr: address): signer acquires OracleSigner {
        object::generate_signer_for_extending(&borrow_global<OracleSigner>(oracle_signer_addr).extend_ref)
    }

    // -----------------------------------
    // Unit Tests
    // -----------------------------------

    #[test_only]
    use aptos_framework::account;

    #[test_only]
    public fun setup_test(
        aptos_framework : &signer, 
        optimistic_oracle : &signer,
        user_one : &signer,
        user_two : &signer,
    ) : (address, address, address) {

        init_module(optimistic_oracle);

        timestamp::set_time_has_started_for_testing(aptos_framework);

        // get addresses
        let aptosforo_addr   = signer::address_of(optimistic_oracle);
        let user_one_addr    = signer::address_of(user_one);
        let user_two_addr    = signer::address_of(user_two);

        // create accounts
        account::create_account_for_test(aptosforo_addr);
        account::create_account_for_test(user_one_addr);
        account::create_account_for_test(user_two_addr);

        (aptosforo_addr, user_one_addr, user_two_addr)
    }


    #[view]
    #[test_only]
    public fun test_AssertionMadeEvent(
        assertion_id: vector<u8>, 
        claim: vector<u8>,
        identifier: vector<u8>,
        asserter: address,
        liveness: u64,
        start_time: u64,
        end_time: u64,
        bond: u64
    ): AssertionMadeEvent {
        let event = AssertionMadeEvent{
            assertion_id,
            claim,
            identifier,
            asserter,
            liveness,
            start_time,
            end_time,
            bond
        };
        return event
    }


    #[view]
    #[test_only]
    public fun test_AssertionDisputedEvent(
        assertion_id: vector<u8>, 
        disputer: address
    ): AssertionDisputedEvent {
        let event = AssertionDisputedEvent{
            assertion_id,
            disputer
        };
        return event
    }


    #[view]
    #[test_only]
    public fun test_AssertionSettledEvent(
        assertion_id: vector<u8>, 
        bond_recipient: address,
        disputed: bool,
        settlement_resolution: bool,
        settle_caller: address
    ): AssertionSettledEvent {
        let event = AssertionSettledEvent{
            assertion_id,
            bond_recipient,
            disputed,
            settlement_resolution,
            settle_caller
        };
        return event
    }

}