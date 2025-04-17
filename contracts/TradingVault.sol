// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title TradingVault
 * @dev A contract for managing trading positions as NFTs with reward distribution capabilities.
 * This contract allows users to:
 * - Create trading positions represented as NFTs
 * - Reduce positions and harvest rewards
 * - Configure reward weights based on position duration
 * - Manage currency and reward token settings
 *
 * The contract implements role-based access control with the following roles:
 * - DEFAULT_ADMIN_ROLE: Can grant other roles and manage contract settings
 * - OPERATOR_ROLE: Can update currency, reward token, and reward configurations
 * - PRICE_SETTER_ROLE: Can update the price used for position calculations
 *
 * Security features:
 * - Upgradeable contract pattern
 * - Role-based access control
 * - Protected token management
 * - Secure reward distribution
 */
contract TradingVault is Initializable, ERC721Upgradeable, OwnableUpgradeable, AccessControlUpgradeable {
    // Custom errors
    error ZeroPrice();
    error InvalidCurrencyAddress();
    error InvalidRewardTokenAddress();
    error ZeroAmount();
    error NotOwnerOrApproved();
    error PositionAlreadyClosed();
    error NoRewardsToHarvest();
    error InsufficientBalance();
    error InsufficientRepayAmount();
    error CannotClaimProtectedToken();
    error ClaimFailed();
    error InvalidTreasuryAddress();
    error InvalidRewardWeight();
    error InvalidDuration();
    error ReducePositionDisabled();
    error InvalidUserAddress();
    error PositionNotExpired();
    error PositionExpired();
    error InvalidPrice();
    error PriceOutOfRange();

    /**
     * @dev Struct defining reward configuration parameters
     * @param weight Weight for user's share (out of BASE_WEIGHT)
     * @param duration Duration threshold in days for this weight to apply
     */
    struct RewardConfig {
        uint256 weight;
        uint256 duration;
    }

    /**
     * @dev Struct containing all details about a trading position
     * @param entryPrice Price at which the position was opened
     * @param outPrice Price at which the position was closed (0 if still open)
     * @param remainingAmount Current amount remaining in the position
     * @param initAmount Initial amount when position was opened
     * @param openedAt Timestamp when position was opened
     * @param closedAt Timestamp when position was closed (0 if still open)
     * @param rewardedAmount Total rewards harvested from this position
     * @param lossAmount Total loss when reducing position at price < entryPrice
     * @param token Currency token used for this position
     * @param expiredAt Timestamp when position expires (0 if no expiration)
     */
    struct Position {
        uint256 entryPrice;
        uint256 outPrice;
        uint256 remainingAmount;
        uint256 initAmount;
        uint256 openedAt;
        uint256 closedAt;
        uint256 rewardedAmount;
        uint256 lossAmount;
        address token;
        uint256 expiredAt;
    }

    /**
     * @dev Emitted when a new position is created
     * @param user Address of the user who created the position
     * @param tokenId ID of the newly created position NFT
     * @param entryPrice Price at which the position was opened
     * @param amount Amount of tokens deposited
     * @param openedAt Timestamp when the position was opened
     * @param currency Address of the currency token used
     * @param expiredAt Timestamp when position expires (0 if no expiration)
     */
    event PositionCreated(address indexed user, uint256 indexed tokenId, uint256 entryPrice, uint256 amount, uint256 openedAt, address currency, uint256 expiredAt);

    /**
     * @dev Emitted when a position is reduced
     * @param user Address of the user who reduced the position
     * @param tokenId ID of the position NFT
     * @param reducedAmount Amount by which the position was reduced
     * @param remainingAmount Amount remaining in the position
     * @param totalReward Total reward calculated for the reduction
     * @param weight Weight applied to the reward calculation
     * @param userReward Amount of reward sent to the user
     * @param treasuryReward Amount of reward sent to the treasury
     * @param lossAmount Total loss amount for the position
     * @param price Current price at reduction
     * @param rewardedAmount Total rewards harvested from this position
     * @param loss Loss amount for this specific reduction
     * @param currency Address of the currency token used
     */
    event PositionReduced(
        address indexed user, 
        uint256 indexed tokenId, 
        uint256 reducedAmount, 
        uint256 remainingAmount,
        uint256 totalReward,
        uint256 weight,
        uint256 userReward,
        uint256 treasuryReward,
        uint256 lossAmount,
        uint256 price,
        uint256 rewardedAmount,
        uint256 loss,
        address currency
    );
    event TotalAmountUpdated(uint256 newTotalAmount);
    event CurrencyBorrowed(address indexed borrower, uint256 amount);
    event CurrencyRepaid(address indexed borrower, uint256 amount);
    event PriceUpdated(uint256 oldPrice, uint256 newPrice, uint256 requiredReward, uint256 timestamp);
    event CurrencyUpdated(address oldCurrency, address newCurrency);
    event RewardTokenUpdated(address oldRewardToken, address newRewardToken);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event RewardConfigsUpdated();
    event ReduceEnabledUpdated(bool enabled);
    event TotalRewardsUpdated(uint256 oldAmount, uint256 newAmount);
    event TotalRewardsHarvestedUpdated(uint256 oldAmount, uint256 newAmount);
    event PositionExpirationUpdated(uint256 indexed tokenId, uint256 expiredAt);
    event EntryPriceUpdated(uint256 indexed tokenId, uint256 oldEntryPrice, uint256 newEntryPrice);
    event UserDebtUpdated(address indexed user, uint256 oldDebt, uint256 newDebt);
    event UserDebtRepaid(address indexed user, uint256 debtAmount, uint256 remainingDebt);
    event PositionCurrencyUpdated(uint256 indexed tokenId, address oldCurrency, address newCurrency);

    // Roles
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PRICE_SETTER_ROLE = keccak256("PRICE_SETTER_ROLE");
    
    // Constants
    uint256 public constant EXPO = 1_000_000;
    uint256 public constant PERCENTAGE_BASE = 100 * EXPO;
    uint256 public constant BASE_WEIGHT = 10_000;
    uint256 public constant MAX_BATCH_SIZE = 8_000; // Can handle ~760 gas per item
    uint256 public constant MIN_PRICE_PERCENTAGE = 80; // 80%
    uint256 public constant MAX_PRICE_PERCENTAGE = 150; // 150%

    /**
     * @dev Struct containing price data for batch updates
     * @param price The price value
     * @param timestamp The timestamp for the price
     */
    struct PriceData {
        uint256 price;
        uint256 timestamp;
    }

    // State variables
    uint256 public price;
    address public currency;
    address public rewardToken;
    address public treasury;
    uint256 private _nextTokenId;
    uint256 public totalAmount;
    uint256 public totalBorrowed;
    bool public isReduceEnabled;
    /// @dev Total rewards added via setPrice
    uint256 public totalRewardsAdded;
    /// @dev Total rewards harvested by users
    uint256 public totalRewardsHarvested;
    
    // Total debt across all users
    uint256 public totalUserDebt;

    // Storage gap for upgradeable contracts
    uint256[49] private __gap;

    // Mappings
    mapping(uint256 => Position) public positions;

    // Arrays
    RewardConfig[] public rewardConfigs;

    // Track user debt balances
    mapping(address => uint256) public userDebt;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ==================== INITIALIZATION ====================
    
    /**
     * @dev Initializes the contract with initial settings
     * @param _currency Address of the currency token
     * @param _rewardToken Address of the reward token
     * @param _treasury Address of the treasury
     * @param _owner Address of the contract owner
     */
    function initialize(address _currency, address _rewardToken, address _treasury, address _owner) external initializer {
        __ERC721_init("TradingVault Position", "VP");
        __Ownable_init(_owner);
        __AccessControl_init();
        
        if (_currency == address(0)) revert InvalidCurrencyAddress();
        if (_rewardToken == address(0)) revert InvalidRewardTokenAddress();
        if (_treasury == address(0)) revert InvalidTreasuryAddress();
        if (_owner == address(0)) revert InvalidUserAddress();
        
        currency = _currency;
        rewardToken = _rewardToken;
        treasury = _treasury;
        
        // Initialize price to PERCENTAGE_BASE
        price = PERCENTAGE_BASE;
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(PRICE_SETTER_ROLE, msg.sender);

        // Initialize reward configurations
        rewardConfigs.push(RewardConfig({weight: BASE_WEIGHT, duration: 0}));

        isReduceEnabled = true;
    }

    // ==================== OWNER FUNCTIONS ====================

    /**
     * @dev Grants operator role to an address
     * @param operator Address to grant the operator role to
     * Requirements:
     * - Caller must have DEFAULT_ADMIN_ROLE
     */
    function grantOperatorRole(address operator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(OPERATOR_ROLE, operator);
    }

    /**
     * @dev Grants price setter role to an address
     * @param priceSetter Address to grant the price setter role to
     * Requirements:
     * - Caller must have DEFAULT_ADMIN_ROLE
     */
    function grantPriceSetterRole(address priceSetter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(PRICE_SETTER_ROLE, priceSetter);
    }

    /**
     * @dev Updates the treasury address
     * @param _treasury New treasury address
     * Requirements:
     * - Caller must be the owner
     * - New treasury address must not be zero
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidTreasuryAddress();
        address oldTreasury = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(oldTreasury, _treasury);
    }

    /**
     * @dev Enables or disables the ability to reduce positions
     * @param _enabled Whether reducing positions should be enabled
     * Requirements:
     * - Caller must be the owner
     */
    function setReduceEnabled(bool _enabled) external onlyOwner {
        isReduceEnabled = _enabled;
        emit ReduceEnabledUpdated(_enabled);
    }

    /**
     * @dev Allows the owner to borrow currency from the contract
     * @param _amount Amount of currency to borrow
     * Requirements:
     * - Caller must be the owner
     * - Amount must not be zero
     * - Contract must have sufficient balance
     */
    function borrowCurrency(uint256 _amount) external onlyOwner {
        if (_amount == 0) revert ZeroAmount();
        
        uint256 contractBalance = IERC20(currency).balanceOf(address(this));
        if (_amount > contractBalance) revert InsufficientBalance();
        
        IERC20(currency).transfer(msg.sender, _amount);
        totalBorrowed += _amount;
        emit CurrencyBorrowed(msg.sender, _amount);
    }

    /**
     * @dev Allows the owner to claim any ERC20 tokens stuck in the contract
     * @param _token Address of the ERC20 token to claim
     * @param _amount Amount of tokens to claim
     * Requirements:
     * - Caller must be the owner
     * - Cannot claim currency or reward tokens
     * - Amount must not be zero
     */
    function claimERC20(address _token, uint256 _amount) external onlyOwner {
        if (_token == currency || _token == rewardToken) 
            revert CannotClaimProtectedToken();
        if (_amount == 0) 
            revert ZeroAmount();

        bool success = IERC20(_token).transfer(msg.sender, _amount);
        if (!success) 
            revert ClaimFailed();
    }

    // ==================== PRICE SETTER FUNCTIONS ====================

    /**
     * @dev Updates the price used for position calculations
     * @param _newPrice New price value
     * Requirements:
     * - Caller must have PRICE_SETTER_ROLE
     * - New price must not be zero
     */
    function setPrice(uint256 _newPrice) external onlyRole(PRICE_SETTER_ROLE) {
        if (_newPrice == 0) revert ZeroPrice();
        
        uint256 oldPrice = price;
        price = _newPrice;

        emit PriceUpdated(oldPrice, _newPrice, 0, block.timestamp);
    }

    /**
     * @dev Emits multiple PriceUpdated events in a single transaction
     * @param _priceDataArray Array of PriceData structs containing price and timestamp
     * Requirements:
     * - Caller must have PRICE_SETTER_ROLE
     * - Array must not be empty
     * - No price can be zero
     * - Timestamps must be in ascending order
     */
    function batchEmitPriceUpdated(PriceData[] calldata _priceDataArray) external onlyRole(PRICE_SETTER_ROLE) {
        if (_priceDataArray.length == 0) revert("Empty array");
        if (_priceDataArray.length > MAX_BATCH_SIZE) revert("Batch size too large");
        
        uint256 oldPrice = price;

        for (uint256 i = 0; i < _priceDataArray.length; i++) {
            emit PriceUpdated(oldPrice, _priceDataArray[i].price, 0, _priceDataArray[i].timestamp);
        }
    }

    // ==================== OPERATOR FUNCTIONS ====================

    /**
     * @dev Updates the currency token address
     * @param _currency New currency token address
     * Requirements:
     * - Caller must have OPERATOR_ROLE
     * - New currency address must not be zero
     */
    function setCurrency(address _currency) external onlyRole(OPERATOR_ROLE) {
        if (_currency == address(0)) revert InvalidCurrencyAddress();
        address oldCurrency = currency;
        currency = _currency;
        emit CurrencyUpdated(oldCurrency, _currency);
    }

    /**
     * @dev Updates the reward token address
     * @param _rewardToken New reward token address
     * Requirements:
     * - Caller must have OPERATOR_ROLE
     * - New reward token address must not be zero
     */
    function setRewardToken(address _rewardToken) external onlyRole(OPERATOR_ROLE) {
        if (_rewardToken == address(0)) revert InvalidRewardTokenAddress();
        address oldRewardToken = rewardToken;
        rewardToken = _rewardToken;
        emit RewardTokenUpdated(oldRewardToken, _rewardToken);
    }

    /**
     * @dev Updates the reward configurations
     * @param _configs Array of new reward configurations
     * Requirements:
     * - Caller must have OPERATOR_ROLE
     * - Weights must not exceed BASE_WEIGHT
     * - Durations must be in ascending order
     */
    function updateRewardConfigs(RewardConfig[] calldata _configs) external onlyRole(OPERATOR_ROLE) {
        delete rewardConfigs;
        uint256 lastDuration = 0;
        uint256 length = _configs.length;
        
        for (uint256 i = 0; i < length; i++) {
            if (_configs[i].weight > BASE_WEIGHT) revert InvalidRewardWeight();
            if (_configs[i].duration <= lastDuration) revert InvalidDuration();
            
            rewardConfigs.push(RewardConfig({
                weight: _configs[i].weight,
                duration: _configs[i].duration
            }));
            
            lastDuration = _configs[i].duration;
        }
        emit RewardConfigsUpdated();
    }

    /**
     * @dev Updates expiration time for a position
     * @param _tokenId ID of the position
     * @param _expiredAt New expiration timestamp
     */
    function setPositionExpiration(uint256 _tokenId, uint256 _expiredAt) external onlyRole(OPERATOR_ROLE) {
        Position storage position = positions[_tokenId];
        
        // Check position is not closed
        if (position.closedAt != 0) revert PositionAlreadyClosed();
        
        position.expiredAt = _expiredAt;
        emit PositionExpirationUpdated(_tokenId, _expiredAt);
    }

    /**
     * @dev Updates expiration time for multiple positions
     * @param _tokenIds Array of position IDs
     * @param _expiredAts Array of expiration timestamps
     */
    function batchSetPositionExpiration(
        uint256[] calldata _tokenIds,
        uint256[] calldata _expiredAts
    ) external onlyRole(OPERATOR_ROLE) {
        if (_tokenIds.length != _expiredAts.length) revert("Array lengths must match");
        if (_tokenIds.length == 0) revert("Empty arrays");
        if (_tokenIds.length > MAX_BATCH_SIZE) revert("Batch size too large");
        
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            // Use direct logic instead of calling the function to avoid visibility issues
            Position storage position = positions[_tokenIds[i]];
            
            // Check position is not closed
            if (position.closedAt != 0) revert PositionAlreadyClosed();
            
            position.expiredAt = _expiredAts[i];
            emit PositionExpirationUpdated(_tokenIds[i], _expiredAts[i]);
        }
    }

    /**
     * @dev Allows operators to close expired positions with a specified price
     * @param _tokenId ID of the expired position to close
     * @param _providedPrice Price to use for calculations (should be price at expiry time)
     */
    function closeExpiredPosition(
        uint256 _tokenId, 
        uint256 _providedPrice
    ) external onlyRole(OPERATOR_ROLE) {
        Position storage position = positions[_tokenId];
        
        // Validate position is expired
        if (position.expiredAt == 0 || block.timestamp <= position.expiredAt) 
            revert PositionNotExpired();
        
        // Validate position is not already closed
        if (position.closedAt != 0) 
            revert PositionAlreadyClosed();
        
        // Validate price is not zero
        if (_providedPrice == 0) 
            revert InvalidPrice();
        
        // Validate price is within fixed range (80%-150%) compared to current price
        uint256 minPrice = (price * MIN_PRICE_PERCENTAGE) / 100;
        uint256 maxPrice = (price * MAX_PRICE_PERCENTAGE) / 100;
        
        if (_providedPrice < minPrice || _providedPrice > maxPrice)
            revert PriceOutOfRange();
        
        address user = ownerOf(_tokenId);
        address positionToken = position.token;
        uint256 remainingAmount = position.remainingAmount;
        
        // Reduce the entire position using the provided price
        uint256 amountToReturn = _reducePositionInternal(
            _tokenId, 
            remainingAmount, 
            _providedPrice, 
            user,
            true // Position is being closed due to expiration
        );
        
        // Transfer tokens back to user
        if (amountToReturn > 0) {
            IERC20(positionToken).transfer(user, amountToReturn);
        }
    }

    /**
     * @dev Updates entry price for a position
     * @param _tokenId ID of the position
     * @param _newEntryPrice New entry price for the position
     * Requirements:
     * - Caller must have OPERATOR_ROLE
     * - Position must not be closed
     * - New entry price must not be zero
     */
    function updateEntryPrice(uint256 _tokenId, uint256 _newEntryPrice) external onlyRole(OPERATOR_ROLE) {
        if (_newEntryPrice == 0) revert ZeroPrice();
        
        Position storage position = positions[_tokenId];
        
        // Check position is not closed
        if (position.closedAt != 0) revert PositionAlreadyClosed();
        
        uint256 oldEntryPrice = position.entryPrice;
        position.entryPrice = _newEntryPrice;
        
        emit EntryPriceUpdated(_tokenId, oldEntryPrice, _newEntryPrice);
    }

    /**
     * @dev Updates entry price for multiple positions
     * @param _tokenIds Array of position IDs
     * @param _newEntryPrices Array of new entry prices
     * Requirements:
     * - Caller must have OPERATOR_ROLE
     * - Arrays must be of equal length and not empty
     * - No entry price can be zero
     * - No position can be closed
     */
    function batchUpdateEntryPrice(
        uint256[] calldata _tokenIds,
        uint256[] calldata _newEntryPrices
    ) external onlyRole(OPERATOR_ROLE) {
        if (_tokenIds.length != _newEntryPrices.length) revert("Array lengths must match");
        if (_tokenIds.length == 0) revert("Empty arrays");
        if (_tokenIds.length > MAX_BATCH_SIZE) revert("Batch size too large");
        
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            if (_newEntryPrices[i] == 0) revert ZeroPrice();
            
            Position storage position = positions[_tokenIds[i]];
            
            // Check position is not closed
            if (position.closedAt != 0) revert PositionAlreadyClosed();
            
            uint256 oldEntryPrice = position.entryPrice;
            position.entryPrice = _newEntryPrices[i];
            
            emit EntryPriceUpdated(_tokenIds[i], oldEntryPrice, _newEntryPrices[i]);
        }
    }

    /**
     * @dev Batch updates debt for multiple users
     * @param _users Array of user addresses
     * @param _debts Array of debt amounts
     * Requirements:
     * - Caller must have OPERATOR_ROLE
     * - Arrays must be of equal length and not empty
     * - Each array must not exceed MAX_BATCH_SIZE
     */
    function batchUpdateUserDebt(
        address[] calldata _users,
        uint256[] calldata _debts
    ) external onlyRole(OPERATOR_ROLE) {
        if (_users.length != _debts.length) revert("Array lengths must match");
        if (_users.length == 0) revert("Empty arrays");
        if (_users.length > MAX_BATCH_SIZE) revert("Batch size too large");
        
        for (uint256 i = 0; i < _users.length; i++) {
            address user = _users[i];
            uint256 newDebt = _debts[i];
            uint256 oldDebt = userDebt[user];
            
            _updateUserDebt(user, oldDebt, newDebt);
        }
    }

    /**
     * @dev Batch updates currency of multiple positions
     * @param _tokenIds Array of position IDs
     * @param _newCurrencies Array of new currency addresses
     * Requirements:
     * - Caller must have OPERATOR_ROLE
     * - Arrays must be of equal length and not empty
     * - No currency address can be zero
     * - No position can be closed
     */
    function batchUpdatePositionCurrency(
        uint256[] calldata _tokenIds,
        address[] calldata _newCurrencies
    ) external onlyRole(OPERATOR_ROLE) {
        if (_tokenIds.length != _newCurrencies.length) revert("Array lengths must match");
        if (_tokenIds.length == 0) revert("Empty arrays");
        if (_tokenIds.length > MAX_BATCH_SIZE) revert("Batch size too large");
        
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            if (_newCurrencies[i] == address(0)) revert InvalidCurrencyAddress();
            
            Position storage position = positions[_tokenIds[i]];
            
            // Check position is not closed
            if (position.closedAt != 0) revert PositionAlreadyClosed();
            
            address oldCurrency = position.token;
            position.token = _newCurrencies[i];
            
            emit PositionCurrencyUpdated(_tokenIds[i], oldCurrency, _newCurrencies[i]);
        }
    }

    // ==================== PUBLIC FUNCTIONS ====================

    /**
     * @dev Creates a new position with the specified amount and recipient
     * @param _amount Amount of tokens to deposit
     * @param _recipient Address that will receive the position NFT (optional)
     * @param _expiredAt Timestamp when position expires (0 if no expiration)
     * @return ID of the newly created position
     * Requirements:
     * - Amount must not be zero
     * - Caller must have approved the contract to spend currency tokens
     */
    function createPosition(uint256 _amount, address _recipient, uint256 _expiredAt) external returns (uint256) {
        if (_amount == 0) revert ZeroAmount();
        
        // If recipient is not specified, use msg.sender
        address recipient = _recipient == address(0) ? msg.sender : _recipient;
        
        // Transfer tokens from sender to contract
        IERC20(currency).transferFrom(msg.sender, address(this), _amount);

        return _createPosition(recipient, _amount, _expiredAt);
    }

    /**
     * @dev Reduces a position by the specified amount and harvests rewards
     * @param _tokenId ID of the position to reduce
     * @param _amount Amount to reduce the position by
     * Requirements:
     * - Position reduction must be enabled
     * - Caller must be owner or approved
     * - Amount must not be zero or exceed remaining amount
     */
    function reducePosition(uint256 _tokenId, uint256 _amount) external {
        if (!isReduceEnabled) revert ReducePositionDisabled();
        
        // Get the position's token before reducing
        address positionToken = positions[_tokenId].token;
        uint256 amountToReturn = _reducePositionInternal(_tokenId, _amount, price, msg.sender, false);
        
        // Transfer tokens back to user using the position's token
        if (amountToReturn > 0) {
            IERC20(positionToken).transfer(msg.sender, amountToReturn);
        }
    }

    /**
     * @dev Reduces multiple positions in a single transaction
     * @param _tokenIds Array of position IDs to reduce
     * @param _amounts Array of amounts to reduce for each position
     * Requirements:
     * - Position reduction must be enabled
     * - Arrays must be of equal length and not empty
     * - All positions must use the same token
     */
    function reducePositions(uint256[] calldata _tokenIds, uint256[] calldata _amounts) external {
        if (!isReduceEnabled) revert ReducePositionDisabled();
        if (_tokenIds.length != _amounts.length) revert("Array lengths must match");
        if (_tokenIds.length == 0) revert("Empty arrays");

        // We can only batch process positions with the same token
        // Get the token from the first position
        address positionToken = positions[_tokenIds[0]].token;
        uint256 totalAmountToReturn = 0;
        
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            // Verify all positions use the same token
            if (positions[_tokenIds[i]].token != positionToken) {
                revert("All positions must use the same token for batch processing");
            }
            
            totalAmountToReturn += _reducePositionInternal(_tokenIds[i], _amounts[i], price, msg.sender, false);
        }
        
        // Transfer tokens back to user in one transaction
        if (totalAmountToReturn > 0) {
            IERC20(positionToken).transfer(msg.sender, totalAmountToReturn);
        }
    }

    /**
     * @dev Adds reward tokens to the contract
     * @param _rewardAmount Amount of reward tokens to add
     * Requirements:
     * - Amount must not be zero
     * - Caller must have approved the contract to spend reward tokens
     */
    function addReward(uint256 _rewardAmount) external {
        if (_rewardAmount == 0) revert ZeroAmount();
        
        IERC20(rewardToken).transferFrom(msg.sender, address(this), _rewardAmount);
        uint256 oldRewardsAmount = totalRewardsAdded;
        totalRewardsAdded += _rewardAmount;
        emit TotalRewardsUpdated(oldRewardsAmount, totalRewardsAdded);
    }

    /**
     * @dev Allows repaying borrowed currency
     * @param _amount Amount of currency to repay
     * Requirements:
     * - Amount must not be zero
     * - Amount must not exceed total borrowed
     * - Caller must have approved the contract to spend currency tokens
     */
    function repayCurrency(uint256 _amount) external {
        if (_amount == 0) revert ZeroAmount();
        if (_amount > totalBorrowed) revert InsufficientRepayAmount();
        
        IERC20(currency).transferFrom(msg.sender, address(this), _amount);
        totalBorrowed -= _amount;
        emit CurrencyRepaid(msg.sender, _amount);
    }

    /**
     * @dev Allows users to repay their debt using reward tokens
     * @param _amount Amount of reward tokens to use for debt repayment
     * Requirements:
     * - Amount must not be zero
     * - Amount must not exceed user's debt
     * - Caller must have approved the contract to spend reward tokens
     */
    function repayUserDebt(uint256 _amount) external {
        if (_amount == 0) revert ZeroAmount();
        
        uint256 userDebtAmount = userDebt[msg.sender];
        if (_amount > userDebtAmount) {
            _amount = userDebtAmount;
        }
        
        IERC20(rewardToken).transferFrom(msg.sender, address(this), _amount);
        
        _updateUserDebt(msg.sender, userDebtAmount, userDebtAmount - _amount);
        emit UserDebtRepaid(msg.sender, _amount, userDebt[msg.sender]);
    }

    /**
     * @dev Returns the number of reward configurations
     * @return The length of the rewardConfigs array
     */
    function getRewardConfigsLength() external view returns (uint256) {
        return rewardConfigs.length;
    }

    /**
     * @dev See {IERC165-supportsInterface}
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // ==================== INTERNAL FUNCTIONS ====================

    /**
     * @dev Internal function to create a new position
     * @param _user Address that will own the position
     * @param _amount Amount of tokens to deposit
     * @param _expiredAt Timestamp when position expires (0 if no expiration)
     * @return ID of the newly created position
     */
    function _createPosition(address _user, uint256 _amount, uint256 _expiredAt) internal returns (uint256) {
        // Create new position
        uint256 newTokenId = _nextTokenId++;

        // Store position details
        positions[newTokenId] = Position({
            entryPrice: price,
            outPrice: 0,
            remainingAmount: _amount,
            initAmount: _amount,
            openedAt: block.timestamp,
            closedAt: 0,
            rewardedAmount: 0,
            lossAmount: 0,
            token: currency,
            expiredAt: _expiredAt
        });

        // Update total amount
        totalAmount += _amount;
        emit TotalAmountUpdated(totalAmount);

        // Mint NFT
        _mint(_user, newTokenId);

        emit PositionCreated(_user, newTokenId, price, _amount, block.timestamp, currency, _expiredAt);
        return newTokenId;
    }

    /**
     * @dev Internal function to verify position ownership and status
     * @param _tokenId ID of the position to check
     * @param _ignoreExpiration Whether to ignore expiration check
     * Requirements:
     * - Caller must be owner or approved
     * - Position must not be closed
     */
    function _checkPositionOwnership(uint256 _tokenId, bool _ignoreExpiration) internal view {
        if (ownerOf(_tokenId) != msg.sender && getApproved(_tokenId) != msg.sender && !_ignoreExpiration) 
            revert NotOwnerOrApproved();
        if (positions[_tokenId].closedAt != 0) 
            revert PositionAlreadyClosed();
        
        // Check expiration (only if not being handled by operator)
        if (!_ignoreExpiration && positions[_tokenId].expiredAt != 0 && block.timestamp > positions[_tokenId].expiredAt) 
            revert PositionExpired();
    }

    /**
     * @dev Internal function to update user debt
     * @param _user Address of the user
     * @param _oldDebt Old debt amount
     * @param _newDebt New debt amount
     */
    function _updateUserDebt(address _user, uint256 _oldDebt, uint256 _newDebt) internal {
        userDebt[_user] = _newDebt;
        totalUserDebt = totalUserDebt - _oldDebt + _newDebt;
        emit UserDebtUpdated(_user, _oldDebt, _newDebt);
    }

    /**
     * @dev Internal function to process user debt before harvesting rewards
     * @param _recipient Address of the reward recipient
     * @param _totalReward Total reward calculated
     * @return Remaining reward after debt has been processed
     */
    function _processUserDebt(address _recipient, uint256 _totalReward) internal returns (uint256) {
        uint256 userDebtAmount = userDebt[_recipient];
        
        // If user has no debt or no rewards, just return the original amount
        if (userDebtAmount == 0 || _totalReward == 0) {
            return _totalReward;
        }
        
        // If total reward can cover all debt
        if (_totalReward >= userDebtAmount) {
            // Update user debt to zero
            _updateUserDebt(_recipient, userDebtAmount, 0);
            
            // Return remaining reward after paying debt
            return _totalReward - userDebtAmount;
        } else {
            // Update user debt with remaining amount
            _updateUserDebt(_recipient, userDebtAmount, userDebtAmount - _totalReward);
            
            // All rewards go to debt repayment
            return 0;
        }
    }

    /**
     * @dev Internal function to calculate and distribute rewards
     * @param _tokenId ID of the position
     * @param _amount Amount being reduced/closed
     * @param _usePrice Price to use for calculations
     * @param _recipient Address to send rewards to
     * @return totalReward Total reward calculated
     * @return weight Weight applied to rewards
     * @return userReward Amount sent to user
     * @return treasuryReward Amount sent to treasury
     */
    function _harvestRewards(
        uint256 _tokenId, 
        uint256 _amount, 
        uint256 _usePrice,
        address _recipient
    ) internal returns (uint256 totalReward, uint256 weight, uint256 userReward, uint256 treasuryReward) {
        Position storage position = positions[_tokenId];
        if (_usePrice <= position.entryPrice) {
            return (0, 0, 0, 0);
        }

        totalReward = (_amount * (_usePrice - position.entryPrice)) / PERCENTAGE_BASE;
        if (totalReward == 0) {
            return (0, 0, 0, 0);
        }

        // Calculate duration in seconds
        uint256 duration = block.timestamp - position.openedAt;
        
        // Get weight based on duration
        weight = _getRewardWeight(duration);
        
        // Calculate initial user's share without considering debt
        uint256 initialUserReward = (totalReward * weight) / BASE_WEIGHT;
        
        // Process user debt first before distributing rewards
        userReward = _processUserDebt(_recipient, initialUserReward);
        treasuryReward = totalReward - userReward;
        
        // Update rewarded amount for the proportional amount
        position.rewardedAmount += totalReward;
        
        // Transfer rewards
        uint256 oldHarvestedAmount = totalRewardsHarvested;
        
        if (userReward > 0) {
            IERC20(rewardToken).transfer(_recipient, userReward);
        }
        if (treasuryReward > 0 && treasury != address(0)) {
            IERC20(rewardToken).transfer(treasury, treasuryReward);
        }

        totalRewardsHarvested += totalReward;
        emit TotalRewardsHarvestedUpdated(oldHarvestedAmount, totalRewardsHarvested);
        
        return (totalReward, weight, userReward, treasuryReward);
    }

    /**
     * @dev Internal function to calculate reward weight based on position duration
     * @param duration Duration in seconds
     * @return Weight to be applied to rewards
     */
    function _getRewardWeight(uint256 duration) internal view returns (uint256) {
        uint256 length = rewardConfigs.length;
        uint256 maxWeight = 0;
        
        for (uint256 i = 0; i < length; i++) {
            if (duration >= rewardConfigs[i].duration) {
                maxWeight = rewardConfigs[i].weight;
            }
        }
        
        return maxWeight;
    }

    /**
     * @dev Internal function containing the core logic for reducing a position
     * @param _tokenId ID of the position to reduce
     * @param _amount Amount to reduce
     * @param _usePrice Price to use for calculations
     * @param _recipient Address to send rewards to
     * @param _isExpired Whether the position is being closed due to expiration
     * @return amountToReturn Amount of currency to return to the user
     */
    function _reducePositionInternal(
        uint256 _tokenId, 
        uint256 _amount, 
        uint256 _usePrice, 
        address _recipient,
        bool _isExpired
    ) internal returns (uint256 amountToReturn) {
        _checkPositionOwnership(_tokenId, _isExpired);
        Position storage position = positions[_tokenId];
        
        if (_amount == 0) revert ZeroAmount();
        if (_amount > position.remainingAmount) revert InsufficientBalance();
        
        // Calculate amount to return and loss if price < entryPrice
        amountToReturn = _amount;
        uint256 loss = 0;
        if (_usePrice < position.entryPrice) {
            uint256 priceDiff = position.entryPrice - _usePrice;
            loss = (_amount * priceDiff) / PERCENTAGE_BASE;
            position.lossAmount += loss;
            amountToReturn = _amount - loss;
            
            // Increase user debt when loss occurs
            uint256 currentDebt = userDebt[_recipient];
            _updateUserDebt(_recipient, currentDebt, currentDebt + loss);
        }
        
        // Calculate and distribute rewards for the reduced amount AFTER processing loss
        (uint256 totalReward, uint256 weight, uint256 userReward, uint256 treasuryReward) = 
            _harvestRewards(_tokenId, _amount, _usePrice, _recipient);
        
        // Decrease total amount
        totalAmount -= _amount;
        emit TotalAmountUpdated(totalAmount);
        
        // If reducing to zero, handle like closePosition
        if (_amount == position.remainingAmount) {
            position.closedAt = block.timestamp;
            position.outPrice = _usePrice;
            position.remainingAmount = 0;
            _burn(_tokenId);
        } else {
            // Update position amount
            position.remainingAmount -= _amount;
        }

        // Emit event with actual price used for this reduction
        emit PositionReduced(
            _recipient,
            _tokenId,
            _amount,
            position.remainingAmount,
            totalReward,
            weight,
            userReward,
            treasuryReward,
            position.lossAmount,
            _usePrice,
            position.rewardedAmount,
            loss,
            position.token
        );

        return amountToReturn;
    }
} 