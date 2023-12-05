// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {StableCoin} from "./StableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

contract DSCEngine is ReentrancyGuard {
    error DSCEngine__tokenAddressLengthAndPriceFeedAddressLengthAreNotEqual();
    error DSCEngine__CannotDepositZeroAmount();
    error DSCEngine__NotEnoughBalance();
    error DSCEngine__TokenAddressNotValid();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactor_Ok();

    using OracleLib for AggregatorV3Interface;

    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% asset discount
    uint256 private constant LIQUIDATION_PRECISION = 100;

    StableCoin private immutable i_sc;
    mapping(address token => address priceFeed) private s_tokenPriceFeed;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralAmountDeposited;
    mapping(address user => uint256 amount) private s_SCMinted;
    address[] private s_collateralTokens;

    event DepositedCollateral(address indexed user, address indexed token, uint256 indexed amount);
    event RedeemedCollateral(address indexed from, address indexed to ,address indexed token, uint256 amount);

    constructor(address[] memory tokenAddress, address[] memory priceFeedAddress, address stableCoin) {
        if (tokenAddress.length != priceFeedAddress.length) {
            revert DSCEngine__tokenAddressLengthAndPriceFeedAddressLengthAreNotEqual();
        }

        for (uint256 i = 0; i < tokenAddress.length; i++) {
            s_tokenPriceFeed[tokenAddress[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddress[i]);
        }

        i_sc = StableCoin(stableCoin);
    }

    modifier MoreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__CannotDepositZeroAmount();
        }
        _;
    }

    modifier ValidTokenAddress(address token) {
        if (s_tokenPriceFeed[token] == address(0)) {
            revert DSCEngine__TokenAddressNotValid();
        }
        _;
    }

    modifier EnoughBalance(uint amount, address user) {
        if(amount > s_SCMinted[user]){
            revert DSCEngine__NotEnoughBalance();
        }
        _;
    }

    // Deposit and Mint //////////////////////////////////////////////////////////////////

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        MoreThanZero(amountCollateral)
        ValidTokenAddress(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralAmountDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit DepositedCollateral(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @param tokenCollateralAddress the address of the token to deposit as collateral
     * @param amountCollateral The amount of the deposited collateral
     * @param amount the amount of stable coin to mint.
     * @notice This function will deposit your collateral and mint DSC in one transaction.
     */
    function depositCollateralAndMintSc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amount)
        external
    {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintSc(amount);
    }

    /**
     * @dev We need to define the user collateral value
     * in order to check for the amount that will be minted.
     * If the collateral value is greater than the amount then
     * the user should be liquidated.
     */

    function mintSc(uint256 amount) public MoreThanZero(amount) nonReentrant {
        s_SCMinted[msg.sender] += amount;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_sc.mint(msg.sender, amount);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    //////////////////////////////////////////////////////////////////////////////////////
    // Redumption ///////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////////
    function redeemCollateral(address collateralToken, uint256 amountRedeemed) public MoreThanZero(amountRedeemed){
        _redeemCollateral(collateralToken, amountRedeemed, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function redeemCollateralForDsc(address collateralToken, uint256 amountCollateral, uint256 amountDscToBurn)
        external
        EnoughBalance(amountDscToBurn, msg.sender)
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(collateralToken, amountCollateral);
    }

    // Why this function non reentrant ????????
    function burnDsc(uint256 amount) public MoreThanZero(amount) EnoughBalance(amount, msg.sender){
        _burnDsc(amount, msg.sender, msg.sender);
        i_sc.burn(amount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////

    /**
     * @param collateral the ERC20 collateral address to liquidate from the user
     * @param user who has broken the health factor. his _healthfactor should be below MIN_HEALTH_FACTOR
     * @param debtToCover the amount of DSC you want to burn to improve the users health factor
     *
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the users funds
     * @notice This function working assumes the protocol will be roughly 200%
     * overcollateralized in order for this to work.
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentive the liquidators.
     *
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        MoreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactor_Ok();
        }
                                                                                                
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        _burnDsc(debtToCover, user, msg.sender);
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenPriceFeed[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function calculateHealthFactor(uint totalDscMinted, uint collateredValueInUsd) public pure returns(uint){
        return _calculateHealthFactor(totalDscMinted, collateredValueInUsd);
    }

    /**
     * @dev the healthFactor is a boolean value that determines
     * if the collateral is deposited is valid, by checking if its usd value is more than the
     * dsc minted.
     */

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateredValueInUsd)
    {
        totalDscMinted = s_SCMinted[user];
        collateredValueInUsd = getAccountCollateralValue(user);
    }

    // This health factor is a function that gets all the sc and the collaterals the user got
    // Then returns the factor.
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateredValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateredValueInUsd);
    }

    /////////////////////////////////////////
    // Internal functions ///////////////////
    /////////////////////////////////////////

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // Check if the collateral value is greater than the minted stable
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _redeemCollateral(address collateralToken, uint256 amountRedeemed, address _from, address _to) internal {
        s_collateralAmountDeposited[_from][collateralToken] -= amountRedeemed;
        emit RedeemedCollateral(_from, _to, collateralToken, amountRedeemed);

        bool success = IERC20(collateralToken).transfer(_to, amountRedeemed);
        if (!success) {
            revert DSCEngine__TransferFailed();
        } 
    }

    function _burnDsc(uint256 _amount, address _from, address _to) internal {
        s_SCMinted[_to] -= _amount;

        bool success = i_sc.transferFrom(_from, address(this), _amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _calculateHealthFactor(uint totalDscMinted, uint collateredValueInUsd) internal pure returns(uint) {
        if(totalDscMinted == 0) return type(uint).max;
        uint256 collateralAdjustedForThreshold = (collateredValueInUsd * LIQUIDATION_THRESHOLD) / 100;
        return (collateralAdjustedForThreshold * LIQUIDATION_THRESHOLD) / totalDscMinted;
    }
    /////////////////////////////////////////////////////////////////////////////////////
    // Getters functions ///////////////////////////////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        address token;
        uint256 amount;
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            token = s_collateralTokens[i];
            amount = s_collateralAmountDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }

        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenPriceFeed[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // Chainlink already returns values with the precision of 1e8 decimals,
        // so we're going to multiply it by the 1e10 to make it 1e18.
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getCollateralAmountDeposited(address user, address token) public view returns(uint) {
        return s_collateralAmountDeposited[user][token];
    }

    function getMinted_Sc(address user) public view returns(uint) {
        return s_SCMinted[user];
    }

    function getAccountInformation(address user) public view returns(uint256 totalDscMinted, uint256 collateredValueInUsd) {
        (totalDscMinted, collateredValueInUsd) = _getAccountInformation(user);
    }

    function getHealthFactor(address user) external view returns(uint){
        return _healthFactor(user);
    }

    function get_ADDITIONAL_FEED_PRECISION() external pure returns(uint) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function get_PRECISION() external pure returns(uint) {
        return PRECISION;
    }

    function get_LIQUIDATION_BONUS() external pure returns(uint) {
        return LIQUIDATION_BONUS;
    }

    function getCollateralTokenPriceFeed(address collateralToken) external view returns(address) {
        return s_tokenPriceFeed[collateralToken];
    }

    function getCollateralTokens() external view returns(address[] memory) {
        return s_collateralTokens;
    }

    function get_MIN_HEALTH_FACTOR() external pure returns(uint) {
        return MIN_HEALTH_FACTOR;
    }

    function get_LIQUIDATION_THRESHOLD() external pure returns(uint) {
        return LIQUIDATION_THRESHOLD;
    }

    function get_Sc() external view returns(address) {
        return address(i_sc);
    }

    function get_LIQUIDATION_PRECISION() external pure returns(uint) {
        return LIQUIDATION_PRECISION;
    }
}
