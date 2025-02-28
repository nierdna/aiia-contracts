// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

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

    // Roles
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PRICE_SETTER_ROLE = keccak256("PRICE_SETTER_ROLE");
    
    // Constants
    uint256 public constant EXPO = 1_000_000;
    uint256 public constant EXPO_100 = 100 * EXPO;
    uint256 public constant BASE_WEIGHT = 10_000;
    // Reward configuration struct
    struct RewardConfig {
        uint256 weight; // Weight for user's share (out of 100)
        uint256 duration; // Duration in days
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

    // Array of reward configurations
    RewardConfig[] public rewardConfigs;

    // Function to get the length of rewardConfigs array
    function getRewardConfigsLength() external view returns (uint256) {
        return rewardConfigs.length;
    }

    // Position struct to store position details
    struct Position {
        uint256 entryPrice;
        uint256 outPrice;
        uint256 remainingAmount;
        uint256 initAmount; // Initial amount when position was opened
        uint256 openedAt;
        uint256 closedAt; // 0 means position is still open
        uint256 rewardedAmount; // Total rewards harvested from this position
        uint256 lossAmount; // Total loss when reducing position at price < entryPrice
    }

    // Mapping from token ID to Position
    mapping(uint256 => Position) public positions;

    // Events
    event PositionCreated(address indexed user, uint256 indexed tokenId, uint256 entryPrice, uint256 amount, uint256 openedAt);
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
        uint256 loss
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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _currency, address _rewardToken) public initializer {
        __ERC721_init("TradingVault Position", "VP");
        __Ownable_init(msg.sender);
        __AccessControl_init();
        
        currency = _currency;
        rewardToken = _rewardToken;
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(PRICE_SETTER_ROLE, msg.sender);

        // Initialize reward configurations
        rewardConfigs.push(RewardConfig({weight: 100, duration: 0}));

        isReduceEnabled = true;
    }

    // Function to grant operator role (only admin)
    function grantOperatorRole(address operator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(OPERATOR_ROLE, operator);
    }

    // Function to grant price setter role (only admin)
    function grantPriceSetterRole(address priceSetter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(PRICE_SETTER_ROLE, priceSetter);
    }

    // Function to update price (only price setter)
    function setPrice(uint256 _newPrice) external onlyRole(PRICE_SETTER_ROLE) {
        if (_newPrice == 0) revert ZeroPrice();
        
        uint256 oldPrice = price;
        price = _newPrice;
        emit PriceUpdated(oldPrice, _newPrice, 0);
    }

    // Function to add rewards (anyone can add)
    function addReward(uint256 _rewardAmount) external {
        if (_rewardAmount == 0) revert ZeroAmount();
        
        IERC20(rewardToken).transferFrom(msg.sender, address(this), _rewardAmount);
        uint256 oldRewardsAmount = totalRewardsAdded;
        totalRewardsAdded += _rewardAmount;
        emit TotalRewardsUpdated(oldRewardsAmount, totalRewardsAdded);
    }

    // Function to update currency address (only owner)
    function setCurrency(address _currency) external onlyOwner {
        if (_currency == address(0)) revert InvalidCurrencyAddress();
        address oldCurrency = currency;
        currency = _currency;
        emit CurrencyUpdated(oldCurrency, _currency);
    }

    // Function to update reward token address (only owner)
    function setRewardToken(address _rewardToken) external onlyOwner {
        if (_rewardToken == address(0)) revert InvalidRewardTokenAddress();
        address oldRewardToken = rewardToken;
        rewardToken = _rewardToken;
        emit RewardTokenUpdated(oldRewardToken, _rewardToken);
    }

    // Function to set treasury address
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidTreasuryAddress();
        address oldTreasury = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(oldTreasury, _treasury);
    }

    // Function to update reward configurations
    function updateRewardConfigs(RewardConfig[] calldata _configs) external onlyOwner {
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

    // Internal function to get reward weight based on duration
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

    // Internal function to create position
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
            lossAmount: 0
        });

        // Update total amount
        totalAmount += _amount;
        emit TotalAmountUpdated(totalAmount);

        // Mint NFT
        _mint(_user, newTokenId);

        emit PositionCreated(_user, newTokenId, price, _amount, block.timestamp);
        return newTokenId;
    }

    // Function to create a new position
    function createPosition(uint256 _amount) external returns (uint256) {
        if (_amount == 0) revert ZeroAmount();
        
        // Transfer tokens from user to contract
        IERC20(currency).transferFrom(msg.sender, address(this), _amount);

        return _createPosition(msg.sender, _amount);
    }

    // Function for operators to create position for a target user
    function createPositionForUser(address _user, uint256 _amount) external onlyRole(OPERATOR_ROLE) returns (uint256) {
        if (_amount == 0) revert ZeroAmount();
        if (_user == address(0)) revert InvalidUserAddress();
        
        // Transfer tokens from operator to contract
        IERC20(currency).transferFrom(msg.sender, address(this), _amount);

        return _createPosition(_user, _amount);
    }

    // Internal function to check ownership
    function _checkPositionOwnership(uint256 _tokenId) internal view {
        if (ownerOf(_tokenId) != msg.sender && getApproved(_tokenId) != msg.sender) revert NotOwnerOrApproved();
        if (positions[_tokenId].closedAt != 0) revert PositionAlreadyClosed();
    }

    // Internal function to calculate and transfer rewards
    function _harvestRewards(uint256 _tokenId, uint256 _amount) internal returns (uint256 totalReward, uint256 weight, uint256 userReward, uint256 treasuryReward) {
        Position storage position = positions[_tokenId];
        if (price <= position.entryPrice) {
            return (0, 0, 0, 0);
        }

        totalReward = (_amount * (price - position.entryPrice)) / EXPO_100;
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

    // Function to toggle reduce position functionality (only owner)
    function setReduceEnabled(bool _enabled) external onlyOwner {
        isReduceEnabled = _enabled;
        emit ReduceEnabledUpdated(_enabled);
    }

    // Function to reduce position amount and harvest proportional rewards
    function reducePosition(uint256 _tokenId, uint256 _amount) external {
        if (!isReduceEnabled) revert ReducePositionDisabled();
        
        uint256 amountToReturn = _reducePositionInternal(_tokenId, _amount);
        
        // Transfer tokens back to user
        if (amountToReturn > 0) {
            IERC20(currency).transfer(msg.sender, amountToReturn);
        }
    }

    /**
     * @notice Internal function containing the core logic for reducing a position
     * @param _tokenId Token ID of the position to reduce
     * @param _amount Amount to reduce
     * @return amountToReturn The amount of currency to return to the user
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
            loss = (_amount * priceDiff) / (100 * EXPO);
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

    /**
     * @notice Helper function to emit PositionReduced event to avoid stack too deep errors
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
            _loss
        );
    }

    /**
     * @notice Reduces multiple positions in a single transaction
     * @param _tokenIds Array of token IDs to reduce
     * @param _amounts Array of amounts to reduce for each position
     * @dev Arrays must be of equal length
     */
    function reducePositions(uint256[] calldata _tokenIds, uint256[] calldata _amounts) external {
        if (!isReduceEnabled) revert ReducePositionDisabled();
        if (_tokenIds.length != _amounts.length) revert("Array lengths must match");
        if (_tokenIds.length == 0) revert("Empty arrays");

        uint256 totalAmountToReturn;
        
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            totalAmountToReturn += _reducePositionInternal(_tokenIds[i], _amounts[i]);
        }
        
        // Transfer total tokens back to user in one transaction
        if (totalAmountToReturn > 0) {
            IERC20(currency).transfer(msg.sender, totalAmountToReturn);
        }
    }

    /**
     * @notice Allows the owner to claim any ERC20 tokens stuck in the contract
     * @dev Cannot claim currency or reward tokens to protect users' funds
     * @param _token Address of the ERC20 token to claim
     * @param _amount Amount of tokens to claim
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

    // Override supportsInterface function
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // Function to borrow currency from contract
    function borrowCurrency(uint256 _amount) external onlyOwner {
        if (_amount == 0) revert ZeroAmount();
        
        uint256 contractBalance = IERC20(currency).balanceOf(address(this));
        if (_amount > contractBalance) revert InsufficientBalance();
        
        IERC20(currency).transfer(msg.sender, _amount);
        totalBorrowed += _amount;
        emit CurrencyBorrowed(msg.sender, _amount);
    }

    // Function to repay currency
    function repayCurrency(uint256 _amount) external {
        if (_amount == 0) revert ZeroAmount();
        if (_amount > totalBorrowed) revert InsufficientRepayAmount();
        
        IERC20(currency).transferFrom(msg.sender, address(this), _amount);
        totalBorrowed -= _amount;
        emit CurrencyRepaid(msg.sender, _amount);
    }

    // Add gap for future storage variables
    uint256[50] private __gap;
    uint256 public totalRewardsAdded; // Track total rewards added via setPrice
    uint256 public totalRewardsHarvested; // Track total rewards harvested by users
} 