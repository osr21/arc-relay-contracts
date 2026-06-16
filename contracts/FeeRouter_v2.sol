// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title FeeRouter v2
 * @notice Collects a protocol fee and forwards the net amount to Circle's CCTP V2
 *         TokenMessenger in a single user transaction.
 *
 * Security hardening over v1
 * ──────────────────────────
 *   - Immutable usdc and tokenMessenger (set at deploy, not caller-supplied).
 *     Eliminates the risk of a caller routing funds through an attacker-controlled
 *     token or messenger.
 *   - Reentrancy lock on bridge().
 *   - Zero mintRecipient check — prevents burning to the zero address.
 *   - rescueTokens() return-value check — surfaces ERC-20 failures that don't revert.
 *   - Two-step ownership transfer — prevents permanent ownership loss on typo.
 */

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev CCTP V2 TokenMessenger — selector 0x8e0250ee (7 params)
interface ITokenMessengerV2 {
    function depositForBurn(
        uint256 amount,
        uint32  destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32  minFinalityThreshold
    ) external returns (uint64 nonce);
}

contract FeeRouter {

    // ── Immutable configuration ───────────────────────────────────────────────
    /// @notice USDC token on this chain (6-decimal ERC-20).
    address public immutable usdc;
    /// @notice Circle CCTP V2 TokenMessenger on this chain.
    address public immutable tokenMessenger;

    // ── Mutable admin state ──────────────────────────────────────────────────
    address public owner;
    /// @notice Pending owner for two-step transfer (zero = no transfer in progress).
    address public pendingOwner;
    address public feeRecipient;
    uint256 public feeBps;

    uint256 public constant MAX_FEE_BPS = 500; // 5% hard cap

    // ── Reentrancy lock ──────────────────────────────────────────────────────
    bool private _locked;

    // ── Events ───────────────────────────────────────────────────────────────
    event BridgeInitiated(
        address indexed sender,
        uint256 grossAmount,
        uint256 feeAmount,
        uint256 bridgeAmount,
        uint32  destinationDomain,
        bytes32 mintRecipient
    );
    event FeeUpdated(uint256 oldBps, uint256 newBps);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    // FIX: split into started + completed to match two-step pattern
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyOwner() {
        require(msg.sender == owner, "FeeRouter: not owner");
        _;
    }

    modifier nonReentrant() {
        require(!_locked, "FeeRouter: reentrant call");
        _locked = true;
        _;
        _locked = false;
    }

    // ── Constructor ──────────────────────────────────────────────────────────
    /**
     * @param _feeRecipient    Address that receives protocol fees.
     * @param _feeBps          Fee in basis points (max 500 = 5%).
     * @param _usdc            USDC token address on this chain.
     * @param _tokenMessenger  Circle CCTP V2 TokenMessenger on this chain.
     */
    constructor(
        address _feeRecipient,
        uint256 _feeBps,
        address _usdc,
        address _tokenMessenger
    ) {
        require(_feeRecipient   != address(0), "FeeRouter: zero fee recipient");
        require(_usdc           != address(0), "FeeRouter: zero usdc");
        require(_tokenMessenger != address(0), "FeeRouter: zero tokenMessenger");
        require(_feeBps <= MAX_FEE_BPS,        "FeeRouter: fee too high");

        owner          = msg.sender;
        feeRecipient   = _feeRecipient;
        feeBps         = _feeBps;
        usdc           = _usdc;
        tokenMessenger = _tokenMessenger;
    }

    // ── Core bridge function ─────────────────────────────────────────────────
    /**
     * @notice Bridge USDC cross-chain via CCTP V2 with protocol fee deduction.
     * @param grossAmount          Total USDC (6 decimals) to pull from caller.
     * @param destinationDomain    CCTP domain ID of the destination chain.
     * @param mintRecipient        32-byte padded recipient on destination (non-zero).
     * @param minFinalityThreshold CCTP V2 finality threshold (2000=finalized, 1000=safe).
     * @return nonce               CCTP burn nonce from the TokenMessenger.
     */
    function bridge(
        uint256 grossAmount,
        uint32  destinationDomain,
        bytes32 mintRecipient,
        uint32  minFinalityThreshold
    ) external nonReentrant returns (uint64 nonce) {
        require(grossAmount    > 0,          "FeeRouter: zero amount");
        require(mintRecipient != bytes32(0), "FeeRouter: zero recipient");

        require(
            IERC20(usdc).transferFrom(msg.sender, address(this), grossAmount),
            "FeeRouter: transferFrom failed"
        );

        uint256 feeAmount    = (grossAmount * feeBps) / 10000;
        uint256 bridgeAmount = grossAmount - feeAmount;
        require(bridgeAmount > 0, "FeeRouter: bridge amount zero");

        if (feeAmount > 0) {
            require(
                IERC20(usdc).transfer(feeRecipient, feeAmount),
                "FeeRouter: fee transfer failed"
            );
        }

        require(
            IERC20(usdc).approve(tokenMessenger, bridgeAmount),
            "FeeRouter: approve failed"
        );

        // CCTP V2: destinationCaller=0 (anyone may relay), maxFee=0 (no premium)
        nonce = ITokenMessengerV2(tokenMessenger).depositForBurn(
            bridgeAmount,
            destinationDomain,
            mintRecipient,
            usdc,
            bytes32(0), // destinationCaller = anyone
            0,          // maxFee = 0
            minFinalityThreshold
        );

        emit BridgeInitiated(
            msg.sender,
            grossAmount,
            feeAmount,
            bridgeAmount,
            destinationDomain,
            mintRecipient
        );
    }

    // ── Admin: fee management ────────────────────────────────────────────────
    function setFeeBps(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= MAX_FEE_BPS, "FeeRouter: fee too high");
        emit FeeUpdated(feeBps, _feeBps);
        feeBps = _feeBps;
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "FeeRouter: zero address");
        emit FeeRecipientUpdated(feeRecipient, _feeRecipient);
        feeRecipient = _feeRecipient;
    }

    // ── Admin: ownership transfer (two-step) ─────────────────────────────────
    /**
     * @notice Initiate a two-step ownership transfer.
     * @dev    FIX: was single-step (owner = newOwner immediately). Now requires
     *         the new owner to call acceptOwnership(), preventing permanent
     *         ownership loss if a wrong address is supplied.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "FeeRouter: zero address");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /**
     * @notice Complete a pending ownership transfer.
     *         Must be called by the address set in transferOwnership().
     */
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "FeeRouter: not pending owner");
        emit OwnershipTransferred(owner, pendingOwner);
        owner        = pendingOwner;
        pendingOwner = address(0);
    }

    // ── Admin: token rescue ───────────────────────────────────────────────────
    /**
     * @notice Rescue accidentally-sent tokens. Only callable by owner.
     * @dev Return value explicitly required to surface non-reverting ERC-20 failures.
     *      Sends to owner's address (not a parameter) to limit attack surface.
     */
    function rescueTokens(address token, uint256 amount) external onlyOwner {
        require(IERC20(token).transfer(owner, amount), "FeeRouter: rescue failed");
    }
}
