// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IGasRelayer
 * @notice Interface for the Arc Relay Bridge GasRelayer paymaster contract.
 *
 * The GasRelayer enables gasless CCTP cross-chain USDC transfers. The user burns
 * USDC on the source chain with mintRecipient set to the GasRelayer address.
 * A trusted relayer (the Arc Relay API) then calls relay(), which:
 *   1. Calls MessageTransmitter.receiveMessage() to mint USDC to itself.
 *   2. Transfers relayFee() USDC to feeRecipient().
 *   3. Transfers the remainder to the user's wallet (recipient parameter).
 *
 * Deployed addresses (all testnet):
 *   Arc Testnet    (5042002)  — 0x837D9a19C07bb7B4E95071dC0BaED72D4dE04ea1
 *   Ethereum Sepolia (11155111) — 0x5E87F210043D8457caCAd0F0c9aB70a99497Eec9
 *   Base Sepolia   (84532)    — 0x64D160b7E91e78e52dFc0e8829640E32A919164C
 *   Avalanche Fuji (43113)    — 0x6F80056564491425273A6a481EcC5DAea9D57f23
 *
 * Integration pattern for dApps:
 * ─────────────────────────────
 *   1. User calls TokenMessenger.depositForBurn with:
 *        mintRecipient = bytes32(uint256(uint160(gasRelayerAddress)))
 *      (left-padded to 32 bytes as required by CCTP V2)
 *   2. After attestation is ready, POST to the Arc Relay API:
 *        POST https://arc-relay-bridge.replit.app/api/relay
 *        { message, attestation, recipient, destChainId, maxFee }
 *   3. The API calls relay() on-chain; user receives USDC without needing gas.
 */
interface IGasRelayer {
    // ── Events ────────────────────────────────────────────────────────────────

    /// @notice Emitted after a successful relay.
    /// @param recipient   Wallet that received the net USDC.
    /// @param grossAmount Total USDC minted to this contract by the CCTP message.
    /// @param fee         Relay fee deducted and sent to feeRecipient.
    event Relayed(address indexed recipient, uint256 grossAmount, uint256 fee);

    // ── Core ─────────────────────────────────────────────────────────────────

    /**
     * @notice Relay a CCTP message: mint USDC to this contract and forward
     *         (amount - relayFee) to `recipient`.
     *
     * @param message     Raw CCTP message bytes emitted by the source-chain burn event.
     * @param attestation Circle Iris attestation signature for the message.
     * @param recipient   Actual user wallet that should receive the net USDC.
     * @param maxFee      Maximum relay fee the caller accepts (slippage guard).
     *                    Reverts if relayFee() > maxFee at call time.
     */
    function relay(
        bytes calldata message,
        bytes calldata attestation,
        address recipient,
        uint256 maxFee
    ) external;

    // ── View ─────────────────────────────────────────────────────────────────

    /// @notice Current flat relay fee in USDC units (6 decimals).
    function relayFee() external view returns (uint256);

    /// @notice Address that receives the relay fee on each successful relay.
    function feeRecipient() external view returns (address);

    /// @notice USDC contract address on this chain.
    function usdc() external view returns (address);

    /// @notice CCTP MessageTransmitter address on this chain.
    function messageTransmitter() external view returns (address);

    /// @notice Whether the contract is paused (relay() will revert).
    function paused() external view returns (bool);

    /// @notice Maximum relay fee that can ever be set (5 USDC = 5_000_000 units).
    function MAX_RELAY_FEE() external view returns (uint256);

    // ── Admin (owner-only) ───────────────────────────────────────────────────

    /// @notice Update the relay fee (capped at MAX_RELAY_FEE).
    function setRelayFee(uint256 newFee) external;

    /// @notice Update the fee recipient wallet.
    function setFeeRecipient(address newRecipient) external;

    /// @notice Pause the relay() function.
    function pause() external;

    /// @notice Unpause the relay() function.
    function unpause() external;

    /// @notice Initiate a two-step ownership transfer.
    function transferOwnership(address newOwner) external;

    /// @notice Complete a pending two-step ownership transfer (called by new owner).
    function acceptOwnership() external;

    /// @notice Rescue accidentally sent ERC-20 tokens.
    function rescueTokens(address token, address to, uint256 amount) external;
}
