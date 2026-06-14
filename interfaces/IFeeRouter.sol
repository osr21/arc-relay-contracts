// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IFeeRouter
 * @notice Interface for the Arc Relay Bridge FeeRouter v2 protocol fee contract.
 *
 * The FeeRouter collects the 0.30% protocol fee on each bridge transfer.
 * The fee is paid on the source chain via a plain ERC-20 transfer before the
 * CCTP burn — no smart contract interaction required from the user for bridging,
 * but the FeeRouter's depositForBurn wrapper handles the full flow atomically.
 *
 * Deployed addresses (all testnet):
 *   Arc Testnet    (5042002)  — 0x8256a1e1f8971448b49dA0F55b8A1BB6557eA8FC
 *   Ethereum Sepolia (11155111) — 0x5B1F511ed4dF76f369671BF1c4aCF0dD84CC0804
 *   Base Sepolia   (84532)    — 0x8d4B57eD464df10414Dde3ADC2E403a01ebc50d8
 *   Avalanche Fuji (43113)    — 0x64D160b7E91e78e52dFc0e8829640E32A919164C
 */
interface IFeeRouter {
    // ── Events ────────────────────────────────────────────────────────────────

    /// @notice Emitted when a fee is collected.
    /// @param payer     Address that paid the fee.
    /// @param amount    Fee amount in USDC units (6 decimals).
    /// @param recipient Fee recipient wallet.
    event FeeCollected(address indexed payer, uint256 amount, address indexed recipient);

    // ── Core ─────────────────────────────────────────────────────────────────

    /**
     * @notice Collect the protocol fee from msg.sender, then call
     *         TokenMessenger.depositForBurn for the net amount.
     *
     * Caller must have approved this contract for `grossAmount` USDC.
     *
     * @param grossAmount          Total USDC to bridge (including fee), in units.
     * @param destinationDomain    CCTP domain of the destination chain.
     * @param mintRecipient        Recipient on the destination chain (bytes32).
     * @param destinationCaller    Who may call receiveMessage (bytes32(0) = anyone).
     * @param maxFee               CCTP V2 maxFee parameter.
     * @param minFinalityThreshold CCTP V2 finality threshold.
     */
    function bridgeWithFee(
        uint256 grossAmount,
        uint32  destinationDomain,
        bytes32 mintRecipient,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32  minFinalityThreshold
    ) external;

    // ── View ─────────────────────────────────────────────────────────────────

    /// @notice Protocol fee in basis points (30 = 0.30%).
    function feeBps() external view returns (uint256);

    /// @notice Wallet that receives the collected protocol fees.
    function feeRecipient() external view returns (address);

    /// @notice USDC contract on this chain (immutable).
    function usdc() external view returns (address);

    /// @notice CCTP V2 TokenMessenger on this chain (immutable).
    function tokenMessenger() external view returns (address);
}
