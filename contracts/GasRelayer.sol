// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IMessageTransmitter {
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool);
}

/**
 * @title GasRelayer
 * @notice Receives CCTP cross-chain USDC burns on behalf of users who lack
 *         destination-chain gas. A trusted relayer calls relay() which mints
 *         USDC to this contract (as the mintRecipient) and forwards
 *         (amount - relayFee) to the actual user wallet.
 *
 * Deployment: one instance per chain. The mintRecipient in the CCTP burn
 * message must be set to this contract's address (bytes32 left-padded).
 *
 * Security properties:
 *   - Reentrancy lock on relay()
 *   - relayFee capped at MAX_RELAY_FEE (5 USDC)
 *   - maxFee parameter prevents fee-griefing between submission and execution
 *   - Emergency pause
 *   - Two-step ownership transfer
 *   - rescueTokens cannot be called re-entrantly
 */
contract GasRelayer {
    address public immutable usdc;
    address public immutable messageTransmitter;

    address public owner;
    address public pendingOwner;
    address public feeRecipient;
    uint256 public relayFee;       // flat fee in USDC units (6 decimals)
    bool    public paused;

    bool private _locked;

    /// @dev 5 USDC — generous ceiling for any testnet or L2 gas cost.
    uint256 public constant MAX_RELAY_FEE = 5_000_000;

    event Relayed(address indexed recipient, uint256 grossAmount, uint256 fee);
    event RelayFeeSet(uint256 oldFee, uint256 newFee);
    event FeeRecipientSet(address oldRecipient, address newRecipient);
    event OwnershipTransferStarted(address indexed newOwner);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event Paused();
    event Unpaused();

    modifier nonReentrant() {
        require(!_locked, "GasRelayer: reentrant");
        _locked = true;
        _;
        _locked = false;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "GasRelayer: not owner");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "GasRelayer: paused");
        _;
    }

    constructor(
        address _usdc,
        address _messageTransmitter,
        address _feeRecipient,
        uint256 _relayFee
    ) {
        require(_usdc               != address(0), "GasRelayer: zero usdc");
        require(_messageTransmitter != address(0), "GasRelayer: zero transmitter");
        require(_feeRecipient       != address(0), "GasRelayer: zero fee recipient");
        require(_relayFee <= MAX_RELAY_FEE,        "GasRelayer: fee too high");

        usdc               = _usdc;
        messageTransmitter = _messageTransmitter;
        feeRecipient       = _feeRecipient;
        relayFee           = _relayFee;
        owner              = msg.sender;
    }

    /**
     * @notice Relay a CCTP burn message: mint USDC to this contract and
     *         forward (amount - relayFee) to `recipient`.
     * @param message     Raw CCTP message bytes emitted by the source-chain burn.
     * @param attestation Circle Iris attestation signature.
     * @param recipient   Actual user wallet that should receive the USDC.
     * @param maxFee      Maximum relay fee the user accepted at bridge time (slippage guard).
     */
    function relay(
        bytes calldata message,
        bytes calldata attestation,
        address recipient,
        uint256 maxFee
    ) external nonReentrant whenNotPaused {
        require(recipient != address(0), "GasRelayer: zero recipient");
        require(relayFee  <= maxFee,     "GasRelayer: fee exceeds maxFee");

        uint256 before = IERC20(usdc).balanceOf(address(this));

        // MessageTransmitter validates the attestation and calls
        // TokenMessenger.handleReceiveMessage → mints USDC to mintRecipient (= this contract).
        bool ok = IMessageTransmitter(messageTransmitter).receiveMessage(message, attestation);
        require(ok, "GasRelayer: receiveMessage failed");

        uint256 received = IERC20(usdc).balanceOf(address(this)) - before;
        require(received > relayFee, "GasRelayer: amount too small to cover fee");

        uint256 net = received - relayFee;

        require(IERC20(usdc).transfer(feeRecipient, relayFee), "GasRelayer: fee transfer failed");
        require(IERC20(usdc).transfer(recipient,    net),      "GasRelayer: net transfer failed");

        emit Relayed(recipient, received, relayFee);
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    function setRelayFee(uint256 newFee) external onlyOwner {
        require(newFee <= MAX_RELAY_FEE, "GasRelayer: fee too high");
        emit RelayFeeSet(relayFee, newFee);
        relayFee = newFee;
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "GasRelayer: zero address");
        emit FeeRecipientSet(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    function pause()   external onlyOwner { paused = true;  emit Paused(); }
    function unpause() external onlyOwner { paused = false; emit Unpaused(); }

    /// @notice Initiate two-step ownership transfer.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "GasRelayer: zero address");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(newOwner);
    }

    /// @notice Complete two-step ownership transfer — must be called by the new owner.
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "GasRelayer: not pending owner");
        emit OwnershipTransferred(owner, pendingOwner);
        owner        = pendingOwner;
        pendingOwner = address(0);
    }

    /**
     * @notice Rescue ERC-20 tokens accidentally sent to this contract.
     *         Cannot be called re-entrantly (nonReentrant on relay guards this).
     */
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "GasRelayer: zero address");
        require(IERC20(token).transfer(to, amount), "GasRelayer: rescue failed");
    }
}
