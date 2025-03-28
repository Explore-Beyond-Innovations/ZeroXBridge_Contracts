// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Chainlink price feed interface
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

interface IGpsStatementVerifier {
    function verifyProofAndRegister(
        uint256[] calldata proofParams,
        uint256[] calldata proof,
        uint256[] calldata publicInputs,
        uint256 cairoVerifierId
    ) external returns (bool);
}

contract ZeroXBridgeL1 is Ownable {
    // Storage variables
    address public admin;
    uint256 public tvl; // Total Value Locked in USD, with 18 decimals
    mapping(address => address) public priceFeeds; // Maps token address to Chainlink price feed address
    address[] public supportedTokens; // List of token addresses, including address(0) for ETH
    mapping(address => uint8) public tokenDecimals; // Maps token address to its decimals

    using SafeERC20 for IERC20;

    // Starknet GPS Statement Verifier interface
    IGpsStatementVerifier public gpsVerifier;

    // Track verified proofs to prevent replay attacks
    mapping(bytes32 => bool) public verifiedProofs;

    // Track claimable funds per user
    mapping(address => uint256) public claimableFunds;

    // Track user deposits per token
    mapping(address => mapping(address => uint256)) public userDeposits; // token -> user -> amount

    // Track deposit nonces to prevent replay attacks
    mapping(address => uint256) public nextDepositNonce; // user -> next nonce

    // Approved relayers that can submit proofs
    mapping(address => bool) public approvedRelayers;

    // Whitelisted tokens mapping
    mapping(address => bool) public whitelistedTokens;

    // Maps Ethereum address to Starknet pub key
    mapping(address => uint256) public userRecord;

    //Starknet curve constants
    uint256 private constant K_BETA = 0x6f21413efbe40de150e596d72f7a8c5609ad26c15c915c1f4cdfcb99cee9e89;
    uint256 private constant K_MODULUS = 0x800000000000011000000000000000000000000000000000000000000000001;

    // Cairo program hash that corresponds to the burn verification program
    uint256 public cairoVerifierId;

    IERC20 public claimableToken;

    using ECDSA for bytes32;

    // Events
    event FundsUnlocked(address indexed user, uint256 amount, bytes32 commitmentHash);
    event RelayerStatusChanged(address indexed relayer, bool status);
    event FundsClaimed(address indexed user, uint256 amount);
    event ClaimEvent(address indexed user, uint256 amount);
    event WhitelistEvent(address indexed token);
    event DewhitelistEvent(address indexed token);
    event DepositEvent(address indexed token, uint256 amount, address indexed user, bytes32 commitmentHash);
    event UserRegistered(address indexed user, uint256 starknetPubKey);

    constructor(
        address _gpsVerifier,
        address _admin,
        uint256 _cairoVerifierId,
        address _initialOwner,
        address _claimableToken
    ) Ownable(_initialOwner) {
        gpsVerifier = IGpsStatementVerifier(_gpsVerifier);
        cairoVerifierId = _cairoVerifierId;
        claimableToken = IERC20(_claimableToken);
        admin = _admin;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can perform this action");
        _;
    }

    modifier onlyRegistered() {
        require(userRecord[msg.sender] != 0, "ZeroXBridge: User not registered");
        _;
    }

    function addSupportedToken(address token, address priceFeed, uint8 decimals) external onlyAdmin {
        supportedTokens.push(token);
        priceFeeds[token] = priceFeed;
        tokenDecimals[token] = decimals;
    }

    function fetch_reserve_tvl() public view returns (uint256) {
        uint256 totalValue = 0;

        // Iterate through all supported tokens, including ETH
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address tokenAddress = supportedTokens[i];
            uint256 balance;
            uint256 dec;
            uint256 price;

            // Get balance and decimals
            if (tokenAddress == address(0)) {
                balance = address(this).balance; // ETH balance in wei
                dec = tokenDecimals[tokenAddress]; // Should be 18 for ETH
            } else {
                IERC20 token = IERC20(tokenAddress);
                balance = token.balanceOf(address(this)); // Token balance in smallest units
                dec = tokenDecimals[tokenAddress]; // Use stored decimals
            }

            // Fetch price from Chainlink price feed
            address feedAddress = priceFeeds[tokenAddress];
            require(feedAddress != address(0), "No price feed for token");
            AggregatorV3Interface priceFeed = AggregatorV3Interface(feedAddress);
            (, int256 priceInt,,,) = priceFeed.latestRoundData();
            require(priceInt > 0, "Invalid price");
            price = uint256(priceInt); // Price in USD with 8 decimals

            // Calculate USD value with 18 decimals
            // value = (balance * price * 10^18) / (10^dec * 10^8)
            // To minimize overflow, compute in steps
            uint256 temp = (balance * price) / 1e8;
            uint256 value = (temp * 1e18) / (10 ** dec);
            totalValue += value;
        }

        // Update TVL
        return totalValue;
    }

    function update_tvl() external {
        tvl = fetch_reserve_tvl();
    }

    function setRelayerStatus(address relayer, bool status) external onlyOwner {
        approvedRelayers[relayer] = status;
        emit RelayerStatusChanged(relayer, status);
    }

    /**
     * @dev Processes a burn zkProof from L2 and unlocks equivalent funds for the user
     * @param proof The zkProof data array
     * @param user The address that will receive the unlocked funds
     * @param amount The amount to unlock
     * @param l2TxId The L2 transaction ID for uniqueness
     * @param commitmentHash The hash of the commitment data that should match proof
     */
    function unlock_funds_with_proof(
        uint256[] calldata proofParams,
        uint256[] calldata proof,
        address user,
        uint256 amount,
        uint256 l2TxId,
        bytes32 commitmentHash
    ) external {
        require(approvedRelayers[msg.sender], "ZeroXBridge: Only approved relayers can submit proofs");

        // Verify that commitmentHash matches expected format based on L2 standards
        bytes32 expectedCommitmentHash =
            keccak256(abi.encodePacked(uint256(uint160(user)), amount, l2TxId, block.chainid));

        require(commitmentHash == expectedCommitmentHash, "ZeroXBridge: Invalid commitment hash");

        // Create the public inputs array with all verification parameters
        uint256[] memory publicInputs = new uint256[](4);
        publicInputs[0] = uint256(uint160(user));
        publicInputs[1] = amount;
        publicInputs[2] = l2TxId;
        publicInputs[3] = uint256(commitmentHash);

        // Check that this proof hasn't been used before
        bytes32 proofHash = keccak256(abi.encodePacked(proof));
        require(!verifiedProofs[proofHash], "ZeroXBridge: Proof has already been used");

        // Verify the proof using Starknet's verifier
        bool isValid = gpsVerifier.verifyProofAndRegister(proofParams, proof, publicInputs, cairoVerifierId);

        require(isValid, "ZeroXBridge: Invalid proof");

        require(!verifiedProofs[commitmentHash], "ZeroXBridge: Commitment already processed");
        verifiedProofs[commitmentHash] = true;

        // Store the proof hash to prevent replay attacks
        verifiedProofs[proofHash] = true;

        claimableFunds[user] += amount;

        emit FundsUnlocked(user, amount, commitmentHash);
    }

    /**
     * @dev Allows users to claim their full unlocked tokens
     * @notice Users can only claim the full amount, partial claims are not allowed
     */
    function claim_tokens() external onlyRegistered {
        uint256 amount = claimableFunds[msg.sender];
        require(amount > 0, "ZeroXBridge: No tokens to claim");

        // Reset claimable amount before transfer to prevent reentrancy
        claimableFunds[msg.sender] = 0;

        // Transfer full amount to user
        claimableToken.safeTransfer(msg.sender, amount);
        emit ClaimEvent(msg.sender, amount);
    }

    // Function to update the GPS verifier address if needed
    function updateGpsVerifier(address _newVerifier) external onlyOwner {
        require(_newVerifier != address(0), "ZeroXBridge: Invalid address");
        gpsVerifier = IGpsStatementVerifier(_newVerifier);
    }

    // Function to update the Cairo verifier ID if needed
    function updateCairoVerifierId(uint256 _newVerifierId) external onlyOwner {
        cairoVerifierId = _newVerifierId;
    }

    function whitelistToken(address _token) public onlyAdmin {
        whitelistedTokens[_token] = true;
        emit WhitelistEvent(_token);
    }

    function dewhitelistToken(address _token) public onlyAdmin {
        whitelistedTokens[_token] = false;
        emit DewhitelistEvent(_token);
    }

    function isWhitelisted(address _token) public view returns (bool) {
        return whitelistedTokens[_token];
    }

    /**
     * @dev Deposits ERC20 tokens to be bridged to L2
     * @param token The address of the token to deposit
     * @param amount The amount of tokens to deposit
     * @param user The address that will receive the bridged tokens on L2
     * @return Returns the generated commitment hash for verification on L2
     */
    function deposit_asset(address token, uint256 amount, address user) external onlyRegistered returns (bytes32) {
        // Verify token is whitelisted
        require(whitelistedTokens[token], "ZeroXBridge: Token not whitelisted");
        require(amount > 0, "ZeroXBridge: Amount must be greater than zero");
        require(user != address(0), "ZeroXBridge: Invalid user address");

        // Get the next nonce for this user
        uint256 nonce = nextDepositNonce[msg.sender];
        // Increment the nonce for replay protection
        nextDepositNonce[msg.sender] = nonce + 1;

        // Transfer tokens from user to this contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update user deposits tracking
        userDeposits[token][user] += amount;

        // Generate commitment hash for verification on L2
        // Hash includes token address, amount, user address, nonce, and chain ID for uniqueness
        bytes32 commitmentHash = keccak256(abi.encodePacked(token, amount, user, nonce, block.chainid));

        // Emit deposit event with all relevant details
        emit DepositEvent(token, amount, user, commitmentHash);

        return commitmentHash;
    }

    /**
     * @dev Using Starknet Curve constants (α and β) for y^2 = x^3 + α.x + β (mod P)
     * @param signature The user signature
     * @param starknetPubKey user starknet public key
     */
    function registerUser(bytes calldata signature, uint256 starknetPubKey) external {
        require(isValidStarknetPublicKey(starknetPubKey), "ZeroXBridge: Invalid Starknet public key");

        address recoveredSigner = recoverSigner(msg.sender, signature, starknetPubKey);
        require(recoveredSigner == msg.sender, "ZeroXBridge: Invalid signature");

        userRecord[msg.sender] = starknetPubKey;

        emit UserRegistered(msg.sender, starknetPubKey);
    }

    /**
     * @notice Checks if a Starknet public key belongs to the Starknet elliptic curve.
     * @param starknetPubKey user starknet public key
     * @return isValid True if the key is valid.
     */
    function isValidStarknetPublicKey(uint256 starknetPubKey) internal view returns (bool) {
        uint256 xCubed = mulmod(mulmod(starknetPubKey, starknetPubKey, K_MODULUS), starknetPubKey, K_MODULUS);
        return isQuadraticResidue(addmod(addmod(xCubed, starknetPubKey, K_MODULUS), K_BETA, K_MODULUS));
    }

    function fieldPow(uint256 base, uint256 exponent) internal view returns (uint256) {
        (bool success, bytes memory returndata) =
            address(5).staticcall(abi.encode(0x20, 0x20, 0x20, base, exponent, K_MODULUS));
        require(success, string(returndata));
        return abi.decode(returndata, (uint256));
    }

    function isQuadraticResidue(uint256 fieldElement) private view returns (bool) {
        return 1 == fieldPow(fieldElement, ((K_MODULUS - 1) / 2));
    }

    /**
     * @dev Recovers the signer's address from a signature.
     * @param ethAddress The Ethereum address of the user.
     * @param signature The user's signature.
     * @param starknetPubKey The Starknet public key.
     * @return The recovered Ethereum address.
     */
    function recoverSigner(address ethAddress, bytes calldata signature, uint256 starknetPubKey)
        internal
        pure
        returns (address)
    {
        require(ethAddress != address(0), "Invalid ethAddress");
        require(signature.length == 65, "Invalid signature length");

        bytes32 messageHash = keccak256(abi.encodePacked("UserRegistration", ethAddress, starknetPubKey));

        bytes memory sig = signature;
        bytes32 r;
        bytes32 s;
        uint8 v = uint8(sig[64]);
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
        }

        return ecrecover(messageHash, v, r, s);
    }
}
