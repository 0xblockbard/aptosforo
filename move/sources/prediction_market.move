/*
* Extension of optimistic oracle for prediction markets
*/

module optimistic_oracle_addr::prediction_market {

    use optimistic_oracle_addr::escalation_manager;

    use std::bcs;
    use std::signer;
    use std::event;
    use std::vector;
    use std::timestamp; 
    use std::string::{utf8};
    use std::option::{Self, Option};
    
    use aptos_std::aptos_hash;
    use aptos_std::smart_table::{Self, SmartTable};

    use aptos_framework::primary_fungible_store;
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::fungible_asset::{Self, MintRef, TransferRef, BurnRef, Metadata};

    // -----------------------------------
    // Seeds
    // -----------------------------------

    const APP_OBJECT_SEED: vector<u8> = b"PREDICTION_MARKET";

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

    const NUMERICAL_TRUE: u8                          = 1; // Numerical representation of true

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
        image_url: vector<u8>,               // Description of the market.

        categories: vector<u8>,             // comma-separated categories
        start_timestamp: u64,               // timestamp of when market was created

        outcome_token_one_metadata: Object<Metadata>, // simple move token representing the value of the first outcome.
        outcome_token_two_metadata: Object<Metadata>, // simple move token representing the value of the second outcome.

        outcome_token_one_address: address,
        outcome_token_two_address: address,
        
        pool_initialized: bool,
        pool_initializer: option::Option<address>
    }

    /// Markets Struct
    struct Markets has key, store {
        market_table: SmartTable<u64, Market> // Maps marketId to Market struct.
    }

    /// Asserted Market Struct
    struct AssertedMarket has key, store, drop {
        asserter: address,      // Address of the asserter used for reward payout.
        market_id: u64          // Identifier for markets mapping.
    }

    /// AssertedMarkets Struct
    struct AssertedMarkets has key, store {
        assertion_to_market: SmartTable<u64, AssertedMarket> // Maps assertion id to AssertedMarket
    }

    /// MarketRegistry Struct
    struct MarketRegistry has key, store {
        market_to_creator: SmartTable<u64, address>, // Maps market id to creator
        next_market_id: u64
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
        assertions: SmartTable<u64, Assertion> // assertion_id: u64
    }

    struct AssertionRegistry has key, store {
        assertion_to_asserter: SmartTable<u64, address>,
        next_assertion_id: u64
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
        swap_fee_percent: u128,
        min_liquidity_required: u128,
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

    // ------------------
    // Assertion Events
    // ------------------

    #[event]
    struct AssertionMadeEvent has drop, store {
        assertion_id: u64,
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
        assertion_id: u64,
        disputer: address
    }

    #[event]
    struct AssertionSettledEvent has drop, store {
        assertion_id: u64,
        bond_recipient: address,
        disputed: bool,
        settlement_resolution: bool,
        settle_caller: address
    }

    // ------------------
    // Market Events
    // ------------------

    #[event]
    struct MarketInitializedEvent has drop, store {
        creator: address,
        market_id: u64,
        outcome_one: vector<u8>,
        outcome_two: vector<u8>,
        description: vector<u8>,
        image_url: vector<u8>,
        reward: u64,
        required_bond: u64,

        outcome_token_one_metadata: Object<Metadata>,
        outcome_token_two_metadata: Object<Metadata>,

        outcome_token_one_address: address,
        outcome_token_two_address: address,
    }

    #[event]
    struct MarketAssertedEvent has drop, store {
        market_id: u64,
        asserted_outcome: vector<u8>,
        assertion_id: u64
    }

    #[event]
    struct MarketResolvedEvent has drop, store {
        market_id: u64
    }

    // ------------------
    // Liquidity Pool Events
    // ------------------

    #[event]
    struct PoolInitializedEvent has drop, store {
        initializer: address,
        market_id: u64,
        collateral_amount: u64
    }

    #[event]
    struct DepositLiquidityEvent has drop, store {
        user: address,
        market_id: u64,
        amount: u64,
        lp_tokens_minted: u64
    }

    #[event]
    struct WithdrawLiquidityEvent has drop, store {
        user: address,
        market_id: u64,
        lp_token_amount: u64,
        collateral_amount: u64
    }

    // ------------------
    // Outcome Token Events
    // ------------------

    #[event]
    struct BuyOutcomeTokensEvent has drop, store {
        user: address,
        market_id: u64,
        outcome_token: vector<u8>,
        collateral_amount: u64,     // currency token used 
        outcome_token_amount: u64   // outcome tokens minted
    }

    #[event]
    struct SellOutcomeTokensEvent has drop, store {
        user: address,
        market_id: u64,
        outcome_token: vector<u8>,
        collateral_amount: u64,     // currency token received
        outcome_token_amount: u64   // outcome tokens burned (registered on pool)
    }

    #[event]
    struct RedeemLpTokensEvent has drop, store {
        user: address,
        market_id: u64,
        lp_amount_redeemed: u64,
        outcome_token_one_amount: u64,
        outcome_token_two_amount: u64,
    }

    #[event]
    struct TokensSettledEvent has drop, store {
        market_id: u64,
        account: address,
        payout: u64,
        outcome_one_tokens: u64,
        outcome_two_tokens: u64
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
            swap_fee_percent        : DEFAULT_SWAP_FEE_PERCENT,
            min_liquidity_required  : DEFAULT_MIN_LIQUIDITY_REQUIRED,
            currency_metadata       : option::none()
        });

        // init AssertionRegistry struct
        move_to(oracle_signer, AssertionRegistry {
            assertion_to_asserter: smart_table::new(),
            next_assertion_id: 0
        });

        // init MarketRegistry struct
        move_to(oracle_signer, MarketRegistry {
            market_to_creator: smart_table::new(),
            next_market_id: 0
        });

        // init AssertedMarkets struct
        move_to(oracle_signer, AssertedMarkets {
            assertion_to_market: smart_table::new(),
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
        swap_fee_percent: u128,
        min_liquidity_required: u128,
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
        admin_properties.swap_fee_percent         = swap_fee_percent;
        admin_properties.min_liquidity_required   = min_liquidity_required;
        admin_properties.currency_metadata        = option::some(currency_metadata);

    }

    // ---------------
    // General functions
    // ---------------

    public entry fun initialize_market(
        creator: &signer,
        outcome_one: vector<u8>, // Short name of the first outcome.
        outcome_two: vector<u8>, // Short name of the second outcome.
        description: vector<u8>, // Description of the market.
        image_url: vector<u8>,   // Image of the market.
        reward: u64,             // Reward available for asserting true market outcome.
        required_bond: u64,      // Expected bond to assert market outcome (OOv3 can require higher bond).
        categories: vector<u8>   // optional categories of market
    ) acquires Markets, MarketRegistry, OracleSigner, AdminProperties {

        let oracle_signer_addr  = get_oracle_signer_addr();
        let oracle_signer       = get_oracle_signer(oracle_signer_addr);
        let market_registry     = borrow_global_mut<MarketRegistry>(oracle_signer_addr);
        let admin_properties    = borrow_global<AdminProperties>(oracle_signer_addr);
        let creator_address     = signer::address_of(creator);

        // check if creator has Markets struct
        if (!exists<Markets>(creator_address)) {
            move_to(creator, Markets {
                market_table: smart_table::new(),
            });
        };
        let markets = borrow_global_mut<Markets>(creator_address);

        assert!(vector::length(&outcome_one) > 0, ERROR_EMPTY_FIRST_OUTCOME);
        assert!(vector::length(&outcome_two) > 0, ERROR_EMPTY_SECOND_OUTCOME);
        assert!(aptos_hash::keccak256(outcome_one) != aptos_hash::keccak256(outcome_two), ERROR_OUTCOMES_ARE_THE_SAME);
        assert!(vector::length(&description) > 0, ERROR_EMPTY_DESCRIPTION);
        
        let current_timestamp = timestamp::now_microseconds();
        let time_bytes        = bcs::to_bytes<u64>(&current_timestamp);
        
        // refactor to use numbers for market id for easier fetching on the frontend
        let market_id                  = market_registry.next_market_id;
        market_registry.next_market_id = market_registry.next_market_id + 1;

        // Generate Outcome tokens

        let market_id_bytes = bcs::to_bytes<u64>(&market_id);

        // For Outcome One Symbol
        let outcome_token_one_symbol = vector::empty<u8>();
        vector::append(&mut outcome_token_one_symbol, time_bytes);
        vector::append(&mut outcome_token_one_symbol, outcome_one);
        vector::append(&mut outcome_token_one_symbol, market_id_bytes);

        // Outcome Two Symbol
        let outcome_token_two_symbol = vector::empty<u8>();
        vector::append(&mut outcome_token_two_symbol, time_bytes);
        vector::append(&mut outcome_token_two_symbol, outcome_two);
        vector::append(&mut outcome_token_two_symbol, market_id_bytes);
        
        let outcome_token_one_constructor_ref = object::create_named_object(&oracle_signer, outcome_token_one_symbol);
        let outcome_token_two_constructor_ref = object::create_named_object(&oracle_signer, outcome_token_two_symbol);

        // Outcome One Token
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &outcome_token_one_constructor_ref,
            option::none(),
            utf8(b"Outcome One"),
            utf8(b"ONE"),
            8,
            utf8(DEFAULT_OUTCOME_TOKEN_ICON),
            utf8(DEFAULT_OUTCOME_TOKEN_WEBSITE),
        );

        // Outcome Two Token
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &outcome_token_two_constructor_ref,
            option::none(),
            utf8(b"Outcome Two"),
            utf8(b"TWO"),
            8,
            utf8(DEFAULT_OUTCOME_TOKEN_ICON),
            utf8(DEFAULT_OUTCOME_TOKEN_WEBSITE),
        );

        // Generate signers for outcome tokens
        let outcome_one_token_metadata_signer = object::generate_signer(&outcome_token_one_constructor_ref);
        let outcome_two_token_metadata_signer = object::generate_signer(&outcome_token_two_constructor_ref);

        // For Outcome One Token
        move_to(&outcome_one_token_metadata_signer,
            Management {
                extend_ref: object::generate_extend_ref(&outcome_token_one_constructor_ref),
                mint_ref: fungible_asset::generate_mint_ref(&outcome_token_one_constructor_ref),
                burn_ref: fungible_asset::generate_burn_ref(&outcome_token_one_constructor_ref),
                transfer_ref: fungible_asset::generate_transfer_ref(&outcome_token_one_constructor_ref),
            },
        );

        // For Outcome Two Token
        move_to(&outcome_two_token_metadata_signer,
            Management {
                extend_ref: object::generate_extend_ref(&outcome_token_two_constructor_ref),
                mint_ref: fungible_asset::generate_mint_ref(&outcome_token_two_constructor_ref),
                burn_ref: fungible_asset::generate_burn_ref(&outcome_token_two_constructor_ref),
                transfer_ref: fungible_asset::generate_transfer_ref(&outcome_token_two_constructor_ref),
            },
        );

        let outcome_token_one_address = signer::address_of(&outcome_one_token_metadata_signer);
        let outcome_token_two_address = signer::address_of(&outcome_two_token_metadata_signer);

        let outcome_token_one_metadata = object::address_to_object(outcome_token_one_address);
        let outcome_token_two_metadata = object::address_to_object(outcome_token_two_address);

        // create Market struct
        let market = Market {
            creator: signer::address_of(creator),
            resolved: false,          
            asserted_outcome_id: vector::empty<u8>(),

            reward,
            required_bond,
            outcome_one,            
            outcome_two,            
            description,
            image_url,

            categories,
            start_timestamp: timestamp::now_microseconds(),

            outcome_token_one_metadata,
            outcome_token_two_metadata,
            outcome_token_one_address,
            outcome_token_two_address,

            pool_initialized: false,
            pool_initializer: option::none()
        };

        // update creator markets
        smart_table::add(&mut markets.market_table, market_id, market);

        // update market registry
        smart_table::add(&mut market_registry.market_to_creator, market_id, creator_address);

        // transfer oracle token reward 
        if(reward > 0){
            let currency_metadata = option::destroy_some(admin_properties.currency_metadata);
            primary_fungible_store::transfer(creator, currency_metadata, oracle_signer_addr, reward);
        };

        // emit event for market initialized
        event::emit(MarketInitializedEvent {
            creator: signer::address_of(creator),
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
        });

    }


    // Assert the market with any of 3 possible outcomes: names of outcome1, outcome2 or unresolvable.
    public entry fun assert_market(
        asserter: &signer,
        market_id: u64,
        asserted_outcome: vector<u8>
    ) acquires Markets, MarketRegistry, AssertedMarkets, AdminProperties, AssertionTable, AssertionRegistry {

        let oracle_signer_addr  = get_oracle_signer_addr();
        let asserted_markets    = borrow_global_mut<AssertedMarkets>(oracle_signer_addr);
        let admin_properties    = borrow_global<AdminProperties>(oracle_signer_addr);
        let market_registry     = borrow_global<MarketRegistry>(oracle_signer_addr);

        // get creator address from registry (and verify market id exists)
        let creator_address     = *smart_table::borrow(&market_registry.market_to_creator, market_id);
        
        // find market by id
        let markets             = borrow_global_mut<Markets>(creator_address);
        let market              = smart_table::borrow_mut(&mut markets.market_table, market_id);

        let asserted_outcome_id = aptos_hash::keccak256(asserted_outcome);

        // verify that market assertion is still active and has not been resolved
        assert!(vector::length<u8>(&market.asserted_outcome_id) == 0, ERROR_ASSERTION_ACTIVE_OR_RESOLVED);

        assert!(
            asserted_outcome_id == aptos_hash::keccak256(market.outcome_one) || 
            asserted_outcome_id == aptos_hash::keccak256(market.outcome_two) ||
            asserted_outcome_id == aptos_hash::keccak256(UNRESOLVABLE),
            ERROR_INVALID_ASSERTED_OUTCOME
        );

        // set asserted outcome id
        market.asserted_outcome_id = asserted_outcome_id;

        let minimum_bond = (admin_properties.default_fee * 10000) / admin_properties.burned_bond_percentage;
        let bond;
        if(market.required_bond > minimum_bond){
            bond =  market.required_bond;
        } else {
            bond = minimum_bond;
        };

        let claim = compose_claim(asserted_outcome, market.description);

        // get assertion id - note: bond will be transferred internally
        let assertion_id = assert_truth_with_defaults(asserter, claim, bond);

        // set asserted market
        let asserted_market = AssertedMarket {
            asserter: signer::address_of(asserter),
            market_id
        };

        // update asserted markets
        smart_table::add(&mut asserted_markets.assertion_to_market, assertion_id, asserted_market);

        // emit event for market asserted
        event::emit(MarketAssertedEvent {
            market_id,
            asserted_outcome,
            assertion_id
        });

    }


    /**
     * @notice Asserts a truth about the world, using a custom configuration.
     * @dev The caller must approve this contract to spend at least bond amount of currency.
     * @param claim the truth claim being asserted. This is an assertion about the world, and is verified by disputers.
     * @param asserter account that receives bonds back at settlement. This could be msg.sender or
     * any other account that the caller wants to receive the bond at settlement time.
     * @param currency bond currency pulled from the caller and held in escrow until the assertion is resolved.
     * @param bond amount of currency to pull from the caller and hold in escrow until the assertion is resolved. This
     * must be >= getMinimumBond(address(currency)).
     * @return assertionId unique identifier for this assertion.
     */
     fun assert_truth_with_defaults(
        asserter: &signer,
        claim: vector<u8>,
        bond: u64,
    ) : u64 acquires AdminProperties, AssertionTable, AssertionRegistry {

        let oracle_signer_addr  = get_oracle_signer_addr();
        let assertion_registry  = borrow_global_mut<AssertionRegistry>(oracle_signer_addr);
        let admin_properties    = borrow_global<AdminProperties>(oracle_signer_addr);
        let asserter_addr       = signer::address_of(asserter);

        // check if creator has assertion table
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
                // if require asserters to be whitelisted 
                let whitelistedBool     = escalation_manager::is_assert_allowed(signer::address_of(asserter));
                assert!(whitelistedBool, ERROR_NOT_WHITELISTED_ASSERTER);
            };
        };

        // set defaults
        let liveness   = DEFAULT_MIN_LIVENESS;
        let identifier = DEFAULT_IDENTIFIER;

        // refactor assertion id to u64 for convenience to fetch on frontend
        let assertion_id = assertion_registry.next_assertion_id;
         assertion_registry.next_assertion_id =  assertion_registry.next_assertion_id + 1;
        
        // note: some old mechanics from previous optimistic oracle implementation for reference
        // --------------------------------------------------------------------
        // - refactored to use next_assertion_id instead
        // set unique assertion id based on input
        // let current_timestamp = timestamp::now_microseconds();
        // let assertion_id = get_assertion_id(
        //     asserter_addr,
        //     claim, 
        //     current_timestamp,
        //     bond,
        //     liveness,
        //     identifier
        // );

        // verify assertion does not exist - not needed anymore as we have ERROR_ASSERTION_ACTIVE_OR_RESOLVED
        // if (smart_table::contains(&assertions_table.assertions, assertion_id)) {
        //     abort ERROR_ASSERTION_ALREADY_EXISTS
        // };

        // verify bond is greater than minimum bond - not needed anymore as minimum bond is set in assert_market
        // let minimum_bond = (admin_properties.default_fee * 10000) / admin_properties.burned_bond_percentage;
        // assert!(bond >= minimum_bond, ERROR_MINIMUM_BOND_NOT_REACHED);

        // verify liveness is greater than minimum liveness - not needed anymore as default min liveness is used
        // assert!(liveness >= admin_properties.min_liveness, ERROR_MINIMUM_LIVENESS_NOT_REACHED);

        let current_timestamp = timestamp::now_microseconds();
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

        assertion_id 
    }


    /**
     * @notice Disputes an assertion. We follow a centralised model for dispute resolution where only whitelisted 
     * disputers can resolve the dispute.
     * @param assertionId unique identifier for the assertion to dispute.
     * @param disputer to transfer bond for making a dispute and will receive bonds back at settlement.
     */
    public entry fun dispute_assertion(
        disputer : &signer,
        assertion_id : u64,
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

        // if require dispute callers to be whitelisted 
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
        assertion_id: u64
    ) acquires Markets, MarketRegistry, AssertedMarkets, AssertionTable, AssertionRegistry, OracleSigner, AdminProperties {

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

        // If the assertion was resolved true, then the asserter gets the reward and the market is marked as resolved.
        // Otherwise, asserted_outcome_id is reset and the market can be asserted again.

        let asserted_markets    = borrow_global_mut<AssertedMarkets>(oracle_signer_addr);
        let market_registry     = borrow_global<MarketRegistry>(oracle_signer_addr);

        let asserted_market     = smart_table::remove(&mut asserted_markets.assertion_to_market, assertion_id);
        let market_id           = asserted_market.market_id;

        // get creator of market_id from market registry
        let creator_address     = *smart_table::borrow(&market_registry.market_to_creator, market_id);
        
        // find market by id
        let markets             = borrow_global_mut<Markets>(creator_address);
        let market              = smart_table::borrow_mut(&mut markets.market_table, market_id);

        // assertion resolved as true
        if(assertion.settlement_resolution == true){

            // mark market resolve as true
            market.resolved = true;

            // transfer market rewards to asserter
            if(market.reward > 0){
                let currency_metadata = option::destroy_some(admin_properties.currency_metadata);
                primary_fungible_store::transfer(&oracle_signer, currency_metadata, asserted_market.asserter, market.reward);
            };

            // emit event for market resolved
            event::emit(MarketResolvedEvent {
                market_id
            });

        } else {
            // reset market asserted outcome id if assertion not resolved truthfully
            market.asserted_outcome_id = vector::empty<u8>(); 
        };

    }


    public entry fun initialize_pool(
        initializer: &signer,
        market_id: u64,
        collateral_amount: u128
    ) acquires LiquidityPools, Markets, MarketRegistry, OracleSigner, AdminProperties {
        
        let oracle_signer_addr  = get_oracle_signer_addr();
        let oracle_signer       = get_oracle_signer(oracle_signer_addr);
        let admin_properties    = borrow_global<AdminProperties>(oracle_signer_addr);
        let initializer_addr    = signer::address_of(initializer);

        // check if initializer has LiquidityPools struct
        if (!exists<LiquidityPools>(initializer_addr)) {
            move_to(initializer, LiquidityPools {
                pools: smart_table::new(),
            });
        };
        let liquidity_pools = borrow_global_mut<LiquidityPools>(initializer_addr);

        // get the market
        let market_registry     = borrow_global<MarketRegistry>(oracle_signer_addr);
        let creator_address     = *smart_table::borrow(&market_registry.market_to_creator, market_id);
        let markets             = borrow_global_mut<Markets>(creator_address);
        let market              = smart_table::borrow_mut(&mut markets.market_table, market_id);

        // check that the market has not been resolved
        assert!(market.resolved == false, ERROR_MARKET_HAS_BEEN_RESOLVED);

        // check that the pool has not been initialized already, update market info pool initializer
        assert!(market.pool_initialized == false, ERROR_POOL_ALREADY_INITIALIZED);
        market.pool_initializer = option::some(initializer_addr);
        market.pool_initialized = true;

        // create LP Token
        let lp_token_symbol: vector<u8> = b"LP Token";
        let lp_token_constructor_ref = object::create_named_object(&oracle_signer, lp_token_symbol);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &lp_token_constructor_ref,
            option::none(),
            utf8(b"LP Token"),
            utf8(b"LP"),
            8,
            utf8(b"http://example.com/favicon.ico"),
            utf8(b"http://example.com"),
        );
        let lp_token_metadata_signer = object::generate_signer(&lp_token_constructor_ref);

        // For LP Token
        // let mint_ref     = fungible_asset::generate_mint_ref(&lp_token_constructor_ref);
        // let transfer_ref = fungible_asset::generate_transfer_ref(&lp_token_constructor_ref);
        move_to(&lp_token_metadata_signer,
            Management {
                extend_ref: object::generate_extend_ref(&lp_token_constructor_ref),
                mint_ref: fungible_asset::generate_mint_ref(&lp_token_constructor_ref),
                burn_ref: fungible_asset::generate_burn_ref(&lp_token_constructor_ref),
                transfer_ref: fungible_asset::generate_transfer_ref(&lp_token_constructor_ref),
            },
        );
        let lp_token_address  = signer::address_of(&lp_token_metadata_signer);
        let lp_token_metadata = object::address_to_object(lp_token_address);

        // fixed point math
        let half_collateral_amount = ((collateral_amount * FIXED_POINT_ACCURACY) / 2) / FIXED_POINT_ACCURACY;

        // create LiquidityPool struct
        let pool = LiquidityPool {
            market_id,
            initializer: initializer_addr,

            outcome_token_one_reserve: half_collateral_amount,
            outcome_token_two_reserve: half_collateral_amount,

            lp_total_supply: half_collateral_amount,
            lp_token_metadata,
            lp_token_address
        };

        // update liquidity pools
        smart_table::add(&mut liquidity_pools.pools, market_id, pool);

        // calculate if min liquidity reached
        assert!(collateral_amount >= admin_properties.min_liquidity_required, ERROR_DEFAULT_MIN_LIQUIDITY_NOT_REACHED);

        // transfer currency collateral tokens (i.e. oracle tokens) from initializer to module
        let currency_metadata = option::destroy_some(admin_properties.currency_metadata);
        primary_fungible_store::transfer(initializer, currency_metadata, oracle_signer_addr, (collateral_amount as u64));

        // Mint LP Token to initializer
        let initializer_wallet = primary_fungible_store::ensure_primary_store_exists(initializer_addr, lp_token_metadata);
        let fa = fungible_asset::mint(&fungible_asset::generate_mint_ref(&lp_token_constructor_ref), (half_collateral_amount as u64));
        fungible_asset::deposit_with_ref(&fungible_asset::generate_transfer_ref(&lp_token_constructor_ref), initializer_wallet, fa);

        // emit event for pool initialized
        event::emit(PoolInitializedEvent {
            initializer: initializer_addr,
            market_id,
            collateral_amount: (collateral_amount as u64)
        });

    }


    public entry fun deposit_liquidity(
        user: &signer,
        market_id: u64,
        amount: u128
    ) acquires LiquidityPools, Markets, MarketRegistry, Management, AdminProperties {
        
        let oracle_signer_addr  = get_oracle_signer_addr();
        let admin_properties    = borrow_global<AdminProperties>(oracle_signer_addr);
        let user_addr           = signer::address_of(user);

        // get the market
        let market_registry     = borrow_global<MarketRegistry>(oracle_signer_addr);
        let creator_address     = *smart_table::borrow(&market_registry.market_to_creator, market_id);
        let markets             = borrow_global_mut<Markets>(creator_address);
        let market              = smart_table::borrow_mut(&mut markets.market_table, market_id);

        // check that the market has not been resolved
        assert!(market.resolved == false, ERROR_MARKET_HAS_BEEN_RESOLVED);

        // check that the pool has been initialized already
        assert!(market.pool_initialized == true, ERROR_POOL_NOT_INITIALIZED);
        
        // get liquidity pool info
        let initializer_addr    = option::destroy_some(market.pool_initializer);
        let liquidity_pools     = borrow_global_mut<LiquidityPools>(initializer_addr);
        let liquidity_pool      = smart_table::borrow_mut(&mut liquidity_pools.pools, market_id);

        // get lp token metadata
        let lp_token_metadata       = liquidity_pool.lp_token_metadata;
        let lp_token_mint_ref       = &borrow_global<Management>(liquidity_pool.lp_token_address).mint_ref;
        let lp_token_transfer_ref   = &borrow_global<Management>(liquidity_pool.lp_token_address).transfer_ref;

        // calculate lp tokens to mint
        let collateral_token_reserve = liquidity_pool.outcome_token_one_reserve + liquidity_pool.outcome_token_two_reserve;
        let lp_tokens_to_mint        = (((amount * liquidity_pool.lp_total_supply * FIXED_POINT_ACCURACY)) / collateral_token_reserve) / FIXED_POINT_ACCURACY;

        // calculate proportional amount to increase for each outcome token 
        let outcome_token_one_reserve_proportion = ((liquidity_pool.outcome_token_one_reserve * FIXED_POINT_ACCURACY) / collateral_token_reserve);
        let outcome_token_one_increase           = (outcome_token_one_reserve_proportion * amount) / FIXED_POINT_ACCURACY;
        let outcome_token_two_increase           = amount - outcome_token_one_increase;

        // register increases in liquidity pool
        liquidity_pool.outcome_token_one_reserve = liquidity_pool.outcome_token_one_reserve + outcome_token_one_increase;
        liquidity_pool.outcome_token_two_reserve = liquidity_pool.outcome_token_two_reserve + outcome_token_two_increase;
        liquidity_pool.lp_total_supply           = liquidity_pool.lp_total_supply + lp_tokens_to_mint;

        // transfer currency collateral tokens (i.e. oracle tokens) from minter to module
        let currency_metadata = option::destroy_some(admin_properties.currency_metadata);
        primary_fungible_store::transfer(user, currency_metadata, oracle_signer_addr, (amount as u64));

        // Mint LP Token to LP 
        let user_wallet = primary_fungible_store::ensure_primary_store_exists(user_addr, lp_token_metadata);
        let fa = fungible_asset::mint(lp_token_mint_ref, (lp_tokens_to_mint as u64));
        fungible_asset::deposit_with_ref(lp_token_transfer_ref, user_wallet, fa);

        // emit event for deposit liquidity
        event::emit(DepositLiquidityEvent {
            user: user_addr,
            market_id,
            amount: (amount as u64),
            lp_tokens_minted: (lp_tokens_to_mint as u64)
        });

    }


    public entry fun withdraw_liquidity(
        user: &signer,
        market_id: u64,
        lp_token_amount: u64
    ) acquires LiquidityPools, Markets, MarketRegistry, Management, AdminProperties, OracleSigner {
        
        let oracle_signer_addr  = get_oracle_signer_addr();
        let oracle_signer       = get_oracle_signer(oracle_signer_addr);
        let admin_properties    = borrow_global<AdminProperties>(oracle_signer_addr);
        let user_addr           = signer::address_of(user);

        // get the market
        let market_registry     = borrow_global<MarketRegistry>(oracle_signer_addr);
        let creator_address     = *smart_table::borrow(&market_registry.market_to_creator, market_id);
        let markets             = borrow_global_mut<Markets>(creator_address);
        let market              = smart_table::borrow_mut(&mut markets.market_table, market_id);

        // check that the market has not been resolved
        assert!(market.resolved == false, ERROR_MARKET_HAS_BEEN_RESOLVED);

        // check that the pool has been initialized already
        assert!(market.pool_initialized == true, ERROR_POOL_NOT_INITIALIZED);
        
        let initializer_addr    = option::destroy_some(market.pool_initializer);
        let liquidity_pools     = borrow_global_mut<LiquidityPools>(initializer_addr);
        let liquidity_pool      = smart_table::borrow_mut(&mut liquidity_pools.pools, market_id);

        // get lp token metadata
        let lp_token_metadata   = liquidity_pool.lp_token_metadata;
        let lp_token_burn_ref   = &borrow_global<Management>(liquidity_pool.lp_token_address).burn_ref;

        // calculate proportion of LP and outcome tokens
        let lp_proportion                     = ((lp_token_amount as u128) * FIXED_POINT_ACCURACY) / liquidity_pool.lp_total_supply;
        let outcome_token_one_withdraw_amount = (liquidity_pool.outcome_token_one_reserve * lp_proportion) / FIXED_POINT_ACCURACY;
        let outcome_token_two_withdraw_amount = (liquidity_pool.outcome_token_two_reserve * lp_proportion) / FIXED_POINT_ACCURACY;

        // update liquidity pool
        liquidity_pool.outcome_token_one_reserve = liquidity_pool.outcome_token_one_reserve - outcome_token_one_withdraw_amount;
        liquidity_pool.outcome_token_two_reserve = liquidity_pool.outcome_token_two_reserve - outcome_token_two_withdraw_amount;
        liquidity_pool.lp_total_supply           = liquidity_pool.lp_total_supply - (lp_token_amount as u128);

        // burn user LP tokens
        let user_lp_fa = primary_fungible_store::withdraw(user, lp_token_metadata, lp_token_amount);
        fungible_asset::burn(lp_token_burn_ref, user_lp_fa);

        // transfer collateral tokens back to the user
        let collateral_amount = outcome_token_one_withdraw_amount + outcome_token_two_withdraw_amount;
        let currency_metadata = option::destroy_some(admin_properties.currency_metadata);
        primary_fungible_store::transfer(&oracle_signer, currency_metadata, user_addr, (collateral_amount as u64));

        // emit event for withdraw liquidity
        event::emit(WithdrawLiquidityEvent {
            user: user_addr,
            market_id,
            lp_token_amount,
            collateral_amount: (collateral_amount as u64)
        });

    }


    public entry fun buy_outcome_tokens(
        user: &signer,
        market_id: u64,
        outcome_token: vector<u8>,
        amount: u128
    ) acquires LiquidityPools, Markets, MarketRegistry, Management, AdminProperties {
        
        let oracle_signer_addr  = get_oracle_signer_addr();
        let admin_properties    = borrow_global<AdminProperties>(oracle_signer_addr);
        let user_addr           = signer::address_of(user);

        // get the market
        let market_registry     = borrow_global<MarketRegistry>(oracle_signer_addr);
        let creator_address     = *smart_table::borrow(&market_registry.market_to_creator, market_id);
        let markets             = borrow_global_mut<Markets>(creator_address);
        let market              = smart_table::borrow_mut(&mut markets.market_table, market_id);

        // check that the market has not been resolved
        assert!(market.resolved == false, ERROR_MARKET_HAS_BEEN_RESOLVED);

        // check that the pool has been initialized already
        assert!(market.pool_initialized == true, ERROR_POOL_NOT_INITIALIZED);
        
        let initializer_addr    = option::destroy_some(market.pool_initializer);
        let liquidity_pools     = borrow_global_mut<LiquidityPools>(initializer_addr);
        let liquidity_pool      = smart_table::borrow_mut(&mut liquidity_pools.pools, market_id);

        assert!(outcome_token == b"one" || outcome_token == b"two", ERROR_INVALID_OUTCOME);

        // get total pool reserves
        let total_pool_reserves = liquidity_pool.outcome_token_one_reserve + liquidity_pool.outcome_token_two_reserve;

        // calculate amount less fees (liquidity provider incentives)
        let amount_less_fees = (amount * (1000 - admin_properties.swap_fee_percent)) / 1000;

        let (token_metadata, token_reserve, token_address) = 
        if(outcome_token == b"one"){
            (market.outcome_token_one_metadata, liquidity_pool.outcome_token_one_reserve, market.outcome_token_one_address)
        } else {
            (market.outcome_token_two_metadata, liquidity_pool.outcome_token_two_reserve, market.outcome_token_two_address)
        };

        // calculate amount to mint
        let token_amount_mint   = (((amount_less_fees * token_reserve * FIXED_POINT_ACCURACY) / total_pool_reserves) / FIXED_POINT_ACCURACY);

        // Get the management resource for the outcome token
        let mint_ref     = &borrow_global<Management>(token_address).mint_ref;
        let transfer_ref = &borrow_global<Management>(token_address).transfer_ref;

        // Ensure the user's wallet is ready to receive the minted tokens
        let minter_wallet = primary_fungible_store::ensure_primary_store_exists(user_addr, token_metadata);
        let fa = fungible_asset::mint(mint_ref, (token_amount_mint as u64));
        fungible_asset::deposit_with_ref(transfer_ref, minter_wallet, fa);

        // Update the liquidity pool reserves
        if(outcome_token == b"one"){
            liquidity_pool.outcome_token_one_reserve = liquidity_pool.outcome_token_one_reserve + amount;
        } else {
            liquidity_pool.outcome_token_two_reserve = liquidity_pool.outcome_token_two_reserve + amount;
        };

        // transfer currency tokens (i.e. oracle tokens) from user to module
        let currency_metadata = option::destroy_some(admin_properties.currency_metadata);
        primary_fungible_store::transfer(user, currency_metadata, oracle_signer_addr, (amount as u64));

        // emit event for buy outcome tokens
        event::emit(BuyOutcomeTokensEvent {
            user: user_addr,
            market_id,
            outcome_token,
            collateral_amount: (amount as u64),
            outcome_token_amount: (token_amount_mint as u64)
        });

    }


    public entry fun sell_outcome_tokens(
        user: &signer,
        market_id: u64,
        outcome_token: vector<u8>,
        amount: u128
    ) acquires LiquidityPools, Markets, MarketRegistry, Management, OracleSigner, AdminProperties {
        
        let oracle_signer_addr  = get_oracle_signer_addr();
        let oracle_signer       = get_oracle_signer(oracle_signer_addr);
        let admin_properties    = borrow_global<AdminProperties>(oracle_signer_addr);
        let user_addr           = signer::address_of(user);

        // get the market
        let market_registry     = borrow_global<MarketRegistry>(oracle_signer_addr);
        let creator_address     = *smart_table::borrow(&market_registry.market_to_creator, market_id);
        let markets             = borrow_global_mut<Markets>(creator_address);
        let market              = smart_table::borrow_mut(&mut markets.market_table, market_id);

        // check that the market has not been resolved
        assert!(market.resolved == false, ERROR_MARKET_HAS_BEEN_RESOLVED);

        // check that the pool has been initialized already
        assert!(market.pool_initialized == true, ERROR_POOL_NOT_INITIALIZED);
        
        let initializer_addr    = option::destroy_some(market.pool_initializer);
        let liquidity_pools     = borrow_global_mut<LiquidityPools>(initializer_addr);
        let liquidity_pool      = smart_table::borrow_mut(&mut liquidity_pools.pools, market_id);

        assert!(outcome_token == b"one" || outcome_token == b"two", ERROR_INVALID_OUTCOME);

        // get total pool reserves
        let total_pool_reserves = liquidity_pool.outcome_token_one_reserve + liquidity_pool.outcome_token_two_reserve;

        // calculate amount less fees (liquidity provider incentives)
        let amount_less_fees = (amount * (1000 - admin_properties.swap_fee_percent)) / 1000;

        let (token_metadata, token_reserve, token_address) = 
        if(outcome_token == b"one"){
            (market.outcome_token_one_metadata, liquidity_pool.outcome_token_one_reserve, market.outcome_token_one_address)
        } else {
            (market.outcome_token_two_metadata, liquidity_pool.outcome_token_two_reserve, market.outcome_token_two_address)
        };

        // calculate amount of collateral token to transfer back 
        let collateral_token_amount = (((amount_less_fees * total_pool_reserves * FIXED_POINT_ACCURACY) / token_reserve) / FIXED_POINT_ACCURACY);

        // Get the burn ref for the outcome token
        let token_burn_ref = &borrow_global<Management>(token_address).burn_ref;
        
        // Burn outcome token
        let token_fa = primary_fungible_store::withdraw(user, token_metadata, (amount as u64));
        fungible_asset::burn(token_burn_ref, token_fa);

        // Update the liquidity pool reserves
        if(outcome_token == b"one"){
            liquidity_pool.outcome_token_one_reserve = liquidity_pool.outcome_token_one_reserve - amount;
        } else {
            liquidity_pool.outcome_token_two_reserve = liquidity_pool.outcome_token_two_reserve - amount;
        };

        // transfer currency tokens (i.e. oracle tokens) from module to user
        let currency_metadata = option::destroy_some(admin_properties.currency_metadata);
        primary_fungible_store::transfer(&oracle_signer, currency_metadata, user_addr, (collateral_token_amount as u64));

        // emit event for sell outcome tokens
        event::emit(SellOutcomeTokensEvent {
            user: user_addr,
            market_id,
            outcome_token,
            collateral_amount: (collateral_token_amount as u64),
            outcome_token_amount: (amount as u64) 
        });

    }


    public entry fun redeem_lp_for_outcome_tokens(
        redeemer: &signer,
        market_id: u64,
        amount: u128
    ) acquires Markets, MarketRegistry, LiquidityPools, Management {

        let oracle_signer_addr     = get_oracle_signer_addr();
        let redeemer_addr          = signer::address_of(redeemer);

        // get the market
        let market_registry     = borrow_global<MarketRegistry>(oracle_signer_addr);
        let creator_address     = *smart_table::borrow(&market_registry.market_to_creator, market_id);
        let markets             = borrow_global_mut<Markets>(creator_address);
        let market              = smart_table::borrow_mut(&mut markets.market_table, market_id);

        // check that the pool has been initialized already
        assert!(market.pool_initialized == true, ERROR_POOL_NOT_INITIALIZED);
        
        let initializer_addr    = option::destroy_some(market.pool_initializer);
        let liquidity_pools     = borrow_global_mut<LiquidityPools>(initializer_addr);
        let liquidity_pool      = smart_table::borrow_mut(&mut liquidity_pools.pools, market_id);

        // Get the management resource for the outcome one token
        let token_one_mint_ref     = &borrow_global<Management>(market.outcome_token_one_address).mint_ref;
        let token_one_transfer_ref = &borrow_global<Management>(market.outcome_token_one_address).transfer_ref;
        let token_one_metadata     = market.outcome_token_one_metadata;

        // Get the management resource for the outcome two token
        let token_two_mint_ref     = &borrow_global<Management>(market.outcome_token_two_address).mint_ref;
        let token_two_transfer_ref = &borrow_global<Management>(market.outcome_token_two_address).transfer_ref;
        let token_two_metadata     = market.outcome_token_two_metadata;

        // get and burn lp token 
        let lp_token_metadata   = liquidity_pool.lp_token_metadata;
        let lp_token_burn_ref   = &borrow_global<Management>(liquidity_pool.lp_token_address).burn_ref;
        let user_lp_fa          = primary_fungible_store::withdraw(redeemer, lp_token_metadata, (amount as u64));
        fungible_asset::burn(lp_token_burn_ref, user_lp_fa);

        let lp_proportion                        = (amount * FIXED_POINT_ACCURACY) / liquidity_pool.lp_total_supply;
        let outcome_token_one_proportion_amount  = ((liquidity_pool.outcome_token_one_reserve * lp_proportion) / FIXED_POINT_ACCURACY);
        let outcome_token_two_proportion_amount  = ((liquidity_pool.outcome_token_two_reserve * lp_proportion) / FIXED_POINT_ACCURACY);

        let outcome_token_one_amount = 0;
        let outcome_token_two_amount = 0;

        // process redemption based on market state
        if(market.resolved == true){

            // only redeem the winning outcome token if market has been resolved
            if(market.asserted_outcome_id == aptos_hash::keccak256(market.outcome_one)){
                // outcome one wins - mint outcome token one to redeemer
                outcome_token_one_amount = outcome_token_one_proportion_amount;

                let minter_token_one_wallet = primary_fungible_store::ensure_primary_store_exists(redeemer_addr, token_one_metadata);
                let fa = fungible_asset::mint(token_one_mint_ref, (outcome_token_one_amount as u64));
                fungible_asset::deposit_with_ref(token_one_transfer_ref, minter_token_one_wallet, fa);

            } else if (market.asserted_outcome_id == aptos_hash::keccak256(market.outcome_two)){
                // outcome two wins - mint outcome token two to redeemer
                outcome_token_two_amount = outcome_token_two_proportion_amount;

                let minter_token_two_wallet = primary_fungible_store::ensure_primary_store_exists(redeemer_addr, token_two_metadata);
                let fa = fungible_asset::mint(token_two_mint_ref, (outcome_token_two_amount as u64));
                fungible_asset::deposit_with_ref(token_two_transfer_ref, minter_token_two_wallet, fa);
                
            } else {
                // unresolved - mint both
                outcome_token_one_amount = outcome_token_one_proportion_amount;
                outcome_token_two_amount = outcome_token_two_proportion_amount;

                let minter_token_one_wallet = primary_fungible_store::ensure_primary_store_exists(redeemer_addr, token_one_metadata);
                let fa = fungible_asset::mint(token_one_mint_ref, (outcome_token_one_amount as u64));
                fungible_asset::deposit_with_ref(token_one_transfer_ref, minter_token_one_wallet, fa);

                let minter_token_two_wallet = primary_fungible_store::ensure_primary_store_exists(redeemer_addr, token_two_metadata);
                let fa = fungible_asset::mint(token_two_mint_ref, (outcome_token_two_amount as u64));
                fungible_asset::deposit_with_ref(token_two_transfer_ref, minter_token_two_wallet, fa);

            };

        } else {

            outcome_token_one_amount = outcome_token_one_proportion_amount;
            outcome_token_two_amount = outcome_token_two_proportion_amount;

            // redeem for both outcome tokens if market has not been resolved yet
            let minter_token_one_wallet = primary_fungible_store::ensure_primary_store_exists(redeemer_addr, token_one_metadata);
            let fa = fungible_asset::mint(token_one_mint_ref, (outcome_token_one_amount as u64));
            fungible_asset::deposit_with_ref(token_one_transfer_ref, minter_token_one_wallet, fa);

            let minter_token_two_wallet = primary_fungible_store::ensure_primary_store_exists(redeemer_addr, token_two_metadata);
            let fa = fungible_asset::mint(token_two_mint_ref, (outcome_token_two_amount as u64));
            fungible_asset::deposit_with_ref(token_two_transfer_ref, minter_token_two_wallet, fa);

        };

        // emit event for redeem LP tokens
        event::emit(RedeemLpTokensEvent {
            user: redeemer_addr,
            market_id,
            lp_amount_redeemed: (amount as u64),
            outcome_token_one_amount: (outcome_token_one_amount as u64),
            outcome_token_two_amount: (outcome_token_two_amount as u64) 
        });

    }


    public entry fun settle_outcome_tokens(
        settler: &signer,
        market_id: u64
    ) acquires Markets, MarketRegistry, LiquidityPools, Management, OracleSigner, AdminProperties {

        let oracle_signer_addr     = get_oracle_signer_addr();
        let oracle_signer          = get_oracle_signer(oracle_signer_addr);
        let admin_properties       = borrow_global<AdminProperties>(oracle_signer_addr);
        let settler_addr           = signer::address_of(settler);

        // get the market
        let market_registry     = borrow_global<MarketRegistry>(oracle_signer_addr);
        let creator_address     = *smart_table::borrow(&market_registry.market_to_creator, market_id);
        let markets             = borrow_global_mut<Markets>(creator_address);
        let market              = smart_table::borrow_mut(&mut markets.market_table, market_id);

        // verify market has been resolved
        assert!(market.resolved == true, ERROR_MARKET_HAS_NOT_BEEN_RESOLVED);
        
        // check that the pool has been initialized already
        assert!(market.pool_initialized == true, ERROR_POOL_NOT_INITIALIZED);

        // get liquidity pool info
        let initializer_addr    = option::destroy_some(market.pool_initializer);
        let liquidity_pools     = borrow_global_mut<LiquidityPools>(initializer_addr);
        let liquidity_pool      = smart_table::borrow_mut(&mut liquidity_pools.pools, market_id);

        let token_one_reserve   = liquidity_pool.outcome_token_one_reserve;
        let token_two_reserve   = liquidity_pool.outcome_token_two_reserve;
        let total_pool_reserves = token_one_reserve + token_two_reserve;

        // Get the management resource for the outcome one token
        let token_one_burn_ref     = &borrow_global<Management>(market.outcome_token_one_address).burn_ref;
        let token_one_metadata     = market.outcome_token_one_metadata;
        let token_one_balance      = primary_fungible_store::balance(settler_addr, token_one_metadata);

        // Get the management resource for the outcome two token
        let token_two_burn_ref     = &borrow_global<Management>(market.outcome_token_two_address).burn_ref;
        let token_two_metadata     = market.outcome_token_two_metadata;
        let token_two_balance      = primary_fungible_store::balance(settler_addr, token_two_metadata);

        let payout;
        let token_one_burn_amount;
        let token_two_burn_amount;
        if(market.asserted_outcome_id == aptos_hash::keccak256(market.outcome_one)){
            
            // outcome one wins
            // calc payout based on proportion 
            let proportion = (((token_one_balance as u128) * FIXED_POINT_ACCURACY) / token_one_reserve);
            payout         = (proportion * total_pool_reserves) / FIXED_POINT_ACCURACY;

            token_one_burn_amount = token_one_balance;
            token_two_burn_amount = token_two_balance;

        } else if (market.asserted_outcome_id == aptos_hash::keccak256(market.outcome_two)){

            // outcome two wins
            // calc payout based on proportion 
            let proportion = (((token_two_balance as u128) * FIXED_POINT_ACCURACY) / token_two_reserve);
            payout         = (proportion * total_pool_reserves) / FIXED_POINT_ACCURACY;

            token_one_burn_amount = token_one_balance;
            token_two_burn_amount = token_two_balance;

        } else {

            // unresolved outcome
            // $1 => one outcome token one + one outcome token two
            if(token_one_balance >= token_two_balance){
                // more token one than token two - we take the min * 2
                payout = ((token_two_balance * 2) as u128);
                
                token_one_burn_amount = token_two_balance;
                token_two_burn_amount = token_two_balance;

            } else {
                // more token two than token one - we take the min * 2
                payout = ((token_one_balance * 2) as u128);

                token_one_burn_amount = token_one_balance;
                token_two_burn_amount = token_one_balance;
            };

        };

        // Burn outcome tokens
        let token_one_fa = primary_fungible_store::withdraw(settler, token_one_metadata, token_one_burn_amount);
        fungible_asset::burn(token_one_burn_ref, token_one_fa);

        let token_two_fa = primary_fungible_store::withdraw(settler, token_two_metadata, token_two_burn_amount);
        fungible_asset::burn(token_two_burn_ref, token_two_fa);

        // transfer payout to settler
        let currency_metadata = option::destroy_some(admin_properties.currency_metadata);
        primary_fungible_store::transfer(&oracle_signer, currency_metadata, settler_addr, (payout as u64));

        // update liquidity pool outcome token reserves
        liquidity_pool.outcome_token_one_reserve - (token_one_burn_amount as u128);
        liquidity_pool.outcome_token_two_reserve - (token_two_burn_amount as u128);

        // emit event for tokens settled
        event::emit(TokensSettledEvent {
            market_id,
            account: settler_addr,
            payout: (payout as u64),
            outcome_one_tokens: token_one_burn_amount,
            outcome_two_tokens: token_two_burn_amount
        });
    }
    
    
    //
    // 
    //  Reference: Original outcome token mechanics from UMA Protocol Optimistic Oracle Prediction Market
    // 
    // 

    // Mints pair of tokens representing the value of outcome1 and outcome2. Trading of outcome tokens is outside of the
    // scope of this contract. 
    // public entry fun create_outcome_tokens(
    //     minter: &signer,
    //     market_id: u64, 
    //     tokens_to_create: u64
    // ) acquires Markets, MarketRegistry, Management, AdminProperties {

    //     let oracle_signer_addr     = get_oracle_signer_addr();
    //     let market_registry        = borrow_global<MarketRegistry>(oracle_signer_addr);
    //     let admin_properties       = borrow_global<AdminProperties>(oracle_signer_addr);
    //     let minter_addr            = signer::address_of(minter);

    //     // get creator address from registry (and verify that market exists)
    //     let creator_address        = *smart_table::borrow(&market_registry.market_to_creator, market_id);
        
    //     // get creator markets
    //     let markets                = borrow_global_mut<Markets>(creator_address);

    //     // find market by id
    //     let market                 = smart_table::borrow_mut(&mut markets.market_table, market_id);

    //     // verify market has not been resolved
    //     assert!(market.resolved == false, ERROR_MARKET_HAS_BEEN_RESOLVED);

    //     // transfer currency tokens (i.e. oracle tokens) from minter to module
    //     let currency_metadata = option::destroy_some(admin_properties.currency_metadata);
    //     primary_fungible_store::transfer(minter, currency_metadata, oracle_signer_addr, tokens_to_create);

    //     // Get the management resource for the outcome one token
    //     let token_one_mint_ref     = &borrow_global<Management>(market.outcome_token_one_address).mint_ref;
    //     let token_one_transfer_ref = &borrow_global<Management>(market.outcome_token_one_address).transfer_ref;
    //     let token_one_metadata     = market.outcome_token_one_metadata;

    //     // Mint outcome token one
    //     let minter_token_one_wallet = primary_fungible_store::ensure_primary_store_exists(minter_addr, token_one_metadata);
    //     let fa = fungible_asset::mint(token_one_mint_ref, tokens_to_create);
    //     fungible_asset::deposit_with_ref(token_one_transfer_ref, minter_token_one_wallet, fa);

    //     // Get the management resource for the outcome two token
    //     let token_two_mint_ref     = &borrow_global<Management>(market.outcome_token_two_address).mint_ref;
    //     let token_two_transfer_ref = &borrow_global<Management>(market.outcome_token_two_address).transfer_ref;
    //     let token_two_metadata     = market.outcome_token_two_metadata;

    //     // Mint outcome token two
    //     let minter_token_two_wallet = primary_fungible_store::ensure_primary_store_exists(minter_addr, token_two_metadata);
    //     let fa = fungible_asset::mint(token_two_mint_ref, tokens_to_create);
    //     fungible_asset::deposit_with_ref(token_two_transfer_ref, minter_token_two_wallet, fa);

    //     // emit event for tokens created
    //     event::emit(TokensCreatedEvent {
    //         market_id,
    //         account: minter_addr,
    //         tokens_created: tokens_to_create
    //     });
    // }


    // Burns equal amount of outcome1 and outcome2 tokens returning settlement currency tokens.
    // public entry fun redeem_outcome_tokens(
    //     redeemer: &signer,
    //     market_id: u64, 
    //     tokens_to_redeem: u64
    // ) acquires Markets, MarketRegistry, Management, OracleSigner, AdminProperties {

    //     let oracle_signer_addr     = get_oracle_signer_addr();
    //     let oracle_signer          = get_oracle_signer(oracle_signer_addr);
    //     let market_registry        = borrow_global<MarketRegistry>(oracle_signer_addr);
    //     let admin_properties       = borrow_global<AdminProperties>(oracle_signer_addr);
    //     let redeemer_addr          = signer::address_of(redeemer);

    //     // get creator address from registry (and verify that market exists)
    //     let creator_address        = *smart_table::borrow(&market_registry.market_to_creator, market_id);
        
    //     // get creator markets
    //     let markets                = borrow_global_mut<Markets>(creator_address);

    //     // find market by id
    //     let market                 = smart_table::borrow_mut(&mut markets.market_table, market_id);

    //     // transfer currency tokens (i.e. oracle tokens) from module to oracle
    //     let currency_metadata = option::destroy_some(admin_properties.currency_metadata);
    //     primary_fungible_store::transfer(&oracle_signer, currency_metadata, redeemer_addr, tokens_to_redeem);

    //     // Get the management resource for the outcome one token
    //     let token_one_burn_ref     = &borrow_global<Management>(market.outcome_token_one_address).burn_ref;
    //     let token_one_metadata     = market.outcome_token_one_metadata;

    //     // Burn outcome token one
    //     let token_one_fa = primary_fungible_store::withdraw(redeemer, token_one_metadata, tokens_to_redeem);
    //     fungible_asset::burn(token_one_burn_ref, token_one_fa);

    //     // Get the management resource for the outcome two token
    //     let token_two_burn_ref     = &borrow_global<Management>(market.outcome_token_two_address).burn_ref;
    //     let token_two_metadata     = market.outcome_token_two_metadata;

    //     // Burn outcome token two
    //     let token_two_fa = primary_fungible_store::withdraw(redeemer, token_two_metadata, tokens_to_redeem);
    //     fungible_asset::burn(token_two_burn_ref, token_two_fa);

    //     // emit event for tokens redeemed
    //     event::emit(TokensRedeemedEvent {
    //         market_id,
    //         account: redeemer_addr,
    //         tokens_redeemed: tokens_to_redeem
    //     });
    // }


    // If the market is resolved, then all of caller's outcome tokens are burned and currency payout is made depending
    // on the resolved market outcome and the amount of outcome tokens burned. If the market was resolved to the first
    // outcome, then the payout equals balance of outcome1Token while outcome2Token provides nothing. If the market was
    // resolved to the second outcome, then the payout equals balance of outcome2Token while outcome1Token provides
    // nothing. If the market was resolved to the split outcome, then both outcome tokens provides half of their balance
    // as currency payout.
    // public entry fun settle_outcome_tokens(
    //     settler: &signer,
    //     market_id: u64
    // ) acquires Markets, MarketRegistry, Management, OracleSigner, AdminProperties {

    //     let oracle_signer_addr     = get_oracle_signer_addr();
    //     let oracle_signer          = get_oracle_signer(oracle_signer_addr);
    //     let market_registry        = borrow_global<MarketRegistry>(oracle_signer_addr);
    //     let admin_properties       = borrow_global<AdminProperties>(oracle_signer_addr);
    //     let settler_addr           = signer::address_of(settler);

    //     // get creator address from registry (and verify that market exists)
    //     let creator_address        = *smart_table::borrow(&market_registry.market_to_creator, market_id);
        
    //     // get creator markets
    //     let markets                = borrow_global_mut<Markets>(creator_address);

    //     // find market by id
    //     let market                 = smart_table::borrow_mut(&mut markets.market_table, market_id);

    //     // verify market has been resolved
    //     assert!(market.resolved == true, ERROR_MARKET_HAS_NOT_BEEN_RESOLVED);

    //     // Get the management resource for the outcome one token
    //     let token_one_burn_ref     = &borrow_global<Management>(market.outcome_token_one_address).burn_ref;
    //     let token_one_metadata     = market.outcome_token_one_metadata;

    //     let token_one_balance      = primary_fungible_store::balance(settler_addr, token_one_metadata);

    //     // Get the management resource for the outcome two token
    //     let token_two_burn_ref     = &borrow_global<Management>(market.outcome_token_two_address).burn_ref;
    //     let token_two_metadata     = market.outcome_token_two_metadata;
    //     let token_two_balance      = primary_fungible_store::balance(settler_addr, token_two_metadata);

    //     let payout;
    //     if(market.asserted_outcome_id == aptos_hash::keccak256(market.outcome_one)){
    //         payout = token_one_balance; // outcome one
    //     } else if (market.asserted_outcome_id == aptos_hash::keccak256(market.outcome_two)){
    //         payout = token_two_balance; // outcome two
    //     } else {
    //         payout = (token_one_balance + token_two_balance) / 2;
    //     };

    //     // Burn outcome tokens
    //     let token_one_fa = primary_fungible_store::withdraw(settler, token_one_metadata, token_one_balance);
    //     fungible_asset::burn(token_one_burn_ref, token_one_fa);

    //     let token_two_fa = primary_fungible_store::withdraw(settler, token_two_metadata, token_two_balance);
    //     fungible_asset::burn(token_two_burn_ref, token_two_fa);

    //     // transfer payout to settler
    //     let currency_metadata = option::destroy_some(admin_properties.currency_metadata);
    //     primary_fungible_store::transfer(&oracle_signer, currency_metadata, settler_addr, payout);

    //     // emit event for tokens settled
    //     event::emit(TokensSettledEvent {
    //         market_id,
    //         account: settler_addr,
    //         payout,
    //         outcome_one_tokens: token_one_balance,
    //         outcome_two_tokens: token_two_balance
    //     });
    // }

    // -----------------------------------
    // Views
    // -----------------------------------

    #[view]
    public fun get_admin_properties(): (
        u64, u64, u64, address, u128, u128, Object<Metadata>
    ) acquires AdminProperties {

        let oracle_signer_addr = get_oracle_signer_addr();
        let admin_properties   = borrow_global_mut<AdminProperties>(oracle_signer_addr);

        // return admin_properties values
        (
            admin_properties.default_fee,
            admin_properties.burned_bond_percentage,
            admin_properties.min_liveness,
            admin_properties.treasury_address,
            admin_properties.swap_fee_percent,
            admin_properties.min_liquidity_required,
            option::destroy_some(admin_properties.currency_metadata)
        )
    }

    #[view]
    public fun get_next_market_id(): (
        u64
    ) acquires MarketRegistry {
        
        let oracle_signer_addr = get_oracle_signer_addr();
        let market_registry     = borrow_global<MarketRegistry>(oracle_signer_addr);
        
        market_registry.next_market_id
    }



    #[view]
    public fun get_next_assertion_id(): (
        u64
    ) acquires AssertionRegistry {
        
        let oracle_signer_addr = get_oracle_signer_addr();
        let assertion_registry = borrow_global<AssertionRegistry>(oracle_signer_addr);
        
        assertion_registry.next_assertion_id
    }



    #[view]
    // refactored to use u64 as assertion id
    public fun get_assertion(assertion_id: u64) : (
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


    #[view]
    // refactored to use u64 as market id
    public fun get_market(market_id: u64) : (
        address, bool, vector<u8>, u64, u64, vector<u8>, vector<u8>, vector<u8>, vector<u8>, vector<u8>, u64, Object<Metadata>, Object<Metadata>, address, address
    ) acquires MarketRegistry, Markets {

        let oracle_signer_addr     = get_oracle_signer_addr();
        let market_registry        = borrow_global<MarketRegistry>(oracle_signer_addr);

        // get creator address from registry
        let creator_address        = *smart_table::borrow(&market_registry.market_to_creator, market_id);
        
        // find market by id
        let markets                = borrow_global_mut<Markets>(creator_address);
        let market                 = smart_table::borrow_mut(&mut markets.market_table, market_id);
        
        // return the necessary fields from the market
        (
            market.creator,
            market.resolved,
            market.asserted_outcome_id,
            market.reward,
            market.required_bond,
            market.outcome_one,
            market.outcome_two,
            market.description,
            market.image_url,

            market.categories,
            market.start_timestamp,

            market.outcome_token_one_metadata,
            market.outcome_token_two_metadata,
            
            market.outcome_token_one_address,
            market.outcome_token_two_address,
        )
    }


    #[view]
    public fun get_pool(market_id: u64) : (
        u64, address, u128, u128, u128, Object<Metadata>, address
    ) acquires MarketRegistry, Markets, LiquidityPools {

        let oracle_signer_addr     = get_oracle_signer_addr();
        
        // get the market
        let market_registry     = borrow_global<MarketRegistry>(oracle_signer_addr);
        let creator_address     = *smart_table::borrow(&market_registry.market_to_creator, market_id);
        let markets             = borrow_global_mut<Markets>(creator_address);
        let market              = smart_table::borrow_mut(&mut markets.market_table, market_id);

        // get the pool
        let initializer_addr    = option::destroy_some(market.pool_initializer);
        let liquidity_pools     = borrow_global_mut<LiquidityPools>(initializer_addr);
        let liquidity_pool      = smart_table::borrow_mut(&mut liquidity_pools.pools, market_id);

        // return the necessary fields from the market
        (
            liquidity_pool.market_id,
            liquidity_pool.initializer,

            liquidity_pool.outcome_token_one_reserve,
            liquidity_pool.outcome_token_two_reserve,

            liquidity_pool.lp_total_supply,
            liquidity_pool.lp_token_metadata,
            liquidity_pool.lp_token_address
        )
    }


    // #[view]
    // public fun get_assertion_id(
    //     asserter: address,
    //     claim: vector<u8>, 
    //     time: u64,
    //     bond: u64, 
    //     liveness: u64,
    //     identifier: vector<u8>
    // ) : vector<u8> {

    //     let asserter_bytes = bcs::to_bytes<address>(&asserter);
    //     let time_bytes     = bcs::to_bytes<u64>(&time);
    //     let bond_bytes     = bcs::to_bytes<u64>(&bond);
    //     let liveness_bytes = bcs::to_bytes<u64>(&liveness);
        
    //     let assertion_id_vector = vector::empty<u8>();
    //     vector::append(&mut assertion_id_vector, asserter_bytes);
    //     vector::append(&mut assertion_id_vector, claim);
    //     vector::append(&mut assertion_id_vector, time_bytes);
    //     vector::append(&mut assertion_id_vector, bond_bytes);
    //     vector::append(&mut assertion_id_vector, liveness_bytes);
    //     vector::append(&mut assertion_id_vector, identifier);
    //     aptos_hash::keccak256(assertion_id_vector)
    // }


    // original: refactor to use numbers for market id for easier fetching on the frontend
    // #[view]
    // public fun get_market_id(
    //     creator: address,
    //     time_bytes: vector<u8>,
    //     description: vector<u8>
    // ): vector<u8> {
    //     let creator_bytes     = bcs::to_bytes<address>(&creator);

    //     let market_id_vector  = vector::empty<u8>();
    //     vector::append(&mut market_id_vector, creator_bytes);
    //     vector::append(&mut market_id_vector, time_bytes);
    //     vector::append(&mut market_id_vector, description);
    //     aptos_hash::keccak256(market_id_vector)
    // }


    // stamp assertion - i.e. ancillary data
    // Returns ancillary data for the Oracle request containing assertionId and asserter.
    // note: originally used as an inline function, however due to the test coverage bug we use a view instead to reach 100% test coverage
    #[view]
    public fun stamp_assertion(assertion_id: u64, asserter: address) : vector<u8> {
        let assertion_id_bytes = bcs::to_bytes<u64>(&assertion_id);
        let ancillary_data_vector = vector::empty<u8>();
        vector::append(&mut ancillary_data_vector, b"assertionId: ");
        vector::append(&mut ancillary_data_vector, assertion_id_bytes);
        vector::append(&mut ancillary_data_vector, b",ooAsserter:");
        vector::append(&mut ancillary_data_vector, bcs::to_bytes<address>(&asserter));
        aptos_hash::keccak256(ancillary_data_vector)
    }


    // compose market claim
    // note: originally used as an inline function, however due to the test coverage bug we use a view instead to reach 100% test coverage
    #[view]
    public fun compose_claim(outcome: vector<u8>, description: vector<u8>) : vector<u8> {

        let current_timestamp = timestamp::now_microseconds();
        let time_bytes        = bcs::to_bytes<u64>(&current_timestamp);

        let claim_data_vector = vector::empty<u8>();
        vector::append(&mut claim_data_vector, b"As of assertion timestamp: ");
        vector::append(&mut claim_data_vector, time_bytes);
        vector::append(&mut claim_data_vector, b", the described prediction market outcome is:");
        vector::append(&mut claim_data_vector, outcome);
        vector::append(&mut claim_data_vector, b". The market description is: ");
        vector::append(&mut claim_data_vector, description);
        aptos_hash::keccak256(claim_data_vector)
    }

    // -----------------------------------
    // Helpers
    // -----------------------------------

    fun get_oracle_signer_addr(): address {
        object::create_object_address(&@optimistic_oracle_addr, APP_OBJECT_SEED)
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
        prediction_market : &signer,
        user_one : &signer,
        user_two : &signer,
    ) : (address, address, address) {

        init_module(prediction_market);

        timestamp::set_time_has_started_for_testing(aptos_framework);

        // get addresses
        let prediction_market_addr   = signer::address_of(prediction_market);
        let user_one_addr            = signer::address_of(user_one);
        let user_two_addr            = signer::address_of(user_two);

        // create accounts
        account::create_account_for_test(prediction_market_addr);
        account::create_account_for_test(user_one_addr);
        account::create_account_for_test(user_two_addr);

        (prediction_market_addr, user_one_addr, user_two_addr)
    }


    #[view]
    #[test_only]
    public fun test_AssertionMadeEvent(
        assertion_id: u64, 
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
        assertion_id: u64, 
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
        assertion_id: u64, 
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


    #[view]
    #[test_only]
    public fun test_MarketInitializedEvent(
        creator: address,
        market_id: u64,
        outcome_one: vector<u8>,
        outcome_two: vector<u8>,
        description: vector<u8>,
        image_url: vector<u8>,
        reward: u64,
        required_bond: u64,

        outcome_token_one_metadata: Object<Metadata>,
        outcome_token_two_metadata: Object<Metadata>,

        outcome_token_one_address: address,
        outcome_token_two_address: address
    ): MarketInitializedEvent {
        let event = MarketInitializedEvent{
            creator,
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
            outcome_token_two_address,
        };
        return event
    }

    #[view]
    #[test_only]
    public fun test_MarketAssertedEvent(
        market_id: u64, 
        asserted_outcome: vector<u8>,
        assertion_id: u64
    ): MarketAssertedEvent {
        let event = MarketAssertedEvent{
            market_id,
            asserted_outcome,
            assertion_id
        };
        return event
    }


    #[view]
    #[test_only]
    public fun test_MarketResolvedEvent(
        market_id: u64
    ): MarketResolvedEvent {
        let event = MarketResolvedEvent{
            market_id
        };
        return event
    }


    #[view]
    #[test_only]
    public fun test_PoolInitializedEvent(
        initializer: address, 
        market_id: u64,
        collateral_amount: u64
    ): PoolInitializedEvent {
        let event = PoolInitializedEvent{
            initializer,
            market_id,
            collateral_amount
        };
        return event
    }

    
    #[view]
    #[test_only]
    public fun test_DepositLiquidityEvent(
        user: address, 
        market_id: u64,
        amount: u64,
        lp_tokens_minted: u64,
    ): DepositLiquidityEvent {
        let event = DepositLiquidityEvent{
            user,
            market_id,
            amount,
            lp_tokens_minted
        };
        return event
    }


    #[view]
    #[test_only]
    public fun test_WithdrawLiquidityEvent(
        user: address, 
        market_id: u64,
        lp_token_amount: u64,
        collateral_amount: u64,
    ): WithdrawLiquidityEvent {
        let event = WithdrawLiquidityEvent{
            user,
            market_id,
            lp_token_amount,
            collateral_amount
        };
        return event
    }


    #[view]
    #[test_only]
    public fun test_BuyOutcomeTokensEvent(
        user: address, 
        market_id: u64,
        outcome_token: vector<u8>,
        collateral_amount: u64,
        outcome_token_amount: u64,
    ): BuyOutcomeTokensEvent {
        let event = BuyOutcomeTokensEvent{
            user,
            market_id,
            outcome_token,
            collateral_amount,
            outcome_token_amount
        };
        return event
    }


    #[view]
    #[test_only]
    public fun test_SellOutcomeTokensEvent(
        user: address, 
        market_id: u64,
        outcome_token: vector<u8>,
        collateral_amount: u64,
        outcome_token_amount: u64,
    ): SellOutcomeTokensEvent {
        let event = SellOutcomeTokensEvent{
            user,
            market_id,
            outcome_token,
            collateral_amount,
            outcome_token_amount
        };
        return event
    }


    #[view]
    #[test_only]
    public fun test_RedeemLpTokensEvent(
        user: address,
        market_id: u64, 
        lp_amount_redeemed: u64,
        outcome_token_one_amount: u64,
        outcome_token_two_amount: u64
    ): RedeemLpTokensEvent {
        let event = RedeemLpTokensEvent{
            user,
            market_id,
            lp_amount_redeemed,
            outcome_token_one_amount,
            outcome_token_two_amount
        };
        return event
    }


    #[view]
    #[test_only]
    public fun test_TokensSettledEvent(
        market_id: u64, 
        account: address,
        payout: u64,
        outcome_one_tokens: u64,
        outcome_two_tokens: u64
    ): TokensSettledEvent {
        let event = TokensSettledEvent{
            market_id,
            account,
            payout,
            outcome_one_tokens,
            outcome_two_tokens
        };
        return event
    }


}