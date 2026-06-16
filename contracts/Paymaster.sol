// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title Paymaster
 * @notice USDC-funded gas sponsorship vault. Users pre-deposit USDC so they never
 *         need native tokens to transact — a trusted relayer pays gas and deducts
 *         the USDC equivalent from the user's on-chain balance.
 *
 * Supports two sponsorship paths:
 *   A. Legacy relayer path  — relayer calls deductGas() after executing meta-txs.
 *   B. ERC-4337 v0.7 path  — EntryPoint calls validatePaymasterUserOp() + postOp()
 *                            so any ERC-4337 AA wallet (Pimlico, ZeroDev, etc.)
 *                            can use USDC deposits to pay gas with no ETH needed.
 *
 * Flow (ERC-4337)
 * ────────────────
 *   1. User deposits USDC via deposit().
 *   2. User submits a UserOperation specifying this contract as paymaster.
 *   3. EntryPoint calls validatePaymasterUserOp() — reserves max USDC cost.
 *   4. EntryPoint executes the UserOperation.
 *   5. EntryPoint calls postOp() — releases reservation, charges actual cost.
 *
 * Security properties
 * ───────────────────
 *   - Only the EntryPoint may call validatePaymasterUserOp / postOp.
 *   - Only the owner-designated relayer may call deductGas.
 *   - All deductions capped at MAX_DEDUCTION_PER_TX (10 USDC) per call.
 *   - ERC-4337 reservations prevent double-spending during pending UserOps.
 *   - withdraw() only allows unlocked (unreserved) funds.
 *   - Reentrancy lock on deposit, withdraw, deductGas, and postOp.
 *   - Emergency pause (owner only).
 *   - Two-step ownership transfer.
 *   - rescueTokens blocks rescue of USDC to protect user deposits.
 */
contract Paymaster {
    address public immutable usdc;

    /// @dev ERC-4337 v0.7 EntryPoint — deployed via CREATE2, same on every EVM chain.
    address public constant entryPoint = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    address public owner;
    address public pendingOwner;
    address public relayer;
    address public feeRecipient;

    /**
     * @notice USDC cost per unit of gas (6-decimal units).
     *         Example: gasRate=2 means 0.000002 USDC per gas unit.
     *         Frontend uses this value to estimate sponsorship cost before deposit.
     */
    uint256 public gasRate;

    bool public paused;
    bool private _locked;

    /// @dev Hard cap: 10 USDC per deductGas / postOp call.
    uint256 public constant MAX_DEDUCTION_PER_TX = 10_000_000;

    /// @dev Hard cap on gasRate: 1 USDC per gas unit.
    uint256 public constant MAX_GAS_RATE = 1_000_000;

    mapping(address => uint256) public balances;

    /// @dev ERC-4337: amounts currently reserved by pending UserOperations.
    ///      locked[user] <= balances[user] is a class invariant.
    mapping(address => uint256) public locked;

    // ── ERC-4337 v0.7 types ────────────────────────────────────────────────

    enum PostOpMode { opSucceeded, opReverted, postOpReverted }

    struct PackedUserOperation {
        address sender;
        uint256 nonce;
        bytes   initCode;
        bytes   callData;
        bytes32 accountGasLimits;   // pack(verificationGasLimit, callGasLimit)
        uint256 preVerificationGas;
        bytes32 gasFees;            // pack(maxPriorityFeePerGas, maxFeePerGas)
        bytes   paymasterAndData;
        bytes   signature;
    }

    // ── Events ────────────────────────────────────────────────────────────────

    event Deposited(address indexed user, uint256 amount, uint256 newBalance);
    event Withdrawn(address indexed user, uint256 amount, uint256 remaining);
    event GasSponsored(address indexed user, uint256 usdcDeducted, uint256 remainingBalance);
    event RelayerSet(address indexed oldRelayer, address indexed newRelayer);
    event FeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);
    event GasRateSet(uint256 oldRate, uint256 newRate);
    event OwnershipTransferStarted(address indexed newOwner);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event Paused();
    event Unpaused();

    // ── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "Paymaster: not owner");
        _;
    }

    modifier onlyRelayer() {
        require(msg.sender == relayer, "Paymaster: not relayer");
        _;
    }

    modifier onlyEntryPoint() {
        require(msg.sender == entryPoint, "Paymaster: not EntryPoint");
        _;
    }

    modifier nonReentrant() {
        require(!_locked, "Paymaster: reentrant");
        _locked = true;
        _;
        _locked = false;
    }

    modifier whenNotPaused() {
        require(!paused, "Paymaster: paused");
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    /**
     * @param _usdc          USDC token on this chain (6-decimal ERC-20).
     * @param _relayer       Trusted relayer address allowed to call deductGas.
     * @param _feeRecipient  Wallet that receives USDC deducted for gas costs.
     * @param _gasRate       Initial USDC-per-gas-unit rate (6 decimals).
     */
    constructor(
        address _usdc,
        address _relayer,
        address _feeRecipient,
        uint256 _gasRate
    ) {
        require(_usdc         != address(0), "Paymaster: zero usdc");
        require(_relayer      != address(0), "Paymaster: zero relayer");
        require(_feeRecipient != address(0), "Paymaster: zero fee recipient");

        // FIX: enforce MAX_GAS_RATE in constructor — setGasRate() enforces it
        // but the constructor previously had no upper-bound check, allowing
        // a deployment to silently bypass the cap.
        require(_gasRate <= MAX_GAS_RATE, "Paymaster: rate exceeds max");

        usdc         = _usdc;
        relayer      = _relayer;
        feeRecipient = _feeRecipient;
        gasRate      = _gasRate;
        owner        = msg.sender;
    }

    // ── User functions ────────────────────────────────────────────────────────

    /**
     * @notice Deposit USDC to fund gas sponsorship for this wallet.
     * @param amount USDC amount (6 decimals).
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Paymaster: zero amount");
        require(
            IERC20(usdc).transferFrom(msg.sender, address(this), amount),
            "Paymaster: transferFrom failed"
        );
        balances[msg.sender] += amount;
        emit Deposited(msg.sender, amount, balances[msg.sender]);
    }

    /**
     * @notice Withdraw unspent USDC from your gas balance.
     *         Only unlocked (not reserved by a pending UserOperation) funds may be withdrawn.
     * @param amount USDC to withdraw. Pass type(uint256).max to withdraw all unlocked funds.
     */
    function withdraw(uint256 amount) external nonReentrant {
        uint256 bal      = balances[msg.sender];
        uint256 lk       = locked[msg.sender];
        uint256 unlocked = bal > lk ? bal - lk : 0;
        if (amount == type(uint256).max) amount = unlocked;
        require(amount   > 0,        "Paymaster: zero amount");
        require(unlocked >= amount,  "Paymaster: insufficient unlocked balance");
        balances[msg.sender] = bal - amount;
        require(
            IERC20(usdc).transfer(msg.sender, amount),
            "Paymaster: transfer failed"
        );
        emit Withdrawn(msg.sender, amount, balances[msg.sender]);
    }

    // ── Relayer functions (legacy path) ───────────────────────────────────────

    /**
     * @notice Deduct USDC from a user's deposit to reimburse the relayer for gas.
     *         Called by the trusted relayer after executing a sponsored meta-transaction.
     * @param user      Wallet whose balance to deduct.
     * @param usdcCost  Gas cost denominated in USDC (6 decimals). Max 10 USDC.
     */
    function deductGas(address user, uint256 usdcCost)
        external
        nonReentrant
        onlyRelayer
        whenNotPaused
    {
        require(user     != address(0),          "Paymaster: zero user");
        require(usdcCost  > 0,                   "Paymaster: zero cost");
        require(usdcCost <= MAX_DEDUCTION_PER_TX, "Paymaster: exceeds cap");

        // Only unlocked funds may be deducted — locked funds are reserved by
        // pending ERC-4337 UserOperations and must not be touched until postOp.
        uint256 bal       = balances[user];
        uint256 lk        = locked[user];
        uint256 available = bal > lk ? bal - lk : 0;
        require(available >= usdcCost, "Paymaster: user underfunded");

        balances[user] = bal - usdcCost;
        require(
            IERC20(usdc).transfer(feeRecipient, usdcCost),
            "Paymaster: fee transfer failed"
        );
        emit GasSponsored(user, usdcCost, balances[user]);
    }

    // ── ERC-4337 v0.7 path ────────────────────────────────────────────────────

    /**
     * @notice ERC-4337 v0.7: called by EntryPoint during validation phase.
     *         Reserves the estimated max USDC cost so it cannot be double-spent
     *         by a concurrent withdraw or another UserOperation.
     *
     * @param userOp   The packed UserOperation being validated.
     * @param maxCost  Maximum native-token cost of the UserOperation (wei).
     * @return context   ABI-encoded (user, reservedAmount) forwarded to postOp.
     * @return validationData  0 = valid (no signature check, no expiry).
     */
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32,
        uint256 maxCost
    )
        external
        onlyEntryPoint
        whenNotPaused
        returns (bytes memory context, uint256 validationData)
    {
        address user = userOp.sender;
        require(user != address(0), "Paymaster: zero user");

        // Derive max USDC cost from maxCost (wei) and gasRate.
        // gasFees = abi.encodePacked(uint128 maxPriorityFeePerGas, uint128 maxFeePerGas)
        // maxFeePerGas occupies the lower 128 bits.
        uint256 maxFeePerGas = uint128(uint256(userOp.gasFees));
        uint256 maxUsdcCost;
        if (maxFeePerGas > 0) {
            uint256 maxGasUnits = maxCost / maxFeePerGas;
            maxUsdcCost = maxGasUnits * gasRate;
        }
        // Cap and use cap as fallback when estimate is 0 (e.g. gasRate not set).
        if (maxUsdcCost == 0 || maxUsdcCost > MAX_DEDUCTION_PER_TX) {
            maxUsdcCost = MAX_DEDUCTION_PER_TX;
        }

        uint256 bal       = balances[user];
        uint256 lk        = locked[user];
        uint256 available = bal > lk ? bal - lk : 0;
        require(available >= maxUsdcCost, "Paymaster: insufficient balance");

        locked[user] = lk + maxUsdcCost;

        return (abi.encode(user, maxUsdcCost), 0);
    }

    /**
     * @notice ERC-4337 v0.7: called by EntryPoint after UserOperation execution.
     *         Releases the reservation and charges the actual USDC cost.
     *
     * @param mode                  opSucceeded / opReverted / postOpReverted.
     * @param context               ABI-encoded (user, reservedAmount) from validatePaymasterUserOp.
     * @param actualGasCost         Actual native-token cost (wei).
     * @param actualUserOpFeePerGas Actual gas price used (wei per gas unit).
     */
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external nonReentrant onlyEntryPoint {
        (address user, uint256 reserved) = abi.decode(context, (address, uint256));

        // Always release the reservation first.
        uint256 lk = locked[user];
        locked[user] = lk > reserved ? lk - reserved : 0;

        // In postOpReverted mode the EntryPoint already reverted the inner call;
        // release the lock and do not charge anything.
        if (mode == PostOpMode.postOpReverted) return;

        // Calculate actual USDC cost from gas units × rate.
        uint256 actualUsdcCost;
        if (actualUserOpFeePerGas > 0 && gasRate > 0) {
            uint256 actualGasUnits = actualGasCost / actualUserOpFeePerGas;
            actualUsdcCost = actualGasUnits * gasRate;
        }
        if (actualUsdcCost > MAX_DEDUCTION_PER_TX) actualUsdcCost = MAX_DEDUCTION_PER_TX;
        if (actualUsdcCost == 0) return;

        // Charge the user (cap at their available balance — they already passed validation).
        uint256 bal = balances[user];
        if (bal < actualUsdcCost) actualUsdcCost = bal;
        if (actualUsdcCost == 0) return;

        balances[user] = bal - actualUsdcCost;
        require(
            IERC20(usdc).transfer(feeRecipient, actualUsdcCost),
            "Paymaster: fee transfer failed"
        );
        emit GasSponsored(user, actualUsdcCost, balances[user]);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setRelayer(address newRelayer) external onlyOwner {
        require(newRelayer != address(0), "Paymaster: zero address");
        emit RelayerSet(relayer, newRelayer);
        relayer = newRelayer;
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Paymaster: zero address");
        emit FeeRecipientSet(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    function setGasRate(uint256 newRate) external onlyOwner {
        require(newRate <= MAX_GAS_RATE, "Paymaster: rate exceeds max");
        emit GasRateSet(gasRate, newRate);
        gasRate = newRate;
    }

    function pause()   external onlyOwner { paused = true;  emit Paused(); }
    function unpause() external onlyOwner { paused = false; emit Unpaused(); }

    /// @notice Initiate two-step ownership transfer.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Paymaster: zero address");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(newOwner);
    }

    /// @notice Complete ownership transfer — must be called by the new owner.
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "Paymaster: not pending owner");
        emit OwnershipTransferred(owner, pendingOwner);
        owner        = pendingOwner;
        pendingOwner = address(0);
    }

    /**
     * @notice Rescue ERC-20 tokens accidentally sent to this contract.
     *         Explicitly blocks rescue of the USDC token to protect user deposits.
     */
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        require(to    != address(0), "Paymaster: zero address");
        require(token != usdc,       "Paymaster: cannot rescue USDC deposits");
        require(IERC20(token).transfer(to, amount), "Paymaster: rescue failed");
    }
}
