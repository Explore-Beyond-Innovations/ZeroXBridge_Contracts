// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Chainlink price feed interface
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "forge-std/console.sol";
import "../utils/ElipticCurve.sol";
import "./ProofRegistry.sol";

contract ZeroXBridgeL1 is Ownable {
    using ECDSA for bytes32;

    // Proof Registry
    IProofRegistry public proofRegistry;

    // Storage variables
    address public admin;
    uint256 public tvl; // Total Value Locked in USD, with 18 decimals
    mapping(address => address) public priceFeeds; // Maps token address to Chainlink price feed address
    address[] public supportedTokens; // List of token addresses, including address(0) for ETH
    mapping(address => uint8) public tokenDecimals; // Maps token address to its decimals

    using SafeERC20 for IERC20;

    // Enum to track asset type for token registry
    enum AssetType {
        ETH,
        ERC20
    }
    // Struct to store token registry data

    struct TokenAssetData {
        AssetType assetType; // 0 for ETH, 1 for ERC-20
        address tokenAddress; // ERC-20 contract address (0x0 for ETH)
        bool isRegistered; // Prevent duplicate registration
    }

    // Maps Ethereum address to Starknet pub key
    mapping(address => uint256) public userRecord;

    // Track verified proofs to prevent replay attacks
    mapping(uint256 => bool) public verifiedProofs;

    // Track token registry data
    mapping(bytes32 => TokenAssetData) public tokenRegistry;

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

    //Starknet curve constants
    uint256 private constant K_BETA = 3141592653589793238462643383279502884197169399375105820974944592307816406665;
    uint256 private constant K_MODULUS = 0x800000000000011000000000000000000000000000000000000000000000001;
    // Full Stark Curve parameters
    uint256 private constant STARK_ALPHA = 1;
    uint256 private constant STARK_N = 0x800000000000010fffffffffffffffffffffffffffffffffffffffffffffffb;
    uint256 private constant STARK_GX = 0x1ef15c18599971b7beced415a40f0c7deacfd9b0d1819e03d723d8bc943cfca;
    uint256 private constant STARK_GY = 0x5668060aa49730b7be4801df46ec62de53ecd11abe43a32873000c36e8dc1f;
    uint256 constant EC_ORDER = 3618502788666131213697322783095070105526743751716087489154079457884512865583;
    uint256 constant N_ELEMENT_BITS_ECDSA = 251;

    // Cairo program hash that corresponds to the burn verification program
    uint256 public cairoVerifierId;

    IERC20 public claimableToken;

    // Events
    event FundsUnlocked(address indexed user, uint256 amount, bytes32 commitmentHash);
    event RelayerStatusChanged(address indexed relayer, bool status);
    event FundsClaimed(address indexed user, uint256 amount);
    event ClaimEvent(address indexed user, uint256 amount);
    event WhitelistEvent(address indexed token);
    event DewhitelistEvent(address indexed token);
    event DepositEvent(
        address indexed token, AssetType assetType, uint256 amount, address indexed user, bytes32 commitmentHash
    );
    event TokenRegistered(bytes32 indexed assetKey, AssetType assetType, address tokenAddress);
    event UserRegistered(address indexed user, uint256 starknetPubKey);

    constructor(address _admin, address _initialOwner, address _claimableToken, address _proofRegistry)
        Ownable(_initialOwner)
    {
        claimableToken = IERC20(_claimableToken);
        admin = _admin;
        proofRegistry = IProofRegistry(_proofRegistry);
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can perform this action");
        _;
    }

    modifier onlyRegistered() {
        require(userRecord[msg.sender] != 0, "ZeroXBridge: User not registered");
        _;
    }

    function registerToken(AssetType assetType, address tokenAddress) external onlyAdmin {
        bytes32 assetKey = keccak256(abi.encodePacked(assetType, tokenAddress));

        require(assetType == AssetType.ETH || assetType == AssetType.ERC20, "Invalid asset type");
        if (assetType == AssetType.ERC20) require(tokenAddress != address(0), "Invalid token address");
        require(!tokenRegistry[assetKey].isRegistered, "Token already registered");

        tokenRegistry[assetKey] =
            TokenAssetData({assetType: AssetType(assetType), tokenAddress: tokenAddress, isRegistered: true});
        emit TokenRegistered(assetKey, assetType, tokenAddress);
    }

    function addSupportedToken(address token, address priceFeed, uint8 decimals) external onlyAdmin {
        supportedTokens.push(token);
        priceFeeds[token] = priceFeed;
        tokenDecimals[token] = decimals;
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
     * @param commitmentHash The hash of the commitment data that should match proof
     * @param starknetPubkey The pubkey of address that will receive the unlocked funds
     * @param amount The amount to unlock
     * @param blockhash The block hash of L2 transaction for uniqueness
     */
    function unlock_funds_with_proof(uint256 commitmentHash, uint256 starknetPubKey, uint256 amount, uint256 blockhash)
        external
    {
        require(approvedRelayers[msg.sender], "ZeroXBridge: Only approved relayers can submit proofs");

        // Verify that commitmentHash matches expected format based on L2 standards
        uint256 expectedCommitmentHash = uint256(keccak256(abi.encodePacked(starknetPubKey, amount, blockhash)));

        require(commitmentHash == expectedCommitmentHash, "ZeroXBridge: Invalid commitment hash");

        // Check proof registry for verified root
        uint256 verifiedRoot = proofRegistry.getVerifiedMerkleRoot(commitmentHash);

        // assert root hasn't been used
        require(!verifiedProofs[verifiedRoot], "ZeroXBridge: Proof has already been used");

        // pass verified root into merkle manager

        // Store the proof hash to prevent replay attacks
        verifiedProofs[verifiedRoot] = true;

        claimableFunds[user] += amount;

        emit FundsUnlocked(user, amount, commitmentHash);
    }

    /**
     * @dev Allows users to claim their full unlocked tokens
     * @notice Users can only claim the full amount, partial claims are not allowed
     */
    function claim_tokens() external {
        uint256 amount = claimableFunds[msg.sender];
        require(amount > 0, "ZeroXBridge: No tokens to claim");

        // Reset claimable amount before transfer to prevent reentrancy
        claimableFunds[msg.sender] = 0;

        // Transfer full amount to user
        claimableToken.safeTransfer(msg.sender, amount);
        emit ClaimEvent(msg.sender, amount);
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
     * @param tokenAddress The address of the token to deposit
     * @param amount The amount of tokens to deposit
     * @param user The address that will receive the bridged tokens on L2
     * @return commitmentHash Returns the generated commitment hash for verification on L2
     */
    function deposit_asset(AssetType assetType, address tokenAddress, uint256 amount, address user)
        external
        payable
        returns (bytes32)
    {
        require(amount > 0, "ZeroXBridge: Amount must be greater than zero");
        require(user != address(0), "ZeroXBridge: Invalid user address");

        TokenAssetData memory tokenData = getTokenData(assetType, tokenAddress);

        // Check if token is whitelisted
        if (tokenData.assetType == AssetType.ETH) {
            require(msg.value == amount, "ZeroXBridge: Incorrect ETH amount");

            // Directly add ETH to tracking (no transfer needed)
            userDeposits[address(0)][user] += amount;
        } else if (tokenData.assetType == AssetType.ERC20) {
            require(tokenData.tokenAddress != address(0), "ZeroXBridge: Invalid token address");

            // Perform ERC20 transfer
            IERC20(tokenData.tokenAddress).safeTransferFrom(user, address(this), amount);

            // Track ERC20 deposit
            userDeposits[tokenData.tokenAddress][user] += amount;
        } else {
            revert("Invalid asset type");
        }

        // Get the next nonce for this user
        uint256 nonce = nextDepositNonce[user];
        nextDepositNonce[user] = nonce + 1;

        // Generate commitment hash
        bytes32 commitmentHash =
            keccak256(abi.encodePacked(uint256(assetType), tokenAddress, amount, user, nonce, block.chainid));

        // Emit deposit event
        emit DepositEvent(tokenAddress, assetType, amount, user, commitmentHash);

        return commitmentHash;
    }

    function getTokenData(AssetType assetType, address tokenAddress) public view returns (TokenAssetData memory) {
        bytes32 assetKey = keccak256(abi.encodePacked(assetType, tokenAddress));
        require(assetType == AssetType.ETH || assetType == AssetType.ERC20, "Invalid asset type");
        if (assetType == AssetType.ETH) {
            require(tokenAddress == address(0), "Invalid token address for ETH");
        } else {
            require(tokenAddress != address(0), "Invalid token address for ERC20");
        }
        require(tokenRegistry[assetKey].isRegistered, "Token not registered");

        return tokenRegistry[assetKey];
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

    function isQuadraticResidue(uint256 fieldElement) private view returns (bool) {
        return 1 == fieldPow(fieldElement, ((K_MODULUS - 1) / 2));
    }

    function fieldPow(uint256 base, uint256 exponent) internal view returns (uint256) {
        (bool success, bytes memory returndata) =
            address(5).staticcall(abi.encode(0x20, 0x20, 0x20, base, exponent, K_MODULUS));
        require(success, string(returndata));
        return abi.decode(returndata, (uint256));
    }

    /**
     * @dev Recovers the signer's address from a signature.
     * @param ethAddress The Ethereum address of the user.
     * @param signature The user's signature.
     * @param starknetPubKey The Starknet public key.
     * @return recoveredAddress The recovered Ethereum address.
     */
    function recoverSigner(address ethAddress, bytes calldata signature, uint256 starknetPubKey)
        internal
        view
        returns (address recoveredAddress)
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

        recoveredAddress = ecrecover(messageHash, v, r, s);
    }

    /**
     * @notice Checks if a point (x, y) lies on the Stark Curve
     * @param x X-coordinate
     * @param y Y-coordinate
     * @return isOnCurve True if the point is on the curve, false otherwise
     */
    function isOnStarkCurve(uint256 x, uint256 y) internal pure returns (bool isOnCurve) {
        uint256 left = mulmod(y, y, K_MODULUS);
        uint256 x2 = mulmod(x, x, K_MODULUS);
        uint256 x3 = mulmod(x2, x, K_MODULUS);
        uint256 right = addmod(addmod(x3, mulmod(STARK_ALPHA, x, K_MODULUS), K_MODULUS), K_BETA, K_MODULUS);
        isOnCurve = left == right;
    }

    /**
     * @notice Computes the modular inverse of a modulo m using exponentiation
     * @param a Number to invert
     * @param m Modulus (must be prime)
     * @return Inverse of a modulo m
     */
    function modInverse(uint256 a, uint256 m) internal pure returns (uint256) {
        require(a != 0, "Inverse does not exist");
        return powMod(a, m - 2, m);
    }

    /**
     * @notice Computes base^exponent mod modulus
     * @param base Base number
     * @param exponent Exponent
     * @param modulus Modulus
     * @return Result of base^exponent mod modulus
     */
    function powMod(uint256 base, uint256 exponent, uint256 modulus) internal pure returns (uint256) {
        uint256 result = 1;
        base = base % modulus;
        while (exponent > 0) {
            if (exponent & 1 == 1) {
                result = mulmod(result, base, modulus);
            }
            base = mulmod(base, base, modulus);
            exponent >>= 1;
        }
        return result;
    }

    /**
     * @notice Adds two points on the Stark Curve
     * @param x1 X-coordinate of first point
     * @param y1 Y-coordinate of first point
     * @param x2 X-coordinate of second point
     * @param y2 Y-coordinate of second point
     * @return x3 Resulting X-coordinate
     * @return y3 Resulting Y-coordinate
     */
    function ecAdd(uint256 x1, uint256 y1, uint256 x2, uint256 y2) internal view returns (uint256 x3, uint256 y3) {
        if (x1 == 0 && y1 == 0) return (x2, y2);
        if (x2 == 0 && y2 == 0) return (x1, y1);
        if (x1 == x2 && addmod(y1, y2, K_MODULUS) == 0) return (0, 0);

        uint256 x1Mod = x1 % K_MODULUS;
        uint256 x2Mod = x2 % K_MODULUS;
        uint256 y1Mod = y1 % K_MODULUS;
        uint256 y2Mod = y2 % K_MODULUS;

        uint256 dx = addmod(x2Mod, K_MODULUS - x1Mod, K_MODULUS);
        uint256 dy = addmod(y2Mod, K_MODULUS - y1Mod, K_MODULUS);
        uint256 lambda = mulmod(dy, modInverse(dx, K_MODULUS), K_MODULUS);
        x3 = addmod(
            mulmod(lambda, lambda, K_MODULUS), addmod(K_MODULUS - x1Mod, K_MODULUS - x2Mod, K_MODULUS), K_MODULUS
        );
        y3 = addmod(mulmod(lambda, addmod(x1Mod, K_MODULUS - x3, K_MODULUS), K_MODULUS), K_MODULUS - y1Mod, K_MODULUS);
    }

    /**
     * @notice Doubles a point on the Stark Curve
     * @param x X-coordinate
     * @param y Y-coordinate
     * @return x2 Resulting X-coordinate
     * @return y2 Resulting Y-coordinate
     */
    function ecDouble(uint256 x, uint256 y) internal view returns (uint256 x2, uint256 y2) {
        if (y == 0) return (0, 0);
        uint256 xMod = x % K_MODULUS;
        uint256 yMod = y % K_MODULUS;
        uint256 lambda = mulmod(
            addmod(mulmod(3, mulmod(xMod, xMod, K_MODULUS), K_MODULUS), STARK_ALPHA, K_MODULUS),
            modInverse(mulmod(2, yMod, K_MODULUS), K_MODULUS),
            K_MODULUS
        );
        x2 = addmod(mulmod(lambda, lambda, K_MODULUS), K_MODULUS - addmod(xMod, xMod, K_MODULUS), K_MODULUS);
        y2 = addmod(mulmod(lambda, addmod(xMod, K_MODULUS - x2, K_MODULUS), K_MODULUS), K_MODULUS - yMod, K_MODULUS);
    }

    /**
     * @notice Multiplies a point on the Stark Curve by a scalar
     * @param scalar Scalar value
     * @param x X-coordinate
     * @param y Y-coordinate
     * @return xR Resulting X-coordinate
     * @return yR Resulting Y-coordinate
     */
    function ecMul(uint256 scalar, uint256 x, uint256 y) internal view returns (uint256 xR, uint256 yR) {
        xR = 0;
        yR = 0;
        uint256 scalarMod = scalar % STARK_N;
        uint256 px = x % K_MODULUS;
        uint256 py = y % K_MODULUS;
        while (scalarMod > 0) {
            if (scalarMod & 1 == 1) {
                (xR, yR) = ecAdd(xR, yR, px, py);
            }
            (px, py) = ecDouble(px, py);
            scalarMod >>= 1;
        }
    }

    /**
     * @notice Verifies a Starknet signature
     * @param messageHash Hash of the message signed
     * @param starknetSig Signature as bytes (r, s concatenated)
     * @param starkPubKeyX X-coordinate of the Starknet public key
     * @param starkPubKeyY Y-coordinate of the Starknet public key
     * @return isValid True if the signature is valid
     */
    function verifyStarknetSignature(
        uint256 messageHash,
        bytes calldata starknetSig,
        uint256 starkPubKeyX,
        uint256 starkPubKeyY
    ) public view returns (bool isValid) {
        require(starknetSig.length == 64, "Invalid signature length");
        uint256 r = uint256(bytes32(starknetSig[0:32]));
        uint256 s = uint256(bytes32(starknetSig[32:64]));

        require(messageHash % EC_ORDER == messageHash, "msgHash out of range");
        require(s >= 1 && s < EC_ORDER, "s out of range");
        uint256 w = EllipticCurve.invMod(s, EC_ORDER);
        require(r >= 1 && r < (1 << N_ELEMENT_BITS_ECDSA), "r out of range");
        require(w >= 1 && w < (1 << N_ELEMENT_BITS_ECDSA), "w out of range");

        // Verify public key is on curve
        uint256 x3 = mulmod(mulmod(starkPubKeyX, starkPubKeyX, K_MODULUS), starkPubKeyX, K_MODULUS);
        uint256 y2 = mulmod(starkPubKeyY, starkPubKeyY, K_MODULUS);
        require(y2 == addmod(addmod(x3, starkPubKeyX, K_MODULUS), K_BETA, K_MODULUS), "Public key not on Stark Curve");

        // Compute signature verification
        (uint256 zG_x, uint256 zG_y) = EllipticCurve.ecMul(messageHash, STARK_GX, STARK_GY, STARK_ALPHA, K_MODULUS);
        (uint256 rQ_x, uint256 rQ_y) = EllipticCurve.ecMul(r, starkPubKeyX, starkPubKeyY, STARK_ALPHA, K_MODULUS);
        (uint256 b_x, uint256 b_y) = EllipticCurve.ecAdd(zG_x, zG_y, rQ_x, rQ_y, STARK_ALPHA, K_MODULUS);
        (uint256 res_x,) = EllipticCurve.ecMul(w, b_x, b_y, STARK_ALPHA, K_MODULUS);

        isValid = res_x == r;
    }
}
