// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ComposableReceiver
 * @notice Example: a dApp contract on Arc Testnet that receives CCTP-bridged USDC
 *         via the Arc Relay GasRelayer paymaster, then performs custom logic
 *         (e.g. deposit into a vault, swap, stake) without the user needing gas.
 *
 * ─── Integration flow ───────────────────────────────────────────────────────
 *
 *   Source chain (e.g. Sepolia):
 *     1. User approves TokenMessenger for bridgeAmount USDC.
 *     2. User calls TokenMessenger.depositForBurn with:
 *          mintRecipient = bytes32(uint256(uint160(address(this))))
 *          destinationDomain = <Arc CCTP domain: 26>
 *        (This contract, not the user wallet, is the CCTP mintRecipient.)
 *
 *   Arc Testnet (destination):
 *     3. Off-chain relayer (or the user) POSTs to the Arc Relay API:
 *          POST https://arc-relay-bridge.replit.app/api/relay
 *          { message, attestation, recipient: address(this), destChainId: 5042002, maxFee }
 *     4. GasRelayer.relay() mints USDC to the GasRelayer, deducts relay fee,
 *        and calls IERC20(usdc).transfer(address(this), net).
 *     5. This contract's receive hook (onUsdcReceived) is called to run custom logic.
 *
 * ─── Note ────────────────────────────────────────────────────────────────────
 * Because GasRelayer uses a plain ERC-20 transfer (not a call), this contract
 * does NOT automatically receive a callback. Instead, integrate by:
 *   a) Having a separate function the relayer calls after transfer, or
 *   b) Implementing a "pull" pattern: GasRelayer transfers USDC to this contract,
 *      then any party calls processIncoming() to execute the vault logic.
 *
 * This example demonstrates approach (b) — a pull-based vault deposit.
 */

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface ISimpleVault {
    function deposit(uint256 amount, address onBehalfOf) external;
}

contract ComposableReceiver {
    IERC20        public immutable usdc;
    ISimpleVault  public immutable vault;

    /// @notice Map from user address → pending USDC balance waiting to be deposited.
    mapping(address => uint256) public pendingDeposit;

    event UsdcReceived(address indexed from, uint256 amount);
    event VaultDeposited(address indexed user, uint256 amount);

    error NothingToDeposit();

    constructor(address _usdc, address _vault) {
        usdc  = IERC20(_usdc);
        vault = ISimpleVault(_vault);
    }

    /**
     * @notice Called by the off-chain relayer after GasRelayer.relay() transfers
     *         USDC to this contract. Records pending deposits for each user.
     *
     * @param user   The original source-chain sender (must match what was recorded off-chain).
     * @param amount Expected USDC amount; used as a sanity check against the live balance.
     */
    function recordIncoming(address user, uint256 amount) external {
        uint256 balance = usdc.balanceOf(address(this));
        uint256 credit  = balance < amount ? balance : amount;

        pendingDeposit[user] += credit;
        emit UsdcReceived(user, credit);
    }

    /**
     * @notice Anyone can trigger a vault deposit for a user who has pending USDC.
     *         Designed to be called by the relayer immediately after recordIncoming().
     *
     * @param user  The user whose pending balance should be deposited.
     */
    function processIncoming(address user) external {
        uint256 amount = pendingDeposit[user];
        if (amount == 0) revert NothingToDeposit();

        pendingDeposit[user] = 0;

        usdc.approve(address(vault), amount);
        vault.deposit(amount, user);

        emit VaultDeposited(user, amount);
    }

    /**
     * @notice Emergency: owner can sweep USDC out if stuck.
     *         In production, add an onlyOwner modifier.
     */
    function rescueUsdc(address to, uint256 amount) external {
        usdc.transfer(to, amount);
    }
}
