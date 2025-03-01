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
    }

    /**
     * @dev Emitted when a new position is created
     * @param user Address of the user who created the position
     * @param tokenId ID of the newly created position NFT
     * @param entryPrice Price at which the position was opened
     * @param amount Amount of tokens deposited
     * @param openedAt Timestamp when the position was opened
     * @param currency Address of the currency token used
     */
    event PositionCreated(address indexed user, uint256 indexed tokenId, uint256 entryPrice, uint256 amount, uint256 openedAt, address currency);

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
    event PriceUpdated(uint256 oldPrice, uint256 newPrice, uint256 requiredReward);
    event CurrencyUpdated(address oldCurrency, address newCurrency);
    event RewardTokenUpdated(address oldRewardToken, address newRewardToken);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event RewardConfigsUpdated();
    event ReduceEnabledUpdated(bool enabled);
    event TotalRewardsUpdated(uint256 oldAmount, uint256 newAmount);
    event TotalRewardsHarvestedUpdated(uint256 oldAmount, uint256 newAmount);

    // Roles
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PRICE_SETTER_ROLE = keccak256("PRICE_SETTER_ROLE");
    
    // Constants
    uint256 public constant EXPO = 1_000_000;
    uint256 public constant PERCENTAGE_BASE = 100 * EXPO;
    uint256 public constant BASE_WEIGHT = 10_000;

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

    // Storage gap for upgradeable contracts
    uint256[50] private __gap;

    // Mappings
    mapping(uint256 => Position) public positions;

    // Arrays
    RewardConfig[] public rewardConfigs;

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
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(PRICE_SETTER_ROLE, msg.sender);

        // Initialize reward configurations
        rewardConfigs.push(RewardConfig({weight: 100, duration: 0}));

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
        emit PriceUpdated(oldPrice, _newPrice, 0);
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

    // ==================== PUBLIC FUNCTIONS ====================

    /**
     * @dev Creates a new position with the specified amount and recipient
     * @param _amount Amount of tokens to deposit
     * @param _recipient Address that will receive the position NFT (optional)
     * @return ID of the newly created position
     * Requirements:
     * - Amount must not be zero
     * - Caller must have approved the contract to spend currency tokens
     */
    function createPosition(uint256 _amount, address _recipient) external returns (uint256) {
        if (_amount == 0) revert ZeroAmount();
        
        // If recipient is not specified, use msg.sender
        address recipient = _recipient == address(0) ? msg.sender : _recipient;
        
        // Transfer tokens from sender to contract
        IERC20(currency).transferFrom(msg.sender, address(this), _amount);

        return _createPosition(recipient, _amount);
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
        uint256 amountToReturn = _reducePositionInternal(_tokenId, _amount);
        
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
            
            totalAmountToReturn += _reducePositionInternal(_tokenIds[i], _amounts[i]);
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
     * @return ID of the newly created position
     */
    function _createPosition(address _user, uint256 _amount) internal returns (uint256) {
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
            token: currency // Store the contract's current currency
        });

        // Update total amount
        totalAmount += _amount;
        emit TotalAmountUpdated(totalAmount);

        // Mint NFT
        _mint(_user, newTokenId);

        emit PositionCreated(_user, newTokenId, price, _amount, block.timestamp, currency);
        return newTokenId;
    }

    /**
     * @dev Internal function to verify position ownership and status
     * @param _tokenId ID of the position to check
     * Requirements:
     * - Caller must be owner or approved
     * - Position must not be closed
     */
    function _checkPositionOwnership(uint256 _tokenId) internal view {
        if (ownerOf(_tokenId) != msg.sender && getApproved(_tokenId) != msg.sender) revert NotOwnerOrApproved();
        if (positions[_tokenId].closedAt != 0) revert PositionAlreadyClosed();
    }

    /**
     * @dev Internal function to calculate and distribute rewards
     * @param _tokenId ID of the position
     * @param _amount Amount being reduced/closed
     * @return totalReward Total reward calculated
     * @return weight Weight applied to rewards
     * @return userReward Amount sent to user
     * @return treasuryReward Amount sent to treasury
     */
    function _harvestRewards(uint256 _tokenId, uint256 _amount) internal returns (uint256 totalReward, uint256 weight, uint256 userReward, uint256 treasuryReward) {
        Position storage position = positions[_tokenId];
        if (price <= position.entryPrice) {
            return (0, 0, 0, 0);
        }

        totalReward = (_amount * (price - position.entryPrice)) / PERCENTAGE_BASE;
        if (totalReward == 0) {
            return (0, 0, 0, 0);
        }

        // Calculate duration in seconds
        uint256 duration = block.timestamp - position.openedAt;
        
        // Get weight based on duration
        weight = _getRewardWeight(duration);
        
        // Calculate user's share and treasury's share
        userReward = (totalReward * weight) / BASE_WEIGHT;
        treasuryReward = totalReward - userReward;
        
        // Update rewarded amount for the proportional amount
        position.rewardedAmount += totalReward;
        
        // Transfer rewards
        uint256 oldHarvestedAmount = totalRewardsHarvested;
        
        if (userReward > 0) {
            IERC20(rewardToken).transfer(msg.sender, userReward);
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
     * @return amountToReturn Amount of currency to return to the user
     */
    function _reducePositionInternal(uint256 _tokenId, uint256 _amount) internal returns (uint256 amountToReturn) {
        _checkPositionOwnership(_tokenId);
        Position storage position = positions[_tokenId];
        
        if (_amount == 0) revert ZeroAmount();
        if (_amount > position.remainingAmount) revert InsufficientBalance();
        
        // Calculate and distribute rewards for the reduced amount
        (uint256 totalReward, uint256 weight, uint256 userReward, uint256 treasuryReward) = _harvestRewards(_tokenId, _amount);
        
        // Calculate amount to return and loss if price < entryPrice
        amountToReturn = _amount;
        uint256 loss = 0;
        if (price < position.entryPrice) {
            uint256 priceDiff = position.entryPrice - price;
            loss = (_amount * priceDiff) / PERCENTAGE_BASE;
            position.lossAmount += loss;
            amountToReturn = _amount - loss;
        }
        
        // Decrease total amount
        totalAmount -= _amount;
        emit TotalAmountUpdated(totalAmount);
        
        // If reducing to zero, handle like closePosition
        if (_amount == position.remainingAmount) {
            position.closedAt = block.timestamp;
            position.outPrice = price;
            position.remainingAmount = 0;
            _burn(_tokenId);
            _emitPositionReduced(_tokenId, _amount, 0, totalReward, weight, userReward, treasuryReward, position.lossAmount, position.rewardedAmount, loss);
        } else {
            // Update position amount
            position.remainingAmount -= _amount;
            _emitPositionReduced(_tokenId, _amount, position.remainingAmount, totalReward, weight, userReward, treasuryReward, position.lossAmount, position.rewardedAmount, loss);
        }

        return amountToReturn;
    }

    // ==================== PRIVATE FUNCTIONS ====================

    /**
     * @dev Helper function to emit PositionReduced event
     * @param _tokenId ID of the position
     * @param _reducedAmount Amount reduced
     * @param _remainingAmount Amount remaining
     * @param _totalReward Total reward calculated
     * @param _weight Weight applied
     * @param _userReward User's reward
     * @param _treasuryReward Treasury's reward
     * @param _lossAmount Total loss amount
     * @param _rewardedAmount Total rewarded amount
     * @param _loss Loss for this reduction
     */
    function _emitPositionReduced(
        uint256 _tokenId,
        uint256 _reducedAmount,
        uint256 _remainingAmount,
        uint256 _totalReward,
        uint256 _weight,
        uint256 _userReward,
        uint256 _treasuryReward,
        uint256 _lossAmount,
        uint256 _rewardedAmount,
        uint256 _loss
    ) private {
        // Get the position's token directly from storage
        address positionToken = positions[_tokenId].token;
        
        emit PositionReduced(
            msg.sender,
            _tokenId,
            _reducedAmount,
            _remainingAmount,
            _totalReward,
            _weight,
            _userReward,
            _treasuryReward,
            _lossAmount,
            price,
            _rewardedAmount,
            _loss,
            positionToken
        );
    }
} 