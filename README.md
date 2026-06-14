# arc-relay-contracts

  Smart contracts powering the **Arc Relay Bridge** — a cross-chain USDC relay built on [Circle CCTP V2](https://developers.circle.com/stablecoins/cctp-getting-started) and deployable to Arc Testnet, Ethereum Sepolia, Base Sepolia, and Avalanche Fuji.

  ## Contracts

  | Contract | Description |
  |---|---|
  | `Paymaster.sol` | USDC-funded gas sponsorship vault (ERC-4337 v0.7 + legacy relay path) |
  | `GasRelayer.sol` | Cross-chain USDC delivery for wallets without destination-chain gas |
  | `FeeRouter_v2.sol` | Protocol fee collector (0.30 bps) that routes USDC into CCTP V2 burns |
  | `YieldVault.sol` | Simulated USDC yield vault to incentivise cross-chain rebalancing |

  ## Deployed Addresses (Testnet)

  ### Paymaster (ERC-4337 v0.7)

  | Chain | Chain ID | Address |
  |---|---|---|
  | Arc Testnet | 5042002 | `0xfD06D288d481515a986DF28030AF013De290D76C` |
  | Ethereum Sepolia | 11155111 | `0xC9E9ba0bfE58FA438B8B6f2182d3ADA3669F9Eb4` |
  | Base Sepolia | 84532 | `0xe355E9dCdEAB37eA8fd81b9457Ad2C56d3eE9055` |
  | Avalanche Fuji | 43113 | `0x7C75A75B59b63871e1Bb47fA63e541F0e5975f93` |

  Constructor: `(address usdc, address relayer, address feeRecipient, uint256 gasRate)`  
  EntryPoint: `0x0000000071727De22E5E9d8BAf0edAc6f37da032` (hardcoded constant)

  ### GasRelayer

  | Chain | Chain ID | Address |
  |---|---|---|
  | Arc Testnet | 5042002 | `0x837D9a19C07bb7B4E95071dC0BaED72D4dE04ea1` |
  | Ethereum Sepolia | 11155111 | `0x5E87F210043D8457caCAd0F0c9aB70a99497Eec9` |
  | Base Sepolia | 84532 | `0x64D160b7E91e78e52dFc0e8829640E32A919164C` |
  | Avalanche Fuji | 43113 | `0x6F80056564491425273A6a481EcC5DAea9D57f23` |

  Constructor: `(address usdc, address messageTransmitter, address feeRecipient, uint256 relayFee)`  
  MessageTransmitter: `0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275` (same on all chains)

  ### FeeRouter v2

  | Chain | Chain ID | Address |
  |---|---|---|
  | Arc Testnet | 5042002 | `0x8256a1e1f8971448b49dA0F55b8A1BB6557eA8FC` |
  | Ethereum Sepolia | 11155111 | `0x5B1F511ed4dF76f369671BF1c4aCF0dD84CC0804` |
  | Base Sepolia | 84532 | `0x8d4B57eD464df10414Dde3ADC2E403a01ebc50d8` |
  | Avalanche Fuji | 43113 | `0x64D160b7E91e78e52dFc0e8829640E32A919164C` |

  Constructor: `(address feeRecipient, uint256 feeBps, address usdc, address tokenMessenger)`  
  Fee: 30 bps (0.30%). TokenMessenger: `0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA`

  ### YieldVault

  | Chain | Chain ID | Address | APY |
  |---|---|---|---|
  | Arc Testnet | 5042002 | `0x9677b4BB48B552E7042619056414Fe69d2b5e204` | 18.5% |
  | Ethereum Sepolia | 11155111 | `0xCD75dad98b3bC9bb3Bb153b623772967e77d56F1` | 7.8% |
  | Base Sepolia | 84532 | `0xDE761A1b0FC1271AF2D1682158D428Bd12DC710d` | 12.3% |
  | Avalanche Fuji | 43113 | `0x57a298356E6B2A98d44C68Ff92B7372D639684E0` | 9.2% |

  Constructor: `(address usdc, uint256 apyBps, string vaultName)`

  ## Shared Infrastructure (same on all 4 chains)

  | Contract | Address |
  |---|---|
  | Circle CCTP V2 TokenMessenger | `0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA` |
  | Circle CCTP V2 MessageTransmitter | `0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275` |

  ## ABIs

  Pre-compiled ABI JSON files live in `abis/`:

  ```
  abis/
    Paymaster.json
    GasRelayer.json
    FeeRouter.json
    YieldVault.json
  ```

  Or fetch them live from the relay API:

  ```
  GET https://arc-relay-bridge.replit.app/api/contracts
  ```

  ## Compiler Settings

  All four contracts compiled with identical settings to support Arc Testnet and Fuji (no PUSH0 / Shanghai opcode):

  ```json
  {
    "version": "0.8.20",
    "evmVersion": "paris",
    "optimizer": { "enabled": true, "runs": 200 }
  }
  ```

  ## Source Verification

  All contracts are single-file (no imports). To verify on any block explorer:

  1. Open the contract address on the explorer.
  2. **Contract** tab → **Verify and Publish**.
  3. Select: Solidity (Single file), compiler `0.8.20`, optimization **ON** (200 runs), evmVersion **paris**.
  4. Paste the full `.sol` source from this repo.
  5. ABI-encode the constructor args (see each contract's section above for values).

  ## Integration

  ### Using GasRelayer (gasless cross-chain USDC)

  ```solidity
  // Set mintRecipient = bytes32(uint256(uint160(gasRelayerAddress)))
  // Set destinationCaller = bytes32(0) (anyone may relay)
  bytes32 mintRecipient = bytes32(uint256(uint160(GAS_RELAYER_ADDRESS)));
  ```

  Then call the relay API once you have the CCTP attestation:

  ```bash
  POST https://arc-relay-bridge.replit.app/api/relay
  {
    "message": "0x...",
    "attestation": "0x...",
    "recipient": "0xYourAddress",
    "destChainId": 5042002,
    "maxFee": "0"
  }
  ```

  ### Using Paymaster (USDC-funded gas)

  ```solidity
  // 1. Deposit USDC
  IERC20(USDC).approve(PAYMASTER, amount);
  IPaymaster(PAYMASTER).deposit(amount);

  // 2. Build UserOp with paymasterAndData = abi.encodePacked(PAYMASTER, uint128(maxPaymasterCost), uint128(0))
  ```

  ### Using FeeRouter (bridging with protocol fee)

  ```solidity
  // 1. Approve gross amount (e.g. 1.003 USDC for a 1 USDC bridge)
  IERC20(USDC).approve(FEE_ROUTER, grossAmount);

  // 2. Call bridge()
  IFeeRouter(FEE_ROUTER).bridge(netAmount, destDomain, mintRecipient, destChain, minFinalityThreshold);
  ```

  ## Links

  - [Arc Relay Bridge app](https://arc-relay-bridge.replit.app)
  - [Arc Docs](https://docs.arc.io)
  - [Circle CCTP Docs](https://developers.circle.com/stablecoins/cctp-getting-started)
  - [Circle USDC Faucet](https://faucet.circle.com)
  - [Arc Testnet Explorer](https://testnet.arcscan.app)

  ## License

  MIT
  