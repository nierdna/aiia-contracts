// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title SeedRoundFundraiser
 * @dev Contract for managing seed round fundraising with multiple rounds
 */
contract SeedRoundFundraiser is Initializable, OwnableUpgradeable, AccessControlUpgradeable {
    // Custom errors
    error InvalidRoundConfig();
    error InvalidTokenAddress();
    error InvalidTokenPrice();
    error InvalidMaxFundPerAccount();
    error RoundNotActive();
    error RoundAlreadyEnded();
    error RoundAlreadyExists();
    error RoundDoesNotExist();
    error ExceedsMaxFundPerAccount();
    error ExceedsRoundTargetFund();
    error TokenNotWhitelisted();
    error ZeroAmount();
    error InvalidStartTime();
    error InvalidEndTime();
    error InvalidTargetFund();
    error InvalidAllocation();
    error InvalidRoundId();
    error TransferFailed();
    error InsufficientBalance();
    error InvalidUserAddress();
    error ClaimingNotEnabled();
    error AlreadyClaimed();
    error AccountAlreadyParticipatedInAnotherRound();
    error NoParticipation();
    error RefundNotAllowed();
    error AlreadyRefunded();
    error InvalidEthAmount();
    error EthTransferFailed();

    // Structs
    // Whitelisted token struct
    struct WhitelistedToken {
        bool isWhitelisted;
        uint256 price; // Price in USD with PRICE_PRECISION decimals
    }

    // Round configuration struct
    struct RoundConfig {
        uint256 startTime;
        uint256 endTime;
        uint256 targetFund; // In USD with PRICE_PRECISION decimals
        uint256 totalAllocation; // Total tokens to be allocated
        uint256 maxFundPerAccount; // Max fund per account in USD with PRICE_PRECISION decimals
        bool exists;
        bool ended;
        bool claimingEnabled; // Flag to control token claiming for this round
        bool refundEnabled; // Flag to control refunds for this round
        bool allowMultiRoundParticipation; // Flag to control if users can participate in multiple rounds
    }

    // User contribution struct
    struct UserContribution {
        uint256 fundAmount; // In USD with PRICE_PRECISION decimals
        uint256 tokenAllocation; // Token allocation
        bool claimed;
        bool refunded; // Flag to track if user has been refunded
        address contributedToken; // The token address used for contribution
        uint256 contributedAmount; // The actual token amount contributed
    }

    // Constants
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");
    uint256 public constant PRICE_PRECISION = 1e18;
    address public constant ETH_ADDRESS = address(0);

    // State variables
    mapping(address => WhitelistedToken) public whitelistedTokens;
    mapping(uint256 => RoundConfig) public rounds;
    mapping(uint256 => mapping(address => UserContribution)) public userContributions;
    mapping(uint256 => uint256) public roundRaisedFunds; // Total raised funds per round in USD
    mapping(uint256 => uint256) public roundParticipants; // Number of participants per round
    mapping(address => uint256) public userParticipatedRound; // Tracks which round a user has participated in, 0 means no participation
    
    address public projectToken; // Token to be distributed
    uint256 public totalRounds;
    uint256 public totalRaisedFunds; // Total raised funds across all rounds in USD
    
    // Add gap for future storage variables
    uint256[50] private __gap;

    // Events
    event TokenWhitelisted(address indexed token, uint256 price);
    event TokenPriceUpdated(address indexed token, uint256 oldPrice, uint256 newPrice);
    event TokenRemovedFromWhitelist(address indexed token);
    event RoundCreated(uint256 indexed roundId, uint256 startTime, uint256 endTime, uint256 targetFund, uint256 totalAllocation, uint256 maxFundPerAccount);
    event RoundUpdated(uint256 indexed roundId, uint256 startTime, uint256 endTime, uint256 targetFund, uint256 totalAllocation, uint256 maxFundPerAccount);
    event RoundEnded(uint256 indexed roundId, uint256 raisedFunds, uint256 participants);
    event Contribution(uint256 indexed roundId, address indexed contributor, address indexed token, uint256 amount, uint256 fundAmount, uint256 tokenAllocation);
    event TokensClaimed(uint256 indexed roundId, address indexed user, uint256 amount);
    event ProjectTokenUpdated(address indexed oldToken, address indexed newToken);
    event ClaimingEnabledUpdated(uint256 indexed roundId, bool enabled);
    event RefundEnabledUpdated(uint256 indexed roundId, bool enabled);
    event Refunded(uint256 indexed roundId, address indexed user, address indexed token, uint256 amount);
    event MultiRoundParticipationUpdated(uint256 indexed roundId, bool enabled);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract
     * @param _projectToken Address of the project token to be distributed
     * @param _owner Address of the owner who will also have the default admin role
     */
    function initialize(address _projectToken, address _owner) public initializer {
        if (_owner == address(0)) revert InvalidUserAddress();
        __Ownable_init(_owner);
        __AccessControl_init();
        
        if (_projectToken == address(0)) revert InvalidTokenAddress();
        projectToken = _projectToken;
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(OPERATOR_ROLE, _owner);
        
        // Grant operator role to the deployer if different from owner
        if (msg.sender != _owner) {
            _grantRole(OPERATOR_ROLE, msg.sender);
        }
    }

    // External functions
    /**
     * @dev Grants operator role to an address
     * @param operator Address to grant the operator role
     */
    function grantOperatorRole(address operator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(OPERATOR_ROLE, operator);
    }

    /**
     * @dev Grants treasurer role to an address
     * @param treasurer Address to grant the treasurer role
     */
    function grantTreasurerRole(address treasurer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(TREASURER_ROLE, treasurer);
    }

    /**
     * @dev Sets the project token address
     * @param _projectToken New project token address
     */
    function setProjectToken(address _projectToken) external onlyRole(OPERATOR_ROLE) {
        if (_projectToken == address(0)) revert InvalidTokenAddress();
        address oldToken = projectToken;
        projectToken = _projectToken;
        emit ProjectTokenUpdated(oldToken, _projectToken);
    }

    /**
     * @dev Adds a token to the whitelist
     * @param _token Token address
     * @param _price Token price in USD with PRICE_PRECISION decimals
     */
    function addWhitelistedToken(address _token, uint256 _price) external onlyRole(OPERATOR_ROLE) {
        // Allow ETH_ADDRESS (which is address(0)) as a valid token address
        if (_token != ETH_ADDRESS && _token == address(0)) revert InvalidTokenAddress();
        if (_price == 0) revert InvalidTokenPrice();
        
        whitelistedTokens[_token] = WhitelistedToken({
            isWhitelisted: true,
            price: _price
        });
        
        emit TokenWhitelisted(_token, _price);
    }

    /**
     * @dev Updates the price of a whitelisted token
     * @param _token Token address
     * @param _newPrice New token price in USD with PRICE_PRECISION decimals
     */
    function updateTokenPrice(address _token, uint256 _newPrice) external onlyRole(OPERATOR_ROLE) {
        if (!whitelistedTokens[_token].isWhitelisted) revert TokenNotWhitelisted();
        if (_newPrice == 0) revert InvalidTokenPrice();
        
        uint256 oldPrice = whitelistedTokens[_token].price;
        whitelistedTokens[_token].price = _newPrice;
        
        emit TokenPriceUpdated(_token, oldPrice, _newPrice);
    }

    /**
     * @dev Removes a token from the whitelist
     * @param _token Token address
     */
    function removeWhitelistedToken(address _token) external onlyRole(OPERATOR_ROLE) {
        if (!whitelistedTokens[_token].isWhitelisted) revert TokenNotWhitelisted();
        
        whitelistedTokens[_token].isWhitelisted = false;
        
        emit TokenRemovedFromWhitelist(_token);
    }

    /**
     * @dev Creates a new funding round
     * @param _startTime Round start time
     * @param _endTime Round end time
     * @param _targetFund Target fund amount in USD with PRICE_PRECISION decimals
     * @param _totalAllocation Total token allocation for the round
     * @param _maxFundPerAccount Maximum fund per account in USD with PRICE_PRECISION decimals
     */
    function createRound(
        uint256 _startTime,
        uint256 _endTime,
        uint256 _targetFund,
        uint256 _totalAllocation,
        uint256 _maxFundPerAccount
    ) external onlyRole(OPERATOR_ROLE) {
        if (_startTime < block.timestamp) revert InvalidStartTime();
        if (_endTime <= _startTime) revert InvalidEndTime();
        if (_targetFund == 0) revert InvalidTargetFund();
        if (_totalAllocation == 0) revert InvalidAllocation();
        if (_maxFundPerAccount == 0 || _maxFundPerAccount > _targetFund) revert InvalidMaxFundPerAccount();
        
        uint256 roundId = totalRounds;
        
        rounds[roundId] = RoundConfig({
            startTime: _startTime,
            endTime: _endTime,
            targetFund: _targetFund,
            totalAllocation: _totalAllocation,
            maxFundPerAccount: _maxFundPerAccount,
            exists: true,
            ended: false,
            claimingEnabled: false,
            refundEnabled: false,
            allowMultiRoundParticipation: true
        });
        
        totalRounds++;
        
        emit RoundCreated(roundId, _startTime, _endTime, _targetFund, _totalAllocation, _maxFundPerAccount);
    }

    /**
     * @dev Updates an existing funding round
     * @param _roundId Round ID
     * @param _startTime New round start time
     * @param _endTime New round end time
     * @param _targetFund New target fund amount in USD with PRICE_PRECISION decimals
     * @param _totalAllocation New total token allocation for the round
     * @param _maxFundPerAccount New maximum fund per account in USD with PRICE_PRECISION decimals
     */
    function updateRound(
        uint256 _roundId,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _targetFund,
        uint256 _totalAllocation,
        uint256 _maxFundPerAccount
    ) external onlyRole(OPERATOR_ROLE) {
        if (!rounds[_roundId].exists) revert RoundDoesNotExist();
        if (rounds[_roundId].ended) revert RoundAlreadyEnded();
        if (block.timestamp >= rounds[_roundId].startTime) revert RoundAlreadyExists();
        if (_startTime < block.timestamp) revert InvalidStartTime();
        if (_endTime <= _startTime) revert InvalidEndTime();
        if (_targetFund == 0) revert InvalidTargetFund();
        if (_totalAllocation == 0) revert InvalidAllocation();
        if (_maxFundPerAccount == 0 || _maxFundPerAccount > _targetFund) revert InvalidMaxFundPerAccount();
        
        rounds[_roundId].startTime = _startTime;
        rounds[_roundId].endTime = _endTime;
        rounds[_roundId].targetFund = _targetFund;
        rounds[_roundId].totalAllocation = _totalAllocation;
        rounds[_roundId].maxFundPerAccount = _maxFundPerAccount;
        
        emit RoundUpdated(_roundId, _startTime, _endTime, _targetFund, _totalAllocation, _maxFundPerAccount);
    }

    /**
     * @dev Ends a round manually
     * @param _roundId Round ID
     */
    function endRound(uint256 _roundId) external onlyRole(OPERATOR_ROLE) {
        if (!rounds[_roundId].exists) revert RoundDoesNotExist();
        if (rounds[_roundId].ended) revert RoundAlreadyEnded();
        
        rounds[_roundId].ended = true;
        
        emit RoundEnded(_roundId, roundRaisedFunds[_roundId], roundParticipants[_roundId]);
    }

    /**
     * @dev Enables or disables token claiming for a specific round
     * @param _roundId Round ID
     * @param _enabled Whether claiming is enabled
     */
    function setClaimingEnabled(uint256 _roundId, bool _enabled) external onlyRole(OPERATOR_ROLE) {
        if (!rounds[_roundId].exists) revert RoundDoesNotExist();
        
        rounds[_roundId].claimingEnabled = _enabled;
        
        emit ClaimingEnabledUpdated(_roundId, _enabled);
    }

    /**
     * @dev Enables or disables refunds for a specific round
     * @param _roundId Round ID
     * @param _enabled Whether refunds are enabled
     */
    function setRefundEnabled(uint256 _roundId, bool _enabled) external onlyRole(OPERATOR_ROLE) {
        if (!rounds[_roundId].exists) revert RoundDoesNotExist();
        
        rounds[_roundId].refundEnabled = _enabled;
        
        emit RefundEnabledUpdated(_roundId, _enabled);
    }

    /**
     * @dev Enables or disables multi-round participation for a specific round
     * @param _roundId Round ID
     * @param _enabled Whether multi-round participation is enabled
     */
    function setMultiRoundParticipation(uint256 _roundId, bool _enabled) external onlyRole(OPERATOR_ROLE) {
        if (!rounds[_roundId].exists) revert RoundDoesNotExist();
        
        rounds[_roundId].allowMultiRoundParticipation = _enabled;
        
        emit MultiRoundParticipationUpdated(_roundId, _enabled);
    }

    /**
     * @dev Contributes to a funding round
     * @param _roundId Round ID
     * @param _token Token address (use ETH_ADDRESS for ETH contributions)
     * @param _amount Amount of tokens to contribute (ignored for ETH, use msg.value instead)
     */
    function contribute(uint256 _roundId, address _token, uint256 _amount) external payable {
        if (!isRoundActive(_roundId)) revert RoundNotActive();
        if (!whitelistedTokens[_token].isWhitelisted) revert TokenNotWhitelisted();
        
        uint256 amount;
        // Handle ETH contribution
        if (_token == ETH_ADDRESS) {
            if (msg.value == 0) revert ZeroAmount();
            amount = msg.value;
        } else {
            // Handle ERC20 contribution
            if (_amount == 0) revert ZeroAmount();
            amount = _amount;
        }
        
        // Check if user has already participated in any round
        uint256 participatedRound = userParticipatedRound[msg.sender];
        if (participatedRound != 0 && participatedRound != _roundId + 1) {
            // Only revert if multi-round participation is not allowed for this round
            if (!rounds[_roundId].allowMultiRoundParticipation) {
                revert AccountAlreadyParticipatedInAnotherRound();
            }
        }
        
        // Calculate fund amount in USD
        uint256 tokenPrice = whitelistedTokens[_token].price;
        uint256 fundAmount = (amount * tokenPrice) / PRICE_PRECISION;
        
        // Check if contribution exceeds max fund per account
        UserContribution storage userContrib = userContributions[_roundId][msg.sender];
        uint256 newTotalContribution = userContrib.fundAmount + fundAmount;
        if (newTotalContribution > rounds[_roundId].maxFundPerAccount) revert ExceedsMaxFundPerAccount();
        
        // Check if contribution exceeds round target fund
        uint256 newRoundTotal = roundRaisedFunds[_roundId] + fundAmount;
        if (newRoundTotal > rounds[_roundId].targetFund) revert ExceedsRoundTargetFund();
        
        // Transfer tokens from user to contract (only for ERC20 tokens)
        if (_token != ETH_ADDRESS) {
            bool success = IERC20(_token).transferFrom(msg.sender, address(this), amount);
            if (!success) revert TransferFailed();
        }
        // For ETH, the transfer happens automatically with the payable function
        
        // Calculate token allocation
        uint256 tokenAllocation = (fundAmount * rounds[_roundId].totalAllocation) / rounds[_roundId].targetFund;
        
        // Update user contribution
        if (userContrib.fundAmount == 0) {
            roundParticipants[_roundId]++;
            // Mark that this user has participated in this round (adding 1 to avoid 0 value)
            userParticipatedRound[msg.sender] = _roundId + 1;
            // Store the token address and amount for potential refunds
            userContrib.contributedToken = _token;
            userContrib.contributedAmount = amount;
        } else {
            // If user is contributing more to the same round with the same token
            if (userContrib.contributedToken == _token) {
                userContrib.contributedAmount += amount;
            } else {
                // If user is contributing with a different token, we don't support this for simplicity
                // In a real implementation, you might want to track multiple token contributions
                revert TokenNotWhitelisted();
            }
        }
        userContrib.fundAmount += fundAmount;
        userContrib.tokenAllocation += tokenAllocation;
        
        // Update round raised funds
        roundRaisedFunds[_roundId] += fundAmount;
        totalRaisedFunds += fundAmount;
        
        // Check if round target is reached
        if (roundRaisedFunds[_roundId] >= rounds[_roundId].targetFund) {
            rounds[_roundId].ended = true;
            emit RoundEnded(_roundId, roundRaisedFunds[_roundId], roundParticipants[_roundId]);
        }
        
        emit Contribution(_roundId, msg.sender, _token, amount, fundAmount, tokenAllocation);
    }

    /**
     * @dev Claims allocated tokens for a specific round
     * @param _roundId Round ID to claim tokens from
     */
    function claimTokensByRoundId(uint256 _roundId) external {
        _processTokenClaim(_roundId, msg.sender);
    }

    /**
     * @dev Allows operators to refund a user's contribution for a specific round
     * @param _roundId Round ID to refund from
     * @param _user Address of the user to refund
     */
    function refund(uint256 _roundId, address _user) external onlyRole(OPERATOR_ROLE) {
        if (_user == address(0)) revert InvalidUserAddress();
        if (!rounds[_roundId].exists) revert RoundDoesNotExist();
        
        // Check if refund is enabled for this round
        if (!rounds[_roundId].refundEnabled) revert RefundNotAllowed();
        
        UserContribution storage userContrib = userContributions[_roundId][_user];
        if (userContrib.fundAmount == 0) revert ZeroAmount();
        if (userContrib.claimed) revert AlreadyClaimed(); // Cannot refund if already claimed
        if (userContrib.refunded) revert AlreadyRefunded();
        
        address token = userContrib.contributedToken;
        uint256 amount = userContrib.contributedAmount;
        
        // Check if contract has enough balance before refunding
        if (token == ETH_ADDRESS) {
            if (amount > address(this).balance) revert InsufficientBalance();
        } else {
            uint256 contractBalance = IERC20(token).balanceOf(address(this));
            if (amount > contractBalance) revert InsufficientBalance();
        }
        
        // Mark as refunded before transfer to prevent reentrancy
        userContrib.refunded = true;
        
        // Update round raised funds and total raised funds
        roundRaisedFunds[_roundId] -= userContrib.fundAmount;
        totalRaisedFunds -= userContrib.fundAmount;
        
        // Transfer tokens or ETH back to user
        if (token == ETH_ADDRESS) {
            // Transfer ETH
            (bool success, ) = _user.call{value: amount}("");
            if (!success) revert EthTransferFailed();
        } else {
            // Transfer ERC20 tokens
            bool success = IERC20(token).transfer(_user, amount);
            if (!success) revert TransferFailed();
        }
        
        emit Refunded(_roundId, _user, token, amount);
    }

    /**
     * @dev Allows only TREASURER_ROLE to withdraw contributed tokens or ETH
     * @param _token Token address (use ETH_ADDRESS for ETH)
     * @param _amount Amount to withdraw
     */
    function withdrawFunds(address _token, uint256 _amount) external onlyRole(TREASURER_ROLE) {
        if (_amount == 0) revert ZeroAmount();
        
        if (_token == ETH_ADDRESS) {
            // Withdraw ETH
            if (_amount > address(this).balance) revert InsufficientBalance();
            
            (bool success, ) = msg.sender.call{value: _amount}("");
            if (!success) revert EthTransferFailed();
        } else {
            // Withdraw ERC20 tokens
            uint256 balance = IERC20(_token).balanceOf(address(this));
            if (_amount > balance) revert InsufficientBalance();
            
            bool success = IERC20(_token).transfer(msg.sender, _amount);
            if (!success) revert TransferFailed();
        }
    }

    /**
     * @dev Returns the total contribution of a user across all rounds
     * @param _user User address
     * @return totalFundAmount Total fund amount in USD
     * @return totalTokenAllocation Total token allocation
     */
    function getUserTotalContribution(address _user) external view returns (uint256 totalFundAmount, uint256 totalTokenAllocation) {
        for (uint256 i = 0; i < totalRounds; i++) {
            UserContribution storage userContrib = userContributions[i][_user];
            totalFundAmount += userContrib.fundAmount;
            totalTokenAllocation += userContrib.tokenAllocation;
        }
        return (totalFundAmount, totalTokenAllocation);
    }

    /**
     * @dev Returns the contribution details of a user for a specific round
     * @param _roundId Round ID
     * @param _user User address
     * @return fundAmount Fund amount in USD
     * @return tokenAllocation Token allocation
     * @return claimed Whether tokens have been claimed
     * @return refunded Whether contribution has been refunded
     * @return contributedToken The token address used for contribution
     * @return contributedAmount The actual token amount contributed
     */
    function getUserRoundContribution(uint256 _roundId, address _user) external view returns (
        uint256 fundAmount, 
        uint256 tokenAllocation, 
        bool claimed, 
        bool refunded,
        address contributedToken,
        uint256 contributedAmount
    ) {
        UserContribution storage userContrib = userContributions[_roundId][_user];
        return (
            userContrib.fundAmount, 
            userContrib.tokenAllocation, 
            userContrib.claimed, 
            userContrib.refunded,
            userContrib.contributedToken,
            userContrib.contributedAmount
        );
    }

    /**
     * @dev Returns the number of rounds
     * @return uint256 Number of rounds
     */
    function getRoundsCount() external view returns (uint256) {
        return totalRounds;
    }

    /**
     * @dev Returns the round ID that a user has participated in
     * @param _user User address
     * @return roundId The round ID the user participated in (0 means no participation)
     */
    function getUserParticipatedRound(address _user) external view returns (uint256 roundId) {
        uint256 participatedRound = userParticipatedRound[_user];
        if (participatedRound == 0) {
            return 0; // User hasn't participated in any round
        }
        return participatedRound - 1; // Subtract 1 to get the actual round ID
    }

    // Public functions
    /**
     * @dev Checks if a round is active
     * @param _roundId Round ID
     * @return bool True if the round is active
     */
    function isRoundActive(uint256 _roundId) public view returns (bool) {
        if (!rounds[_roundId].exists) return false;
        if (rounds[_roundId].ended) return false;
        if (block.timestamp < rounds[_roundId].startTime) return false;
        if (block.timestamp > rounds[_roundId].endTime) return false;
        if (roundRaisedFunds[_roundId] >= rounds[_roundId].targetFund) return false;
        
        return true;
    }

    // Override supportsInterface function
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // Internal functions
    /**
     * @dev Internal function to process token claiming
     * @param _roundId Round ID to claim tokens from
     * @param _user Address of the user claiming tokens
     */
    function _processTokenClaim(uint256 _roundId, address _user) internal {
        if (!rounds[_roundId].exists) revert RoundDoesNotExist();
        if (!rounds[_roundId].ended && block.timestamp <= rounds[_roundId].endTime) revert RoundNotActive();
        
        // Check if claiming is enabled for this round
        if (!rounds[_roundId].claimingEnabled) revert ClaimingNotEnabled();
        
        UserContribution storage userContrib = userContributions[_roundId][_user];
        if (userContrib.fundAmount == 0) revert ZeroAmount();
        if (userContrib.claimed) revert AlreadyClaimed();
        if (userContrib.refunded) revert AlreadyRefunded(); // Cannot claim if already refunded
        
        uint256 tokenAmount = userContrib.tokenAllocation;
        
        // Check if contract has enough tokens before claiming
        uint256 contractBalance = IERC20(projectToken).balanceOf(address(this));
        if (tokenAmount > contractBalance) revert InsufficientBalance();
        
        userContrib.claimed = true;
        
        bool success = IERC20(projectToken).transfer(_user, tokenAmount);
        if (!success) revert TransferFailed();
        
        emit TokensClaimed(_roundId, _user, tokenAmount);
    }

    // Function to receive ETH
    receive() external payable {}
    
    // Fallback function in case someone sends ETH directly to the contract
    fallback() external payable {}
} 