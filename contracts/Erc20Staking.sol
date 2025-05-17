// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Erc20Staking
 * @dev A contract for staking ERC20 token with off-chain reward calculations
 */
contract Erc20Staking is 
    Initializable, 
    OwnableUpgradeable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using SafeERC20 for IERC20;

    // Custom errors
    error ZeroAmount();
    error InvalidSignature();
    error InvalidOperator();
    error InsufficientContractBalance();
    error InsufficientStake();
    error TransferFailed();
    error NoRewardAvailable();
    error SignatureExpired();
    error SignatureUsed();
    error BelowMinimumStake();
    error InvalidNonce();
    error InvalidTokenAddress();

    // Roles
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    // Events
    event Staked(address indexed user, uint256 amount, uint256 timestamp);
    event Unstaked(address indexed user, uint256 amount, uint256 timestamp);
    event RewardHarvested(address indexed user, uint256 amount, uint256 timestamp, bytes32 signatureHash);
    event SignerUpdated(address indexed newSigner);
    event MinStakeUpdated(uint256 oldAmount, uint256 newAmount);
    event TokenUpdated(address indexed newToken);

    // State variables
    uint256 public totalStaked;
    uint256 public totalRewards;
    uint256 public maxRewardAmount;
    uint256 public minStakeAmount;
    IERC20 public stakingToken; // The ERC20 token used for staking

    // Mappings
    mapping(address => uint256) public userStakes;
    mapping(address => uint256) public userTotalRewardsHarvested;
    mapping(address => uint256) public userNonces;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract
     * @param _owner Address of the contract owner
     * @param _signer Address authorized to sign reward data
     * @param _stakingToken Address of the ERC20 token used for staking
     * @param _maxRewardAmount Maximum reward amount allowed in a single harvest
     * @param _minStakeAmount Minimum amount required for staking
     */
    function initialize(
        address _owner, 
        address _signer,
        address _stakingToken,
        uint256 _maxRewardAmount,
        uint256 _minStakeAmount
    ) external initializer {
        __Ownable_init(_owner);
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        
        if (_signer == address(0)) revert InvalidOperator();
        if (_stakingToken == address(0)) revert InvalidTokenAddress();
        
        stakingToken = IERC20(_stakingToken);
        maxRewardAmount = _maxRewardAmount;
        minStakeAmount = _minStakeAmount;
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(SIGNER_ROLE, _signer);
        
        emit SignerUpdated(_signer);
        emit MinStakeUpdated(0, _minStakeAmount);
        emit TokenUpdated(_stakingToken);
    }

    /**
     * @dev Stake ERC20 tokens to the contract
     * @param _amount Amount of tokens to stake
     */
    function stake(uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount == 0) revert ZeroAmount();
        if (_amount < minStakeAmount) revert BelowMinimumStake();
        
        // Transfer tokens from user to contract
        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
        
        // Update user stake
        userStakes[msg.sender] += _amount;
        
        // Update total staked
        totalStaked += _amount;
        
        emit Staked(msg.sender, _amount, block.timestamp);
    }

    /**
     * @dev Unstake ERC20 tokens
     * @param _amount Amount to unstake
     */
    function unstake(uint256 _amount) external nonReentrant {
        if (_amount == 0) revert ZeroAmount();
        if (_amount > userStakes[msg.sender]) revert InsufficientStake();
        
        // Update user stake
        userStakes[msg.sender] -= _amount;
        
        // Update total staked
        totalStaked -= _amount;
        
        // Transfer tokens to user
        stakingToken.safeTransfer(msg.sender, _amount);
        
        emit Unstaked(msg.sender, _amount, block.timestamp);
    }

    /**
     * @dev Harvest rewards with off-chain signature verification
     * @param _amount Reward amount to harvest
     * @param _nonce Unique nonce to prevent replay attacks
     * @param _deadline Timestamp after which signature is invalid
     * @param _signature Signature from authorized signer
     */
    function harvestReward(
        uint256 _amount, 
        uint256 _nonce,
        uint256 _deadline,
        bytes calldata _signature
    ) external nonReentrant whenNotPaused {
        // Verify signature and get signature hash
        bytes32 signatureHash = _verifySignature(
            msg.sender, 
            _amount, 
            _nonce, 
            _deadline, 
            _signature
        );
        
        // Process the reward harvest
        _harvestReward(msg.sender, _amount, signatureHash);
    }

    /**
     * @dev Add funds to the reward pool
     * @param _amount Amount of tokens to add to rewards
     */
    function addRewards(uint256 _amount) external {
        if (_amount == 0) revert ZeroAmount();
        
        // Transfer tokens from caller to contract
        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
    }

    /**
     * @dev Update the maximum reward amount
     * @param _newMaxReward New maximum reward amount
     */
    function updateMaxRewardAmount(uint256 _newMaxReward) external onlyRole(OPERATOR_ROLE) {
        maxRewardAmount = _newMaxReward;
    }

    /**
     * @dev Update the minimum stake amount
     * @param _newMinStake New minimum stake amount
     */
    function setMinStakeAmount(uint256 _newMinStake) external onlyRole(OPERATOR_ROLE) {
        uint256 oldMinStake = minStakeAmount;
        minStakeAmount = _newMinStake;
        emit MinStakeUpdated(oldMinStake, _newMinStake);
    }

    /**
     * @dev Add a new signer
     * @param _signer Address of the new signer
     */
    function addSigner(address _signer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_signer == address(0)) revert InvalidOperator();
        _grantRole(SIGNER_ROLE, _signer);
        emit SignerUpdated(_signer);
    }

    /**
     * @dev Remove a signer
     * @param _signer Address of the signer to remove
     */
    function removeSigner(address _signer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(SIGNER_ROLE, _signer);
    }

    /**
     * @dev Change the staking token (only callable by admin)
     * @param _newToken New ERC20 token address
     */
    function updateStakingToken(address _newToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newToken == address(0)) revert InvalidTokenAddress();
        stakingToken = IERC20(_newToken);
        emit TokenUpdated(_newToken);
    }

    /**
     * @dev Pause the contract
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause the contract
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev Emergency withdraw all staking tokens (only admin can call)
     * @param _recipient Address to receive the funds
     */
    function emergencyWithdraw(address _recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 balance = stakingToken.balanceOf(address(this));
        stakingToken.safeTransfer(_recipient, balance);
    }

    /**
     * @dev Emergency withdraw a specific amount of staking tokens (only admin can call)
     * @param _recipient Address to receive the funds
     * @param _amount Amount of tokens to withdraw
     */
    function emergencyWithdrawAmount(address _recipient, uint256 _amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_amount == 0) revert ZeroAmount();
        uint256 balance = stakingToken.balanceOf(address(this));
        if (_amount > balance) revert InsufficientContractBalance();
        stakingToken.safeTransfer(_recipient, _amount);
    }

    /**
     * @dev Get user's stake and total harvested rewards
     * @param _user Address of the user
     * @return stake User's current stake
     * @return harvested Total rewards harvested so far
     */
    function getUserInfo(address _user) external view returns (uint256 stake, uint256 harvested) {
        return (userStakes[_user], userTotalRewardsHarvested[_user]);
    }

    /**
     * @dev Unstake and harvest rewards in a single transaction 
     * @param _unstakeAmount Amount to unstake
     * @param _rewardAmount Reward amount to harvest
     * @param _nonce Unique nonce to prevent replay attacks
     * @param _deadline Timestamp after which signature is invalid
     * @param _signature Signature from authorized signer
     */
    function unstakeAndHarvest(
        uint256 _unstakeAmount,
        uint256 _rewardAmount,
        uint256 _nonce,
        uint256 _deadline,
        bytes calldata _signature
    ) external nonReentrant {
        // Verify signature for reward harvest
        bytes32 signatureHash = _verifySignature(
            msg.sender, 
            _rewardAmount, 
            _nonce, 
            _deadline, 
            _signature
        );
        
        // Check contract balance
        if (stakingToken.balanceOf(address(this)) < (_unstakeAmount + _rewardAmount)) revert InsufficientContractBalance();
        
        // Process unstake
        if (_unstakeAmount > 0) {
            if (_unstakeAmount > userStakes[msg.sender]) revert InsufficientStake();
            
            // Update user stake
            userStakes[msg.sender] -= _unstakeAmount;
            
            // Update total staked
            totalStaked -= _unstakeAmount;
            
            emit Unstaked(msg.sender, _unstakeAmount, block.timestamp);
        }
        
        // Process reward harvest
        _harvestRewardInternal(msg.sender, _rewardAmount, signatureHash);
        
        // Transfer total amount
        uint256 totalAmount = _unstakeAmount + _rewardAmount;
        stakingToken.safeTransfer(msg.sender, totalAmount);
    }
    
    /**
     * @dev Internal function to verify a signature for reward harvests
     * @param _user Address of the user harvesting reward
     * @param _amount Reward amount to harvest
     * @param _nonce Unique nonce to prevent replay attacks
     * @param _deadline Timestamp after which signature is invalid
     * @param _signature Signature from authorized signer
     * @return signatureHash The hash of the signature
     */
    function _verifySignature(
        address _user,
        uint256 _amount,
        uint256 _nonce,
        uint256 _deadline,
        bytes calldata _signature
    ) internal returns (bytes32 signatureHash) {
        // if (_amount == 0) revert ZeroAmount();
        if (_amount > maxRewardAmount) revert NoRewardAvailable();
        if (block.timestamp > _deadline) revert SignatureExpired();
        
        // Validate nonce for user
        if (_nonce != userNonces[_user]) revert InvalidNonce();
        
        // Create message hash
        bytes32 messageHash = keccak256(abi.encodePacked(
            address(this),
            _user,
            _amount,
            _nonce,
            _deadline
        ));
        
        // Create signature hash for EIP-191 prefixed signatures
        signatureHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        
        // Verify signature using ECDSA library
        address signer = ECDSA.recover(signatureHash, _signature);
        if (!hasRole(SIGNER_ROLE, signer)) revert InvalidSignature();
        
        // Increment user's nonce after successful verification
        userNonces[_user]++;
        
        return signatureHash;
    }
    
    /**
     * @dev Internal function to harvest reward
     * @param _user Address of the user
     * @param _amount Reward amount to harvest
     * @param _signatureHash Hash of the verified signature
     */
    function _harvestReward(
        address _user, 
        uint256 _amount,
        bytes32 _signatureHash
    ) internal {
        // Check contract has enough balance
        if (stakingToken.balanceOf(address(this)) < _amount) revert InsufficientContractBalance();
        
        // Update user's harvested rewards
        userTotalRewardsHarvested[_user] += _amount;
        
        // Update total rewards distributed
        totalRewards += _amount;
        
        // Transfer tokens to user
        stakingToken.safeTransfer(_user, _amount);
        
        emit RewardHarvested(_user, _amount, block.timestamp, _signatureHash);
    }
    
    /**
     * @dev Internal function to handle reward harvest logic without transfer
     * @param _user Address of the user
     * @param _amount Reward amount to harvest
     * @param _signatureHash Hash of the verified signature
     */
    function _harvestRewardInternal(
        address _user, 
        uint256 _amount,
        bytes32 _signatureHash
    ) internal {
        // Update user's harvested rewards
        userTotalRewardsHarvested[_user] += _amount;
        
        // Update total rewards distributed
        totalRewards += _amount;
        
        emit RewardHarvested(_user, _amount, block.timestamp, _signatureHash);
    }
} 