// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title YieldVault
 * @notice Simulated USDC yield vault for the Arc Relay Bridge yield routing demo.
 *
 * Users deposit USDC and earn simulated yield at an APY set by the owner.
 * The vault tracks per-user principal and accumulated yield using a checkpoint
 * pattern so multiple deposits/withdrawals are handled correctly.
 *
 * Yield is SIMULATED — real USDC is minted only if the vault is pre-funded
 * by the owner. On testnet, users always receive at least their principal back.
 *
 * Deploy with different APYs on each chain to incentivize cross-chain rebalancing:
 *   Arc Testnet    — 18.5% APY (highest)
 *   Base Sepolia   — 12.3% APY
 *   Avalanche Fuji —  9.2% APY
 *   Eth Sepolia    —  7.8% APY (lowest)
 */

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract YieldVault {
    IERC20  public immutable usdc;
    address public owner;
    address public pendingOwner;

    /// @notice Annual percentage yield in basis points (e.g. 1850 = 18.5%).
    uint256 public apyBps;
    /// @notice Human-readable label shown in the UI.
    string  public vaultName;
    /// @notice Total USDC deposited by users (not counting yield).
    uint256 public totalDeposited;

    struct Position {
        uint256 principal;        // USDC currently deposited
        uint256 checkpointYield;  // yield accrued before last deposit update
        uint256 lastTimestamp;    // block.timestamp at last deposit/checkpoint
    }

    mapping(address => Position) public positions;

    // ── Events ────────────────────────────────────────────────────────────────
    event Deposited(address indexed user, uint256 amount, uint256 newPrincipal);
    event Withdrawn(address indexed user, uint256 principal, uint256 yieldPaid, uint256 total);
    event ApyUpdated(uint256 oldApyBps, uint256 newApyBps);
    event VaultFunded(address indexed funder, uint256 amount);
    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ── Errors ────────────────────────────────────────────────────────────────
    error NotOwner();
    error NotPendingOwner();
    error ZeroUsdc();
    error ZeroAmount();
    error NoPosition();
    error ApyTooHigh();
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _usdc, uint256 _apyBps, string memory _vaultName) {
        if (_usdc == address(0)) revert ZeroUsdc();
        if (_apyBps > 50_000)   revert ApyTooHigh(); // max 500%
        usdc      = IERC20(_usdc);
        apyBps    = _apyBps;
        vaultName = _vaultName;
        owner     = msg.sender;
    }

    // ── Core ─────────────────────────────────────────────────────────────────

    /**
     * @notice Deposit USDC into the vault.
     * @param amount Amount of USDC to deposit (6 decimals).
     */
    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        Position storage pos = positions[msg.sender];

        // Checkpoint any yield that has accrued on the existing principal
        // before we change the principal amount.
        if (pos.principal > 0 && pos.lastTimestamp > 0) {
            pos.checkpointYield += _computeYield(pos.principal, pos.lastTimestamp);
        }

        pos.principal    += amount;
        pos.lastTimestamp = block.timestamp;
        totalDeposited   += amount;

        if (!usdc.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit Deposited(msg.sender, amount, pos.principal);
    }

    /**
     * @notice Withdraw the full position (principal + accrued yield).
     *         If the vault lacks sufficient USDC to cover yield, the user
     *         receives only the available balance (principal is always safe).
     * @return received Actual USDC transferred to the caller.
     */
    function withdraw() external returns (uint256 received) {
        Position storage pos = positions[msg.sender];
        if (pos.principal == 0) revert NoPosition();

        uint256 yieldEarned = pos.checkpointYield
            + _computeYield(pos.principal, pos.lastTimestamp);
        uint256 total = pos.principal + yieldEarned;

        // Cap at vault's available USDC balance (yield is only paid if funded)
        uint256 available = usdc.balanceOf(address(this));
        received = total > available ? available : total;

        uint256 yieldPaid = received > pos.principal ? received - pos.principal : 0;

        totalDeposited -= pos.principal;
        delete positions[msg.sender];

        if (!usdc.transfer(msg.sender, received)) revert TransferFailed();
        emit Withdrawn(msg.sender, pos.principal, yieldPaid, received);
    }

    // ── View ─────────────────────────────────────────────────────────────────

    /// @notice Yield accrued since the last deposit (not yet claimed).
    function pendingYield(address user) public view returns (uint256) {
        Position storage pos = positions[user];
        if (pos.principal == 0) return 0;
        return pos.checkpointYield + _computeYield(pos.principal, pos.lastTimestamp);
    }

    /// @notice Current value of the position (principal + pending yield).
    function currentValue(address user) public view returns (uint256) {
        return positions[user].principal + pendingYield(user);
    }

    /// @notice APY as a human-readable percentage (e.g. 1850 → "18.50%").
    function apyPercent() external view returns (uint256 whole, uint256 frac) {
        whole = apyBps / 100;
        frac  = apyBps % 100;
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    function _computeYield(uint256 principal, uint256 since) internal view returns (uint256) {
        if (since == 0 || block.timestamp <= since) return 0;
        uint256 elapsed = block.timestamp - since;
        // yield = principal × apyBps × elapsed / (10000 × 365 days)
        return (principal * apyBps * elapsed) / (10_000 * 365 days);
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    /// @notice Update the APY (max 500% = 50000 bps).
    function setApy(uint256 newApyBps) external onlyOwner {
        if (newApyBps > 50_000) revert ApyTooHigh();
        emit ApyUpdated(apyBps, newApyBps);
        apyBps = newApyBps;
    }

    /// @notice Update the vault name shown in the UI.
    function setVaultName(string calldata newName) external onlyOwner {
        vaultName = newName;
    }

    /// @notice Pre-fund the vault with extra USDC to cover simulated yield payouts.
    function fundVault(uint256 amount) external {
        if (!usdc.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit VaultFunded(msg.sender, amount);
    }

    /// @notice Rescue accidentally sent tokens or recover surplus yield capacity.
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        if (!IERC20(token).transfer(to, amount)) revert TransferFailed();
    }

    /// @notice Initiate two-step ownership transfer.
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Accept ownership (called by pending owner).
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner        = msg.sender;
        pendingOwner = address(0);
    }
}
