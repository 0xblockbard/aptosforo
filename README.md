# AptosForo

***Decentralised Prediction Market built on Optimistic Oracles***

AptosForo (derived from "Aptos" and "Foro," Latin for "market") is an innovative prediction market that lets you trade on a diverse range of highly debated topics, from current events and politics to cryptocurrency trends. 

As prediction markets gain popularity, they appeal to individuals who seek to leverage their insights and capitalise on their understanding of future events. 

By transforming forecasts into tradable assets, these markets allow users to profit from their predictions while also creating a collective intelligence that offers valuable insights into the likelihood of various outcomes. 

With platforms like Polymarket on Polygon leading the way, prediction markets have become an exciting intersection of finance, technology, and social sentiment. 

Inspired by this trend, AptosForo allows users to leverage their knowledge and insights on the future to build a dynamic portfolio. By buying shares in various markets, one can turn their predictions into potential profits.

At the core of our Minimum Viable Product (MVP) is a robust Optimistic Oracle, built on UMA Protocol's design and adapted for the Aptos Move language, which secures market resolution with economic guarantees and bonds.

Unlike conventional oracles limited to price feeds, UMA Protocol's Optimistic Oracle can validate a broad range of on-chain data, supporting AptosForo’s mission to enable secure, decentralised predictions.

Integrated with a Full Policy Escalation Manager and Automated Market Maker, AptosForo provides a seamless trading experience and reliable data verification, empowering users to engage confidently in predictive markets on Aptos.

![AptosForo](https://res.cloudinary.com/blockbard/image/upload/c_scale,w_auto,q_auto,f_auto,fl_lossy/v1728917255/aptosforo-home-screenshot_t3vwpv.png)

## AptosForo Full Process Flow

Currently, on the Aptos Testnet, any user will be able to initialise a new market for a given scenario with binary outcomes (e.g. Yes / No), and can provide a reward as incentive for users to assert a truthful market resolution.

Then, the user can initialise a liquidity pool for the newly created market, providing initial liquidity that meets or exceeds the minimum requirement. This liquidity is split evenly between both outcomes, and the user will receive corresponding LP tokens (representing half of the total liquidity provided, with each LP token equating to one share of both outcomes).

On the Aptos Testnet, we primarily use a standard fungible asset token as the Oracle Token on AptosForo, functioning as the main currency and liquidity token. Users can mint Oracle Tokens via our faucet to interact with the sample markets created. Should we deploy on the Mainnet in the future, the main currency token could be a USDT-equivalent fungible asset, with the Oracle Token designated for market assertions and resolutions.

![Faucet](https://res.cloudinary.com/blockbard/image/upload/c_scale,w_auto,q_auto,f_auto,fl_lossy/v1728917427/faucet-screenshot_qsc0vu.png)

With the liquidity pool in place, other users can freely buy or sell outcome tokens from it. For each swap, a small fee (e.g. 0.2%, equivalent to Polymarket’s fee) is charged, which serves as an incentive for liquidity providers.

Unlike the traditional CPMM, which follows the x * y = k formula, our modified AMM adopts a ratio formula to ensure that the total price always equals 1, regardless of demand or supply fluctuations for either outcome token. For instance, the price of an outcome token is determined by its corresponding reserve  amount against the total reserves in the liquidity pool.

This differs from Polymarket, which has recently moved away from AMM DEXs, and is now operating through an order book model with market and limit orders. 

A user can also deposit collateral to the liquidity pool and receive LP tokens, which they can later redeem for outcome tokens. Similarly, they can withdraw collateral by returning LP tokens, which will then be burned. 

When LP tokens are redeemed, they are exchanged for outcome tokens at the current pool ratio. For instance, with a 70:30 ratio between the two outcomes, the user will receive outcome tokens reflecting that ratio. 

For market resolutions, AptosForo uses a modified Full Policy Escalation Manager from UMA Protocol, adapted for Aptos Move, allowing for whitelisting of asserters and disputers if required. This ensures controlled access to market assertions and disputes, reducing frivolous or malicious activities. If necessary, we can also pause all assertion activities on the market.

To resolve a market, users post a bond with their asserted outcome. This assertion remains open for a liveness period (e.g. 2 hours), during which other users may dispute it. At any one time, there can only be one asserter or disputer for a market. 

If no dispute arises, the market settles at the end of the liveness period, with the asserted outcome recognised as true. Any existing market reward will also be awarded to the asserter at this time. 

However, in the case of a dispute, the escalation manager steps in to resolve the conflict. Here, the admin will be able to set an arbitration resolution for the disputed assertion. We have also modified the UMA Escalation Manager smart contract to allow for overrides on the arbitration resolution to facilitate testing on Aptos Testnet. 

The winner of the dispute (whether asserter or disputer) recoups their bond and claims half of the opposing party's bond (less fees) as an incentive. For potential high-activity markets, the bond requirement may be set higher to deter frivolous or malicious assertions. 

Should a market be disputed successful in favour of the disputer, the market’s asserted outcome resets, allowing another user to make a new assertion. 

After a market has been resolved, trading on the market’s liquidity pool ceases. Users cannot buy, sell, deposit, or withdraw liquidity from the pool, though they can still redeem LP tokens for outcome tokens. The redeemed amount will be calculated proportionally based on the total LP Token supply and ratio of outcome token reserves. 

Finally, users can settle their outcome tokens for rewards. If, for example, outcome one wins, holders of outcome one tokens will receive payouts proportionate to the pool’s outcome token one reserves. Tokens from the losing outcome are discarded and burned. In cases where there is an unresolved outcome, one token from each outcome is required to claim rewards.

## Demo MVP

The AptosForo demo is accessible at https://aptosforo.com. The demo showcases sample markets across various topics that have been pre-generated for sample purposes to showcase our functionality.

Features:
Wallet Integration: Users can connect their Aptos wallets to interact with the platform on testnet
Sample Markets: Explore pre-generated markets across various topics
Faucet: Mint our oracle token to interact with markets, trade outcome tokens, and provide liquidity
Create Markets: Users can experiment and create their own prediction markets
Market Outcomes: Users can buy or sell their desired market outcomes
Liquidity Pool: Users can deposit or withdraw oracle token collateral into the liquidity pool 
Real-Time Updates: Successful trades trigger automatic updates to the market’s liquidity pool, reflecting new prices instantly.

Our interactive demo provides a comprehensive preview of the AptosForo platform, highlighting our simple and user-friendly interface based on Polymarket’s design. 

We prioritise the user journey and experience, and aim to make the process straightforward and accessible.

Once an outcome token has been bought or sold successfully, the transaction is recorded on the blockchain, and the outcome token prices will be updated to reflect the new prices. 

The frontend demo for AptosForo is maintained in a separate repository to ensure that the Move smart contracts remain focused and well-organised. 

It can be found here: AptosForo Frontend Github

![Welcome](https://res.cloudinary.com/blockbard/image/upload/c_scale,w_auto,q_auto,f_auto,fl_lossy/v1728917557/get-started-screenshot_j8ngmp.png)

## Tech Overview and Considerations

We follow the Aptos Object Model approach, storing Market, Assertion, and Liquidity Pool objects on user accounts rather than on the AptosForo module to decentralise data storage, enhance scalability, and optimise gas costs. 

Market creators will have a Markets, AssertionTable, and LiquidityPools struct containing the corresponding smart table mapping unique ids to their objects. 

The AptosForo module then maintains the MarketRegistry and AssertionRegistry structs that maps market IDs and assertion IDs to their creators respectively. 

Market and assertion IDs are unique and sequentially assigned, ensuring that no two objects of the same type share the same ID, regardless of their creator.

While the AptosForo prediction market and escalation manager modules are based on UMA Protocol’s Solidity contracts, there are some significant differences between them. 

Firstly, instead of inheriting the Optimistic Oracle V3 contract in the prediction market contract like in Solidity, we have integrated the Optimistic Oracle functionality, Liquidity Pool, Automated Market Maker (AMM), and Prediction Market functionalities into a single module. This is then deployed together with the escalation manager module as a single package. 

Secondly, while preserving the underlying architecture as closely as possible, we have simplified the market and assertion IDs from keccak hashes to u64 IDs for easier data retrieval. The implementation of outcome tokens has also been significantly modified as we integrate them with the AMM mechanics to determine outcome token prices.

UMA Protocol’s Solidity smart contracts referenced:

- [Optimistic Oracle V3](https://github.com/UMAprotocol/protocol/blob/master/packages/core/contracts/optimistic-oracle-v3/implementation/OptimisticOracleV3.sol)
- [Full Policy Escalation Manager](https://github.com/UMAprotocol/protocol/blob/master/packages/core/contracts/-optimistic-oracle-v3/implementation/escalation-manager/FullPolicyEscalationManager.sol)
- [Prediction Market](https://github.com/UMAprotocol/dev-quickstart-oov3/blob/master/src/PredictionMarket.sol)


## Smart Contract Entrypoints

The AptosForo prediction market module includes eleven public entrypoints and one admin entrypoint:

**Prediction Market Public Entrypoints**

1. **initialize_market**: Allows a user to initialize a new market
   - **Input**: New market properties (outcome one, outcome two, description, image_url, reward, required_bond, and categories)
   - **Output**: Creates a new prediction market and corresponding outcome tokens

2. **initialize_pool**: Allows a user to initialize a liquidity pool for a market. Liquidity pool can only be initialized once per market.
   - **Input**: Market ID and initial collateral amount greater than the minimum liquidity required
   - **Output**: Creates a new liquidity pool for the given market

3. **assert_market**: Allows a user to assert one of three possible outcomes (market outcome one, market outcome two, or unresolvable). If whitelisted asserters are enabled on the escalation manager, the user will need to be whitelisted in order to call this entrypoint. If block_assertion is set to true on the escalation manager, then all market assertions are paused.
   - **Input**: Market ID and asserted outcome
   - **Output**: Creates a new assertion for the market with the asserted outcome

4. **dispute_assertion**: Allows a user to dispute an asserted market outcome. If whitelisted disputes are enabled on the escalation manager, the user will need to be whitelisted in order to call this entrypoint.
   - **Input**: Assertion ID
   - **Output**: Raises a new dispute for the assertion, requiring the escalation manager admin to set an arbitration resolution to resolve the dispute

5. **settle_assertion**: Allows any user to settle an assertion after it has been resolved. If there are no disputes, the assertion is resolved as true and the asserter receives the bond. If the assertion has been disputed, the assertion is resolved depending on the result. Based on the result, the asserter or disputer receives the bond. If the assertion was disputed then an amount of the bond is sent to a treasury as a fee based on the burnedBondPercentage. The remainder of the bond is returned to the asserter or disputer.
   - **Input**: Assertion ID
   - **Output**: Resolves assertion and handles disbursement of the bond

6. **deposit_liquidity**: Allows a user to deposit oracle tokens into a market’s liquidity pool and receive a proportional amount of LP Tokens
   - **Input**: Market ID and oracle token amount
   - **Output**: Receives proportional amount of LP Tokens, and outcome token reserves are increased proportionally in the liquidity pool

7. **withdraw_liquidity**: Allows a user to return LP tokens and receive oracle tokens from a market’s liquidity pool
   - **Input**: Market ID and LP token amount
   - **Output**: Receives proportional amount of oracle tokens, and outcome token reserves are decreased proportionally in the liquidity pool

8. **buy_outcome_token**: Allows a user to buy a specified outcome token from a market (e.g. buy $10 worth of outcome tokens)
   - **Input**: Market ID, outcome, and oracle token amount
   - **Output**: Receives a proportional amount of outcome tokens based on the outcome token reserve ratio in the liquidity pool

9. **sell_outcome_token**: Allows a user to sell a specified outcome token (e.g. sell 10 outcome tokens)
   - **Input**: Market ID, outcome, and outcome token amount
   - **Output**: Receives a proportional amount of oracle tokens based on the outcome token reserve ratio in the liquidity pool

10. **redeem_lp_for_outcome_tokens**: Allows a user to redeem their LP tokens for outcome tokens
    - **Input**: Market ID and LP token amount
    - **Output**: Receives a proportional amount of outcome tokens based on the ratio of reserves in the liquidity pool

11. **settle_outcome_tokens**: Allows a user to settle their outcome tokens based on the market resolution
    - **Input**: Market ID
    - **Output**: Receives a proportional amount of oracle tokens based on the user’s balance of winning outcome tokens and the ratio of reserves in the liquidity pool

**Prediction Market Admin Entrypoints**

1. **set_admin_properties**: Allows the AptosForo admin to update the module admin properties or config (min_liveness, default_fee, treasury_address, swap_fee_percent, min_liquidity_required, burned_bond_percentage, currency_metadata)
   - **Input**: Verifies that the signer is the admin and that the burned_bond_percentage is greater than 0 and less than 10000 (100%)
   - **Output**: Updates the AptosForo module admin properties

2. **set_assertion_policy**: Allows the escalation manager admin to set the assertion policy that the prediction market module will follow
   - **Input**: Verifies that the signer is the admin and new boolean policy values (block_assertion, validate_asserters, validate_disputers)
   - **Output**: Updates the escalation manager assertion policy

3. **set_whitelisted_asserter**: Allows the escalation manager admin to set whitelisted asserter with a given boolean representing the whitelisted asserter’s permission
   - **Input**: Verifies that the signer is the admin
   - **Output**: Sets whitelisted asserter

4. **set_whitelisted_dispute_caller**: Allows the escalation manager admin to set whitelisted disputer with a given boolean representing the whitelisted disputer’s permission
   - **Input**: Verifies that the signer is the admin
   - **Output**: Sets whitelisted disputer

5. **set_arbitration_resolution**: Allows the escalation manager admin to resolve a market assertion outcome in the event of a dispute. We have also customized it slightly to allow for an override for greater control and flexibility.
   - **Input**: Verifies that the signer is the admin and derives the resolution request based on the assertion’s timestamp, market identifier, and ancillary data
   - **Output**: Sets an arbitration resolution

---
The AptosForo escalation manager module includes four admin entrypoint:

**Escalation Manager Admin Entrypoints**

1. **set_assertion_policy**: Allows the escalation manager admin to set the assertion policy that the prediction market module will follow  
   - **Input**: Verifies that the signer is the admin and new boolean policy values (block_assertion, validate_asserters, validate_disputers)
   - **Output**: Updates the escalation manager assertion policy

2. **set_whitelisted_asserter**: Allows the escalation manager admin to set a whitelisted asserter with a given boolean representing the whitelisted asserter’s permission
   - **Input**: Verifies that the signer is the admin
   - **Output**: Sets whitelisted asserter

3. **set_whitelisted_dispute_caller**: Allows the escalation manager admin to set a whitelisted disputer with a given boolean representing the whitelisted disputer’s permission
   - **Input**: Verifies that the signer is the admin
   - **Output**: Sets whitelisted disputer

4. **set_arbitration_resolution**: Allows the escalation manager admin to resolve a market assertion outcome in the event of a dispute. This function has been customized to allow for an override for greater control and flexibility.
   - **Input**: Verifies that the signer is the admin and derives the resolution request based on the assertion’s timestamp, market identifier, and ancillary data
   - **Output**: Sets an arbitration resolution


## Code Coverage

AptosForo has comprehensive test coverage, with 100% of the codebase thoroughly tested. This includes a full range of scenarios that ensure the platform's reliability and robustness.

The following section provides a breakdown of the tests that validate each function and feature, affirming that AptosForo performs as expected under all intended use cases.

![Code Coverage](https://res.cloudinary.com/blockbard/image/upload/c_scale,w_auto,q_auto,f_auto,fl_lossy/v1728916938/aptosforo-code-coverage_shdyzl.png)

## Dummy Data Script

We have also included a dummy data script to populate the AptosForo Demo MVP with sample prediction markets referenced from Polymarket. This helps to demonstrate our features and provides a realistic view of how markets appear and function on the site.

To run the dummy data script after deploying a local instance of our frontend and AptosForo package, follow these steps:

```
# compile the dummy data script and get the script path location
aptos move compile-script

# copy the script path location and paste it at the end (replace path_to_script.mv)
aptos move run-script --compiled-script-path /path_to_script.mv
```

## Future Plans

Looking ahead, here are some plans to expand the features and capabilities of AptosForo in Phase 2. 

### Planned Features:

- **Gnosis Conditional Tokens**: Implement the Gnosis Conditional Token framework on Aptos Move to enable split combinatorial outcomes for prediction markets, providing users with more granular options for forecasting complex scenarios.

- **Liquidity Mining**: Introduce liquidity mining rewards to incentivise more users to provide liquidity for prediction markets, enhancing market depth and creating more robust trading environments. 

- **Enhanced User Interface**: Develop an improved user interface with advanced analytics, prediction tracking, and visualisations to provide users with deeper insights and a better user experience. 

- **Community Governance**: Introduce a governance model that allows users to participate in decision-making, such as voting on new market topics, fee structures, and liquidity incentives. This will help create a more user-driven platform.  

By pursuing these plans, AptosForo aims to become a leading platform in the decentralised prediction markets space on Aptos. 

### Long-Term Vision:

- **Building Trust in Decentralised Prediction Markets**: As a secure, transparent, and user-driven platform, AptosForo aims to establish itself as a fully decentralised prediction market gradually 

- **Fostering Community and Collaboration**: Actively engage with the Aptos community to build a thriving community of participants and liquidity providers 

## Conclusion

AptosForo introduces the world of prediction markets from Polygon and Solidity to Aptos and Move with a clean, user-friendly interface and robust smart contract fundamentals based on industry standards from UMA protocol and Polymarket. 

With AptosForo, we hope to open new opportunities for the Aptos community to experiment and explore decentralised prediction markets with greater confidence and curiosity.

## Credits and Support

Thanks for reading till the end!

AptosForo is designed and built by 0xBlockBard, a solo indie maker passionate about building innovative products in the web3 space. 

With over 10 years of experience, my work spans full-stack and smart contract development, with the Laravel Framework as my go-to for web projects. I’m also familiar with Solidity, Rust, LIGO, and most recently, Aptos Move.

Beyond coding, I occasionally write and share insights on crypto market trends and interesting projects to watch. If you are interested to follow along my web3 journey, you can subscribe to my [Substack](https://www.0xblockbard.com/) here :)

Twitter / X: [0xBlockBard](https://x.com/0xblockbard)

Substack: [0xBlockBard Research](https://www.0xblockbard.com/)