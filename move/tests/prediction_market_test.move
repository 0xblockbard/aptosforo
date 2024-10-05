#[test_only]
module optimistic_oracle_addr::prediction_market_test {

    use optimistic_oracle_addr::escalation_manager;
    use optimistic_oracle_addr::prediction_market;
    use optimistic_oracle_addr::oracle_token;

    use std::bcs;
    use std::signer;
    use std::vector;
    use std::option::{Self, Option};

    use aptos_std::aptos_hash;
    use aptos_std::smart_table::{SmartTable};

    use aptos_framework::timestamp;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::event::{ was_event_emitted };
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::fungible_asset::{MintRef, TransferRef, BurnRef, Metadata};

    // -----------------------------------
    // Errors
    // -----------------------------------

    const ERROR_NOT_ADMIN : u64                             = 1;

    // continued after escalation manager errors
    const ERROR_ASSERT_IS_BLOCKED: u64                      = 5;
    const ERROR_NOT_WHITELISTED_ASSERTER: u64               = 6;
    const ERROR_NOT_WHITELISTED_DISPUTER: u64               = 7;
    const ERROR_BURNED_BOND_PERCENTAGE_EXCEEDS_HUNDRED: u64 = 8;
    const ERROR_BURNED_BOND_PERCENTAGE_IS_ZERO: u64         = 9;
    const ERROR_ASSERTION_IS_EXPIRED: u64                   = 10;
    const ERROR_ASSERTION_ALREADY_DISPUTED: u64             = 11;
    const ERROR_MINIMUM_BOND_NOT_REACHED: u64               = 12;
    const ERROR_MINIMUM_LIVENESS_NOT_REACHED: u64           = 13;
    const ERROR_ASSERTION_ALREADY_SETTLED: u64              = 14;
    const ERROR_ASSERTION_NOT_EXPIRED: u64                  = 15;
    const ERROR_ASSERTION_ALREADY_EXISTS: u64               = 16;

    // prediction market specific errors
    const ERROR_EMPTY_FIRST_OUTCOME: u64                    = 17;
    const ERROR_EMPTY_SECOND_OUTCOME: u64                   = 18;
    const ERROR_OUTCOMES_ARE_THE_SAME: u64                  = 19;
    const ERROR_EMPTY_DESCRIPTION: u64                      = 20;
    const ERROR_MARKET_ALREADY_EXISTS: u64                  = 21;
    const ERROR_MARKET_DOES_NOT_EXIST: u64                  = 22;
    const ERROR_ASSERTION_ACTIVE_OR_RESOLVED: u64           = 23;
    const ERROR_INVALID_ASSERTED_OUTCOME: u64               = 24;
    const ERROR_MARKET_HAS_BEEN_RESOLVED: u64               = 25;
    const ERROR_MARKET_HAS_NOT_BEEN_RESOLVED: u64           = 26;
    const ERROR_POOL_ALREADY_INITIALIZED: u64               = 27;
    const ERROR_POOL_NOT_INITIALIZED: u64                   = 28;
    const ERROR_DEFAULT_MIN_LIQUIDITY_NOT_REACHED: u64      = 29;
    const ERROR_INSUFFICIENT_LP_BALANCE: u64                = 30;
    const ERROR_INVALID_OUTCOME: u64                        = 31;
    const ERROR_INSUFFICIENT_OUTPUT_AMOUNT: u64             = 32;
    const ERROR_INSUFFICIENT_POOL_OUTCOME_TOKENS: u64       = 33;

    // -----------------------------------
    // Constants
    // -----------------------------------

    // note: we use numerical true/false since UMA oracle/escalation_manager may return price data if required
    const NUMERICAL_TRUE: u8                          = 1;    // Numerical representation of true.
    const NUMERICAL_FALSE: u8                         = 0;    // Numerical representation of false.
    
    const DEFAULT_MIN_LIVENESS: u64                   = 7200; // 2 hours
    const DEFAULT_FEE: u64                            = 1000;
    const DEFAULT_SWAP_FEE_PERCENT: u128              = 2;    // 0.02%
    const DEFAULT_BURNED_BOND_PERCENTAGE: u64         = 1000;
    const DEFAULT_TREASURY_ADDRESS: address           = @optimistic_oracle_addr;
    const DEFAULT_IDENTIFIER: vector<u8>              = b"YES/NO";        // Identifier used for all prediction markets.
    const UNRESOLVABLE: vector<u8>                    = b"Unresolvable";  // Name of the unresolvable outcome where payouts are split.

    const DEFAULT_OUTCOME_TOKEN_ICON: vector<u8>      = b"http://example.com/favicon.ico";
    const DEFAULT_OUTCOME_TOKEN_WEBSITE: vector<u8>   = b"http://example.com";

    const DEFAULT_MIN_LIQUIDITY_REQUIRED: u128         = 100;
    const FIXED_POINT_ACCURACY: u128                   = 1_000_000_000_000_000_000;  // 10^18 for fixed point arithmetic
    
    // -----------------------------------
    // Structs
    // -----------------------------------

    // Management struct for control of outcome tokens
    struct Management has key, store {
        extend_ref: ExtendRef,
        mint_ref: MintRef,
        burn_ref: BurnRef,
        transfer_ref: TransferRef,
    }

    /// Market Struct
    struct Market has key, store {
        creator: address,
        resolved: bool,                      // True if the market has been resolved and payouts can be settled.
        asserted_outcome_id: vector<u8>,     // Hash of asserted outcome (outcome1, outcome2 or unresolvable).
        reward: u64,                         // Reward available for asserting true market outcome.
        required_bond: u64,                  // Expected bond to assert market outcome (OOv3 can require higher bond).
        outcome_one: vector<u8>,             // Short name of the first outcome.
        outcome_two: vector<u8>,             // Short name of the second outcome.
        description: vector<u8>,             // Description of the market.
        image_url: vector<u8>,               // Image of the market.

        outcome_token_one_metadata: Object<Metadata>, // simple move token representing the value of the first outcome.
        outcome_token_two_metadata: Object<Metadata>, // simple move token representing the value of the second outcome.

        outcome_token_one_address: address,
        outcome_token_two_address: address,
    }

    /// Markets Struct
    struct Markets has key, store {
        market_table: SmartTable<vector<u8>, Market> // Maps marketId to Market struct.
    }

    /// Asserted Market Struct
    struct AssertedMarket has key, store, drop {
        asserter: address,      // Address of the asserter used for reward payout.
        market_id: vector<u8>   // Identifier for markets mapping.
    }

    /// Asserted Markets Struct
    struct AssertedMarkets has key, store {
        assertion_to_market: SmartTable<vector<u8>, AssertedMarket> // Maps assertion id to AssertedMarket
    }

    /// MarketRegistry Struct
    struct MarketRegistry has key, store {
        market_to_creator: SmartTable<vector<u8>, address> // Maps market id to creator
    }

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

    struct LiquidityPool has key, store {
        market_id: u64,
        initializer: address,
        
        outcome_token_one_reserve: u128,      // amount of protocol tokens backing outcome token one (on prod, could be USDC etc)
        outcome_token_two_reserve: u128,      // amount of protocol tokens backing outcome token two (on prod, could be USDC etc)
                
        lp_total_supply: u128,
        lp_token_metadata: Object<Metadata>,
        lp_token_address: address
    }

    struct LiquidityPools has key, store {
        pools: SmartTable<u64, LiquidityPool>, // market_id -> LiquidityPool
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
    // Unit Tests
    // -----------------------------------

    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, user_one = @0x333, user_two = @0x444)]
    public entry fun test_admin_can_set_admin_properties(
        aptos_framework: &signer,
        prediction_market: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, _user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        let oracle_token_metadata   = oracle_token::metadata();
        let min_liveness            = 1000;
        let default_fee             = 100;
        let treasury_addr           = user_one_addr;
        let burned_bond_percentage  = 100;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // check views
        let (
            prop_default_fee, 
            prop_burned_bond_percentage, 
            prop_min_liveness, 
            prop_treasury_addr, 
            prop_swap_fee_percent, 
            prop_min_liquidity_required, 
            prop_currency_metadata
        ) = prediction_market::get_admin_properties();

        assert!(prop_min_liveness             == min_liveness                   , 100);
        assert!(prop_default_fee              == default_fee                    , 101);
        assert!(prop_treasury_addr            == treasury_addr                  , 102);
        assert!(prop_burned_bond_percentage   == burned_bond_percentage         , 103);
        assert!(prop_swap_fee_percent         == DEFAULT_SWAP_FEE_PERCENT       , 104);
        assert!(prop_min_liquidity_required   == DEFAULT_MIN_LIQUIDITY_REQUIRED , 105);
        assert!(prop_currency_metadata        == oracle_token_metadata          , 106);
    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_NOT_ADMIN, location = prediction_market)]
    public entry fun test_non_admin_cannot_set_admin_properties(
        aptos_framework: &signer,
        prediction_market: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, _user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        let oracle_token_metadata   = oracle_token::metadata();
        let min_liveness            = 1000;
        let default_fee             = 100;
        let treasury_addr           = user_one_addr;
        let burned_bond_percentage  = 100;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            user_one,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );
    }
    

    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_BURNED_BOND_PERCENTAGE_EXCEEDS_HUNDRED, location = prediction_market)]
    public entry fun test_set_admin_properties_burned_bond_percentage_cannot_exceed_hundred(
        aptos_framework: &signer,
        prediction_market: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, _user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        let oracle_token_metadata   = oracle_token::metadata();
        let min_liveness            = 1000;
        let default_fee             = 100;
        let treasury_addr           = user_one_addr;
        let burned_bond_percentage  = 10001; // should fail

        // should fail
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );
    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_BURNED_BOND_PERCENTAGE_IS_ZERO, location = prediction_market)]
    public entry fun test_set_admin_properties_burned_bond_percentage_cannot_be_zero(
        aptos_framework: &signer,
        prediction_market: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, _user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        let oracle_token_metadata   = oracle_token::metadata();
        let min_liveness            = 1000;
        let default_fee             = 100;
        let treasury_addr           = user_one_addr;
        let burned_bond_percentage  = 0; // should fail

        // should fail
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );
    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, user_one = @0x333, user_two = @0x444)]
    public entry fun test_anyone_can_initialize_a_new_market(
        aptos_framework: &signer,
        prediction_market: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, _user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one for bond
        let mint_amount = 1_000_000_000;
        oracle_token::mint(prediction_market, user_one_addr, mint_amount);

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // get market id
        let current_timestamp   = timestamp::now_microseconds();  
        // let time_bytes          = bcs::to_bytes<u64>(&current_timestamp);
        // let market_id           = prediction_market::get_market_id(user_one_addr, time_bytes, description);

        // test view get market
        let (
            creator,
            resolved,
            asserted_outcome_id,
            reward,
            required_bond,
            view_outcome_one,
            view_outcome_two,
            view_description,
            view_image_url,
            view_categories,
            view_start_timestamp,
            outcome_token_one_metadata,
            outcome_token_two_metadata,
            outcome_token_one_address,
            outcome_token_two_address,
            pool_initialized,
            pool_initializer
        ) = prediction_market::get_market(market_id);

        assert!(creator              == user_one_addr        , 100);
        assert!(resolved             == false                , 101);
        assert!(asserted_outcome_id  == vector::empty<u8>()  , 102);
        assert!(reward               == reward               , 103);
        assert!(required_bond        == required_bond        , 104);

        assert!(view_outcome_one     == outcome_one          , 105);
        assert!(view_outcome_two     == outcome_two          , 106);
        assert!(view_description     == description          , 107);
        assert!(view_image_url       == image_url            , 108);

        assert!(view_categories      == b""                  , 109);
        assert!(view_start_timestamp == current_timestamp    , 110);

        assert!(pool_initialized     == false                , 111);
        assert!(pool_initializer     == option::none()       , 112);
        

        // create instance of expected event
        let market_initialized_event = prediction_market::test_MarketInitializedEvent(
            user_one_addr,          
            market_id,      
            outcome_one,
            outcome_two, 
            description,
            image_url,
            reward,
            required_bond,

            outcome_token_one_metadata,
            outcome_token_two_metadata,

            outcome_token_one_address,
            outcome_token_two_address
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&market_initialized_event), 113);
    }

    
    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_EMPTY_FIRST_OUTCOME, location = prediction_market)]
    public entry fun test_outcome_one_cannot_be_empty_to_initialize_market(
        aptos_framework: &signer,
        prediction_market: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, _user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one for bond
        let mint_amount = 1_000_000_000;
        oracle_token::mint(prediction_market, user_one_addr, mint_amount);

        // init market params
        let outcome_one             = b"";  // should fail
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // should fail
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );
    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_EMPTY_SECOND_OUTCOME, location = prediction_market)]
    public entry fun test_outcome_two_cannot_be_empty_to_initialize_market(
        aptos_framework: &signer,
        prediction_market: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, _user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one for bond
        let mint_amount = 1_000_000_000;
        oracle_token::mint(prediction_market, user_one_addr, mint_amount);

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b""; // should fail
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // should fail
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );
    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_OUTCOMES_ARE_THE_SAME, location = prediction_market)]
    public entry fun test_outcome_two_cannot_be_equal_to_outcome_one_to_initialize_market(
        aptos_framework: &signer,
        prediction_market: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, _user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one for bond
        let mint_amount = 1_000_000_000;
        oracle_token::mint(prediction_market, user_one_addr, mint_amount);

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome One"; // should fail
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // should fail
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );
    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_EMPTY_DESCRIPTION, location = prediction_market)]
    public entry fun test_description_cannot_be_empty_to_initialize_market(
        aptos_framework: &signer,
        prediction_market: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, _user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one for bond
        let mint_amount = 1_000_000_000;
        oracle_token::mint(prediction_market, user_one_addr, mint_amount);

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b""; // should fail
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // should fail
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );
    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, user_one = @0x333, user_two = @0x444)]
    public entry fun test_identical_market_can_be_initialized_again_since_we_go_by_market_id(
        aptos_framework: &signer,
        prediction_market: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, _user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one for bond
        let mint_amount = 1_000_000_000;
        oracle_token::mint(prediction_market, user_one_addr, mint_amount);

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two"; 
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // should work
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // should fail 
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );
    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    public entry fun test_assert_market_end_to_end_without_dispute(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);
        
        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = true;

        // call set_assertion_policy to set validate_asserters to false
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one and two
        let mint_amount = 100_000_000;
        oracle_token::mint(prediction_market, user_one_addr, mint_amount);
        oracle_token::mint(prediction_market, user_two_addr, mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = user_one_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // ----------------------------------
        // Initialize Market
        // ----------------------------------

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 100_000; 
        let required_bond           = 100_000;
        
        // get balance
        let initial_initializer_balance = primary_fungible_store::balance(user_one_addr, oracle_token_metadata);

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // check that reward was transferred
        let updated_initializer_balance = primary_fungible_store::balance(user_one_addr, oracle_token_metadata);
        assert!(updated_initializer_balance == initial_initializer_balance - reward, 100);

        // ----------------------------------
        // Assert Market
        // ----------------------------------

        // init params for truth assertion
        let asserted_outcome = outcome_one; // we assert outcome one is correct

        // get next assertion id
        let assertion_id = prediction_market::get_next_assertion_id();

        // user two to call assert_market
        prediction_market::assert_market(
            user_two,
            market_id,
            asserted_outcome
        );

        let minimum_bond = (DEFAULT_FEE * 10000) / DEFAULT_BURNED_BOND_PERCENTAGE;
        let bond;
        if(required_bond > minimum_bond){
            bond =  required_bond;
        } else {
            bond = minimum_bond;
        };

        // bond is transferred from asserter to module
        let asserter_balance = primary_fungible_store::balance(user_two_addr, oracle_token_metadata);
        assert!(asserter_balance == mint_amount - bond, 100);

        // ----------------------------------
        // Get assertion id and market info
        // ----------------------------------

        // get the assertion id
        let liveness     = DEFAULT_MIN_LIVENESS;

        // get market view
        let (
            _creator,
            _resolved,
            _asserted_outcome_id,
            _reward,
            _required_bond,
            _view_outcome_one,
            _view_outcome_two,
            _view_description,
            _view_image_url,
            _view_categories,
            _view_start_timestamp,
            outcome_token_one_metadata,
            outcome_token_two_metadata,
            _outcome_token_one_address,
            _outcome_token_two_address,
            _pool_initialized,
            _pool_initializer
        ) = prediction_market::get_market(market_id);

        // ----------------------------------
        // Initialize Liquidity Pool
        // ----------------------------------

        let initial_liquidity            = (100_000 as u128);
        let initial_oracle_token_balance = primary_fungible_store::balance(user_one_addr, oracle_token_metadata);

        prediction_market::initialize_pool(user_one, market_id, initial_liquidity);

        let updated_oracle_token_balance = primary_fungible_store::balance(user_one_addr, oracle_token_metadata);

        // check that oracle token was sent by user to be used as collateral
        assert!(updated_oracle_token_balance == initial_oracle_token_balance - (initial_liquidity as u64), 101);

        // create instance of expected event
        let pool_initialized_event = prediction_market::test_PoolInitializedEvent(
            user_one_addr,
            market_id,
            (initial_liquidity as u64)
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&pool_initialized_event), 102);

        let (
            view_market_id,
            view_initializer,
            outcome_token_one_reserve,
            outcome_token_two_reserve,
            lp_total_supply,
            _lp_token_metadata,
            _lp_token_address
        ) = prediction_market::get_pool(market_id);

        assert!(view_market_id              == market_id             , 103);
        assert!(view_initializer            == user_one_addr         , 104);
        assert!(outcome_token_one_reserve   == initial_liquidity / 2 , 105);
        assert!(outcome_token_two_reserve   == initial_liquidity / 2 , 106);
        assert!(lp_total_supply             == initial_liquidity / 2 , 107);
        
        // ----------------------------------
        // Outcome Tokens interactions test
        // ----------------------------------

        // buy some outcome tokens for user one 
        let buy_amount      = 1000;
        let outcome_token   = b"one";

        // calc outcome token amount received
        let token_reserve     = initial_liquidity / 2;
        let amount_less_fees  = (buy_amount * (1000 - DEFAULT_SWAP_FEE_PERCENT)) / 1000;
        let token_amount_mint = (((amount_less_fees * token_reserve * FIXED_POINT_ACCURACY) / initial_liquidity) / FIXED_POINT_ACCURACY);

        prediction_market::buy_outcome_tokens(user_one, market_id, outcome_token, buy_amount);
        // user one should receive [token_amount_mint] amount of outcome one tokens

        // create instance of expected event
        let buy_outcome_tokens_event = prediction_market::test_BuyOutcomeTokensEvent(
            user_one_addr,
            market_id,
            outcome_token,
            (buy_amount as u64),
            (token_amount_mint as u64)
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&buy_outcome_tokens_event), 108);

        // buy some outcome tokens for user two
        let user_two_outcome_token = b"two";
        prediction_market::buy_outcome_tokens(user_two, market_id, user_two_outcome_token, buy_amount);

        // get pool info 
        let (
            _,
            _,
            outcome_token_one_reserve,
            outcome_token_two_reserve,
            _lp_total_supply,
            _,
            _
        ) = prediction_market::get_pool(market_id);

        // calc collateral token received after selling some outcome tokens
        let tokens_to_sell          = 100;
        let total_pool_reserves     = outcome_token_one_reserve + outcome_token_two_reserve;
        token_reserve               = outcome_token_one_reserve;
        amount_less_fees            = (tokens_to_sell * (1000 - DEFAULT_SWAP_FEE_PERCENT)) / 1000;
        let collateral_token_amount = (((amount_less_fees * total_pool_reserves * FIXED_POINT_ACCURACY) / token_reserve) / FIXED_POINT_ACCURACY);

        // user one can sell some outcome one tokens 
        prediction_market::sell_outcome_tokens(user_one, market_id, outcome_token, tokens_to_sell);

        // create instance of expected event
        let sell_outcome_tokens_event = prediction_market::test_SellOutcomeTokensEvent(
            user_one_addr,
            market_id,
            outcome_token,
            (collateral_token_amount as u64),
            (tokens_to_sell as u64)
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&sell_outcome_tokens_event), 109);

        // user two can sell some outcome two tokens 
        prediction_market::sell_outcome_tokens(user_two, market_id, user_two_outcome_token, tokens_to_sell);

        // user two can deposit liquidity 
        let deposit_amount = 1000;

        // get updated token reserves
        let (
            _,
            _,
            outcome_token_one_reserve,
            outcome_token_two_reserve,
            lp_total_supply,
            _,
            _
        ) = prediction_market::get_pool(market_id);

        total_pool_reserves     = outcome_token_one_reserve + outcome_token_two_reserve;
        let lp_tokens_to_mint   = (((deposit_amount * lp_total_supply * FIXED_POINT_ACCURACY)) / total_pool_reserves) / FIXED_POINT_ACCURACY;

        prediction_market::deposit_liquidity(user_two, market_id, deposit_amount);
        
        // create instance of expected event
        let sell_outcome_tokens_event = prediction_market::test_DepositLiquidityEvent(
            user_two_addr,
            market_id,
            (deposit_amount as u64),
            (lp_tokens_to_mint as u64)
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&sell_outcome_tokens_event), 110);

        // user two can redeem some LP for outcome tokens
        let lp_token_redeem_amount = 200;

        // get updated token reserves
        let (
            _,
            _,
            outcome_token_one_reserve,
            outcome_token_two_reserve,
            lp_total_supply,
            lp_token_metadata,
            _
        ) = prediction_market::get_pool(market_id);

        // calc outcome token amounts to be redeemed based on LP amount
        let lp_proportion                   = (lp_token_redeem_amount * FIXED_POINT_ACCURACY) / lp_total_supply;
        let redeem_outcome_token_one_amount = ((outcome_token_one_reserve * lp_proportion) / FIXED_POINT_ACCURACY);
        let redeem_outcome_token_two_amount = ((outcome_token_two_reserve * lp_proportion) / FIXED_POINT_ACCURACY);

        let initial_user_two_lp_token_balance          = primary_fungible_store::balance(user_two_addr, lp_token_metadata);
        let initial_user_two_outcome_token_one_balance = primary_fungible_store::balance(user_two_addr, outcome_token_one_metadata);
        let initial_user_two_outcome_token_two_balance = primary_fungible_store::balance(user_two_addr, outcome_token_two_metadata);

        prediction_market::redeem_lp_for_outcome_tokens(user_two, market_id, lp_token_redeem_amount);

        let updated_user_two_lp_token_balance          = primary_fungible_store::balance(user_two_addr, lp_token_metadata);
        let updated_user_two_outcome_token_one_balance = primary_fungible_store::balance(user_two_addr, outcome_token_one_metadata);
        let updated_user_two_outcome_token_two_balance = primary_fungible_store::balance(user_two_addr, outcome_token_two_metadata);

        // check correct outcome token amounts redeemed, and LP tokens burnt
        assert!(updated_user_two_outcome_token_one_balance == initial_user_two_outcome_token_one_balance + (redeem_outcome_token_one_amount as u64) , 111);
        assert!(updated_user_two_outcome_token_two_balance == initial_user_two_outcome_token_two_balance + (redeem_outcome_token_two_amount as u64) , 112);
        assert!(updated_user_two_lp_token_balance          == initial_user_two_lp_token_balance - (lp_token_redeem_amount as u64)                   , 113);

        // create instance of expected event
        let redeem_lp_tokens_event = prediction_market::test_RedeemLpTokensEvent(
            user_two_addr,
            market_id,
            (lp_token_redeem_amount as u64),
            (redeem_outcome_token_one_amount as u64),
            (redeem_outcome_token_two_amount as u64)
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&redeem_lp_tokens_event), 114);

        // ----------------------------------
        // Settle Assertion
        // ----------------------------------

        // fast forward to liveness over (after assertion has expired)
        timestamp::fast_forward_seconds(liveness + 1);

        // get initial asserter alance
        let initial_asserter_balance = primary_fungible_store::balance(user_two_addr, oracle_token_metadata);

        // anyone can settle the assertion
        prediction_market::settle_assertion(
            user_two,
            assertion_id
        );

        // get asserter balance after assertion settled
        let updated_asserter_balance = primary_fungible_store::balance(user_two_addr, oracle_token_metadata);

        // asserter should have his bond returned + reward
        assert!(updated_asserter_balance == initial_asserter_balance + bond + reward, 115);

        // get views to confirm assertion has been resolved
        let (
            _asserter, 
            settled, 
            settlement_resolution, 
            _liveness, 
            _assertion_time, 
            _expiration_time, 
            _identifier, 
            _bond, 
            _disputer
        ) = prediction_market::get_assertion(assertion_id);

        assert!(settled                 == true, 116);
        assert!(settlement_resolution   == true, 117);

        // create instance of expected event
        let assertion_settled_event = prediction_market::test_AssertionSettledEvent(
            assertion_id,
            user_two_addr,          // asserter is the bond recipient
            false,                  // disputed
            settlement_resolution,
            user_two_addr           // settle_caller
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&assertion_settled_event), 118);

        // ----------------------------------
        // Settle Outcome Tokens
        // ----------------------------------

        let initial_user_one_balance = primary_fungible_store::balance(user_one_addr, oracle_token_metadata);
        let initial_user_two_balance = primary_fungible_store::balance(user_two_addr, oracle_token_metadata);

        // initial outcome token one balance
        let initial_user_one_outcome_token_one_balance = primary_fungible_store::balance(user_one_addr, outcome_token_one_metadata);
        let initial_user_two_outcome_token_one_balance = primary_fungible_store::balance(user_two_addr, outcome_token_one_metadata);
        
        // initial outcome token two balance
        let initial_user_one_outcome_token_two_balance = primary_fungible_store::balance(user_one_addr, outcome_token_two_metadata);
        let initial_user_two_outcome_token_two_balance = primary_fungible_store::balance(user_two_addr, outcome_token_two_metadata);

        // get updated liquidity pool token reserves
        let (
            _,
            _,
            outcome_token_one_reserve,
            outcome_token_two_reserve,
            _lp_total_supply,
            _lp_token_metadata,
            _
        ) = prediction_market::get_pool(market_id);

        // calc user one proportion 
        total_pool_reserves     = outcome_token_one_reserve + outcome_token_two_reserve;
        let user_one_proportion = (((initial_user_one_outcome_token_one_balance as u128) * FIXED_POINT_ACCURACY) / outcome_token_one_reserve);
        let user_one_payout     = (user_one_proportion * total_pool_reserves) / FIXED_POINT_ACCURACY;

        let user_two_proportion = (((initial_user_two_outcome_token_one_balance as u128) * FIXED_POINT_ACCURACY) / outcome_token_one_reserve);
        let user_two_payout     = (user_two_proportion * total_pool_reserves) / FIXED_POINT_ACCURACY;

        // settle outcome tokens
        // as market was resolved to the first outcome, payout is based on outcome token one proportions
        prediction_market::settle_outcome_tokens(user_one, market_id);
        prediction_market::settle_outcome_tokens(user_two, market_id);
        
        let updated_user_one_balance = primary_fungible_store::balance(user_one_addr, oracle_token_metadata);
        let updated_user_two_balance = primary_fungible_store::balance(user_two_addr, oracle_token_metadata);

        assert!(updated_user_one_balance == initial_user_one_balance + (user_one_payout as u64) , 119);
        assert!(updated_user_two_balance == initial_user_two_balance + (user_two_payout as u64) , 120);

        // create instance of expected event for user one tokens settled event
        let tokens_settled_event = prediction_market::test_TokensSettledEvent(
            market_id,
            user_one_addr,
            (user_one_payout as u64),
            (initial_user_one_outcome_token_one_balance as u64),
            (initial_user_one_outcome_token_two_balance as u64)
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&tokens_settled_event), 121);

        // create instance of expected event for user two tokens settled event
        let tokens_settled_event = prediction_market::test_TokensSettledEvent(
            market_id,
            user_two_addr,
            (user_two_payout as u64),
            (initial_user_two_outcome_token_one_balance as u64),
            (initial_user_two_outcome_token_two_balance as u64)
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&tokens_settled_event), 122);

        // updated outcome token one balance
        let updated_user_one_outcome_token_one_balance = primary_fungible_store::balance(user_one_addr, outcome_token_one_metadata);
        let updated_user_two_outcome_token_one_balance = primary_fungible_store::balance(user_two_addr, outcome_token_one_metadata);

        // updated outcome token two balance
        let updated_user_one_outcome_token_two_balance = primary_fungible_store::balance(user_one_addr, outcome_token_two_metadata);
        let updated_user_two_outcome_token_two_balance = primary_fungible_store::balance(user_two_addr, outcome_token_two_metadata);

        // check all outcome token balances are now zero after settling
        assert!(updated_user_one_outcome_token_one_balance == 0, 123);
        assert!(updated_user_one_outcome_token_two_balance == 0, 124);
        assert!(updated_user_two_outcome_token_one_balance == 0, 125);
        assert!(updated_user_two_outcome_token_two_balance == 0, 126);

        // user can still redeem lp tokens for outcome tokens and settle them
        lp_token_redeem_amount = 100;
        prediction_market::redeem_lp_for_outcome_tokens(user_two, market_id, lp_token_redeem_amount);
        prediction_market::settle_outcome_tokens(user_two, market_id);

    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444, user_three = @0x555, treasury = @0x666)]
    public entry fun test_assert_truth_end_to_end_with_dispute_and_asserter_wins(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
        user_three: &signer,
        treasury: &signer
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);
        
        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // set assertion policy
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one (asserter), user two (disputer), and treasury
        let mint_amount     = 100000000;
        let treasury_addr   = signer::address_of(treasury);
        let user_three_addr = signer::address_of(user_three);
        oracle_token::mint(prediction_market, user_one_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_two_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_three_addr   , mint_amount);
        oracle_token::mint(prediction_market, treasury_addr     , mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = treasury_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // ----------------------------------
        // Initialize Market
        // ----------------------------------

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // ----------------------------------
        // Assert Market
        // ----------------------------------

        // init params for truth assertion
        let asserted_outcome = outcome_two; // we assert outcome two is correct now

        // init roles
        let asserter            = user_two;
        let asserter_addr       = user_two_addr;
        let disputer            = user_three;
        let disputer_addr       = user_three_addr;
        let settle_caller       = user_one;
        let settle_caller_addr  = user_one_addr;

        // get next assertion id
        let assertion_id = prediction_market::get_next_assertion_id();

        // user two to call assert_market
        prediction_market::assert_market(
            asserter,
            market_id,
            asserted_outcome
        );

        // check that asserted outcome is now set
        let (
            _creator,
            _resolved,
            view_asserted_outcome_id,
            _reward,
            _required_bond,
            _view_outcome_one,
            _view_outcome_two,
            _view_description,
            _view_image_url,
            _view_categories,
            _view_start_timestamp,
            _outcome_token_one_metadata,
            _outcome_token_two_metadata,
            _outcome_token_one_address,
            _outcome_token_two_address,
            _pool_initialized,
            _pool_initializer
        ) = prediction_market::get_market(market_id);
        assert!(view_asserted_outcome_id == aptos_hash::keccak256(asserted_outcome), 100);

        // calc bond to be transferred
        let minimum_bond = (DEFAULT_FEE * 10000) / DEFAULT_BURNED_BOND_PERCENTAGE;
        let bond;
        if(required_bond > minimum_bond){
            bond =  required_bond;
        } else {
            bond = minimum_bond;
        };

        // bond is transferred from asserter to module
        let asserter_balance = primary_fungible_store::balance(asserter_addr, oracle_token_metadata);
        assert!(asserter_balance == mint_amount - bond, 101);

        // ----------------------------------
        // Set defaults
        // ----------------------------------

        let liveness     = DEFAULT_MIN_LIVENESS;
        let identifier   = DEFAULT_IDENTIFIER;

        // ----------------------------------
        // Initialize Liquidity Pool
        // ----------------------------------

        let initial_liquidity = (100_000 as u128);
        prediction_market::initialize_pool(user_one, market_id, initial_liquidity);

        // ----------------------------------
        // Outcome Tokens interactions test
        // ----------------------------------

        // let user two deposit some liquidity
        let deposit_amount = 10_000;
        prediction_market::deposit_liquidity(user_two, market_id, deposit_amount);

        // redeem some LP tokens for outcome tokens for user one and two
        let lp_token_redeem_amount = 1000;
        prediction_market::redeem_lp_for_outcome_tokens(user_one, market_id, lp_token_redeem_amount);
        prediction_market::redeem_lp_for_outcome_tokens(user_two, market_id, lp_token_redeem_amount);

        // ----------------------------------
        // Dispute Assertion
        // ----------------------------------

        // user three disputes assertion
        prediction_market::dispute_assertion(
            disputer,
            assertion_id
        );

        // bond is transferred from disputer to module
        let disputer_balance = primary_fungible_store::balance(disputer_addr, oracle_token_metadata);
        assert!(disputer_balance == mint_amount - bond, 102);

        // create instance of expected event
        let assertion_disputed_event = prediction_market::test_AssertionDisputedEvent(
            assertion_id,
            disputer_addr // disputer
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&assertion_disputed_event), 103);

        // get views to confirm assertion has been updated with disputer
        let (
            _asserter, 
            _settled, 
            _settlement_resolution, 
            _liveness, 
            assertion_time, 
            _expiration_time, 
            _identifier, 
            _bond, 
            disputer
        ) = prediction_market::get_assertion(assertion_id);

        assert!(option::destroy_some(disputer) == disputer_addr, 104);

        // ----------------------------------
        // Escalation Manager to set arbitration resolution
        // ----------------------------------

        // set arbitration resolution parameters
        let time                    = bcs::to_bytes<u64>(&assertion_time); 
        let ancillary_data          = prediction_market::stamp_assertion(assertion_id, asserter_addr);
        let arbitration_resolution  = true; // asserter wins
        let override                = false;

        // escalation manager to resolve the dispute
        escalation_manager::set_arbitration_resolution(
            escalation_manager,
            time,
            identifier,
            ancillary_data,
            arbitration_resolution,
            override
        );

        // fast forward to liveness over (after assertion has expired)
        timestamp::fast_forward_seconds(liveness + 1);

        // get asserter, disputer, and treasury balance before assertion settled
        let initial_asserter_balance = primary_fungible_store::balance(asserter_addr    , oracle_token_metadata);
        let initial_disputer_balance = primary_fungible_store::balance(disputer_addr    , oracle_token_metadata);
        let initial_treasury_balance = primary_fungible_store::balance(treasury_addr    , oracle_token_metadata);

        // ----------------------------------
        // Settle Assertion
        // ----------------------------------

        // anyone can settle the assertion
        prediction_market::settle_assertion(
            settle_caller,
            assertion_id
        );

        // get views to confirm assertion has been settled
        let (
            _asserter, 
            settled, 
            settlement_resolution, 
            _liveness, 
            _assertion_time, 
            _expiration_time, 
            _identifier, 
            bond, 
            _disputer
        ) = prediction_market::get_assertion(assertion_id);

        assert!(settled                 == true                     , 105);
        assert!(settlement_resolution   == arbitration_resolution   , 106);

        // get asserter, disputer, and treasury balance after assertion settled
        let updated_asserter_balance = primary_fungible_store::balance(asserter_addr    , oracle_token_metadata);
        let updated_disputer_balance = primary_fungible_store::balance(disputer_addr    , oracle_token_metadata);
        let updated_treasury_balance = primary_fungible_store::balance(treasury_addr    , oracle_token_metadata);

        // calculate fee 
        let oracle_fee            = (burned_bond_percentage * bond) / 10000;
        let bond_recipient_amount = (bond * 2) - oracle_fee;

        // asserter should receive his bond + disputer bond less oracle fee
        assert!(updated_asserter_balance == initial_asserter_balance + bond_recipient_amount, 107);

        // treasury should receive oracle fee
        assert!(updated_treasury_balance == initial_treasury_balance + oracle_fee, 108);

        // no changes to disputer balance as he lost the dispute
        assert!(updated_disputer_balance == initial_disputer_balance, 109);

        // create instance of expected event
        let assertion_settled_event = prediction_market::test_AssertionSettledEvent(
            assertion_id,
            asserter_addr,          // asserter is the bond recipient
            true,                   // disputed
            settlement_resolution,
            settle_caller_addr      // settle_caller
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&assertion_settled_event), 110);

        // test view get market
        let (
            _creator,
            resolved,
            view_asserted_outcome_id,
            _reward,
            _required_bond,
            _view_outcome_one,
            _view_outcome_two,
            _view_description,
            _view_image_url,
            _view_categories,
            _view_start_timestamp,
            outcome_token_one_metadata,
            outcome_token_two_metadata,
            _outcome_token_one_address,
            _outcome_token_two_address,
            _pool_initialized,
            _pool_initializer
        ) = prediction_market::get_market(market_id);

        // market is now resolved and asserted outcome id is reset 
        assert!(resolved                 == true                 , 111);
        assert!(view_asserted_outcome_id != vector::empty<u8>()  , 112);

        // ----------------------------------
        // Settle Outcome Tokens
        // ----------------------------------

        // get updated liquidity pool token reserves
        let (
            _,
            _,
            outcome_token_one_reserve,
            outcome_token_two_reserve,
            _lp_total_supply,
            _lp_token_metadata,
            _
        ) = prediction_market::get_pool(market_id);
        
        let initial_user_one_balance                   = primary_fungible_store::balance(user_one_addr, oracle_token_metadata);
        let initial_user_one_outcome_token_two_balance = primary_fungible_store::balance(user_one_addr, outcome_token_two_metadata);

        // calc user one proportion 
        let total_pool_reserves = outcome_token_one_reserve + outcome_token_two_reserve;
        let user_one_proportion = (((initial_user_one_outcome_token_two_balance as u128) * FIXED_POINT_ACCURACY) / outcome_token_two_reserve);
        let user_one_payout     = (user_one_proportion * total_pool_reserves) / FIXED_POINT_ACCURACY;

        prediction_market::settle_outcome_tokens(user_one, market_id);

        let updated_user_one_balance                   = primary_fungible_store::balance(user_one_addr, oracle_token_metadata);

        // increase by outcome token two balance
        assert!(updated_user_one_balance == initial_user_one_balance + (user_one_payout as u64)  , 105);

        // ----------------------------------
        // Test redeem LP Tokens for Outcome tokens
        // ----------------------------------

        // user can only redeem LP tokens for outcome two tokens now
        let lp_token_redeem_amount = 1000;
        
        // initial outcome token one balance
        let initial_user_one_outcome_token_one_balance = primary_fungible_store::balance(user_one_addr, outcome_token_one_metadata);
        let initial_user_one_outcome_token_two_balance = primary_fungible_store::balance(user_one_addr, outcome_token_two_metadata);

        prediction_market::redeem_lp_for_outcome_tokens(user_one, market_id, lp_token_redeem_amount);

        // updated outcome token one balance
        let updated_user_one_outcome_token_one_balance = primary_fungible_store::balance(user_one_addr, outcome_token_one_metadata);
        let updated_user_one_outcome_token_two_balance = primary_fungible_store::balance(user_one_addr, outcome_token_two_metadata);

        assert!(updated_user_one_outcome_token_one_balance == initial_user_one_outcome_token_one_balance , 113);
        assert!(updated_user_one_outcome_token_two_balance > initial_user_one_outcome_token_two_balance  , 114);

    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444, user_three = @0x555, treasury = @0x666)]
    public entry fun test_assert_truth_end_to_end_with_dispute_and_disputer_wins(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
        user_three: &signer,
        treasury: &signer
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);
        
        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // set assertion policy
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one (asserter), user two (disputer), and treasury
        let mint_amount     = 100000000;
        let treasury_addr   = signer::address_of(treasury);
        let user_three_addr = signer::address_of(user_three);
        oracle_token::mint(prediction_market, user_one_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_two_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_three_addr   , mint_amount);
        oracle_token::mint(prediction_market, treasury_addr     , mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = treasury_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // ----------------------------------
        // Initialize Market
        // ----------------------------------

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // init params for truth assertion
        let asserted_outcome = outcome_two; // we assert outcome two is correct now

        // ----------------------------------
        // Assert Market
        // ----------------------------------

        // init roles
        let asserter            = user_two;
        let asserter_addr       = user_two_addr;
        let disputer            = user_three;
        let disputer_addr       = user_three_addr;
        let settle_caller       = user_one;
        let settle_caller_addr  = user_one_addr;

        // get next assertion id
        let assertion_id = prediction_market::get_next_assertion_id();

        // user two to call assert_market
        prediction_market::assert_market(
            asserter,
            market_id,
            asserted_outcome
        );

        // check that asserted outcome is now set
        let (
            _creator,
            _resolved,
            view_asserted_outcome_id,
            _reward,
            _required_bond,
            _view_outcome_one,
            _view_outcome_two,
            _view_description,
            _view_image_url,
            _view_categories,
            _view_start_timestamp,
            _outcome_token_one_metadata,
            _outcome_token_two_metadata,
            _outcome_token_one_address,
            _outcome_token_two_address,
            _pool_initialized,
            _pool_initializer
        ) = prediction_market::get_market(market_id);
        assert!(view_asserted_outcome_id == aptos_hash::keccak256(asserted_outcome), 100);

        // calc bond to be transferred
        let minimum_bond = (DEFAULT_FEE * 10000) / DEFAULT_BURNED_BOND_PERCENTAGE;
        let bond;
        if(required_bond > minimum_bond){
            bond = required_bond;
        } else {
            bond = minimum_bond;
        };

        // bond is transferred from asserter to module
        let asserter_balance = primary_fungible_store::balance(asserter_addr, oracle_token_metadata);
        assert!(asserter_balance == mint_amount - bond, 101);

        // ----------------------------------
        // Set defaults
        // ----------------------------------

        let liveness     = DEFAULT_MIN_LIVENESS;
        let identifier   = DEFAULT_IDENTIFIER;

        // ----------------------------------
        // Initialize Liquidity Pool
        // ----------------------------------

        let initial_liquidity = (100_000 as u128);
        prediction_market::initialize_pool(user_one, market_id, initial_liquidity);

        // ----------------------------------
        // Outcome Tokens interactions test
        // ----------------------------------
        
        // let user two deposit some liquidity
        let deposit_amount = 10_000;
        prediction_market::deposit_liquidity(user_two, market_id, deposit_amount);

        // redeem some LP tokens for outcome tokens for user one and two
        let lp_token_redeem_amount = 1000;
        prediction_market::redeem_lp_for_outcome_tokens(user_one, market_id, lp_token_redeem_amount);
        prediction_market::redeem_lp_for_outcome_tokens(user_two, market_id, lp_token_redeem_amount);

        // ----------------------------------
        // Dispute Assertion
        // ----------------------------------

        // user three disputes assertion
        prediction_market::dispute_assertion(
            disputer,
            assertion_id
        );

        // bond is transferred from disputer to module
        let disputer_balance = primary_fungible_store::balance(disputer_addr, oracle_token_metadata);
        assert!(disputer_balance == mint_amount - bond, 102);

        // create instance of expected event
        let assertion_disputed_event = prediction_market::test_AssertionDisputedEvent(
            assertion_id,
            disputer_addr // disputer
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&assertion_disputed_event), 103);

        // get views to confirm assertion has been updated with disputer
        let (
            _asserter, 
            _settled, 
            _settlement_resolution, 
            _liveness, 
            assertion_time, 
            _expiration_time, 
            _identifier, 
            _bond, 
            disputer
        ) = prediction_market::get_assertion(assertion_id);

        assert!(option::destroy_some(disputer) == disputer_addr, 104);

        // ----------------------------------
        // Escalation Manager to set arbitration resolution
        // ----------------------------------

        // set arbitration resolution parameters
        let time                    = bcs::to_bytes<u64>(&assertion_time); 
        let ancillary_data          = prediction_market::stamp_assertion(assertion_id, asserter_addr);
        let arbitration_resolution  = false; // disputer wins
        let override                = false;

        // escalation manager to resolve the dispute
        escalation_manager::set_arbitration_resolution(
            escalation_manager,
            time,
            identifier,
            ancillary_data,
            arbitration_resolution,
            override
        );

        // fast forward to liveness over (after assertion has expired)
        timestamp::fast_forward_seconds(liveness + 1);

        // get asserter, disputer, and treasury balance before assertion settled
        let initial_asserter_balance = primary_fungible_store::balance(asserter_addr    , oracle_token_metadata);
        let initial_disputer_balance = primary_fungible_store::balance(disputer_addr    , oracle_token_metadata);
        let initial_treasury_balance = primary_fungible_store::balance(treasury_addr    , oracle_token_metadata);

        // ----------------------------------
        // Settle Assertion
        // ----------------------------------

        // anyone can settle the assertion
        prediction_market::settle_assertion(
            settle_caller,
            assertion_id
        );

        // get views to confirm assertion has been settled
        let (
            _asserter, 
            settled, 
            settlement_resolution, 
            _liveness, 
            _assertion_time, 
            _expiration_time, 
            _identifier, 
            bond, 
            _disputer
        ) = prediction_market::get_assertion(assertion_id);

        assert!(settled                 == true                     , 105);
        assert!(settlement_resolution   == arbitration_resolution   , 106);

        // get asserter, disputer, and treasury balance after assertion settled
        let updated_asserter_balance = primary_fungible_store::balance(asserter_addr    , oracle_token_metadata);
        let updated_disputer_balance = primary_fungible_store::balance(disputer_addr    , oracle_token_metadata);
        let updated_treasury_balance = primary_fungible_store::balance(treasury_addr    , oracle_token_metadata);

        // calculate fee 
        let oracle_fee            = (burned_bond_percentage * bond) / 10000;
        let bond_recipient_amount = (bond * 2) - oracle_fee;

        // no changes to asserter balance as he lost the dispute
        assert!(updated_asserter_balance == initial_asserter_balance, 107);

        // treasury should receive oracle fee
        assert!(updated_treasury_balance == initial_treasury_balance + oracle_fee, 108);

        // disputer should receive his bond + asserter bond less oracle fee
        assert!(updated_disputer_balance == initial_disputer_balance + bond_recipient_amount, 109);

        // create instance of expected event
        let assertion_settled_event = prediction_market::test_AssertionSettledEvent(
            assertion_id,
            disputer_addr,          // disputer is the bond recipient
            true,                   // disputed
            settlement_resolution,
            settle_caller_addr      // settle_caller
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&assertion_settled_event), 110);

        // test view get market
        let (
            _creator,
            resolved,
            view_asserted_outcome_id,
            _reward,
            _required_bond,
            _view_outcome_one,
            _view_outcome_two,
            _view_description,
            _view_image_url,
            _view_categories,
            _view_start_timestamp,
            _outcome_token_one_metadata,
            _outcome_token_two_metadata,
            _outcome_token_one_address,
            _outcome_token_two_address,
            _pool_initialized,
            _pool_initializer
        ) = prediction_market::get_market(market_id);

        // market is now resolved and asserted outcome id is reset 
        assert!(resolved                 == false                , 111);
        assert!(view_asserted_outcome_id == vector::empty<u8>()  , 112);

    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    public entry fun test_assert_market_with_unresolved_outcome_end_to_end_without_dispute(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);
        
        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = true;

        // call set_assertion_policy to set validate_asserters to false
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one and two
        let mint_amount = 100_000_000;
        oracle_token::mint(prediction_market, user_one_addr, mint_amount);
        oracle_token::mint(prediction_market, user_two_addr, mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = user_one_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // ----------------------------------
        // Initialize Market
        // ----------------------------------

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 100_000; 
        let required_bond           = 100_000;

        // get next market id
        let market_id = prediction_market::get_next_market_id();
        
        // get balance
        let initial_initializer_balance = primary_fungible_store::balance(user_one_addr, oracle_token_metadata);

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // check that reward was transferred
        let updated_initializer_balance = primary_fungible_store::balance(user_one_addr, oracle_token_metadata);
        assert!(updated_initializer_balance == initial_initializer_balance - reward, 99);

        // ----------------------------------
        // Assert Market
        // ----------------------------------

        // init params for truth assertion
        let asserted_outcome    = UNRESOLVABLE; // we assert outcome is unresolvable

        // get next assertion id
        let assertion_id = prediction_market::get_next_assertion_id();

        // user two to call assert_market
        prediction_market::assert_market(
            user_two,
            market_id,
            asserted_outcome
        );

        // get market view
        let (
            _creator,
            _resolved,
            view_asserted_outcome_id,
            _reward,
            _required_bond,
            _view_outcome_one,
            _view_outcome_two,
            _view_description,
            _view_image_url,
            _view_categories,
            _view_start_timestamp,
            outcome_token_one_metadata,
            outcome_token_two_metadata,
            _outcome_token_one_address,
            _outcome_token_two_address,
            _pool_initialized,
            _pool_initializer
        ) = prediction_market::get_market(market_id);
        assert!(view_asserted_outcome_id == aptos_hash::keccak256(asserted_outcome), 100);

        let minimum_bond = (DEFAULT_FEE * 10000) / DEFAULT_BURNED_BOND_PERCENTAGE;
        let bond;
        if(required_bond > minimum_bond){
            bond =  required_bond;
        } else {
            bond = minimum_bond;
        };

        // bond is transferred from asserter to module
        let asserter_balance = primary_fungible_store::balance(user_two_addr, oracle_token_metadata);
        assert!(asserter_balance == mint_amount - bond, 100);

        // ----------------------------------
        // Set defaults
        // ----------------------------------

        let liveness     = DEFAULT_MIN_LIVENESS;

        // ----------------------------------
        // Initialize Liquidity Pool
        // ----------------------------------

        let initial_liquidity = (100_000 as u128);
        prediction_market::initialize_pool(user_one, market_id, initial_liquidity);

        // ----------------------------------
        // Outcome Tokens interactions test
        // ----------------------------------

        // let user two deposit some liquidity
        let deposit_amount = 10_000;
        prediction_market::deposit_liquidity(user_two, market_id, deposit_amount);

        // redeem some LP tokens for outcome tokens for user one and two
        let lp_token_redeem_amount = 1000;
        prediction_market::redeem_lp_for_outcome_tokens(user_one, market_id, lp_token_redeem_amount);
        prediction_market::redeem_lp_for_outcome_tokens(user_two, market_id, lp_token_redeem_amount);

        // ----------------------------------
        // Settle Assertion
        // ----------------------------------

        // fast forward to liveness over (after assertion has expired)
        timestamp::fast_forward_seconds(liveness + 1);

        // get initial asserter alance
        let initial_asserter_balance = primary_fungible_store::balance(user_two_addr, oracle_token_metadata);

        // anyone can settle the assertion
        prediction_market::settle_assertion(
            user_two,
            assertion_id
        );

        // get asserter balance after assertion settled
        let updated_asserter_balance = primary_fungible_store::balance(user_two_addr, oracle_token_metadata);

        // asserter should have his bond returned + reward
        assert!(updated_asserter_balance == initial_asserter_balance + bond + reward, 101);

        // get views to confirm assertion has been resolved
        let (
            _asserter, 
            settled, 
            settlement_resolution, 
            _liveness, 
            _assertion_time, 
            _expiration_time, 
            _identifier, 
            _bond, 
            _disputer
        ) = prediction_market::get_assertion(assertion_id);

        assert!(settled                 == true, 102);
        assert!(settlement_resolution   == true, 103);

        // create instance of expected event
        let assertion_settled_event = prediction_market::test_AssertionSettledEvent(
            assertion_id,
            user_two_addr,          // asserter is the bond recipient
            false,                  // disputed
            settlement_resolution,
            user_two_addr           // settle_caller
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&assertion_settled_event), 104);

        // ----------------------------------
        // Settle Outcome Tokens
        // ----------------------------------

        // unresolved outcome so $1 => one outcome token one + one outcome token two 

        // transfer 500 outcome token one from user two to one
        // to test different burn amounts for unresolved outcome
        let transfer_amount = 500;
        primary_fungible_store::transfer(user_two, outcome_token_one_metadata, user_one_addr, transfer_amount);

        let initial_user_one_balance = primary_fungible_store::balance(user_one_addr, oracle_token_metadata);
        let initial_user_two_balance = primary_fungible_store::balance(user_two_addr, oracle_token_metadata);

        // initial outcome token one balance
        let initial_user_one_outcome_token_one_balance = primary_fungible_store::balance(user_one_addr, outcome_token_one_metadata);
        let initial_user_two_outcome_token_one_balance = primary_fungible_store::balance(user_two_addr, outcome_token_one_metadata);
        
        // initial outcome token two balance
        let initial_user_one_outcome_token_two_balance = primary_fungible_store::balance(user_one_addr, outcome_token_two_metadata);
        let initial_user_two_outcome_token_two_balance = primary_fungible_store::balance(user_two_addr, outcome_token_two_metadata);
        
        // calc user payouts
        let _user_one_payout                = 0;
        let _user_one_token_one_burn_amount = 0;
        let _user_one_token_two_burn_amount = 0;
        if(initial_user_one_outcome_token_one_balance > initial_user_one_outcome_token_two_balance){
            _user_one_payout                = initial_user_one_outcome_token_two_balance * 2;
            _user_one_token_one_burn_amount = initial_user_one_outcome_token_two_balance;
            _user_one_token_two_burn_amount = initial_user_one_outcome_token_two_balance;
        } else {
            _user_one_payout                = initial_user_one_outcome_token_one_balance * 2;
            _user_one_token_one_burn_amount = initial_user_one_outcome_token_one_balance;
            _user_one_token_two_burn_amount = initial_user_one_outcome_token_one_balance;
        };

        let _user_two_payout                = 0;
        let _user_two_token_one_burn_amount = 0;
        let _user_two_token_two_burn_amount = 0;
        if(initial_user_two_outcome_token_one_balance > initial_user_two_outcome_token_two_balance){
            _user_two_payout                = initial_user_two_outcome_token_two_balance * 2;
            _user_two_token_one_burn_amount = initial_user_two_outcome_token_two_balance;
            _user_two_token_two_burn_amount = initial_user_two_outcome_token_two_balance;
        } else {
            _user_two_payout                = initial_user_two_outcome_token_one_balance * 2;
            _user_two_token_one_burn_amount = initial_user_two_outcome_token_one_balance;
            _user_two_token_two_burn_amount = initial_user_two_outcome_token_one_balance;
        };

        // settle outcome tokens
        // as market was resolved to the first outcome, payout is based on outcome token one proportions
        prediction_market::settle_outcome_tokens(user_one, market_id);
        prediction_market::settle_outcome_tokens(user_two, market_id);
        
        let updated_user_one_balance = primary_fungible_store::balance(user_one_addr, oracle_token_metadata);
        let updated_user_two_balance = primary_fungible_store::balance(user_two_addr, oracle_token_metadata);

        assert!(updated_user_one_balance == initial_user_one_balance + (_user_one_payout as u64) , 119);
        assert!(updated_user_two_balance == initial_user_two_balance + (_user_two_payout as u64) , 120);

        // create instance of expected event for user two tokens settled event
        let tokens_settled_event = prediction_market::test_TokensSettledEvent(
            market_id,
            user_one_addr,
            _user_one_payout,
            (_user_one_token_one_burn_amount as u64),
            (_user_one_token_two_burn_amount as u64)
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&tokens_settled_event), 121);

        // create instance of expected event for user two tokens settled event
        let tokens_settled_event = prediction_market::test_TokensSettledEvent(
            market_id,
            user_two_addr,
            _user_two_payout,
            (_user_two_token_one_burn_amount as u64),
            (_user_two_token_two_burn_amount as u64)
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&tokens_settled_event), 122);

        // updated outcome token one balance
        let updated_user_one_outcome_token_one_balance = primary_fungible_store::balance(user_one_addr, outcome_token_one_metadata);
        let updated_user_two_outcome_token_one_balance = primary_fungible_store::balance(user_two_addr, outcome_token_one_metadata);

        // updated outcome token two balance
        let updated_user_one_outcome_token_two_balance = primary_fungible_store::balance(user_one_addr, outcome_token_two_metadata);
        let updated_user_two_outcome_token_two_balance = primary_fungible_store::balance(user_two_addr, outcome_token_two_metadata);

        // check all outcome token balances are now zero after settling
        assert!(updated_user_one_outcome_token_one_balance == initial_user_one_outcome_token_one_balance - (_user_one_token_one_burn_amount as u64), 123);
        assert!(updated_user_one_outcome_token_two_balance == initial_user_one_outcome_token_two_balance - (_user_one_token_two_burn_amount as u64), 124);
        assert!(updated_user_two_outcome_token_one_balance == initial_user_two_outcome_token_one_balance - (_user_two_token_one_burn_amount as u64), 125);
        assert!(updated_user_two_outcome_token_two_balance == initial_user_two_outcome_token_two_balance - (_user_two_token_two_burn_amount as u64), 126);

        // ----------------------------------
        // Test redeem LP Tokens for Outcome tokens
        // ----------------------------------

        // get updated liquidity pool token reserves
        let (
            _,
            _,
            outcome_token_one_reserve,
            outcome_token_two_reserve,
            lp_total_supply,
            _lp_token_metadata,
            _
        ) = prediction_market::get_pool(market_id);

        // user can redeem LP tokens for outcome one and two tokens
        let lp_token_redeem_amount = 1000;
        
        // calcs
        let lp_proportion = ((lp_token_redeem_amount as u128) * FIXED_POINT_ACCURACY) / lp_total_supply;
        let outcome_token_one_proportion_amount  = ((outcome_token_one_reserve * lp_proportion) / FIXED_POINT_ACCURACY);
        let outcome_token_two_proportion_amount  = ((outcome_token_two_reserve * lp_proportion) / FIXED_POINT_ACCURACY);

        // initial outcome token one balance
        let initial_user_one_outcome_token_one_balance = primary_fungible_store::balance(user_one_addr, outcome_token_one_metadata);
        let initial_user_one_outcome_token_two_balance = primary_fungible_store::balance(user_one_addr, outcome_token_two_metadata);

        prediction_market::redeem_lp_for_outcome_tokens(user_one, market_id, lp_token_redeem_amount);

        // updated outcome token one balance
        let updated_user_one_outcome_token_one_balance = primary_fungible_store::balance(user_one_addr, outcome_token_one_metadata);
        let updated_user_one_outcome_token_two_balance = primary_fungible_store::balance(user_one_addr, outcome_token_two_metadata);

        assert!(updated_user_one_outcome_token_one_balance == initial_user_one_outcome_token_one_balance + (outcome_token_one_proportion_amount as u64) , 113);
        assert!(updated_user_one_outcome_token_two_balance == initial_user_one_outcome_token_two_balance + (outcome_token_two_proportion_amount as u64) , 114);

    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_NOT_WHITELISTED_ASSERTER, location = prediction_market)]
    public entry fun test_non_whitelisted_asserters_cannot_call_assert_truth_if_validate_asserters_is_true(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, _user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        let block_assertion    = false;
        let validate_asserters = true;
        let validate_disputers = false;

        // call set_assertion_policy to set validate_asserters to false
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one for bond
        let mint_amount = 100000000;
        oracle_token::mint(prediction_market, user_one_addr, mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = user_one_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // init params for truth assertion
        let asserted_outcome = outcome_one; // we assert outcome one is correct

        // user one to call assert_market
        prediction_market::assert_market(
            user_one,
            market_id,
            asserted_outcome
        );
    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    public entry fun test_only_whitelisted_asserters_can_call_assert_truth_if_validate_asserters_is_true(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, _user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        let block_assertion    = false;
        let validate_asserters = true;
        let validate_disputers = false;

        // call set_assertion_policy to set validate_asserters to false
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // call set_whitelisted_asserter
        escalation_manager::set_whitelisted_asserter(
            escalation_manager,
            user_one_addr,
            true
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one for bond
        let mint_amount = 100000000;
        oracle_token::mint(prediction_market, user_one_addr, mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = user_one_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // init params for truth assertion
        let asserted_outcome = outcome_one; // we assert outcome one is correct

        // user one to call assert_market
        prediction_market::assert_market(
            user_one,
            market_id,
            asserted_outcome
        );
    }

    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_ASSERT_IS_BLOCKED, location = prediction_market)]
    public entry fun test_user_cannot_assert_truth_if_block_assertion_is_true(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, _user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        let block_assertion    = true;
        let validate_asserters = false;
        let validate_disputers = false;

        // call set_assertion_policy to set validate_asserters to false
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one for bond
        let mint_amount = 100000000;
        oracle_token::mint(prediction_market, user_one_addr, mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = user_one_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // init params for truth assertion
        let asserted_outcome = outcome_one; // we assert outcome one is correct

        // user one to call assert_market
        prediction_market::assert_market(
            user_one,
            market_id,
            asserted_outcome
        );
    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_ASSERTION_ACTIVE_OR_RESOLVED, location = prediction_market)]
    public entry fun test_user_cannot_assert_truth_if_the_same_assertion_already_exists(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, _user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // call set_assertion_policy to set validate_asserters to false
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one for bond
        let mint_amount = 100000000;
        oracle_token::mint(prediction_market, user_one_addr, mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = user_one_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // init params for truth assertion
        let asserted_outcome = outcome_one; // we assert outcome one is correct

        // user one to call assert_market
        prediction_market::assert_market(
            user_one,
            market_id,
            asserted_outcome
        );

        // should fail
        prediction_market::assert_market(
            user_one,
            market_id,
            asserted_outcome
        );
    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_NOT_WHITELISTED_DISPUTER, location = prediction_market)]
    public entry fun test_non_whitelisted_disputers_cannot_dispute_assertions_if_validate_disputers_is_true(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = true;

        // call set_assertion_policy to set validate_asserters to false
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one for bond
        let mint_amount = 100000000;
        oracle_token::mint(prediction_market, user_one_addr, mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = user_one_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 1;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // init params for truth assertion
        let asserted_outcome = outcome_one; // we assert outcome one is correct

        // init roles
        let asserter            = user_one;
        // let asserter_addr       = user_one_addr;
        let disputer            = user_two;
        let _disputer_addr      = user_two_addr;

        // get next assertion id
        let assertion_id = prediction_market::get_next_assertion_id();

        // user one to call assert_market
        prediction_market::assert_market(
            asserter,
            market_id,
            asserted_outcome
        );

        // user two disputes assertion
        prediction_market::dispute_assertion(
            disputer,
            assertion_id
        );
    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    public entry fun test_only_whitelisted_disputers_can_dispute_assertions_if_validate_disputers_is_true(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = true;

        // call set_assertion_policy to set validate_asserters to false
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // call set_whitelisted_dispute_caller
        escalation_manager::set_whitelisted_dispute_caller(
            escalation_manager,
            user_two_addr,
            true
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one for bond
        let mint_amount = 100000000;
        oracle_token::mint(prediction_market, user_one_addr, mint_amount);
        oracle_token::mint(prediction_market, user_two_addr, mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = user_one_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 1;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // init params for truth assertion
        let asserted_outcome = outcome_one; // we assert outcome one is correct

        // init roles
        let asserter            = user_one;
        // let asserter_addr       = user_one_addr;
        let disputer            = user_two;
        let _disputer_addr      = user_two_addr;

        // get next assertion id
        let assertion_id = prediction_market::get_next_assertion_id();

        // user one to call assert_market
        prediction_market::assert_market(
            asserter,
            market_id,
            asserted_outcome
        );

        // user two disputes assertion
        prediction_market::dispute_assertion(
            disputer,
            assertion_id
        );

    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_ASSERTION_IS_EXPIRED, location = prediction_market)]
    public entry fun test_dispute_assertion_cannot_be_called_after_assertion_has_expired(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = true;

        // call set_assertion_policy to set validate_asserters to false
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // call set_whitelisted_dispute_caller
        escalation_manager::set_whitelisted_dispute_caller(
            escalation_manager,
            user_two_addr,
            true
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one for bond
        let mint_amount = 100000000;
        oracle_token::mint(prediction_market, user_one_addr, mint_amount);
        oracle_token::mint(prediction_market, user_two_addr, mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = user_one_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 1;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // init params for truth assertion
        let asserted_outcome = outcome_one; // we assert outcome one is correct

        // init roles
        let asserter            = user_one;
        // let asserter_addr       = user_one_addr;
        let disputer            = user_two;
        let _disputer_addr      = user_two_addr;

        // get next assertion id
        let assertion_id = prediction_market::get_next_assertion_id();

        // user one to call assert_market
        prediction_market::assert_market(
            asserter,
            market_id,
            asserted_outcome
        );

        let liveness     = DEFAULT_MIN_LIVENESS;

        // fast forward to liveness over (after assertion has expired)
        timestamp::fast_forward_seconds(liveness + 1);

        // user two disputes assertion
        prediction_market::dispute_assertion(
            disputer,
            assertion_id
        );
    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_ASSERTION_ALREADY_DISPUTED, location = prediction_market)]
    public entry fun test_assertion_cannot_be_disputed_more_than_once(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = true;

        // call set_assertion_policy to set validate_asserters to false
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // call set_whitelisted_dispute_caller
        escalation_manager::set_whitelisted_dispute_caller(
            escalation_manager,
            user_two_addr,
            true
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one for bond
        let mint_amount = 100000000;
        oracle_token::mint(prediction_market, user_one_addr, mint_amount);
        oracle_token::mint(prediction_market, user_two_addr, mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = user_one_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 1;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // init params for truth assertion
        let asserted_outcome = outcome_one; // we assert outcome one is correct

        // init roles
        let asserter            = user_one;
        let _asserter_addr      = user_one_addr;
        let disputer            = user_two;
        let _disputer_addr      = user_two_addr;

        // get next assertion id
        let assertion_id = prediction_market::get_next_assertion_id();

        // user one to call assert_market
        prediction_market::assert_market(
            asserter,
            market_id,
            asserted_outcome
        );

        // user two disputes assertion
        prediction_market::dispute_assertion(
            disputer,
            assertion_id
        );

        // should fail
        prediction_market::dispute_assertion(
            disputer,
            assertion_id
        );
    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444, user_three = @0x555, treasury = @0x666)]
    #[expected_failure(abort_code = ERROR_MARKET_HAS_BEEN_RESOLVED, location = prediction_market)]
    public entry fun test_cannot_deposit_liquidity_to_pool_for_resolved_market(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
        user_three: &signer,
        treasury: &signer
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);
        
        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // set assertion policy
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one (asserter), user two (disputer), and treasury
        let mint_amount     = 100000000;
        let treasury_addr   = signer::address_of(treasury);
        let user_three_addr = signer::address_of(user_three);
        oracle_token::mint(prediction_market, user_one_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_two_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_three_addr   , mint_amount);
        oracle_token::mint(prediction_market, treasury_addr     , mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = treasury_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // ----------------------------------
        // Initialize Market
        // ----------------------------------

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // ----------------------------------
        // Initialize Liquidity Pool
        // ----------------------------------

        let initial_liquidity = (100_000 as u128);
        prediction_market::initialize_pool(user_one, market_id, initial_liquidity);

        // ----------------------------------
        // Assert Market
        // ----------------------------------

        // init params for truth assertion
        let asserted_outcome = outcome_one; // we assert outcome one is correct

        // init roles
        let asserter            = user_two;
        let asserter_addr       = user_two_addr;
        let disputer            = user_three;
        let disputer_addr       = user_three_addr;
        let settle_caller       = user_one;

        // get next assertion id
        let assertion_id = prediction_market::get_next_assertion_id();

        // user two to call assert_market
        prediction_market::assert_market(
            asserter,
            market_id,
            asserted_outcome
        );

        // calc bond to be transferred
        let minimum_bond = (DEFAULT_FEE * 10000) / DEFAULT_BURNED_BOND_PERCENTAGE;
        let bond;
        if(required_bond > minimum_bond){
            bond =  required_bond;
        } else {
            bond = minimum_bond;
        };

        // bond is transferred from asserter to module
        let asserter_balance = primary_fungible_store::balance(asserter_addr, oracle_token_metadata);
        assert!(asserter_balance == mint_amount - bond, 101);

        // ----------------------------------
        // Set defaults
        // ----------------------------------

        let liveness     = DEFAULT_MIN_LIVENESS;
        let identifier   = DEFAULT_IDENTIFIER;

        // ----------------------------------
        // Dispute Assertion
        // ----------------------------------

        // user three disputes assertion
        prediction_market::dispute_assertion(
            disputer,
            assertion_id
        );

        // bond is transferred from disputer to module
        let disputer_balance = primary_fungible_store::balance(disputer_addr, oracle_token_metadata);
        assert!(disputer_balance == mint_amount - bond, 102);

        // create instance of expected event
        let assertion_disputed_event = prediction_market::test_AssertionDisputedEvent(
            assertion_id,
            disputer_addr // disputer
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&assertion_disputed_event), 103);

        // get views to confirm assertion has been updated with disputer
        let (
            _asserter, 
            _settled, 
            _settlement_resolution, 
            _liveness, 
            assertion_time, 
            _expiration_time, 
            _identifier, 
            _bond, 
            disputer
        ) = prediction_market::get_assertion(assertion_id);

        assert!(option::destroy_some(disputer) == disputer_addr, 104);

        // ----------------------------------
        // Escalation Manager to set arbitration resolution
        // ----------------------------------

        // set arbitration resolution parameters
        let time                    = bcs::to_bytes<u64>(&assertion_time); 
        let ancillary_data          = prediction_market::stamp_assertion(assertion_id, asserter_addr);
        let arbitration_resolution  = true; // asserter wins
        let override                = false;

        // escalation manager to resolve the dispute
        escalation_manager::set_arbitration_resolution(
            escalation_manager,
            time,
            identifier,
            ancillary_data,
            arbitration_resolution,
            override
        );

        // fast forward to liveness over (after assertion has expired)
        timestamp::fast_forward_seconds(liveness + 1);

        // get asserter, disputer, and treasury balance before assertion settled
        let initial_asserter_balance = primary_fungible_store::balance(asserter_addr    , oracle_token_metadata);
        let initial_disputer_balance = primary_fungible_store::balance(disputer_addr    , oracle_token_metadata);
        let initial_treasury_balance = primary_fungible_store::balance(treasury_addr    , oracle_token_metadata);

        // ----------------------------------
        // Settle Assertion
        // ----------------------------------

        // anyone can settle the assertion
        prediction_market::settle_assertion(
            settle_caller,
            assertion_id
        );

        // get views to confirm assertion has been settled
        let (
            _asserter, 
            settled, 
            settlement_resolution, 
            _liveness, 
            _assertion_time, 
            _expiration_time, 
            _identifier, 
            bond, 
            _disputer
        ) = prediction_market::get_assertion(assertion_id);

        assert!(settled                 == true                     , 105);
        assert!(settlement_resolution   == arbitration_resolution   , 106);

        // get asserter, disputer, and treasury balance after assertion settled
        let updated_asserter_balance = primary_fungible_store::balance(asserter_addr    , oracle_token_metadata);
        let updated_disputer_balance = primary_fungible_store::balance(disputer_addr    , oracle_token_metadata);
        let updated_treasury_balance = primary_fungible_store::balance(treasury_addr    , oracle_token_metadata);

        // calculate fee 
        let oracle_fee            = (burned_bond_percentage * bond) / 10000;
        let bond_recipient_amount = (bond * 2) - oracle_fee;

        // asserter should receive his bond + disputer bond less oracle fee
        assert!(updated_asserter_balance == initial_asserter_balance + bond_recipient_amount, 107);

        // treasury should receive oracle fee
        assert!(updated_treasury_balance == initial_treasury_balance + oracle_fee, 108);

        // no changes to disputer balance as he lost the dispute
        assert!(updated_disputer_balance == initial_disputer_balance, 109);

        // test view get market
        let (
            _creator,
            resolved,
            view_asserted_outcome_id,
            _reward,
            _required_bond,
            _view_outcome_one,
            _view_outcome_two,
            _view_description,
            _view_image_url,
            _view_categories,
            _view_start_timestamp,
            _outcome_token_one_metadata,
            _outcome_token_two_metadata,
            _outcome_token_one_address,
            _outcome_token_two_address,
            _pool_initialized,
            _pool_initializer
        ) = prediction_market::get_market(market_id);

        // market is now resolved and asserted outcome id is reset 
        assert!(resolved                 == true                 , 111);
        assert!(view_asserted_outcome_id != vector::empty<u8>()  , 112);

        // should fail: cannot deposit liquidity after market resolved
        let deposit_amount = 1000;
        prediction_market::deposit_liquidity(user_one, market_id, deposit_amount);
    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444, user_three = @0x555, treasury = @0x666)]
    #[expected_failure(abort_code = ERROR_MARKET_HAS_BEEN_RESOLVED, location = prediction_market)]
    public entry fun test_cannot_buy_outcome_tokens_after_market_resolved(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
        user_three: &signer,
        treasury: &signer
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);
        
        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // set assertion policy
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one (asserter), user two (disputer), and treasury
        let mint_amount     = 100000000;
        let treasury_addr   = signer::address_of(treasury);
        let user_three_addr = signer::address_of(user_three);
        oracle_token::mint(prediction_market, user_one_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_two_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_three_addr   , mint_amount);
        oracle_token::mint(prediction_market, treasury_addr     , mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = treasury_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // ----------------------------------
        // Initialize Market
        // ----------------------------------

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // ----------------------------------
        // Initialize Liquidity Pool
        // ----------------------------------

        let initial_liquidity = (100_000 as u128);
        prediction_market::initialize_pool(user_one, market_id, initial_liquidity);

        // ----------------------------------
        // Assert Market
        // ----------------------------------

        // init params for truth assertion
        let asserted_outcome = outcome_one; // we assert outcome one is correct

        // init roles
        let asserter            = user_two;
        let asserter_addr       = user_two_addr;
        let disputer            = user_three;
        let disputer_addr       = user_three_addr;
        let settle_caller       = user_one;

        // get next assertion id
        let assertion_id = prediction_market::get_next_assertion_id();

        // user two to call assert_market
        prediction_market::assert_market(
            asserter,
            market_id,
            asserted_outcome
        );

        // calc bond to be transferred
        let minimum_bond = (DEFAULT_FEE * 10000) / DEFAULT_BURNED_BOND_PERCENTAGE;
        let bond;
        if(required_bond > minimum_bond){
            bond =  required_bond;
        } else {
            bond = minimum_bond;
        };

        // bond is transferred from asserter to module
        let asserter_balance = primary_fungible_store::balance(asserter_addr, oracle_token_metadata);
        assert!(asserter_balance == mint_amount - bond, 101);

        // ----------------------------------
        // Set defaults
        // ----------------------------------

        let liveness     = DEFAULT_MIN_LIVENESS;
        let identifier   = DEFAULT_IDENTIFIER;

        // ----------------------------------
        // Dispute Assertion
        // ----------------------------------

        // user three disputes assertion
        prediction_market::dispute_assertion(
            disputer,
            assertion_id
        );

        // bond is transferred from disputer to module
        let disputer_balance = primary_fungible_store::balance(disputer_addr, oracle_token_metadata);
        assert!(disputer_balance == mint_amount - bond, 102);

        // create instance of expected event
        let assertion_disputed_event = prediction_market::test_AssertionDisputedEvent(
            assertion_id,
            disputer_addr // disputer
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&assertion_disputed_event), 103);

        // get views to confirm assertion has been updated with disputer
        let (
            _asserter, 
            _settled, 
            _settlement_resolution, 
            _liveness, 
            assertion_time, 
            _expiration_time, 
            _identifier, 
            _bond, 
            disputer
        ) = prediction_market::get_assertion(assertion_id);

        assert!(option::destroy_some(disputer) == disputer_addr, 104);

        // ----------------------------------
        // Escalation Manager to set arbitration resolution
        // ----------------------------------

        // set arbitration resolution parameters
        let time                    = bcs::to_bytes<u64>(&assertion_time); 
        let ancillary_data          = prediction_market::stamp_assertion(assertion_id, asserter_addr);
        let arbitration_resolution  = true; // asserter wins
        let override                = false;

        // escalation manager to resolve the dispute
        escalation_manager::set_arbitration_resolution(
            escalation_manager,
            time,
            identifier,
            ancillary_data,
            arbitration_resolution,
            override
        );

        // fast forward to liveness over (after assertion has expired)
        timestamp::fast_forward_seconds(liveness + 1);

        // get asserter, disputer, and treasury balance before assertion settled
        let initial_asserter_balance = primary_fungible_store::balance(asserter_addr    , oracle_token_metadata);
        let initial_disputer_balance = primary_fungible_store::balance(disputer_addr    , oracle_token_metadata);
        let initial_treasury_balance = primary_fungible_store::balance(treasury_addr    , oracle_token_metadata);

        // ----------------------------------
        // Settle Assertion
        // ----------------------------------

        // anyone can settle the assertion
        prediction_market::settle_assertion(
            settle_caller,
            assertion_id
        );

        // get views to confirm assertion has been settled
        let (
            _asserter, 
            settled, 
            settlement_resolution, 
            _liveness, 
            _assertion_time, 
            _expiration_time, 
            _identifier, 
            bond, 
            _disputer
        ) = prediction_market::get_assertion(assertion_id);

        assert!(settled                 == true                     , 105);
        assert!(settlement_resolution   == arbitration_resolution   , 106);

        // get asserter, disputer, and treasury balance after assertion settled
        let updated_asserter_balance = primary_fungible_store::balance(asserter_addr    , oracle_token_metadata);
        let updated_disputer_balance = primary_fungible_store::balance(disputer_addr    , oracle_token_metadata);
        let updated_treasury_balance = primary_fungible_store::balance(treasury_addr    , oracle_token_metadata);

        // calculate fee 
        let oracle_fee            = (burned_bond_percentage * bond) / 10000;
        let bond_recipient_amount = (bond * 2) - oracle_fee;

        // asserter should receive his bond + disputer bond less oracle fee
        assert!(updated_asserter_balance == initial_asserter_balance + bond_recipient_amount, 107);

        // treasury should receive oracle fee
        assert!(updated_treasury_balance == initial_treasury_balance + oracle_fee, 108);

        // no changes to disputer balance as he lost the dispute
        assert!(updated_disputer_balance == initial_disputer_balance, 109);

        // test view get market
        let (
            _creator,
            resolved,
            view_asserted_outcome_id,
            _reward,
            _required_bond,
            _view_outcome_one,
            _view_outcome_two,
            _view_description,
            _view_image_url,
            _view_categories,
            _view_start_timestamp,
            _outcome_token_one_metadata,
            _outcome_token_two_metadata,
            _outcome_token_one_address,
            _outcome_token_two_address,
            _pool_initialized,
            _pool_initializer
        ) = prediction_market::get_market(market_id);

        // market is now resolved and asserted outcome id is reset 
        assert!(resolved                 == true                 , 111);
        assert!(view_asserted_outcome_id != vector::empty<u8>()  , 112);

        // should fail: cannot buy outcome tokens after market resolved
        let buy_amount      = 1000;
        let outcome_token   = b"one";
        prediction_market::buy_outcome_tokens(user_one, market_id, outcome_token, buy_amount);
    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444, user_three = @0x555, treasury = @0x666)]
    #[expected_failure(abort_code = ERROR_MARKET_HAS_BEEN_RESOLVED, location = prediction_market)]
    public entry fun test_cannot_sell_outcome_tokens_after_market_resolved(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
        user_three: &signer,
        treasury: &signer
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);
        
        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // set assertion policy
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one (asserter), user two (disputer), and treasury
        let mint_amount     = 100000000;
        let treasury_addr   = signer::address_of(treasury);
        let user_three_addr = signer::address_of(user_three);
        oracle_token::mint(prediction_market, user_one_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_two_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_three_addr   , mint_amount);
        oracle_token::mint(prediction_market, treasury_addr     , mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = treasury_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // ----------------------------------
        // Initialize Market
        // ----------------------------------

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // ----------------------------------
        // Initialize Liquidity Pool
        // ----------------------------------

        let initial_liquidity = (100_000 as u128);
        prediction_market::initialize_pool(user_one, market_id, initial_liquidity);

        // ----------------------------------
        // Assert Market
        // ----------------------------------

        // init params for truth assertion
        let asserted_outcome = outcome_one; // we assert outcome one is correct

        // init roles
        let asserter            = user_two;
        let asserter_addr       = user_two_addr;
        let disputer            = user_three;
        let disputer_addr       = user_three_addr;
        let settle_caller       = user_one;

        // get next assertion id
        let assertion_id = prediction_market::get_next_assertion_id();

        // user two to call assert_market
        prediction_market::assert_market(
            asserter,
            market_id,
            asserted_outcome
        );

        // calc bond to be transferred
        let minimum_bond = (DEFAULT_FEE * 10000) / DEFAULT_BURNED_BOND_PERCENTAGE;
        let bond;
        if(required_bond > minimum_bond){
            bond =  required_bond;
        } else {
            bond = minimum_bond;
        };

        // bond is transferred from asserter to module
        let asserter_balance = primary_fungible_store::balance(asserter_addr, oracle_token_metadata);
        assert!(asserter_balance == mint_amount - bond, 101);

        // ----------------------------------
        // Set defaults
        // ----------------------------------

        let liveness     = DEFAULT_MIN_LIVENESS;
        let identifier   = DEFAULT_IDENTIFIER;

        // ----------------------------------
        // Dispute Assertion
        // ----------------------------------

        // user three disputes assertion
        prediction_market::dispute_assertion(
            disputer,
            assertion_id
        );

        // bond is transferred from disputer to module
        let disputer_balance = primary_fungible_store::balance(disputer_addr, oracle_token_metadata);
        assert!(disputer_balance == mint_amount - bond, 102);

        // create instance of expected event
        let assertion_disputed_event = prediction_market::test_AssertionDisputedEvent(
            assertion_id,
            disputer_addr // disputer
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&assertion_disputed_event), 103);

        // get views to confirm assertion has been updated with disputer
        let (
            _asserter, 
            _settled, 
            _settlement_resolution, 
            _liveness, 
            assertion_time, 
            _expiration_time, 
            _identifier, 
            _bond, 
            disputer
        ) = prediction_market::get_assertion(assertion_id);

        assert!(option::destroy_some(disputer) == disputer_addr, 104);

        // ----------------------------------
        // Escalation Manager to set arbitration resolution
        // ----------------------------------

        // set arbitration resolution parameters
        let time                    = bcs::to_bytes<u64>(&assertion_time); 
        let ancillary_data          = prediction_market::stamp_assertion(assertion_id, asserter_addr);
        let arbitration_resolution  = true; // asserter wins
        let override                = false;

        // escalation manager to resolve the dispute
        escalation_manager::set_arbitration_resolution(
            escalation_manager,
            time,
            identifier,
            ancillary_data,
            arbitration_resolution,
            override
        );

        // fast forward to liveness over (after assertion has expired)
        timestamp::fast_forward_seconds(liveness + 1);

        // get asserter, disputer, and treasury balance before assertion settled
        let initial_asserter_balance = primary_fungible_store::balance(asserter_addr    , oracle_token_metadata);
        let initial_disputer_balance = primary_fungible_store::balance(disputer_addr    , oracle_token_metadata);
        let initial_treasury_balance = primary_fungible_store::balance(treasury_addr    , oracle_token_metadata);

        // ----------------------------------
        // Settle Assertion
        // ----------------------------------

        // anyone can settle the assertion
        prediction_market::settle_assertion(
            settle_caller,
            assertion_id
        );

        // get views to confirm assertion has been settled
        let (
            _asserter, 
            settled, 
            settlement_resolution, 
            _liveness, 
            _assertion_time, 
            _expiration_time, 
            _identifier, 
            bond, 
            _disputer
        ) = prediction_market::get_assertion(assertion_id);

        assert!(settled                 == true                     , 105);
        assert!(settlement_resolution   == arbitration_resolution   , 106);

        // get asserter, disputer, and treasury balance after assertion settled
        let updated_asserter_balance = primary_fungible_store::balance(asserter_addr    , oracle_token_metadata);
        let updated_disputer_balance = primary_fungible_store::balance(disputer_addr    , oracle_token_metadata);
        let updated_treasury_balance = primary_fungible_store::balance(treasury_addr    , oracle_token_metadata);

        // calculate fee 
        let oracle_fee            = (burned_bond_percentage * bond) / 10000;
        let bond_recipient_amount = (bond * 2) - oracle_fee;

        // asserter should receive his bond + disputer bond less oracle fee
        assert!(updated_asserter_balance == initial_asserter_balance + bond_recipient_amount, 107);

        // treasury should receive oracle fee
        assert!(updated_treasury_balance == initial_treasury_balance + oracle_fee, 108);

        // no changes to disputer balance as he lost the dispute
        assert!(updated_disputer_balance == initial_disputer_balance, 109);

        // test view get market
        let (
            _creator,
            resolved,
            view_asserted_outcome_id,
            _reward,
            _required_bond,
            _view_outcome_one,
            _view_outcome_two,
            _view_description,
            _view_image_url,
            _view_categories,
            _view_start_timestamp,
            _outcome_token_one_metadata,
            _outcome_token_two_metadata,
            _outcome_token_one_address,
            _outcome_token_two_address,
            _pool_initialized,
            _pool_initializer
        ) = prediction_market::get_market(market_id);

        // market is now resolved and asserted outcome id is reset 
        assert!(resolved                 == true                 , 111);
        assert!(view_asserted_outcome_id != vector::empty<u8>()  , 112);

        // should fail: cannot buy outcome tokens after market resolved
        let sell_amount     = 1000;
        let outcome_token   = b"one";
        prediction_market::sell_outcome_tokens(user_one, market_id, outcome_token, sell_amount);
    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444, user_three = @0x555, treasury = @0x666)]
    #[expected_failure(abort_code = ERROR_MARKET_HAS_BEEN_RESOLVED, location = prediction_market)]
    public entry fun test_cannot_initialize_pool_for_resolved_market(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
        user_three: &signer,
        treasury: &signer
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);
        
        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // set assertion policy
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one (asserter), user two (disputer), and treasury
        let mint_amount     = 100000000;
        let treasury_addr   = signer::address_of(treasury);
        let user_three_addr = signer::address_of(user_three);
        oracle_token::mint(prediction_market, user_one_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_two_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_three_addr   , mint_amount);
        oracle_token::mint(prediction_market, treasury_addr     , mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = treasury_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // ----------------------------------
        // Initialize Market
        // ----------------------------------

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // ----------------------------------
        // Initialize Liquidity Pool
        // ----------------------------------

        let initial_liquidity = (100_000 as u128);
        prediction_market::initialize_pool(user_one, market_id, initial_liquidity);

        // ----------------------------------
        // Assert Market
        // ----------------------------------

        // init params for truth assertion
        let asserted_outcome = outcome_one; // we assert outcome one is correct

        // init roles
        let asserter            = user_two;
        let asserter_addr       = user_two_addr;
        let disputer            = user_three;
        let disputer_addr       = user_three_addr;
        let settle_caller       = user_one;

        // get next assertion id
        let assertion_id = prediction_market::get_next_assertion_id();

        // user two to call assert_market
        prediction_market::assert_market(
            asserter,
            market_id,
            asserted_outcome
        );

        // calc bond to be transferred
        let minimum_bond = (DEFAULT_FEE * 10000) / DEFAULT_BURNED_BOND_PERCENTAGE;
        let bond;
        if(required_bond > minimum_bond){
            bond =  required_bond;
        } else {
            bond = minimum_bond;
        };

        // bond is transferred from asserter to module
        let asserter_balance = primary_fungible_store::balance(asserter_addr, oracle_token_metadata);
        assert!(asserter_balance == mint_amount - bond, 101);

        // ----------------------------------
        // Set defaults
        // ----------------------------------

        let liveness     = DEFAULT_MIN_LIVENESS;
        let identifier   = DEFAULT_IDENTIFIER;

        // ----------------------------------
        // Dispute Assertion
        // ----------------------------------

        // user three disputes assertion
        prediction_market::dispute_assertion(
            disputer,
            assertion_id
        );

        // bond is transferred from disputer to module
        let disputer_balance = primary_fungible_store::balance(disputer_addr, oracle_token_metadata);
        assert!(disputer_balance == mint_amount - bond, 102);

        // create instance of expected event
        let assertion_disputed_event = prediction_market::test_AssertionDisputedEvent(
            assertion_id,
            disputer_addr // disputer
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&assertion_disputed_event), 103);

        // get views to confirm assertion has been updated with disputer
        let (
            _asserter, 
            _settled, 
            _settlement_resolution, 
            _liveness, 
            assertion_time, 
            _expiration_time, 
            _identifier, 
            _bond, 
            disputer
        ) = prediction_market::get_assertion(assertion_id);

        assert!(option::destroy_some(disputer) == disputer_addr, 104);

        // ----------------------------------
        // Escalation Manager to set arbitration resolution
        // ----------------------------------

        // set arbitration resolution parameters
        let time                    = bcs::to_bytes<u64>(&assertion_time); 
        let ancillary_data          = prediction_market::stamp_assertion(assertion_id, asserter_addr);
        let arbitration_resolution  = true; // asserter wins
        let override                = false;

        // escalation manager to resolve the dispute
        escalation_manager::set_arbitration_resolution(
            escalation_manager,
            time,
            identifier,
            ancillary_data,
            arbitration_resolution,
            override
        );

        // fast forward to liveness over (after assertion has expired)
        timestamp::fast_forward_seconds(liveness + 1);

        // get asserter, disputer, and treasury balance before assertion settled
        let initial_asserter_balance = primary_fungible_store::balance(asserter_addr    , oracle_token_metadata);
        let initial_disputer_balance = primary_fungible_store::balance(disputer_addr    , oracle_token_metadata);
        let initial_treasury_balance = primary_fungible_store::balance(treasury_addr    , oracle_token_metadata);

        // ----------------------------------
        // Settle Assertion
        // ----------------------------------

        // anyone can settle the assertion
        prediction_market::settle_assertion(
            settle_caller,
            assertion_id
        );

        // get views to confirm assertion has been settled
        let (
            _asserter, 
            settled, 
            settlement_resolution, 
            _liveness, 
            _assertion_time, 
            _expiration_time, 
            _identifier, 
            bond, 
            _disputer
        ) = prediction_market::get_assertion(assertion_id);

        assert!(settled                 == true                     , 105);
        assert!(settlement_resolution   == arbitration_resolution   , 106);

        // get asserter, disputer, and treasury balance after assertion settled
        let updated_asserter_balance = primary_fungible_store::balance(asserter_addr    , oracle_token_metadata);
        let updated_disputer_balance = primary_fungible_store::balance(disputer_addr    , oracle_token_metadata);
        let updated_treasury_balance = primary_fungible_store::balance(treasury_addr    , oracle_token_metadata);

        // calculate fee 
        let oracle_fee            = (burned_bond_percentage * bond) / 10000;
        let bond_recipient_amount = (bond * 2) - oracle_fee;

        // asserter should receive his bond + disputer bond less oracle fee
        assert!(updated_asserter_balance == initial_asserter_balance + bond_recipient_amount, 107);

        // treasury should receive oracle fee
        assert!(updated_treasury_balance == initial_treasury_balance + oracle_fee, 108);

        // no changes to disputer balance as he lost the dispute
        assert!(updated_disputer_balance == initial_disputer_balance, 109);

        // test view get market
        let (
            _creator,
            resolved,
            view_asserted_outcome_id,
            _reward,
            _required_bond,
            _view_outcome_one,
            _view_outcome_two,
            _view_description,
            _view_image_url,
            _view_categories,
            _view_start_timestamp,
            _outcome_token_one_metadata,
            _outcome_token_two_metadata,
            _outcome_token_one_address,
            _outcome_token_two_address,
            _pool_initialized,
            _pool_initializer
        ) = prediction_market::get_market(market_id);

        // market is now resolved and asserted outcome id is reset 
        assert!(resolved                 == true                 , 111);
        assert!(view_asserted_outcome_id != vector::empty<u8>()  , 112);

        // should fail: cannot initialize pool after market resolved
        let initial_liquidity = (100_000 as u128);
        prediction_market::initialize_pool(user_one, market_id, initial_liquidity);
    }

    

    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure]
    public entry fun test_cannot_assert_market_with_invalid_outcome(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // call set_assertion_policy to set validate_asserters to false
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // call set_whitelisted_dispute_caller
        escalation_manager::set_whitelisted_dispute_caller(
            escalation_manager,
            user_two_addr,
            true
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one for bond
        let mint_amount = 100000000;
        oracle_token::mint(prediction_market, user_one_addr, mint_amount);
        oracle_token::mint(prediction_market, user_two_addr, mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = user_one_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 1;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // init params for truth assertion
        let asserted_outcome = b"invalid outcome"; 

        // ----------------------------------
        // Assert Market
        // ----------------------------------

        // user two to call assert_market
        prediction_market::assert_market(
            user_two,
            market_id,
            asserted_outcome
        );

    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_MARKET_HAS_NOT_BEEN_RESOLVED, location = prediction_market)]
    public entry fun test_cannot_settle_outcome_tokens_before_market_has_been_resolved(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // call set_assertion_policy to set validate_asserters to false
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // call set_whitelisted_dispute_caller
        escalation_manager::set_whitelisted_dispute_caller(
            escalation_manager,
            user_two_addr,
            true
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one for bond
        let mint_amount = 100000000;
        oracle_token::mint(prediction_market, user_one_addr, mint_amount);
        oracle_token::mint(prediction_market, user_two_addr, mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = user_one_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 1;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // init params for truth assertion
        let asserted_outcome    = outcome_one; 

        // ----------------------------------
        // Initialize Liquidity Pool
        // ----------------------------------

        let initial_liquidity = (100_000 as u128);
        prediction_market::initialize_pool(user_one, market_id, initial_liquidity);

        // ----------------------------------
        // Assert Market
        // ----------------------------------

        // init roles
        let asserter            = user_two;

        // user two to call assert_market
        prediction_market::assert_market(
            asserter,
            market_id,
            asserted_outcome
        );
        
        // ----------------------------------
        // Outcome Tokens interactions test
        // ----------------------------------

        // redeem some LP tokens for outcome tokens for user one
        let lp_token_redeem_amount = 1000;
        prediction_market::redeem_lp_for_outcome_tokens(user_one, market_id, lp_token_redeem_amount);

        // should fail if user tries to settle outcome tokens now before market has been resolved
        prediction_market::settle_outcome_tokens(user_one, market_id);

    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_ASSERTION_NOT_EXPIRED, location = prediction_market)]
    public entry fun test_cannot_settle_assertion_before_expiration(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // call set_assertion_policy to set validate_asserters to false
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // call set_whitelisted_dispute_caller
        escalation_manager::set_whitelisted_dispute_caller(
            escalation_manager,
            user_two_addr,
            true
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one for bond
        let mint_amount = 100000000;
        oracle_token::mint(prediction_market, user_one_addr, mint_amount);
        oracle_token::mint(prediction_market, user_two_addr, mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = user_one_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 1;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // init params for truth assertion
        let asserted_outcome    = outcome_one; 

        // ----------------------------------
        // Assert Market
        // ----------------------------------

        // init roles
        let asserter            = user_two;

        // get next assertion id
        let assertion_id = prediction_market::get_next_assertion_id();

        // user two to call assert_market
        prediction_market::assert_market(
            asserter,
            market_id,
            asserted_outcome
        );

        // should fail: cannot settle assertion before expiration
        prediction_market::settle_assertion(
            asserter,
            assertion_id
        );

    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_ASSERTION_ALREADY_SETTLED, location = prediction_market)]
    public entry fun test_cannot_settle_assertion_more_than_once(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // call set_assertion_policy to set validate_asserters to false
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // call set_whitelisted_dispute_caller
        escalation_manager::set_whitelisted_dispute_caller(
            escalation_manager,
            user_two_addr,
            true
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one for bond
        let mint_amount = 100000000;
        oracle_token::mint(prediction_market, user_one_addr, mint_amount);
        oracle_token::mint(prediction_market, user_two_addr, mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = user_one_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 1;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // init params for truth assertion
        let asserted_outcome    = outcome_one; 

        // ----------------------------------
        // Assert Market
        // ----------------------------------

        // init roles
        let asserter            = user_two;

        // get next assertion id
        let assertion_id = prediction_market::get_next_assertion_id();

        // user two to call assert_market
        prediction_market::assert_market(
            asserter,
            market_id,
            asserted_outcome
        );

        let liveness = DEFAULT_MIN_LIVENESS;

        // fast forward to liveness over (after assertion has expired)
        timestamp::fast_forward_seconds(liveness + 1);

        prediction_market::settle_assertion(
            asserter,
            assertion_id
        );

        // should fail: cannot settle assertion again
        prediction_market::settle_assertion(
            asserter,
            assertion_id
        );

    }

    
    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_POOL_ALREADY_INITIALIZED, location = prediction_market)]
    public entry fun test_cannot_initialize_pool_for_market_more_than_once(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // call set_assertion_policy to set validate_asserters to false
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // call set_whitelisted_dispute_caller
        escalation_manager::set_whitelisted_dispute_caller(
            escalation_manager,
            user_two_addr,
            true
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one for bond
        let mint_amount = 100000000;
        oracle_token::mint(prediction_market, user_one_addr, mint_amount);
        oracle_token::mint(prediction_market, user_two_addr, mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = user_one_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 1;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // ----------------------------------
        // Initialize Liquidity Pool
        // ----------------------------------

        let initial_liquidity = (100_000 as u128);
        prediction_market::initialize_pool(user_one, market_id, initial_liquidity);

        // should fail
        prediction_market::initialize_pool(user_one, market_id, initial_liquidity);

    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444)]
    #[expected_failure(abort_code = ERROR_POOL_NOT_INITIALIZED, location = prediction_market)]
    public entry fun test_cannot_redeem_lp_tokens_for_outcome_tokens_if_pool_is_not_initialized(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);

        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // call set_assertion_policy to set validate_asserters to false
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // call set_whitelisted_dispute_caller
        escalation_manager::set_whitelisted_dispute_caller(
            escalation_manager,
            user_two_addr,
            true
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one for bond
        let mint_amount = 100000000;
        oracle_token::mint(prediction_market, user_one_addr, mint_amount);
        oracle_token::mint(prediction_market, user_two_addr, mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = user_one_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 1;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // ----------------------------------
        // Initialize Liquidity Pool
        // ----------------------------------
        
        let lp_token_redeem_amount = 200;
        prediction_market::redeem_lp_for_outcome_tokens(user_two, market_id, lp_token_redeem_amount);        

    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444, user_three = @0x555, treasury = @0x666)]
    #[expected_failure(abort_code = ERROR_POOL_NOT_INITIALIZED, location = prediction_market)]
    public entry fun test_cannot_settle_outcome_tokens_for_resolved_market_if_pool_has_not_been_initialized(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
        user_three: &signer,
        treasury: &signer
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);
        
        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // set assertion policy
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one (asserter), user two (disputer), and treasury
        let mint_amount     = 100000000;
        let treasury_addr   = signer::address_of(treasury);
        let user_three_addr = signer::address_of(user_three);
        oracle_token::mint(prediction_market, user_one_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_two_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_three_addr   , mint_amount);
        oracle_token::mint(prediction_market, treasury_addr     , mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = treasury_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // ----------------------------------
        // Initialize Market
        // ----------------------------------

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // ----------------------------------
        // Assert Market
        // ----------------------------------

        // init params for truth assertion
        let asserted_outcome = outcome_one; // we assert outcome one is correct

        // init roles
        let asserter            = user_two;
        let asserter_addr       = user_two_addr;
        let disputer            = user_three;
        let disputer_addr       = user_three_addr;
        let settle_caller       = user_one;

        // get next assertion id
        let assertion_id = prediction_market::get_next_assertion_id();

        // user two to call assert_market
        prediction_market::assert_market(
            asserter,
            market_id,
            asserted_outcome
        );

        // calc bond to be transferred
        let minimum_bond = (DEFAULT_FEE * 10000) / DEFAULT_BURNED_BOND_PERCENTAGE;
        let bond;
        if(required_bond > minimum_bond){
            bond =  required_bond;
        } else {
            bond = minimum_bond;
        };

        // bond is transferred from asserter to module
        let asserter_balance = primary_fungible_store::balance(asserter_addr, oracle_token_metadata);
        assert!(asserter_balance == mint_amount - bond, 101);

        // ----------------------------------
        // Set defaults
        // ----------------------------------

        let liveness     = DEFAULT_MIN_LIVENESS;
        let identifier   = DEFAULT_IDENTIFIER;

        // ----------------------------------
        // Dispute Assertion
        // ----------------------------------

        // user three disputes assertion
        prediction_market::dispute_assertion(
            disputer,
            assertion_id
        );

        // bond is transferred from disputer to module
        let disputer_balance = primary_fungible_store::balance(disputer_addr, oracle_token_metadata);
        assert!(disputer_balance == mint_amount - bond, 102);

        // create instance of expected event
        let assertion_disputed_event = prediction_market::test_AssertionDisputedEvent(
            assertion_id,
            disputer_addr // disputer
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&assertion_disputed_event), 103);

        // get views to confirm assertion has been updated with disputer
        let (
            _asserter, 
            _settled, 
            _settlement_resolution, 
            _liveness, 
            assertion_time, 
            _expiration_time, 
            _identifier, 
            _bond, 
            disputer
        ) = prediction_market::get_assertion(assertion_id);

        assert!(option::destroy_some(disputer) == disputer_addr, 104);

        // ----------------------------------
        // Escalation Manager to set arbitration resolution
        // ----------------------------------

        // set arbitration resolution parameters
        let time                    = bcs::to_bytes<u64>(&assertion_time); 
        let ancillary_data          = prediction_market::stamp_assertion(assertion_id, asserter_addr);
        let arbitration_resolution  = true; // asserter wins
        let override                = false;

        // escalation manager to resolve the dispute
        escalation_manager::set_arbitration_resolution(
            escalation_manager,
            time,
            identifier,
            ancillary_data,
            arbitration_resolution,
            override
        );

        // fast forward to liveness over (after assertion has expired)
        timestamp::fast_forward_seconds(liveness + 1);

        // get asserter, disputer, and treasury balance before assertion settled
        let initial_asserter_balance = primary_fungible_store::balance(asserter_addr    , oracle_token_metadata);
        let initial_disputer_balance = primary_fungible_store::balance(disputer_addr    , oracle_token_metadata);
        let initial_treasury_balance = primary_fungible_store::balance(treasury_addr    , oracle_token_metadata);

        // ----------------------------------
        // Settle Assertion
        // ----------------------------------

        // anyone can settle the assertion
        prediction_market::settle_assertion(
            settle_caller,
            assertion_id
        );

        // get views to confirm assertion has been settled
        let (
            _asserter, 
            settled, 
            settlement_resolution, 
            _liveness, 
            _assertion_time, 
            _expiration_time, 
            _identifier, 
            bond, 
            _disputer
        ) = prediction_market::get_assertion(assertion_id);

        assert!(settled                 == true                     , 105);
        assert!(settlement_resolution   == arbitration_resolution   , 106);

        // get asserter, disputer, and treasury balance after assertion settled
        let updated_asserter_balance = primary_fungible_store::balance(asserter_addr    , oracle_token_metadata);
        let updated_disputer_balance = primary_fungible_store::balance(disputer_addr    , oracle_token_metadata);
        let updated_treasury_balance = primary_fungible_store::balance(treasury_addr    , oracle_token_metadata);

        // calculate fee 
        let oracle_fee            = (burned_bond_percentage * bond) / 10000;
        let bond_recipient_amount = (bond * 2) - oracle_fee;

        // asserter should receive his bond + disputer bond less oracle fee
        assert!(updated_asserter_balance == initial_asserter_balance + bond_recipient_amount, 107);

        // treasury should receive oracle fee
        assert!(updated_treasury_balance == initial_treasury_balance + oracle_fee, 108);

        // no changes to disputer balance as he lost the dispute
        assert!(updated_disputer_balance == initial_disputer_balance, 109);

        // test view get market
        let (
            _creator,
            resolved,
            view_asserted_outcome_id,
            _reward,
            _required_bond,
            _view_outcome_one,
            _view_outcome_two,
            _view_description,
            _view_image_url,
            _view_categories,
            _view_start_timestamp,
            _outcome_token_one_metadata,
            _outcome_token_two_metadata,
            _outcome_token_one_address,
            _outcome_token_two_address,
            _pool_initialized,
            _pool_initializer
        ) = prediction_market::get_market(market_id);

        // market is now resolved and asserted outcome id is reset 
        assert!(resolved                 == true                 , 111);
        assert!(view_asserted_outcome_id != vector::empty<u8>()  , 112);

        // should fail: cannot settle outcome tokens after market resolved
        prediction_market::settle_outcome_tokens(user_one, market_id);
    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444, user_three = @0x555, treasury = @0x666)]
    #[expected_failure(abort_code = ERROR_MARKET_HAS_BEEN_RESOLVED, location = prediction_market)]
    public entry fun test_cannot_withdraw_liqudity_after_market_has_been_resolved(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
        user_three: &signer,
        treasury: &signer
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);
        
        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // set assertion policy
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one (asserter), user two (disputer), and treasury
        let mint_amount     = 100000000;
        let treasury_addr   = signer::address_of(treasury);
        let user_three_addr = signer::address_of(user_three);
        oracle_token::mint(prediction_market, user_one_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_two_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_three_addr   , mint_amount);
        oracle_token::mint(prediction_market, treasury_addr     , mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = treasury_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // ----------------------------------
        // Initialize Market
        // ----------------------------------

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // ----------------------------------
        // Assert Market
        // ----------------------------------

        // init params for truth assertion
        let asserted_outcome = outcome_one; // we assert outcome one is correct

        // init roles
        let asserter            = user_two;
        let asserter_addr       = user_two_addr;
        let disputer            = user_three;
        let disputer_addr       = user_three_addr;
        let settle_caller       = user_one;

        // get next assertion id
        let assertion_id = prediction_market::get_next_assertion_id();

        // user two to call assert_market
        prediction_market::assert_market(
            asserter,
            market_id,
            asserted_outcome
        );

        // calc bond to be transferred
        let minimum_bond = (DEFAULT_FEE * 10000) / DEFAULT_BURNED_BOND_PERCENTAGE;
        let bond;
        if(required_bond > minimum_bond){
            bond =  required_bond;
        } else {
            bond = minimum_bond;
        };

        // bond is transferred from asserter to module
        let asserter_balance = primary_fungible_store::balance(asserter_addr, oracle_token_metadata);
        assert!(asserter_balance == mint_amount - bond, 101);

        // ----------------------------------
        // Set defaults
        // ----------------------------------

        let liveness     = DEFAULT_MIN_LIVENESS;
        let identifier   = DEFAULT_IDENTIFIER;

        // ----------------------------------
        // Dispute Assertion
        // ----------------------------------

        // user three disputes assertion
        prediction_market::dispute_assertion(
            disputer,
            assertion_id
        );

        // bond is transferred from disputer to module
        let disputer_balance = primary_fungible_store::balance(disputer_addr, oracle_token_metadata);
        assert!(disputer_balance == mint_amount - bond, 102);

        // create instance of expected event
        let assertion_disputed_event = prediction_market::test_AssertionDisputedEvent(
            assertion_id,
            disputer_addr // disputer
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&assertion_disputed_event), 103);

        // get views to confirm assertion has been updated with disputer
        let (
            _asserter, 
            _settled, 
            _settlement_resolution, 
            _liveness, 
            assertion_time, 
            _expiration_time, 
            _identifier, 
            _bond, 
            disputer
        ) = prediction_market::get_assertion(assertion_id);

        assert!(option::destroy_some(disputer) == disputer_addr, 104);

        // ----------------------------------
        // Escalation Manager to set arbitration resolution
        // ----------------------------------

        // set arbitration resolution parameters
        let time                    = bcs::to_bytes<u64>(&assertion_time); 
        let ancillary_data          = prediction_market::stamp_assertion(assertion_id, asserter_addr);
        let arbitration_resolution  = true; // asserter wins
        let override                = false;

        // escalation manager to resolve the dispute
        escalation_manager::set_arbitration_resolution(
            escalation_manager,
            time,
            identifier,
            ancillary_data,
            arbitration_resolution,
            override
        );

        // fast forward to liveness over (after assertion has expired)
        timestamp::fast_forward_seconds(liveness + 1);

        // get asserter, disputer, and treasury balance before assertion settled
        let initial_asserter_balance = primary_fungible_store::balance(asserter_addr    , oracle_token_metadata);
        let initial_disputer_balance = primary_fungible_store::balance(disputer_addr    , oracle_token_metadata);
        let initial_treasury_balance = primary_fungible_store::balance(treasury_addr    , oracle_token_metadata);

        // ----------------------------------
        // Settle Assertion
        // ----------------------------------

        // anyone can settle the assertion
        prediction_market::settle_assertion(
            settle_caller,
            assertion_id
        );

        // get views to confirm assertion has been settled
        let (
            _asserter, 
            settled, 
            settlement_resolution, 
            _liveness, 
            _assertion_time, 
            _expiration_time, 
            _identifier, 
            bond, 
            _disputer
        ) = prediction_market::get_assertion(assertion_id);

        assert!(settled                 == true                     , 105);
        assert!(settlement_resolution   == arbitration_resolution   , 106);

        // get asserter, disputer, and treasury balance after assertion settled
        let updated_asserter_balance = primary_fungible_store::balance(asserter_addr    , oracle_token_metadata);
        let updated_disputer_balance = primary_fungible_store::balance(disputer_addr    , oracle_token_metadata);
        let updated_treasury_balance = primary_fungible_store::balance(treasury_addr    , oracle_token_metadata);

        // calculate fee 
        let oracle_fee            = (burned_bond_percentage * bond) / 10000;
        let bond_recipient_amount = (bond * 2) - oracle_fee;

        // asserter should receive his bond + disputer bond less oracle fee
        assert!(updated_asserter_balance == initial_asserter_balance + bond_recipient_amount, 107);

        // treasury should receive oracle fee
        assert!(updated_treasury_balance == initial_treasury_balance + oracle_fee, 108);

        // no changes to disputer balance as he lost the dispute
        assert!(updated_disputer_balance == initial_disputer_balance, 109);

        // test view get market
        let (
            _creator,
            resolved,
            view_asserted_outcome_id,
            _reward,
            _required_bond,
            _view_outcome_one,
            _view_outcome_two,
            _view_description,
            _view_image_url,
            _view_categories,
            _view_start_timestamp,
            _outcome_token_one_metadata,
            _outcome_token_two_metadata,
            _outcome_token_one_address,
            _outcome_token_two_address,
            _pool_initialized,
            _pool_initializer
        ) = prediction_market::get_market(market_id);

        // market is now resolved and asserted outcome id is reset 
        assert!(resolved                 == true                 , 111);
        assert!(view_asserted_outcome_id != vector::empty<u8>()  , 112);

        // should fail: cannot withdraw liquidity after market resolved
        let withdraw_amount = 1000;
        prediction_market::withdraw_liquidity(user_one, market_id, withdraw_amount);
    }

   
    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444, user_three = @0x555, treasury = @0x666)]
    public entry fun test_user_can_withdraw_liquidity(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
        user_three: &signer,
        treasury: &signer
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);
        
        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // set assertion policy
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one (asserter), user two (disputer), and treasury
        let mint_amount     = 100000000;
        let treasury_addr   = signer::address_of(treasury);
        let user_three_addr = signer::address_of(user_three);
        oracle_token::mint(prediction_market, user_one_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_two_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_three_addr   , mint_amount);
        oracle_token::mint(prediction_market, treasury_addr     , mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = treasury_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // ----------------------------------
        // Initialize Market
        // ----------------------------------

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // ----------------------------------
        // Assert Market
        // ----------------------------------

        // init params for truth assertion
        let asserted_outcome = outcome_one; // we assert outcome one is correct

        // init roles
        let asserter            = user_two;
        let asserter_addr       = user_two_addr;

        // user two to call assert_market
        prediction_market::assert_market(
            asserter,
            market_id,
            asserted_outcome
        );

        // calc bond to be transferred
        let minimum_bond = (DEFAULT_FEE * 10000) / DEFAULT_BURNED_BOND_PERCENTAGE;
        let bond;
        if(required_bond > minimum_bond){
            bond =  required_bond;
        } else {
            bond = minimum_bond;
        };

        // bond is transferred from asserter to module
        let asserter_balance = primary_fungible_store::balance(asserter_addr, oracle_token_metadata);
        assert!(asserter_balance == mint_amount - bond, 101);

        // ----------------------------------
        // Initialize Liquidity Pool
        // ----------------------------------

        let initial_liquidity = (100_000 as u128);
        prediction_market::initialize_pool(user_one, market_id, initial_liquidity);

        // test user can withdraw liquidity
        let withdraw_amount = 1000;
        prediction_market::withdraw_liquidity(user_one, market_id, withdraw_amount);

        let lp_proportion                     = ((withdraw_amount as u128) * FIXED_POINT_ACCURACY) / (initial_liquidity / 2);
        let outcome_token_one_withdraw_amount = ((initial_liquidity/2 * lp_proportion) / FIXED_POINT_ACCURACY);
        let outcome_token_two_withdraw_amount = ((initial_liquidity/2 * lp_proportion) / FIXED_POINT_ACCURACY);
        let collateral_amount                 = outcome_token_one_withdraw_amount + outcome_token_two_withdraw_amount;

        // create instance of expected event
        let withdraw_liquidity_event = prediction_market::test_WithdrawLiquidityEvent(
            user_one_addr,
            market_id,
            (withdraw_amount as u64),
            (collateral_amount as u64)
        );

        // verify if expected event was emitted
        assert!(was_event_emitted(&withdraw_liquidity_event), 102);

    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444, user_three = @0x555, treasury = @0x666)]
    #[expected_failure(abort_code = ERROR_POOL_NOT_INITIALIZED, location = prediction_market)]
    public entry fun test_user_cannot_deposit_liquidity_if_pool_has_not_been_initialized(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
        user_three: &signer,
        treasury: &signer
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);
        
        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // set assertion policy
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one (asserter), user two (disputer), and treasury
        let mint_amount     = 100000000;
        let treasury_addr   = signer::address_of(treasury);
        let user_three_addr = signer::address_of(user_three);
        oracle_token::mint(prediction_market, user_one_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_two_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_three_addr   , mint_amount);
        oracle_token::mint(prediction_market, treasury_addr     , mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = treasury_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // ----------------------------------
        // Initialize Market
        // ----------------------------------

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // should fail
        let deposit_amount = 1000;
        prediction_market::deposit_liquidity(user_two, market_id, deposit_amount);

    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444, user_three = @0x555, treasury = @0x666)]
    #[expected_failure(abort_code = ERROR_POOL_NOT_INITIALIZED, location = prediction_market)]
    public entry fun test_user_cannot_withdraw_liquidity_if_pool_has_not_been_initialized(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
        user_three: &signer,
        treasury: &signer
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);
        
        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // set assertion policy
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one (asserter), user two (disputer), and treasury
        let mint_amount     = 100000000;
        let treasury_addr   = signer::address_of(treasury);
        let user_three_addr = signer::address_of(user_three);
        oracle_token::mint(prediction_market, user_one_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_two_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_three_addr   , mint_amount);
        oracle_token::mint(prediction_market, treasury_addr     , mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = treasury_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // ----------------------------------
        // Initialize Market
        // ----------------------------------

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // should fail
        let withdraw_amount = 1000;
        prediction_market::withdraw_liquidity(user_two, market_id, withdraw_amount);

    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444, user_three = @0x555, treasury = @0x666)]
    #[expected_failure(abort_code = ERROR_DEFAULT_MIN_LIQUIDITY_NOT_REACHED, location = prediction_market)]
    public entry fun test_user_cannot_initialize_pool_if_default_min_liquidity_required_is_not_reached(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
        user_three: &signer,
        treasury: &signer
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);
        
        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // set assertion policy
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one (asserter), user two (disputer), and treasury
        let mint_amount     = 100000000;
        let treasury_addr   = signer::address_of(treasury);
        let user_three_addr = signer::address_of(user_three);
        oracle_token::mint(prediction_market, user_one_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_two_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_three_addr   , mint_amount);
        oracle_token::mint(prediction_market, treasury_addr     , mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = treasury_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // ----------------------------------
        // Initialize Market
        // ----------------------------------

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // should fail
        let initial_liquidity = (1 as u128);
        prediction_market::initialize_pool(user_one, market_id, initial_liquidity);

    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444, user_three = @0x555, treasury = @0x666)]
    #[expected_failure(abort_code = ERROR_POOL_NOT_INITIALIZED, location = prediction_market)]
    public entry fun test_user_cannot_buy_outcome_tokens_if_liquidity_pool_has_not_been_initialized(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
        user_three: &signer,
        treasury: &signer
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);
        
        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // set assertion policy
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one (asserter), user two (disputer), and treasury
        let mint_amount     = 100000000;
        let treasury_addr   = signer::address_of(treasury);
        let user_three_addr = signer::address_of(user_three);
        oracle_token::mint(prediction_market, user_one_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_two_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_three_addr   , mint_amount);
        oracle_token::mint(prediction_market, treasury_addr     , mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = treasury_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // ----------------------------------
        // Initialize Market
        // ----------------------------------

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // should fail
        let buy_amount      = 1000;
        let outcome_token   = b"one";
        prediction_market::buy_outcome_tokens(user_one, market_id, outcome_token, buy_amount);

    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444, user_three = @0x555, treasury = @0x666)]
    #[expected_failure(abort_code = ERROR_POOL_NOT_INITIALIZED, location = prediction_market)]
    public entry fun test_user_cannot_sell_outcome_tokens_if_liquidity_pool_has_not_been_initialized(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
        user_three: &signer,
        treasury: &signer
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);
        
        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // set assertion policy
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one (asserter), user two (disputer), and treasury
        let mint_amount     = 100000000;
        let treasury_addr   = signer::address_of(treasury);
        let user_three_addr = signer::address_of(user_three);
        oracle_token::mint(prediction_market, user_one_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_two_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_three_addr   , mint_amount);
        oracle_token::mint(prediction_market, treasury_addr     , mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = treasury_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // ----------------------------------
        // Initialize Market
        // ----------------------------------

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // should fail
        let sell_amount     = 1000;
        let outcome_token   = b"one";
        prediction_market::sell_outcome_tokens(user_one, market_id, outcome_token, sell_amount);

    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444, user_three = @0x555, treasury = @0x666)]
    #[expected_failure(abort_code = ERROR_INVALID_OUTCOME, location = prediction_market)]
    public entry fun test_user_cannot_buy_outcome_tokens_for_invalid_outcome(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
        user_three: &signer,
        treasury: &signer
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);
        
        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // set assertion policy
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one (asserter), user two (disputer), and treasury
        let mint_amount     = 100000000;
        let treasury_addr   = signer::address_of(treasury);
        let user_three_addr = signer::address_of(user_three);
        oracle_token::mint(prediction_market, user_one_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_two_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_three_addr   , mint_amount);
        oracle_token::mint(prediction_market, treasury_addr     , mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = treasury_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // ----------------------------------
        // Initialize Market
        // ----------------------------------

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // ----------------------------------
        // Initialize Liquidity Pool
        // ----------------------------------

        let initial_liquidity = (100_000 as u128);
        prediction_market::initialize_pool(user_one, market_id, initial_liquidity);

        // should fail
        let buy_amount      = 1000;
        let outcome_token   = b"wrongoutcome";
        prediction_market::buy_outcome_tokens(user_one, market_id, outcome_token, buy_amount);

    }


    #[test(aptos_framework = @0x1, prediction_market=@optimistic_oracle_addr, escalation_manager=@escalation_manager_addr, user_one = @0x333, user_two = @0x444, user_three = @0x555, treasury = @0x666)]
    #[expected_failure(abort_code = ERROR_INVALID_OUTCOME, location = prediction_market)]
    public entry fun test_user_cannot_sell_outcome_tokens_for_invalid_outcome(
        aptos_framework: &signer,
        prediction_market: &signer,
        escalation_manager: &signer,
        user_one: &signer,
        user_two: &signer,
        user_three: &signer,
        treasury: &signer
    )  {

        // setup environment
        let (_prediction_market_addr, user_one_addr, user_two_addr) = prediction_market::setup_test(aptos_framework, prediction_market, user_one, user_two);

        // setup escalation manager
        escalation_manager::setup_test(aptos_framework, escalation_manager, user_one, user_two);
        
        let block_assertion    = false;
        let validate_asserters = false;
        let validate_disputers = false;

        // set assertion policy
        escalation_manager::set_assertion_policy(
            escalation_manager,
            block_assertion,
            validate_asserters,
            validate_disputers
        );

        // setup oracle dapp token
        oracle_token::setup_test(prediction_market);

        // mint some tokens to user one (asserter), user two (disputer), and treasury
        let mint_amount     = 100000000;
        let treasury_addr   = signer::address_of(treasury);
        let user_three_addr = signer::address_of(user_three);
        oracle_token::mint(prediction_market, user_one_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_two_addr     , mint_amount);
        oracle_token::mint(prediction_market, user_three_addr   , mint_amount);
        oracle_token::mint(prediction_market, treasury_addr     , mint_amount);

        // setup admin properties
        let oracle_token_metadata   = oracle_token::metadata();
        let treasury_addr           = treasury_addr;
        let min_liveness            = DEFAULT_MIN_LIVENESS;
        let default_fee             = DEFAULT_FEE;
        let burned_bond_percentage  = DEFAULT_BURNED_BOND_PERCENTAGE;

        // call set_admin_properties
        prediction_market::set_admin_properties(
            prediction_market,
            oracle_token_metadata,
            min_liveness,
            default_fee,
            treasury_addr,
            DEFAULT_SWAP_FEE_PERCENT,
            DEFAULT_MIN_LIQUIDITY_REQUIRED,
            burned_bond_percentage
        );

        // ----------------------------------
        // Initialize Market
        // ----------------------------------

        // init market params
        let outcome_one             = b"Outcome One";
        let outcome_two             = b"Outcome Two";
        let description             = b"Test Initialize Market";
        let image_url               = b"Image URL of Market";
        let reward                  = 0; 
        let required_bond           = 100_000;

        // get next market id
        let market_id = prediction_market::get_next_market_id();

        // call initialize_market
        prediction_market::initialize_market(
            user_one,
            outcome_one,
            outcome_two,
            description,
            image_url,
            reward,
            required_bond,
            b""
        );

        // ----------------------------------
        // Initialize Liquidity Pool
        // ----------------------------------

        let initial_liquidity = (100_000 as u128);
        prediction_market::initialize_pool(user_one, market_id, initial_liquidity);

        // should fail
        let sell_amount      = 1000;
        let outcome_token   = b"wrongoutcome";
        prediction_market::sell_outcome_tokens(user_one, market_id, outcome_token, sell_amount);

    }
    
}