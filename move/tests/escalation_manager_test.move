#[test_only]
module aptosforo_addr::escalation_manager_test {

    use aptosforo_addr::escalation_manager;

    use std::bcs;
    
    use aptos_std::smart_table::{SmartTable};
    
    use aptos_framework::timestamp;
    use aptos_framework::event::{ was_event_emitted };

    // -----------------------------------
    // Errors
    // -----------------------------------

    const ERROR_NOT_ADMIN : u64                             = 1;
    const ERROR_ARBITRATION_RESOLUTION_NOT_FOUND: u64       = 2;
    const ERROR_RESOLUTION_ALREADY_RESOLVED: u64            = 3;
    const ERROR_ARBITRATION_RESOLUTION_NOT_SET: u64         = 4;

    // -----------------------------------
    // Constants
    // -----------------------------------

    // note: we use numerical true/false since UMA oracle/escalation_manager may return price data if required
    const NUMERICAL_TRUE: u8  = 1; // Numerical representation of true.
    const NUMERICAL_FALSE: u8 = 0; // Numerical representation of false.

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
    // Unit Tests
    // -----------------------------------

    #[test(aptos_framework = @0x1, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    public entry fun test_admin_can_set_assertion_policy(
        aptos_framework: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        let block_assertion    = true;
        let validate_asserters = true;
        let validate_disputers = true;

        // call set_assertion_policy
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // check views
        let (policy_block_assertion, policy_validate_asserters, policy_validate_disputers) = escalation_manager::get_assertion_policy();
        assert!(policy_block_assertion      == block_assertion      , 100);
        assert!(policy_validate_asserters   == validate_asserters   , 101);
        assert!(policy_validate_disputers   == validate_disputers   , 102);
    }


    #[test(aptos_framework = @0x1, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_NOT_ADMIN, location = escalation_manager)]
    public entry fun test_non_admin_cannot_set_assertion_policy(
        aptos_framework: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        let block_assertion    = true;
        let validate_asserters = true;
        let validate_disputers = true;

        // call set_assertion_policy
        escalation_manager::set_assertion_policy(
            user_two,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

    }

    #[test(aptos_framework = @0x1, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    public entry fun test_admin_can_set_whitelisted_asserter_and_disputer(
        aptos_framework: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_escalation_manager_addr, user_one_addr, _user_two_addr) = escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        // call set_whitelisted_asserter
        escalation_manager::set_whitelisted_asserter(
            escalation_manager,
            user_one_addr,
            true
        );

        // call set_whitelisted_dispute_caller
        escalation_manager::set_whitelisted_dispute_caller(
            escalation_manager,
            user_one_addr,
            true
        );

        // check views
        let is_assert_allowed = escalation_manager::is_assert_allowed(user_one_addr);
        assert!(is_assert_allowed == true, 100);

        let is_dispute_allowed = escalation_manager::is_dispute_allowed(user_one_addr);
        assert!(is_dispute_allowed == true, 100);
    }


    #[test(aptos_framework = @0x1, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_NOT_ADMIN, location = escalation_manager)]
    public entry fun test_non_admin_cannot_set_whitelisted_asserter(
        aptos_framework: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_escalation_manager_addr, user_one_addr, _user_two_addr) = escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        // call set_whitelisted_asserter
        escalation_manager::set_whitelisted_asserter(
            user_one,
            user_one_addr,
            true
        );

    }


    #[test(aptos_framework = @0x1, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_NOT_ADMIN, location = escalation_manager)]
    public entry fun test_non_admin_cannot_set_whitelisted_dispute_caller(
        aptos_framework: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_escalation_manager_addr, user_one_addr, _user_two_addr) = escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        // call set_whitelisted_disputer
        escalation_manager::set_whitelisted_dispute_caller(
            user_one,
            user_one_addr,
            true
        );
    }


    #[test(aptos_framework = @0x1, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    public entry fun test_view_non_whitelisted_dispute_caller_not_allowed(
        aptos_framework: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_escalation_manager_addr, user_one_addr, _user_two_addr) = escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        // call is_dispute_allowed
        let is_dispute_allowed = escalation_manager::is_dispute_allowed(user_one_addr);
        assert!(is_dispute_allowed == false, 100);
    }


    #[test(aptos_framework = @0x1, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    public entry fun test_view_non_whitelisted_asserter_not_allowed(
        aptos_framework: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_escalation_manager_addr, user_one_addr, _user_two_addr) = escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        // call is_assert_allowed
        let is_assert_allowed = escalation_manager::is_assert_allowed(user_one_addr);
        assert!(is_assert_allowed == false, 100);
    }


    #[test(aptos_framework = @0x1, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    public entry fun test_admin_can_set_arbitration_resolution(
        aptos_framework: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_escalation_manager_addr, _user_one_addr, _user_two_addr) = escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        // sample data
        let raw_time                = timestamp::now_microseconds();  
        let time                    = bcs::to_bytes<u64>(&raw_time); 
        let identifier              = b"identifier";
        let ancillary_data          = b"ancillary_data";
        let arbitration_resolution  = true;
        let override                = false;

        // call set_whitelisted_asserter
        escalation_manager::set_arbitration_resolution(
            escalation_manager,
            time,
            identifier,
            ancillary_data,
            arbitration_resolution,
            override
        );

        // get request id
        let request_id = escalation_manager::get_request_id(time, identifier, ancillary_data);

        // create instance of expected event
        let arbitration_resolution_set_event = escalation_manager::test_ArbitrationResolutionSetEvent(
            request_id,
            identifier,
            ancillary_data,
            arbitration_resolution
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&arbitration_resolution_set_event), 100);

        // test get resolution view
        let view_resolution = escalation_manager::get_resolution(
            time,
            identifier,
            ancillary_data
        );
        assert!(view_resolution == NUMERICAL_TRUE, 101);

    }


    #[test(aptos_framework = @0x1, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_NOT_ADMIN, location = escalation_manager)]
    public entry fun test_non_admin_cannot_set_arbitration_resolution(
        aptos_framework: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_escalation_manager_addr, _user_one_addr, _user_two_addr) = escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        // sample data
        let raw_time                = timestamp::now_microseconds();  
        let time                    = bcs::to_bytes<u64>(&raw_time); 
        let identifier              = b"identifier";
        let ancillary_data          = b"ancillary_data";
        let arbitration_resolution  = true;
        let override                = false;

        // call set_whitelisted_asserter
        escalation_manager::set_arbitration_resolution(
            user_one,
            time,
            identifier,
            ancillary_data,
            arbitration_resolution,
            override
        );

    }


    #[test(aptos_framework = @0x1, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_RESOLUTION_ALREADY_RESOLVED, location = escalation_manager)]
    public entry fun test_arbitration_resolution_cannot_be_resolved_twice_if_override_set_to_false(
        aptos_framework: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_escalation_manager_addr, _user_one_addr, _user_two_addr) = escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        // sample data
        let raw_time                = timestamp::now_microseconds();  
        let time                    = bcs::to_bytes<u64>(&raw_time); 
        let identifier              = b"identifier";
        let ancillary_data          = b"ancillary_data";
        let arbitration_resolution  = true;
        let override                = false;

        // call set_whitelisted_asserter
        escalation_manager::set_arbitration_resolution(
            escalation_manager,
            time,
            identifier,
            ancillary_data,
            arbitration_resolution,
            override
        );

        // should fail since it is already resolved
        escalation_manager::set_arbitration_resolution(
            escalation_manager,
            time,
            identifier,
            ancillary_data,
            arbitration_resolution,
            override
        );

    }


    #[test(aptos_framework = @0x1, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    public entry fun test_arbitration_resolution_can_be_resolved_twice_if_override_set_to_true(
        aptos_framework: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_escalation_manager_addr, _user_one_addr, _user_two_addr) = escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        // sample data
        let raw_time                = timestamp::now_microseconds();  
        let time                    = bcs::to_bytes<u64>(&raw_time); 
        let identifier              = b"identifier";
        let ancillary_data          = b"ancillary_data";
        let arbitration_resolution  = true;
        let override                = true;

        // call set_whitelisted_asserter
        escalation_manager::set_arbitration_resolution(
            escalation_manager,
            time,
            identifier,
            ancillary_data,
            arbitration_resolution,
            override
        );

        // view_resolution should be true
        let view_resolution = escalation_manager::get_resolution(
            time,
            identifier,
            ancillary_data
        );
        assert!(view_resolution == NUMERICAL_TRUE, 100);

        let new_arbitration_resolution  = false;

        // should pass as override set to true
        escalation_manager::set_arbitration_resolution(
            escalation_manager,
            time,
            identifier,
            ancillary_data,
            new_arbitration_resolution,
            override
        );

        // view_resolution should now be false
        let view_resolution = escalation_manager::get_resolution(
            time,
            identifier,
            ancillary_data
        );
        assert!(view_resolution == NUMERICAL_FALSE, 101);

    }


    #[test(aptos_framework = @0x1, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_ARBITRATION_RESOLUTION_NOT_FOUND, location = escalation_manager)]
    public entry fun test_arbitration_resolution_not_found(
        aptos_framework: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_escalation_manager_addr, _user_one_addr, _user_two_addr) = escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        // sample data
        let raw_time                = timestamp::now_microseconds();  
        let time                    = bcs::to_bytes<u64>(&raw_time); 
        let identifier              = b"identifier";
        let ancillary_data          = b"ancillary_data";

        // test get resolution view
        escalation_manager::get_resolution(
            time,
            identifier,
            ancillary_data
        );

    }
    
}