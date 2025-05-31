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
import "../utils/Starknet.sol";
import "./ProofRegistry.sol";

contract ZeroXBridgeL1 is Ownable, Starknet {
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

    // Maps Starknet pub key to Ethereum address
    mapping(uint256 => address) public starkPubKeyRecord;

    // Track verified proofs to prevent replay attacks
    mapping(uint256 => bool) public verifiedProofs;

    // Track token registry data
    mapping(bytes32 => TokenAssetData) public tokenRegistry;

    // Track user deposits per token
    mapping(address => mapping(address => uint256)) public userDeposits; // token -> user -> amount

    // Track deposit nonces to prevent replay attacks
    mapping(address => uint256) public nextDepositNonce; // user -> next nonce

    // Approved relayers that can submit proofs
    mapping(address => bool) public approvedRelayers;

    mapping(address => uint256) public tokenReserves;

    // Events
    event FundsUnlocked(address indexed user, uint256 amount, uint256 commitmentHash);
    event RelayerStatusChanged(address indexed relayer, bool status);
    event FundsClaimed(address indexed user, uint256 amount);
    event ClaimEvent(address indexed user, uint256 amount);
    event WhitelistEvent(address indexed token);
    event DewhitelistEvent(address indexed token);
    event DepositEvent(
        address indexed token, AssetType assetType, uint256 amount, address indexed user, uint256 commitmentHash
    );
    event TokenRegistered(bytes32 indexed assetKey, AssetType assetType, address tokenAddress);
    event UserRegistered(address indexed user, uint256 starknetPubKey);
    event TokenReserveUpdated(address indexed token, uint256 newReserve);

    constructor(address _admin, address _initialOwner, address _proofRegistry) Ownable(_initialOwner) {
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

    function registerToken(AssetType assetType, address tokenAddress, address priceFeed, uint8 decimals)
        external
        onlyAdmin
    {
        bytes32 assetKey = keccak256(abi.encodePacked(assetType, tokenAddress));

        require(assetType == AssetType.ETH || assetType == AssetType.ERC20, "Invalid asset type");
        if (assetType == AssetType.ERC20) require(tokenAddress != address(0), "Invalid token address");
        require(!tokenRegistry[assetKey].isRegistered, "Token already registered");

        tokenRegistry[assetKey] =
            TokenAssetData({assetType: AssetType(assetType), tokenAddress: tokenAddress, isRegistered: true});

        priceFeeds[tokenAddress] = priceFeed;
        tokenDecimals[tokenAddress] = decimals;

        supportedTokens.push(tokenAddress);

        emit TokenRegistered(assetKey, assetType, tokenAddress);
    }

    /**
     * @dev Using Starknet Curve constants (α and β) for y^2 = x^3 + α.x + β (mod P)
     * @param signature The user signature
     * @param starknetPubKey user starknet public key
     */
    function registerUser(bytes calldata signature, uint256 starknetPubKey) external {
        require(Starknet.isValidStarknetPublicKey(starknetPubKey), "ZeroXBridge: Invalid Starknet public key");

        address recoveredSigner = Starknet.recoverSigner(msg.sender, signature, starknetPubKey);
        require(recoveredSigner == msg.sender, "ZeroXBridge: Invalid signature");

        userRecord[msg.sender] = starknetPubKey;
        starkPubKeyRecord[starknetPubKey] = msg.sender;
        emit UserRegistered(msg.sender, starknetPubKey);
    }

    function getTokenPriceUSD(address tokenAddress) public view returns (uint256) {
        address feedAddress = priceFeeds[tokenAddress];
        require(feedAddress != address(0), "No price feed for token");

        AggregatorV3Interface priceFeed = AggregatorV3Interface(feedAddress);
        (, int256 priceInt,,,) = priceFeed.latestRoundData();
        require(priceInt > 0, "Invalid price from feed");

        // e.g. 1 ETH = 3000.12345678 => 300012345678
        return uint256(priceInt);
    }

    function fetchReserveTVL() public view returns (uint256) {
        uint256 totalValue = 0;

        for (uint256 i = 0; i < supportedTokens.length; i++) {
                address tokenAddr = supportedTokens[i];

                // Use tokenReserves instead of actual balance
                uint256 balance = tokenReserves[tokenAddr];
                uint8 dec = tokenDecimals[tokenAddr];

                // Pull the USD price (8-decimals)
                uint256 price = getTokenPriceUSD(tokenAddr);

                //      value = balance * price / 1e8   --> this is USD value in token-units (18+8 decimals)
                //      value = value / (10 ** dec)     --> normalize back to 18 decimals
                uint256 usdRaw = (balance * price) / 1e8;
                uint256 usdVal = (usdRaw * 1e18) / (10 ** dec);

                totalValue += usdVal;
            }

        return totalValue;
    }

    function updateTvl() external {
        tvl = fetchReserveTVL();
    }

    function setRelayerStatus(address relayer, bool status) external onlyOwner {
        approvedRelayers[relayer] = status;
        emit RelayerStatusChanged(relayer, status);
    }

    /**
     * @dev Deposits ERC20 tokens to be bridged to L2
     * @param tokenAddress The address of the token to deposit
     * @param amount The amount of tokens to deposit
     * @param user The address that will receive the bridged tokens on L2
     * @return commitmentHash Returns the generated commitment hash for verification on L2
     */
    function depositAsset(AssetType assetType, address tokenAddress, uint256 amount, address user)
        external
        payable
        returns (uint256)
    {
        require(amount > 0, "ZeroXBridge: Amount must be greater than zero");
        require(user != address(0), "ZeroXBridge: Invalid user address");

        TokenAssetData memory tokenData = getTokenData(assetType, tokenAddress);

        // Check if token is whitelisted
        if (tokenData.assetType == AssetType.ETH) {
            require(msg.value == amount, "ZeroXBridge: Incorrect ETH amount");

            tokenReserves[address(0)] += amount;
            // Directly add ETH to tracking (no transfer needed)
            userDeposits[address(0)][user] += amount;
            emit TokenReserveUpdated(address(0), tokenReserves[address(0)]);
        } else if (tokenData.assetType == AssetType.ERC20) {
            require(tokenData.tokenAddress != address(0), "ZeroXBridge: Invalid token address");

            // Perform ERC20 transfer
            IERC20(tokenData.tokenAddress).safeTransferFrom(user, address(this), amount);

            // Increment token reserves for ERC20
            tokenReserves[tokenData.tokenAddress] += amount;
            emit TokenReserveUpdated(tokenData.tokenAddress, tokenReserves[tokenData.tokenAddress]);

            // Track ERC20 deposit
            userDeposits[tokenData.tokenAddress][user] += amount;
        } else {
            revert("Invalid asset type");
        }

        // Pull the USD price (8-decimals)
        uint256 price = getTokenPriceUSD(tokenAddress);
        uint8 dec = tokenDecimals[tokenAddress];

        uint256 usdRaw = (amount * price) / 1e8;
        uint256 usdVal = (usdRaw * 1e18) / (10 ** dec);

        // Get the next nonce for this user
        uint256 nonce = nextDepositNonce[user];
        nextDepositNonce[user] = nonce + 1;

        // Generate commitment hash
        uint256 commitmentHash = uint256(keccak256(abi.encodePacked(userRecord[user], usdVal, nonce, block.timestamp)));

        // Emit deposit event
        emit DepositEvent(tokenAddress, assetType, usdVal, user, commitmentHash);

        return commitmentHash;
    }

    /**
     * @dev Processes a proof and unlocks funds from L2 to L1
     * @param assetType The type of asset (ETH or ERC20)
     * @param tokenAddress The address of token to unlock (address(0) for ETH)
     * @param proofdata Array of proof values
     * @param commitmentHash The hash of the commitment data
     * @param starknetSig The signature from the L2 transaction
     */
    function unlockFundsWithProof(
        AssetType assetType,
        address tokenAddress,
        uint256[] memory proofdata,
        uint256 commitmentHash,
        bytes calldata starknetSig
    ) external {
        // require(approvedRelayers[msg.sender], "ZeroXBridge: Only approved relayers can submit proofs");
        require(proofdata.length == 4, "ZeroXBridge: Invalid proof data length");

        uint256 starknetPubKey = proofdata[0];
        uint256 usd_amount = proofdata[1];
        uint256 nonce = proofdata[2];
        uint256 timestamp = proofdata[3];

        // Verify that commitmentHash matches expected format based on L2 standards

        uint256 expectedCommitmentHash =
            uint256(keccak256(abi.encodePacked(starknetPubKey, usd_amount, nonce, timestamp)));

        require(commitmentHash == expectedCommitmentHash, "ZeroXBridge: Invalid commitment hash");

        require(verifyStarknetSignature(commitmentHash, starknetSig, starknetPubKey), "ZeroXBridge: Invalid signature");

        // Check proof registry for verified root
        uint256 verifiedRoot = proofRegistry.getVerifiedMerkleRoot(commitmentHash);

        // assert root hasn't been used
        require(!verifiedProofs[verifiedRoot], "ZeroXBridge: Proof has already been used");

        // pass verified root into merkle manager
        // todo: implement merkle manager

        // get user address from starknet pubkey
        address user = starkPubKeyRecord[starknetPubKey];

        // Store the proof hash to prevent replay attacks
        verifiedProofs[verifiedRoot] = true;

        require(usd_amount > 0, "ZeroXBridge: No tokens to claim");

        TokenAssetData memory tokenData = getTokenData(assetType, tokenAddress);

        uint8 dec = tokenDecimals[tokenAddress];
        uint256 price = getTokenPriceUSD(tokenAddress);
        // uint256 amount = (usd_amount * (10 ** dec)) / price;
        uint256 amount = (usd_amount * 10 ** dec) / (price * 10 ** 10); //TODO Check if Calculation is correct

        // Check if token is whitelisted
        if (tokenData.assetType == AssetType.ETH) {
            require(tokenReserves[address(0)] >= amount, "Insufficient token reserves1");
            require(address(this).balance >= amount, "Insufficient balance");

            // Decrement token reserves for ETH
            tokenReserves[address(0)] -= amount;
            emit TokenReserveUpdated(address(0), tokenReserves[address(0)]);

            // forward all gas, revert on failure
            (bool success,) = user.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else if (tokenData.assetType == AssetType.ERC20) {
            require(tokenData.tokenAddress != address(0), "ZeroXBridge: Invalid token address");
            require(tokenReserves[tokenData.tokenAddress] >= amount, "Insufficient token reserves");
            
            // Decrement token reserves for ERC20
            tokenReserves[tokenData.tokenAddress] -= amount;
            emit TokenReserveUpdated(tokenData.tokenAddress, tokenReserves[tokenData.tokenAddress]);

            // Perform ERC20 transfer
            IERC20(tokenData.tokenAddress).safeTransfer(user, amount);
        } else {
            revert("Invalid asset type");
        }

        emit FundsUnlocked(user, amount, commitmentHash);
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
}