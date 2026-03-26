// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import { DUSD } from "src/DUSDStableCoin.sol";
import { OracleLib } from "./libraries/OracleLib.sol";
/*
 * @title DUSDEngine
 * @author Lau Lok Jing
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DUSD system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DUSD.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DUSD, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */

contract DUSDEngine is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error DUSDEngine__NeedMoreThanZero();
    error DUSDEngine__NeedMoreThanZero__TokenAddressesLengthMustBeEqualToPriceFeedsLength();
    error DUSDEngine__TokenNotAllowedAsCollateral();
    error DUSDEngine__TransferFailed();
    error DUSDEngine__HealthFactorTooLow();
    error DUSDEngine__MintFailed();
    error DUSDEngine__HealthFactorIsGood();
    error DUSDEngine__HealthFactorNotImproved();
    error DUSDEngine__InvalidDUSDAmount();
    error DUSDEngine__InvalidCollateralAmount();
    error DUSDEngine__NotEnoughAssetsToRedeem(address user, uint256 debtToCover, uint256 requiredValue);
    error DUSDEngine__ExceedsDebt();
    error DUSDEngine__InvalidDebtAmount();
    error DUSDEngine__InvalidPriceFeedAddress();

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/
    using OracleLib for AggregatorV3Interface;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    address[] private s_collateralTokenAddr;
    mapping(address tokenAddr => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address tokenAddr => uint256 amount)) private s_userDepositedCollateral;
    mapping(address user => uint256 amountMinted) private s_DUSDMinted;
    DUSD private immutable i_dUSD;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant MIN_HEALTH_FACTOR = 1 * PRECISION;
    uint256 private constant OVERCOLLATERAL_RATIO = 2;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant LIQUIDATION_PRECISION = 100;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount
    );

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DUSDEngine__NeedMoreThanZero();
        }
        _;
    }

    modifier isTokenAllowedAsCollateral(address tokenAddr) {
        if (s_priceFeeds[tokenAddr] == address(0)) {
            revert DUSDEngine__TokenNotAllowedAsCollateral();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    constructor(address[] memory tokenAddrs, address[] memory priceFeeds, address dUSDAddr) {
        if (tokenAddrs.length != priceFeeds.length) {
            revert DUSDEngine__NeedMoreThanZero__TokenAddressesLengthMustBeEqualToPriceFeedsLength();
        }

        s_collateralTokenAddr = tokenAddrs;
        for (uint256 i = 0; i < tokenAddrs.length; i++) {
            s_priceFeeds[tokenAddrs[i]] = priceFeeds[i];
        }
        i_dUSD = DUSD(dUSDAddr);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice  Deposit collateral and mint DUSD in one transaction
     * @param   tokenCollateralAddress The token address of the collateral
     * @param   collateralAmount The amount of the collateral token
     * @param   mintAmount  The amount of DUSD to be minted
     */
    function depositCollateralAndMintDUSD(
        address tokenCollateralAddress,
        uint256 collateralAmount,
        uint256 mintAmount
    )
        external
    {
        depositCollateral(tokenCollateralAddress, collateralAmount);
        mintDUSD(mintAmount);
    }

    /**
     * @notice  Redeem collateral and burn DUSD in one transaction
     * @param   tokenCollateralAddress The token address of the collateral
     * @param   collateralAmount The amount of the collateral token
     * @param   burnAmount  The amount of DUSD to be burnt
     */
    function redeemCollateralForDUSD(
        address tokenCollateralAddress,
        uint256 collateralAmount,
        uint256 burnAmount
    )
        external
    {
        burnDUSD(burnAmount);
        redeemCollateral(tokenCollateralAddress, collateralAmount); // Checked the user Health Factor
    }

    /**
     * @notice  Fully or partially liquidate user position without prioritizing collateral asset.
     *          You will get a LIQUIDATION_BONUS for taking the users funds.
     *          This function working assumes that the protocol will be at least (100 + LIQUIDATION_BONUS)%
     * overcollateralized in order for this
     *          to work.
     *          A known bug would be if the protocol is less than (100 + LIQUIDATION_BONUS)% collateralized, we wouldn't
     * be able to liquidate
     *          anyone.
     *          For example, if the price of the collateral plummeted before anyone could be liquidated.
     * @dev     Seizing / Redeeming collateral(s) proportionally in terms of value instead of priority.
     * @param   user  The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param   debtToCover  The amount of DUSD the liquidator intended to cover for the user
     */
    function liquidate(address user, uint256 debtToCover) external moreThanZero(debtToCover) {
        // Checks
        uint256 startingHealthFactor = _healthFactor(user);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) revert DUSDEngine__HealthFactorIsGood();
        if (s_DUSDMinted[user] < debtToCover) revert DUSDEngine__ExceedsDebt();
        uint256 totalCollateralValue = getAccountTotalCollateralValue(user);
        uint256 requiredValue = debtToCover * (LIQUIDATION_PRECISION + LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        if (requiredValue > totalCollateralValue) {
            revert DUSDEngine__NotEnoughAssetsToRedeem(user, debtToCover, requiredValue);
        }

        // Effects & Interacitons -- Need to account for both WBTC and WETH instead of just single asset
        _burnDUSD(debtToCover, user, msg.sender);

        for (uint256 i = 0; i < s_collateralTokenAddr.length; i++) {
            address tokenAddr = s_collateralTokenAddr[i];
            uint256 collateralAmount = s_userDepositedCollateral[user][tokenAddr];
            if (collateralAmount == 0) continue;

            // Total USD value of the tokenAddr collateral
            uint256 collateralValue = _getUSDValue(tokenAddr, collateralAmount);
            uint256 valueToSeize = (requiredValue * collateralValue) / totalCollateralValue;
            uint256 amountToSeize = getTokenAmountFromUSD(tokenAddr, valueToSeize);

            // Hypothetically not needed since requiredValue is <= totalCollateralValue
            if (amountToSeize > collateralAmount) amountToSeize = collateralAmount;

            _redeemCollateral(tokenAddr, amountToSeize, user, msg.sender);
        }
        uint256 endingHealthFactor = _healthFactor(user);

        if (endingHealthFactor <= startingHealthFactor) revert DUSDEngine__HealthFactorNotImproved();

        _revertIfHealthFactorIsBroken(user);
    }

    /**
     * @notice  You can partially liquidate a user.
     *          You will get a LIQUIDATION_BONUS for taking the users funds.
     *          This function working assumes that the protocol will be at least (100 + LIQUIDATION_BONUS)%
     * overcollateralized in order for this
     *          to work.
     *          A known bug would be if the protocol is less than (100 + LIQUIDATION_BONUS)% collateralized, we wouldn't
     * be able to liquidate
     *          anyone.
     *          For example, if the price of the collateral plummeted before anyone could be liquidated.
     * @dev     Liquidating a user with a health factor below MIN_HEALTH_FACTOR * (LIQUIDATION_BONUS +
     * LIQUIDATION_PRECISION)/ (LIQUIDATION_PRECISION * OVERCOLLATERAL_RATIO)
     *          will always revert to prevents liquidations that would worsen the user's position
     *          as they would leave the protocol even more undercollateralized.
     * @param   collateralAddr  The ERC20 token address of the collateral you're paid in to make the protocol solvent
     * again.
     * @param   user  The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param   debtToCover  The amount of DUSD you want to burn to cover the user's debt.
     */
    function liquidateByAsset(
        address collateralAddr,
        address user,
        uint256 debtToCover
    )
        external
        moreThanZero(debtToCover)
        isTokenAllowedAsCollateral(collateralAddr)
    {
        // Checks
        uint256 startingHealthFactor = _healthFactor(user);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) revert DUSDEngine__HealthFactorIsGood();

        if (s_DUSDMinted[user] < debtToCover) revert DUSDEngine__ExceedsDebt();
        uint256 totalCollateralValue = getAccountCollateralValue(user, collateralAddr);
        uint256 requiredValue = debtToCover * (LIQUIDATION_PRECISION + LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        if (requiredValue > totalCollateralValue) {
            revert DUSDEngine__NotEnoughAssetsToRedeem(user, debtToCover, requiredValue);
        }

        // Effects -- Need to account for both WBTC and WETH instead of just single asset
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUSD(collateralAddr, debtToCover);
        uint256 bonusCollateral = tokenAmountFromDebtCovered * LIQUIDATION_BONUS / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        // Interactions
        _burnDUSD(debtToCover, user, msg.sender);
        _redeemCollateral(collateralAddr, totalCollateralToRedeem, user, msg.sender);

        uint256 endingHealthFactor = _healthFactor(user);

        if (startingHealthFactor >= endingHealthFactor) {
            revert DUSDEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(user);
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice  Follows Check-Effects-Interactions(CEI)
     * @param   tokenCollateralAddress  The token address of the collateral
     * @param   amount  The amount of the collateral token
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amount
    )
        public
        nonReentrant
        moreThanZero(amount)
        isTokenAllowedAsCollateral(tokenCollateralAddress)
    {
        s_userDepositedCollateral[msg.sender][tokenCollateralAddress] += amount;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amount);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amount);

        // Hypothetically unreachable for most ERC20 tokens except those that return false instead of revert when
        // transfer fails
        if (!success) {
            revert DUSDEngine__TransferFailed();
        }
    }

    /**
     * @notice  Redeem user's collateral, provided min. health factor of 1.
     * @param   collateralTokenAddr  Collateral address.
     * @param   amount  Collateral token amount.
     */
    function redeemCollateral(address collateralTokenAddr, uint256 amount) public moreThanZero(amount) {
        _redeemCollateral(collateralTokenAddr, amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice  Follows Check-Effects-Interactions(CEI), must have min. health factor of 1.
     * @param   amount  The amount of DUSD to be minted
     */
    function mintDUSD(uint256 amount) public moreThanZero(amount) {
        s_DUSDMinted[msg.sender] += amount;

        _revertIfHealthFactorIsBroken(msg.sender);

        bool success = i_dUSD.mint(msg.sender, amount);
        if (!success) {
            // Hypotheticall unreachable
            revert DUSDEngine__MintFailed();
        }
    }

    /**
     * @notice  To burn DUSD.
     * @param   amount  Amount of DUSD.
     */
    function burnDUSD(uint256 amount) public {
        _burnDUSD(amount, msg.sender, msg.sender);

        // Hypothetically unreachable
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                           PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice  To redeem the user's collateral
     * @dev     Private functions that accounts redeeming from user to liquidator i.e. not msg.sender
     * @param   collateralTokenAddr  Collateral address
     * @param   amount  Collateral amount
     * @param   from  From address
     * @param   to  To address
     */
    function _redeemCollateral(
        address collateralTokenAddr,
        uint256 amount,
        address from,
        address to
    )
        private
        nonReentrant
        moreThanZero(amount)
    {
        if (s_userDepositedCollateral[from][collateralTokenAddr] < amount) {
            revert DUSDEngine__InvalidCollateralAmount();
        }
        s_userDepositedCollateral[from][collateralTokenAddr] -= amount;
        emit CollateralRedeemed(from, to, collateralTokenAddr, amount);

        bool success = IERC20(collateralTokenAddr).transfer(to, amount); // Moves a `value` amount of tokens from the
        // caller's account to `to`.

        // Hypothetically unreachable
        if (!success) {
            revert DUSDEngine__TransferFailed();
        }
    }
    /**
     * @notice  To burn the user's DUSD
     * @dev     Low-level internal functions, do not call unless the function calling is checking the health factor of
     * the user.
     * @param   amount  Amount to burn
     * @param   onBehalfOf  Address of the DUSD holder on behalf of payer to be burn
     * @param   payer  Address who will send DUSD to burn
     */

    function _burnDUSD(uint256 amount, address onBehalfOf, address payer) private nonReentrant {
        if (s_DUSDMinted[onBehalfOf] < amount) {
            revert DUSDEngine__InvalidDUSDAmount();
        }
        s_DUSDMinted[onBehalfOf] -= amount;
        bool success = i_dUSD.transferFrom(payer, address(this), amount);

        // Hypothetically unreachable
        if (!success) {
            revert DUSDEngine__TransferFailed();
        }

        i_dUSD.burn(amount);
    }

    /*//////////////////////////////////////////////////////////////
                PRIVATE & INTERNAL VIEW & PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice  Get and calculates user's total minted DUSD and collateral value in USD respectively
     * @param   user  User's address
     * @return  totalDUSDMinted  Total amount of DUSD minted
     * @return  totalCollateralValue  Total collateral value in USD deposited by the user
     */
    function _getAccountInfo(address user)
        private
        view
        returns (uint256 totalDUSDMinted, uint256 totalCollateralValue)
    {
        totalDUSDMinted = s_DUSDMinted[user];
        totalCollateralValue = getAccountTotalCollateralValue(user);
    }

    /**
     * @notice  If the account HF reaches MIN_HEALTH_FACTOR, it can be liquidated.
     * @param   user  Address of the account
     * @return  healthFactor  Returns the HF of the account, totalCollateralValue / totalDUSDMinted >
     * OVERCOLLATERAL_RATIO to avoid liquidation.
     *                        i.e. OVERCOLLATERAL_RATIO = 2, totalCollateralValue = $1001, ttotalDUSDMinted = $500
     */
    function _healthFactor(address user) private view returns (uint256 healthFactor) {
        (uint256 totalDUSDMinted, uint256 totalCollateralValue) = _getAccountInfo(user);
        healthFactor = _calculateHealthFactor(totalDUSDMinted, totalCollateralValue);
    }

    /**
     * @notice  Calculates user's health factor
     * @param   totalDUSDMinted  Total DUSD minted by the user
     * @param   totalCollateralValue Total collateral value in USD deposited by the user
     * @return  uint256  User's health factor
     */
    function _calculateHealthFactor(
        uint256 totalDUSDMinted,
        uint256 totalCollateralValue
    )
        internal
        pure
        returns (uint256)
    {
        if (totalDUSDMinted == 0) {
            // No Debt

            return type(uint256).max;
        }

        return totalCollateralValue * PRECISION / (totalDUSDMinted * OVERCOLLATERAL_RATIO);
    }

    /**
     * @notice  Revert when the user's health factor is below MIN_HEALTH_FACTOR
     * @param   user  User's address
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _healthFactor(user);

        if (healthFactor < MIN_HEALTH_FACTOR) revert DUSDEngine__HealthFactorTooLow();
    }

    /*//////////////////////////////////////////////////////////////
                EXTERNAL & PUBLIC VIEW & PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice  Calculate and return the difference between two exponents numbers
     * @param   _PRECISION  Exponential number 1, i.e. 1e18
     * @param   _DECIMALS  Exponential number 2, i.e. 1e8
     * @return  uint256  Exponential number, i.e. 1e10
     */
    function calculateAdditionalPriceFeedPrecision(uint256 _PRECISION, uint256 _DECIMALS)
        public
        pure
        returns (uint256)
    {
        return _PRECISION / _DECIMALS;
    }

    /**
     * @notice  Calculates the user's Health Factor
     * @param   totalDUSDMinted  Total minted DUSD by the user
     * @param   totalCollateralValue Total collateral value in USD deposited by the user
     * @return  healthFactor  User's health factor
     */
    function calculateHealthFactor(
        uint256 totalDUSDMinted,
        uint256 totalCollateralValue
    )
        public
        pure
        returns (uint256 healthFactor)
    {
        healthFactor = _calculateHealthFactor(totalDUSDMinted, totalCollateralValue);
    }

    /**
     * @notice  Calculate the total USD value of a token given the amount
     * @dev     Relies on Chainlink AggregatorV3Interface and stale check for token price fetches
     * @param   tokenAddr  Token Address
     * @param   amount  Amount of the token
     * @return  value  Returns the latest price of the token using Chainlink AggregatorV3
     */
    function _getUSDValue(address tokenAddr, uint256 amount) public view returns (uint256 value) {
        uint8 tokenDecimals = ERC20(tokenAddr).decimals();
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[tokenAddr]);
        uint8 feedDecimals = priceFeed.decimals();
        uint256 _ADDTIONAL_PRICEFEED_PRECISION = calculateAdditionalPriceFeedPrecision(PRECISION, 10 ** feedDecimals);

        (, int256 answer,,,) = priceFeed.staleCheckLatestRoundData();

        // price in wei (18 decimals)
        uint256 priceInWei = uint256(answer) * _ADDTIONAL_PRICEFEED_PRECISION;

        value = priceInWei * amount / (10 ** tokenDecimals);
    }

    /**
     * @notice  Calculate the token amount corresponding to a given USD value.
     * @dev     Relies on Chainlink AggregatorV3 stale check for token price fetches
     * @param   tokenAddr  Token Address
     * @param   usdAmountInWei  USD value
     * @return  tokenAmount  Amount of the token
     */
    function getTokenAmountFromUSD(address tokenAddr, uint256 usdAmountInWei)
        public
        view
        returns (uint256 tokenAmount)
    {
        address priceFeedAddress = s_priceFeeds[tokenAddr];
        if (priceFeedAddress == address(uint160(0))) revert DUSDEngine__InvalidPriceFeedAddress();
        uint8 tokenDecimals = ERC20(tokenAddr).decimals();

        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeedAddress);
        uint8 feedDecimals = priceFeed.decimals();

        uint256 _ADDTIONAL_PRICEFEED_PRECISION = calculateAdditionalPriceFeedPrecision(PRECISION, 10 ** feedDecimals);

        (, int256 answer,,,) = priceFeed.staleCheckLatestRoundData();
        uint256 priceInWei = uint256(answer) * _ADDTIONAL_PRICEFEED_PRECISION;

        tokenAmount = usdAmountInWei * 10 ** tokenDecimals / priceInWei;

        return tokenAmount;
    }

    /**
     * @notice  Determine if user's overall posiiton is liquidable
     * @dev     Liquidating a user's health factor is < (1 + bonus) will always revert to prevents liquidations that
     * would worsen the user's position
     *          as they would leave the protocol even more undercollateralized.
     * @param   user  user's address
     * @return  bool  return true if user's position is liquidable, else false
     */
    function isLiquidable(address user) public view returns (bool) {
        uint256 hf = _healthFactor(user);
        uint256 minLiquidableHF = MIN_HEALTH_FACTOR * (LIQUIDATION_PRECISION + LIQUIDATION_BONUS)
            / (LIQUIDATION_PRECISION * OVERCOLLATERAL_RATIO);
        return hf < MIN_HEALTH_FACTOR && hf >= minLiquidableHF;
    }

    /**
     * @notice  Calculates the amount of DUSD needed to redeem the user's maximum deposited collaterals with liquidation
     * bonus accounted for
     * @dev     Does not check user's health factor
     * @param   user  User's address
     * @return  uint256  User's maximum debt to cover in DUSD
     */
    function getMaxDebtToCover(address user) public view returns (uint256) {
        uint256 totalCollateralValue = getAccountTotalCollateralValue(user);
        uint256 maximumCollateralValueToCover =
            totalCollateralValue * LIQUIDATION_PRECISION / (LIQUIDATION_PRECISION + LIQUIDATION_BONUS);
        if (maximumCollateralValueToCover > s_DUSDMinted[user]) return s_DUSDMinted[user];

        return maximumCollateralValueToCover;
    }

    /**
     * @notice  Calculates the amount of DUSD needed to redeem user's maximum specific deposited collateral with
     * liquidation bonus accounted for
     * @dev     Does not check user's health factor
     * @param   user  The user's address
     * @param   collateralAddr  The collateral token address
     * @return  uint256  The amount of DUSD
     */
    function getMaxDebtToCoverForSpecificCollateral(address user, address collateralAddr)
        public
        view
        returns (uint256)
    {
        uint256 totalCollateralValue = getAccountCollateralValue(user, collateralAddr);
        uint256 maximumCollateralValueToCover =
            totalCollateralValue * LIQUIDATION_PRECISION / (LIQUIDATION_PRECISION + LIQUIDATION_BONUS);

        if (maximumCollateralValueToCover > s_DUSDMinted[user]) return s_DUSDMinted[user];

        return maximumCollateralValueToCover;
    }
    /**
     * @notice  Returns the user's total collateral value in USD
     * @param   user  User's address
     * @return  totalCollateralValue  The total collateral value in USD
     */

    function getAccountTotalCollateralValue(address user) public view returns (uint256 totalCollateralValue) {
        for (uint256 i = 0; i < s_collateralTokenAddr.length; i++) {
            address tokenAddr = s_collateralTokenAddr[i];
            uint256 collateralAmount = s_userDepositedCollateral[user][tokenAddr];

            totalCollateralValue += _getUSDValue(tokenAddr, collateralAmount);
        }
    }

    /**
     * @notice  Returns the user's specific collateral value in USD
     * @dev     .
     * @param   user  User's address
     * @param   collateralAddr  The concerned collateral address
     * @return  collateralValue  The collateral value in USD
     */
    function getAccountCollateralValue(
        address user,
        address collateralAddr
    )
        public
        view
        returns (uint256 collateralValue)
    {
        uint256 collateralAmount = s_userDepositedCollateral[user][collateralAddr];
        collateralValue = _getUSDValue(collateralAddr, collateralAmount);
    }

    /**
     * @notice  Get and calculate the total DUSD minted and total collateral value respectively
     * @return  totalDUSDMinted  Total DUSD minted
     * @return  totalCollateralValue  The collateral value in USD
     */
    function getAccountInfo() public view returns (uint256 totalDUSDMinted, uint256 totalCollateralValue) {
        return _getAccountInfo(msg.sender);
    }

    /**
     * @notice  Get the total DUSD minted by a user
     * @param   user  User's address
     * @return  uint256  Total number of DUSD minted
     */
    function _getDUSDMinted(address user) public view returns (uint256) {
        return s_DUSDMinted[user];
    }

    /**
     * @notice  Get the precision used in calculations
     * @return  uint256  Precision
     */
    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    /**
     * @notice  Get the liquidation incentives
     * @return  uint256  Liquidation bonus
     */
    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    /**
     * @notice  Get the liquidation precision
     * @return  uint256  Liquidation precision
     */
    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    /**
     * @notice  Get the overcollateral ratio
     * @return  uint256  Overcollateral ratio
     */
    function getOvercollateralRatio() external pure returns (uint256) {
        return OVERCOLLATERAL_RATIO;
    }

    /**
     * @notice  Get the minimum health factor
     * @return  uint256  The minimum health factor
     */
    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    /**
     * @notice  Get the token addresses that are used as collateral
     * @return  address[]  Collateral addresses
     */
    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokenAddr;
    }

    /**
     * @notice  Get the DUSD contract address
     * @return  address  The DUSD contract address
     */
    function getDusd() external view returns (address) {
        return address(i_dUSD);
    }

    /**
     * @notice  Get the pricefeed address for a collateral
     * @dev     Chainlink AggregatorV3
     * @param   token  Collateral token address
     * @return  address  Pricefeed address for the collateral
     */
    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    /**
     * @notice  Get user's health factor
     * @param   user  User's address
     * @return  uint256  User's health factor calculated in 1 * PRECISION
     */
    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    /**
     * @notice  Get the amount of collateral user has deposited
     * @param   user  user's address
     * @param   tokenAddr  collateral's address
     * @return  uint256  amount of collateral deposited
     */
    function getCollateralDeposited(address user, address tokenAddr) external view returns (uint256) {
        return s_userDepositedCollateral[user][tokenAddr];
    }
}
