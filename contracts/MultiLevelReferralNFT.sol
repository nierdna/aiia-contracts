// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract NFTTicket is Initializable, ERC721Upgradeable, OwnableUpgradeable, PausableUpgradeable {
    using Strings for uint256;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    uint256 public price;
    uint256 public sharePercent;
    uint256 private _tokenId;
    mapping(address => address) public referrers;
    uint256 public maxReferralLevels;

    // Mapping from referral code to user address
    mapping(string => address) public referralCodes;
    // Mapping from user address to their referral code
    mapping(address => string) public userReferralCodes;

    // Constants
    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    event NFTMinted(address indexed owner, uint256 tokenId);
    event ReferrerSet(address indexed referrer, address indexed referee);
    event ReferralPaid(
        address indexed receiver,
        address indexed buyer,
        uint256 amount,
        uint256 level,
        uint256 originalAmount,
        uint256 tokenId
    );
    event BaseURIChanged(string newBaseURI);
    event ReferralCodeSet(address indexed user, string referralCode);
    event MaxReferralLevelsUpdated(uint256 oldValue, uint256 newValue);
    event SharePercentUpdated(uint256 oldValue, uint256 newValue);
    event NFTSold(
        address indexed seller,
        uint256[] tokenIds,
        uint256 reward,
        uint256 timestamp
    );
    event MaxRewardUpdated(uint256 oldValue, uint256 newValue);
    event EthReceived(address indexed sender, uint256 amount);

    // Custom errors
    error InsufficientBalance();
    error WithdrawError();
    error IncorrectEthAmount(uint256 sent, uint256 required);
    error InvalidReferrer(address referrer);
    error ReferralPaymentFailed(address referrer, uint256 amount);
    error InvalidRecipient();
    error ReferralCodeAlreadyExists(address user, string code);
    error InvalidMaxReferralLevels(uint256 value);
    error InvalidSharePercent(uint256 value);
    error InsufficientNFTBalance(uint256 available, uint256 requested);
    error ZeroAmount();
    error InvalidSignature();
    error SignatureExpired();
    error InvalidNonce();
    error NotTokenOwner(uint256 tokenId);
    error RewardExceedsMax(uint256 reward, uint256 maxAllowed);

    // Function to generate a random referral code
    function _generateReferralCode() internal view returns (string memory) {
        bytes memory charset = "abcdefghijklmnopqrstuvwxyz0123456789";
        bytes memory code = new bytes(6);
        for (uint256 i = 0; i < 6; i++) {
            code[i] = charset[
                uint256(
                    keccak256(
                        abi.encodePacked(block.timestamp, block.prevrandao, i)
                    )
                ) % charset.length
            ];
        }
        return string(code);
    }

    /**
     * @dev Internal function to mint a single NFT to a recipient
     * @param recipient The address to receive the minted NFT
     * @return tokenId The ID of the minted token
     */
    function _mintSingleNFT(address recipient) internal returns (uint256) {
        _safeMint(recipient, _tokenId);
        emit NFTMinted(recipient, _tokenId);
        uint256 currentTokenId = _tokenId;
        _tokenId++;
        return currentTokenId;
    }

    /**
     * @dev Internal function to generate and assign a referral code to a user if they don't have one
     * @param user The address of the user to assign a referral code to
     */
    function _assignReferralCode(address user) internal {
        if (bytes(userReferralCodes[user]).length == 0) {
            string memory newCode = _generateReferralCode();
            referralCodes[newCode] = user;
            userReferralCodes[user] = newCode;
            emit ReferralCodeSet(user, newCode);
        }
    }

    /**
     * @dev Internal function to distribute referral payments
     * @param buyer The address of the NFT buyer
     * @param amount The total amount to distribute
     * @param tokenId The ID of the minted token
     */
    function _distributeReferralPayments(
        address buyer,
        uint256 amount,
        uint256 tokenId
    ) internal {
        uint256 currentAmount = (amount * sharePercent) / 100;
        address payable currentReferrer = payable(referrers[buyer]);
        uint256 level = 0;

        while (currentReferrer != address(0) && level < maxReferralLevels) {
            // Get the parent's address from the referral tree.
            address payable nextReferrer = payable(referrers[currentReferrer]);

            // If no further parent exists or we've reached max level, pay the current referrer 100%
            if (nextReferrer == address(0) || level == maxReferralLevels - 1) {
                (bool success, ) = currentReferrer.call{value: currentAmount}(
                    ""
                );
                if (!success)
                    revert ReferralPaymentFailed(
                        currentReferrer,
                        currentAmount
                    );
                emit ReferralPaid(
                    currentReferrer,
                    buyer,
                    currentAmount,
                    level,
                    amount,
                    tokenId
                );
                break;
            } else {
                // If there is a parent, current referrer keeps 80% and passes up 20%.
                uint256 rewardForCurrent = (currentAmount *
                    (100 - sharePercent)) / 100; // 80%
                uint256 rewardToParent = currentAmount - rewardForCurrent; // 20%
                (bool success, ) = currentReferrer.call{
                    value: rewardForCurrent
                }("");
                if (!success)
                    revert ReferralPaymentFailed(
                        currentReferrer,
                        rewardForCurrent
                    );
                emit ReferralPaid(
                    currentReferrer,
                    buyer,
                    rewardForCurrent,
                    level,
                    amount,
                    tokenId
                );

                // Prepare for the next level up.
                currentReferrer = nextReferrer;
                currentAmount = rewardToParent;
            }
            level++;
        }
    }

    /**
     * @dev Updates the initialize function to include a signer
     */
    function initialize(
        address owner,
        string memory name,
        string memory symbol,
        string memory _baseURI
    ) public initializer {
        __ERC721_init(name, symbol);
        __Ownable_init(owner);
        __Pausable_init();
        transferOwnership(owner);
        price = 0.001 ether; // 0.001 ETH <=> $2
        sharePercent = 20; // 20% share for parent if exists
        maxReferralLevels = 4; // Maximum referral levels
        _baseTokenURI = _baseURI; // Set the base URI from the parameter
        maxReward = 0.1 ether; // Setting default max reward to 0.1 ETH

        // Generate and store referral code for the owner
        _assignReferralCode(owner);
    }

    /**
     * @dev Sets the base URI for all token IDs
     * @param _baseURI The new base URI
     */
    function setBaseURI(string memory _baseURI) external onlyOwner {
        _baseTokenURI = _baseURI;
        emit BaseURIChanged(_baseURI);
    }

    /**
     * @dev Returns the current base URI
     */
    function baseURI() external view returns (string memory) {
        return _baseTokenURI;
    }

    /**
     * @dev Override the tokenURI function to use our custom base URI
     */
    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        require(
            ownerOf(tokenId) != address(0),
            "ERC721Metadata: URI query for nonexistent token"
        );

        // Return just the base URI without appending token ID
        // This makes all NFTs in the collection use the same image
        return _baseTokenURI;
    }

    function setPrice(uint256 _price) external onlyOwner {
        price = _price;
    }

    /**
     * @dev Updates the share percentage for referral payments
     * @param _sharePercent The new share percentage (0-100)
     */
    function setSharePercent(uint256 _sharePercent) external onlyOwner {
        // Ensure the new value is reasonable (between 0 and 100)
        if (_sharePercent > 100) {
            revert InvalidSharePercent(_sharePercent);
        }

        // Store old value for event emission
        uint256 oldValue = sharePercent;

        // Update the share percentage
        sharePercent = _sharePercent;

        // Emit event for the update
        emit SharePercentUpdated(oldValue, _sharePercent);
    }

    /**
     * @dev Updates the maximum number of referral levels
     * @param _maxReferralLevels The new maximum number of referral levels
     */
    function setMaxReferralLevels(
        uint256 _maxReferralLevels
    ) external onlyOwner {
        // Ensure the new value is reasonable (not zero and not excessively large)
        if (_maxReferralLevels == 0 || _maxReferralLevels > 10) {
            revert InvalidMaxReferralLevels(_maxReferralLevels);
        }

        // Store old value for event emission
        uint256 oldValue = maxReferralLevels;

        // Update the max referral levels
        maxReferralLevels = _maxReferralLevels;

        // Emit event for the update
        emit MaxReferralLevelsUpdated(oldValue, _maxReferralLevels);
    }

    /**
     * @dev Allows the contract owner to mint an NFT directly to a recipient
     * @param recipient The address to receive the minted NFT
     */
    function mintTo(address recipient) external onlyOwner {
        if (recipient == address(0)) revert InvalidRecipient();

        // Mint the NFT to the recipient
        _mintSingleNFT(recipient);

        // Generate and store referral code for the recipient if they don't have one
        _assignReferralCode(recipient);
    }

    /**
     * @dev Allows the contract owner to mint multiple NFTs to a single recipient in a single transaction
     * @param recipient Address to receive the minted NFTs
     * @param amount Number of NFTs to mint for the recipient
     */
    function batchMint(address recipient, uint256 amount) external onlyOwner {
        // Skip invalid recipients
        if (recipient == address(0)) revert InvalidRecipient();

        // Mint the specified amount of NFTs to the recipient
        for (uint256 j = 0; j < amount; j++) {
            _mintSingleNFT(recipient);
        }

        // Generate and store referral code for the recipient if they don't have one
        _assignReferralCode(recipient);
    }

    function buy(string memory _referralCode) external payable whenNotPaused {
        if (msg.value != price) revert IncorrectEthAmount(msg.value, price);

        // Mint the NFT to the buyer
        uint256 tokenId = _mintSingleNFT(msg.sender);

        // Generate and store referral code for the buyer
        _assignReferralCode(msg.sender);

        address payable referrer = payable(referralCodes[_referralCode]);
        if (referrer == address(0) || referrer == msg.sender) {
            revert InvalidReferrer(referrer);
        }

        // Set the referrer only if it's not already set.
        if (referrers[msg.sender] == address(0)) {
            referrers[msg.sender] = referrer;
            emit ReferrerSet(referrer, msg.sender);
        }

        // Distribute referral payments
        _distributeReferralPayments(msg.sender, msg.value, tokenId);
    }

    /**
     * @dev Allows a user to buy multiple NFTs in a single transaction
     * @param _referralCode The referral code to use for the purchase
     * @param _amount The number of NFTs to buy
     */
    function batchBuy(
        string memory _referralCode,
        uint256 _amount
    ) external payable whenNotPaused {
        // Ensure amount is valid (greater than 0)
        require(_amount > 0, "Amount must be greater than 0");

        // Check if the correct amount of ETH was sent
        uint256 requiredAmount = price * _amount;
        if (msg.value != requiredAmount)
            revert IncorrectEthAmount(msg.value, requiredAmount);

        // Validate referrer
        address payable referrer = payable(referralCodes[_referralCode]);
        if (referrer == address(0) || referrer == msg.sender) {
            revert InvalidReferrer(referrer);
        }

        // Set the referrer only if it's not already set
        if (referrers[msg.sender] == address(0)) {
            referrers[msg.sender] = referrer;
            emit ReferrerSet(referrer, msg.sender);
        }

        // Generate and store referral code for the buyer if they don't have one
        _assignReferralCode(msg.sender);

        // Mint the specified amount of NFTs to the buyer
        uint256[] memory tokenIds = new uint256[](_amount);
        for (uint256 i = 0; i < _amount; i++) {
            tokenIds[i] = _mintSingleNFT(msg.sender);
        }

        // Distribute referral payments for each NFT
        // We divide the total payment by the number of NFTs to get the payment per NFT
        uint256 paymentPerNFT = msg.value / _amount;
        for (uint256 i = 0; i < _amount; i++) {
            _distributeReferralPayments(msg.sender, paymentPerNFT, tokenIds[i]);
        }
    }

    // Function for the owner to withdraw contract balance.
    function withdraw(uint256 _amount) public onlyOwner {
        if (_amount > address(this).balance) revert InsufficientBalance();
        (bool success, ) = msg.sender.call{value: _amount}("");
        if (!success) revert WithdrawError();
    }

    /**
     * @dev Allows a user to generate their own referral code if they don't have one
     * @return code The generated referral code
     */
    function generateReferralCode() external returns (string memory) {
        // Check if user already has a referral code
        if (bytes(userReferralCodes[msg.sender]).length > 0) {
            // Revert if user already has a referral code
            revert ReferralCodeAlreadyExists(
                msg.sender,
                userReferralCodes[msg.sender]
            );
        }

        // Generate and assign a new referral code
        _assignReferralCode(msg.sender);

        // Return the newly generated code
        return userReferralCodes[msg.sender];
    }

    /**
     * @dev Allows the owner to generate a referral code for a specific user
     * @param user The address of the user to generate a referral code for
     * @return code The generated referral code
     */
    function generateReferralCodeForUser(
        address user
    ) external onlyOwner returns (string memory) {
        // Check if user already has a referral code
        if (bytes(userReferralCodes[user]).length > 0) {
            // Revert if user already has a referral code
            revert ReferralCodeAlreadyExists(user, userReferralCodes[user]);
        }

        // Generate and assign a new referral code
        _assignReferralCode(user);

        // Return the newly generated code
        return userReferralCodes[user];
    }

    /**
     * @dev Internal function to verify a signature for reward verification
     * @param _user Address of the user selling NFTs
     * @param _tokenIds List of token IDs to sell
     * @param _reward Reward amount to be paid
     * @param _nonce Unique nonce to prevent replay attacks
     * @param _deadline Timestamp after which signature is invalid
     * @param _signature Signature from authorized signer
     * @return signatureHash The hash of the signature
     */
    function _verifySignature(
        address _user,
        uint256[] memory _tokenIds,
        uint256 _reward,
        uint256 _nonce,
        uint256 _deadline,
        bytes calldata _signature
    ) internal returns (bytes32 signatureHash) {
        if (_tokenIds.length == 0) revert ZeroAmount();
        if (block.timestamp > _deadline) revert SignatureExpired();

        // Validate nonce for user
        if (_nonce != userNonces[_user]) revert InvalidNonce();

        // Create message hash - include the entire array of token IDs
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                address(this),
                _user,
                keccak256(abi.encodePacked(_tokenIds)), // Hash the array of token IDs
                _reward,
                _nonce,
                _deadline
            )
        );

        // Create signature hash for EIP-191 prefixed signatures
        signatureHash = MessageHashUtils.toEthSignedMessageHash(messageHash);

        // Verify signature using ECDSA library
        address signer = ECDSA.recover(signatureHash, _signature);
        if (signer != owner()) revert InvalidSignature();

        // Increment user's nonce after successful verification
        userNonces[_user]++;

        return signatureHash;
    }

    /**
     * @dev Allows a user to sell their NFTs back to the contract with a reward
     * @param _tokenIds Array of token IDs to sell
     * @param _reward Reward amount (interest from holding NFT)
     * @param _nonce Unique nonce to prevent replay attacks
     * @param _deadline Timestamp after which signature is invalid
     * @param _signature Signature from authorized signer
     */
    function sell(
        uint256[] memory _tokenIds,
        uint256 _reward,
        uint256 _nonce,
        uint256 _deadline,
        bytes calldata _signature
    ) external {
        // Check if array is not empty
        if (_tokenIds.length == 0) revert ZeroAmount();

        // Check if reward exceeds maximum allowed
        if (_reward > maxReward) revert RewardExceedsMax(_reward, maxReward);

        // Verify signature to confirm the reward amount
        _verifySignature(
            msg.sender,
            _tokenIds,
            _reward,
            _nonce,
            _deadline,
            _signature
        );

        // Calculate the total amount to pay
        uint256 totalPayment = (_tokenIds.length * price) + _reward;

        // Check if contract has enough balance
        if (address(this).balance < totalPayment) revert InsufficientBalance();

        // Verify ownership and burn each token
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            uint256 tokenId = _tokenIds[i];

            // Verify ownership
            if (ownerOf(tokenId) != msg.sender) {
                revert NotTokenOwner(tokenId);
            }

            // Burn the NFT
            _burn(tokenId);
        }

        // Send payment to user
        (bool success, ) = msg.sender.call{value: totalPayment}("");
        if (!success) revert WithdrawError();

        // Emit event with the actual array of tokenIds
        emit NFTSold(msg.sender, _tokenIds, _reward, block.timestamp);
    }

    /**
     * @dev Sets the maximum reward that can be given when selling NFTs
     * @param _maxReward The new maximum reward value
     */
    function setMaxReward(uint256 _maxReward) external onlyOwner {
        uint256 oldValue = maxReward;
        maxReward = _maxReward;
        emit MaxRewardUpdated(oldValue, _maxReward);
    }

    /**
     * @dev Pauses the contract to prevent buying NFTs
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpauses the contract to allow buying NFTs
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // Base URI for token metadata
    string private _baseTokenURI;

    // Mapping from user address to their nonce (for signature verification)
    mapping(address => uint256) public userNonces;

    // Mapping from address to boolean to check if the address is a signer
    // mapping(address => bool) public signers;

    // Maximum reward that can be given when selling NFTs
    uint256 public maxReward;

    /**
     * @dev Allows this contract to receive ETH directly
     */
    receive() external payable {
        emit EthReceived(msg.sender, msg.value);
    }
}
