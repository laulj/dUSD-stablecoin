// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Test, console } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { DUSD } from "../../src/DUSDStableCoin.sol";
import { DUSDEngine } from "../../src/DUSDEngine.sol";
import { DUSDScript } from "../../script/DeployDUSD.s.sol";
import { CodeConstants, HelperConfig } from "../../script/HelperConfig.s.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import { MockV3Aggregator } from "../mocks/MockV3Aggregator.sol";
import { OracleLib } from "../../src/libraries/OracleLib.sol";

contract DUSDEngineTest is Test, CodeConstants {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    DUSD public dUSD;
    DUSDEngine public dUSDEngine;
    HelperConfig public helperConfig;
    address[] public tokenAddresses;
    address[] public priceFeeds;

    address public WETH_tokenAddress;
    address public WBTC_tokenAddress;

    address public USER = makeAddr("USER");
    uint256 public constant STARTING_BALANCE = 10 ether;
    uint256 public constant DEPOSIT_COLLATERAL = 10 ether;
    uint256 public constant INTERVAL = 60;
    uint256 public constant ORACLE_TIMEOUT = 3 hours;

    mapping(address tokenAddr => uint256 amountDeposited) s_CollateralAmountToSeize;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount
    );

    function setUp() public {
        DUSDScript deployer = new DUSDScript();
        (dUSD, dUSDEngine, helperConfig) = deployer.deployContract();
        HelperConfig.NetworkConfig memory networkConfig = helperConfig.getConfig();
        tokenAddresses = networkConfig.tokenAddresses;
        priceFeeds = networkConfig.priceFeeds;
        WETH_tokenAddress = tokenAddresses[0];
        WBTC_tokenAddress = tokenAddresses[1];

        vm.deal(USER, STARTING_BALANCE);
        ERC20Mock(WETH_tokenAddress).mint(USER, STARTING_BALANCE);
        ERC20Mock(WBTC_tokenAddress).mint(USER, STARTING_BALANCE);
    }

    modifier depositedCollateral(address tokenAddress, uint256 amountToDeposit) {
        vm.startPrank(USER);

        ERC20Mock(tokenAddress).approve(address(dUSDEngine), amountToDeposit);
        dUSDEngine.depositCollateral(tokenAddress, amountToDeposit);
        vm.stopPrank();
        _;
    }

    modifier mintedMaxDUSD() {
        vm.startPrank(USER);
        (uint256 totalDUSDMinted, uint256 totalCollateralValue) = dUSDEngine.getAccountInfo();
        dUSDEngine.mintDUSD(totalCollateralValue / OVERCOLLATERAL_RATIO);
        vm.stopPrank();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                GENERAL
    //////////////////////////////////////////////////////////////*/
    function test_CanGetDUSDContract() public view {
        assertEq(dUSDEngine.getDusd(), address(dUSD));
    }

    /*//////////////////////////////////////////////////////////////
                                 PRICE
    //////////////////////////////////////////////////////////////*/
    function test_RevertIfLengthOfTokenAndPriceFeedsAreUnequal() public {
        HelperConfig.NetworkConfig memory networkConfig = helperConfig.getConfig();
        tokenAddresses.push(WETH_tokenAddress);
        priceFeeds.push(networkConfig.priceFeeds[0]);
        priceFeeds.push(networkConfig.priceFeeds[1]);
        vm.expectRevert(
            DUSDEngine.DUSDEngine__NeedMoreThanZero__TokenAddressesLengthMustBeEqualToPriceFeedsLength.selector
        );
        new DUSDEngine(tokenAddresses, priceFeeds, address(dUSD));
    }

    function test_StalePriceRevert() public {
        uint256 ethAmount = 1e18;

        dUSDEngine._getUSDValue(WETH_tokenAddress, ethAmount);

        vm.warp(block.timestamp + ORACLE_TIMEOUT + 1);
        vm.roll(block.number + 100);

        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        dUSDEngine._getUSDValue(WETH_tokenAddress, ethAmount);
    }

    function test_GetUSDValue() public view {
        uint256 ethAmount = 1e18;
        MockV3Aggregator EthPriceFeeds = MockV3Aggregator(priceFeeds[0]);
        uint256 _ADDTIONAL_ETH_PRICEFEED_PRECISION =
            dUSDEngine.calculateAdditionalPriceFeedPrecision(PRECISION, 10 ** EthPriceFeeds.decimals());
        uint256 expectedETHUSD =
            (uint256(MOCK_WETH_INITIAL_ANSWER) * _ADDTIONAL_ETH_PRICEFEED_PRECISION * ethAmount) / PRECISION;

        uint256 actualETHUSD = dUSDEngine._getUSDValue(WETH_tokenAddress, ethAmount);
        assertEq(actualETHUSD, expectedETHUSD);

        uint256 btcAmount = 1e18;
        MockV3Aggregator BtcPriceFeeds = MockV3Aggregator(priceFeeds[1]);
        uint256 _ADDTIONAL_BTC_PRICEFEED_PRECISION =
            dUSDEngine.calculateAdditionalPriceFeedPrecision(PRECISION, 10 ** BtcPriceFeeds.decimals());
        uint256 expectedBTCUSD =
            (uint256(MOCK_WBTC_INITIAL_ANSWER) * _ADDTIONAL_BTC_PRICEFEED_PRECISION * btcAmount) / PRECISION;

        uint256 actualBTCUSD = dUSDEngine._getUSDValue(WBTC_tokenAddress, btcAmount);
        assertEq(actualBTCUSD, expectedBTCUSD);
    }

    function test_GetTokenQuantityFromUSD() public view {
        uint256 ethAmount = 1e18;

        uint256 actualETHUSD = dUSDEngine._getUSDValue(WETH_tokenAddress, ethAmount);
        uint256 actualETHAmount = dUSDEngine.getTokenAmountFromUSD(WETH_tokenAddress, actualETHUSD);
        assertEq(ethAmount, actualETHAmount);

        uint256 btcAmount = 1e18;

        uint256 actualBTCUSD = dUSDEngine._getUSDValue(WBTC_tokenAddress, btcAmount);
        uint256 actualBTCAmount = dUSDEngine.getTokenAmountFromUSD(WBTC_tokenAddress, actualBTCUSD);
        assertEq(btcAmount, actualBTCAmount);
    }

    function test_GetTokenQuantityFromUSDRevertWithInvalidTokenAddress() public {
        vm.expectRevert(DUSDEngine.DUSDEngine__InvalidPriceFeedAddress.selector);
        dUSDEngine.getTokenAmountFromUSD(address(uint160(10)), 1000);
    }

    function test_getAccountTotalCollateralValue()
        public
        depositedCollateral(WETH_tokenAddress, 1 ether)
        depositedCollateral(WBTC_tokenAddress, 1 ether)
    {
        vm.startPrank(USER);
        uint256 totalDepositValueInUSD =
            dUSDEngine._getUSDValue(WETH_tokenAddress, 1 ether) + dUSDEngine._getUSDValue(WBTC_tokenAddress, 1 ether);
        uint256 totalCollateralValue = dUSDEngine.getAccountTotalCollateralValue(USER);

        assertEq(totalCollateralValue, totalDepositValueInUSD);
        vm.stopPrank();
    }

    function test_getAccountCollateralValue()
        public
        depositedCollateral(WETH_tokenAddress, 1 ether)
        depositedCollateral(WBTC_tokenAddress, 2 ether)
    {
        vm.startPrank(USER);
        uint256 ExpectedWETHDepositedValue = dUSDEngine._getUSDValue(WETH_tokenAddress, 1 ether);
        uint256 ExpectedWBTCDepositedValue = dUSDEngine._getUSDValue(WBTC_tokenAddress, 2 ether);
        uint256 WETHCollateralValue = dUSDEngine.getAccountCollateralValue(USER, WETH_tokenAddress);
        uint256 WBTCCollateralValue = dUSDEngine.getAccountCollateralValue(USER, WBTC_tokenAddress);

        assertEq(WETHCollateralValue, ExpectedWETHDepositedValue);
        assertEq(WBTCCollateralValue, ExpectedWBTCDepositedValue);

        vm.stopPrank();
    }

    function test_getAccountInfo() public depositedCollateral(WETH_tokenAddress, 1 ether) {
        uint256 otherCollateralAmount = 2 ether;
        depositCollateral(WBTC_tokenAddress, otherCollateralAmount);

        vm.startPrank(USER);
        uint256 totalDepositValueInUSD = dUSDEngine._getUSDValue(WETH_tokenAddress, 1 ether)
            + dUSDEngine._getUSDValue(WBTC_tokenAddress, otherCollateralAmount);
        (uint256 totalDUSDMinted, uint256 totalCollateralValue) = dUSDEngine.getAccountInfo();

        assertEq(totalDUSDMinted, 0);
        assertEq(totalCollateralValue, totalDepositValueInUSD);
        vm.stopPrank();
    }

    function test_getMaxDebtToCoverWhenCollateralisMoreThanTotalDUSDMinted()
        public
        depositedCollateral(WETH_tokenAddress, 1 ether)
        mintedMaxDUSD
    {
        uint256 ExpectedMaximumCollateralValueToCover = dUSDEngine._getDUSDMinted(USER);
        uint256 maximumCollateralValueToCover = dUSDEngine.getMaxDebtToCover(USER);

        assertEq(maximumCollateralValueToCover, ExpectedMaximumCollateralValueToCover);
    }

    function test_getMaxDebtToCoverWhenLessThanTotalDUSDMinted()
        public
        depositedCollateral(WETH_tokenAddress, 1 ether)
        mintedMaxDUSD
    {
        uint256 LIQUIDATION_PRECISION = dUSDEngine.getLiquidationPrecision();
        uint256 LIQUIDATION_BONUS = dUSDEngine.getLiquidationBonus();
        MockV3Aggregator WETH_PriceFeed = MockV3Aggregator(priceFeeds[0]);

        uint256 PRICE_DECREASE_PERCENTAGE = 100 / dUSDEngine.getOvercollateralRatio();
        int256 NEW_WETH_PRICE = MOCK_WETH_INITIAL_ANSWER * (100 - int256(PRICE_DECREASE_PERCENTAGE)) / 100; // Price
        // Dropped by 30%

        // Update WETH Price
        MockV3Aggregator(WETH_PriceFeed).updateAnswer(NEW_WETH_PRICE);

        uint256 totalCollateralValue = dUSDEngine.getAccountTotalCollateralValue(USER) * LIQUIDATION_PRECISION
            / (LIQUIDATION_PRECISION + LIQUIDATION_BONUS);

        uint256 ExpectedMaximumCollateralValueToCover = totalCollateralValue;
        uint256 maximumCollateralValueToCover = dUSDEngine.getMaxDebtToCover(USER);

        assertEq(maximumCollateralValueToCover, ExpectedMaximumCollateralValueToCover);
    }

    function test_getMaxDebtToCoverForSpecificCollateralWhenCollateralisMoreThanTotalDUSDMinted()
        public
        depositedCollateral(WETH_tokenAddress, 1 ether)
        mintedMaxDUSD
    {
        uint256 ExpectedMaximumCollateralValueToCover = dUSDEngine._getDUSDMinted(USER);
        uint256 maximumCollateralValueToCover =
            dUSDEngine.getMaxDebtToCoverForSpecificCollateral(USER, WETH_tokenAddress);

        assertEq(maximumCollateralValueToCover, ExpectedMaximumCollateralValueToCover);
    }

    function test_getMaxDebtToCoverForSpecificCollateralWhenLessThanTotalDUSDMinted()
        public
        depositedCollateral(WETH_tokenAddress, 1 ether)
        mintedMaxDUSD
    {
        uint256 LIQUIDATION_PRECISION = dUSDEngine.getLiquidationPrecision();
        uint256 LIQUIDATION_BONUS = dUSDEngine.getLiquidationBonus();
        MockV3Aggregator WETH_PriceFeed = MockV3Aggregator(priceFeeds[0]);

        uint256 PRICE_DECREASE_PERCENTAGE = 100 / dUSDEngine.getOvercollateralRatio();
        int256 NEW_WETH_PRICE = MOCK_WETH_INITIAL_ANSWER * (100 - int256(PRICE_DECREASE_PERCENTAGE)) / 100; // Price
        // Dropped by 30%

        // Update WETH Price
        MockV3Aggregator(WETH_PriceFeed).updateAnswer(NEW_WETH_PRICE);

        uint256 totalCollateralValue = dUSDEngine.getAccountTotalCollateralValue(USER) * LIQUIDATION_PRECISION
            / (LIQUIDATION_PRECISION + LIQUIDATION_BONUS);

        uint256 ExpectedMaximumCollateralValueToCover = totalCollateralValue;
        uint256 maximumCollateralValueToCover =
            dUSDEngine.getMaxDebtToCoverForSpecificCollateral(USER, WETH_tokenAddress);

        assertEq(maximumCollateralValueToCover, ExpectedMaximumCollateralValueToCover);
    }

    function test_calculateAdditionalPriceFeedPrecision(uint256 value1, uint256 value2) public view {
        value2 = bound(value2, 1e5, type(uint256).max);
        assertEq(dUSDEngine.calculateAdditionalPriceFeedPrecision(value1, value2), value1 / value2);
    }

    /*//////////////////////////////////////////////////////////////
                             HEALTH FACTOR
    //////////////////////////////////////////////////////////////*/
    function test_RevertIfCallHealthFactor() public depositedCollateral(WETH_tokenAddress, 1 ether) {
        vm.startPrank(USER);

        (bool success,) = address(dUSDEngine).call{ value: 0 }(abi.encodeWithSignature("_healthFactor(address)", USER));
        assertEq(success, false);
        vm.stopPrank();
    }

    function test_InitialHealthFactor() public {
        vm.startPrank(USER);
        uint256 EXPECTED_HF = ZERO_DEBT_HEALTH_FACTOR;

        uint256 actualHealthFactor = dUSDEngine.getHealthFactor(USER);
        assertEq(actualHealthFactor, EXPECTED_HF);

        vm.stopPrank();
    }

    function test_ArbitratyHealthFactor(uint256 mintedDUSDAmount)
        public
        depositedCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL)
    {
        vm.startPrank(USER);
        uint256 collateralizedValueInUSD = dUSDEngine._getUSDValue(WETH_tokenAddress, DEPOSIT_COLLATERAL);
        uint256 OVERCOLLATERALRATIO = dUSDEngine.getOvercollateralRatio();
        mintedDUSDAmount = bound(mintedDUSDAmount, 1e5, collateralizedValueInUSD / OVERCOLLATERALRATIO);
        uint256 EXPECTED_HF = collateralizedValueInUSD * PRECISION / (mintedDUSDAmount * OVERCOLLATERALRATIO);

        dUSDEngine.mintDUSD(mintedDUSDAmount);

        uint256 actualHealthFactor = dUSDEngine.getHealthFactor(USER);
        assertEq(actualHealthFactor, EXPECTED_HF);
        vm.stopPrank();
    }

    function test_CalculateHealthFactorReturnsMaxWhenDUSDMintedIsZero(uint256 collateralValue) public view {
        collateralValue = bound(collateralValue, 1e5, type(uint256).max);
        assertEq(dUSDEngine.calculateHealthFactor(0, collateralValue), type(uint256).max);
    }

    function test_CalculateHealthFactorForNonZeroDUSDMinted(uint256 dUSDMinted, uint256 collateralValue) public view {
        dUSDMinted = bound(dUSDMinted, 1e5, type(uint96).max);
        collateralValue = bound(collateralValue, 1e5, type(uint96).max);
        uint256 EXPECTED_VALUE =
            collateralValue * dUSDEngine.getPrecision() / (dUSDMinted * dUSDEngine.getOvercollateralRatio());
        assertEq(dUSDEngine.calculateHealthFactor(dUSDMinted, collateralValue), EXPECTED_VALUE);
    }

    /*//////////////////////////////////////////////////////////////
                           DEPOSIT COLLATERAL
    //////////////////////////////////////////////////////////////*/
    function test_RevertIfDepositTransferFailed() public {
        // Some ERC20 tokens return false instead of Revert when .transferFrom failed
        vm.startPrank(USER);
        ERC20(WETH_tokenAddress).approve(address(dUSDEngine), type(uint256).max);
        vm.expectRevert(DUSDEngine.DUSDEngine__TransferFailed.selector);
        dUSDEngine.depositCollateral(WETH_tokenAddress, STARTING_BALANCE + 1);
        vm.stopPrank();
    }

    function test_RevertIfDepositingZeroCollateral() public {
        vm.prank(USER);
        vm.expectRevert(DUSDEngine.DUSDEngine__NeedMoreThanZero.selector);
        dUSDEngine.depositCollateral(WETH_tokenAddress, 0);
    }

    function test_RevertIfDepositingUnApprovedCollateral() public {
        ERC20Mock unknownToken = new ERC20Mock("UN", "UN", USER, STARTING_BALANCE);
        vm.prank(USER);
        vm.expectRevert(DUSDEngine.DUSDEngine__TokenNotAllowedAsCollateral.selector);
        dUSDEngine.depositCollateral(address(unknownToken), STARTING_BALANCE);
    }

    function test_CanDepositInitialCollateralNGetAccountInfo() public depositedCollateral(WETH_tokenAddress, 1 ether) {
        vm.startPrank(USER);
        (uint256 totalDUSDMinted, uint256 totalCollateralValue) = dUSDEngine.getAccountInfo();

        assertEq(totalDUSDMinted, 0);
        assertEq(totalCollateralValue, dUSDEngine._getUSDValue(WETH_tokenAddress, 1 ether));
        vm.stopPrank();
    }

    function test_CanDepositMoreCollateralNGetAccountInfo() public depositedCollateral(WETH_tokenAddress, 1 ether) {
        uint256 randomAmount = 2 ether;
        vm.deal(USER, randomAmount);

        vm.startPrank(USER);
        uint256 totalDepositedCollateralAmount = 1 ether + randomAmount;
        ERC20Mock(WETH_tokenAddress).approve(address(dUSDEngine), randomAmount);
        dUSDEngine.depositCollateral(WETH_tokenAddress, randomAmount);
        (uint256 totalDUSDMinted, uint256 totalCollateralValue) = dUSDEngine.getAccountInfo();

        assertEq(totalDUSDMinted, 0);
        assertEq(totalCollateralValue, dUSDEngine._getUSDValue(WETH_tokenAddress, totalDepositedCollateralAmount));
        vm.stopPrank();
    }

    function test_CanDepositMultipleCollateralsNGetAccountInfo()
        public
        depositedCollateral(WETH_tokenAddress, 1 ether)
    {
        uint256 otherCollateralAmount = 2 ether;
        depositCollateral(WBTC_tokenAddress, otherCollateralAmount);

        vm.startPrank(USER);
        uint256 totalDepositValueInUSD = dUSDEngine._getUSDValue(WETH_tokenAddress, 1 ether)
            + dUSDEngine._getUSDValue(WBTC_tokenAddress, otherCollateralAmount);
        (uint256 totalDUSDMinted, uint256 totalCollateralValue) = dUSDEngine.getAccountInfo();

        assertEq(totalDUSDMinted, 0);
        assertEq(totalCollateralValue, totalDepositValueInUSD);
        vm.stopPrank();
    }

    function test_EmitEventCollateralDeposited() public {
        vm.startPrank(USER);
        ERC20Mock(WETH_tokenAddress).approve(address(dUSDEngine), DEPOSIT_COLLATERAL);

        vm.expectEmit(true, true, true, false, address(dUSDEngine));
        emit CollateralDeposited(USER, WETH_tokenAddress, DEPOSIT_COLLATERAL);

        dUSDEngine.depositCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL);
        vm.stopPrank();
    }

    function test_RevertWhenApprovedAnInvalidTokenAmount() public {
        vm.startPrank(USER);

        ERC20Mock(WETH_tokenAddress).approve(address(dUSDEngine), DEPOSIT_COLLATERAL - 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(dUSDEngine),
                DEPOSIT_COLLATERAL - 1 ether,
                DEPOSIT_COLLATERAL
            )
        );

        dUSDEngine.depositCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL);
        vm.stopPrank();
    }

    function test_CanDepositCollateralAndMintDUSD() public {
        vm.startPrank(USER);
        uint256 DUSD_TO_MINT = 1 ether;
        MockV3Aggregator EthPriceFeeds = MockV3Aggregator(priceFeeds[0]);
        uint256 _ADDTIONAL_ETH_PRICEFEED_PRECISION =
            dUSDEngine.calculateAdditionalPriceFeedPrecision(PRECISION, 10 ** EthPriceFeeds.decimals());
        (, int256 price,,,) = MockV3Aggregator(EthPriceFeeds).latestRoundData();

        uint256 EXPECTED_COLLATERALIZED_VALUE =
            uint256(price) * _ADDTIONAL_ETH_PRICEFEED_PRECISION * DEPOSIT_COLLATERAL / PRECISION;
        uint256 EXPECTED_HF = ((EXPECTED_COLLATERALIZED_VALUE / DUSD_TO_MINT) * PRECISION / OVERCOLLATERAL_RATIO);

        // ERC20Mock(address(dUSD)).approve(address(dUSDEngine), totalDUSDMinted);
        ERC20Mock(WETH_tokenAddress).approve(address(dUSDEngine), DEPOSIT_COLLATERAL);
        vm.expectEmit(true, true, true, false, address(dUSDEngine));
        emit CollateralDeposited(USER, WETH_tokenAddress, DEPOSIT_COLLATERAL);
        dUSDEngine.depositCollateralAndMintDUSD(WETH_tokenAddress, DEPOSIT_COLLATERAL, DUSD_TO_MINT);

        (uint256 totalDUSDMintedAfter, uint256 totalCollateralizedValueAfter) = dUSDEngine.getAccountInfo();
        assertEq(totalDUSDMintedAfter, DUSD_TO_MINT);
        assertEq(totalCollateralizedValueAfter, EXPECTED_COLLATERALIZED_VALUE);
        assertEq(dUSDEngine.getHealthFactor(USER), EXPECTED_HF);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           REDEEM COLLATERAL
    //////////////////////////////////////////////////////////////*/
    function test_RevertIfRedeemCollateralAmountIsZero()
        public
        depositedCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL)
    {
        vm.startPrank(USER);
        vm.expectRevert(DUSDEngine.DUSDEngine__NeedMoreThanZero.selector);
        dUSDEngine.redeemCollateral(WETH_tokenAddress, 0);
        vm.stopPrank();
    }

    function test_RevertIfRedeemCollateralAmountIsMoreThanUserHas()
        public
        depositedCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL)
    {
        vm.startPrank(USER);
        vm.expectRevert(DUSDEngine.DUSDEngine__InvalidCollateralAmount.selector);
        dUSDEngine.redeemCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL + 1);
        vm.stopPrank();
    }

    function test_CanRedeemCollateral() public depositedCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL) {
        vm.startPrank(USER);
        vm.expectEmit(true, true, true, true, address(dUSDEngine));
        emit CollateralRedeemed(USER, USER, WETH_tokenAddress, DEPOSIT_COLLATERAL);

        dUSDEngine.redeemCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL);
        vm.stopPrank();
    }

    function test_RevertIfRedeemCollateralAmountBreakHeathFactor()
        public
        depositedCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL)
        mintedMaxDUSD
    {
        vm.startPrank(USER);

        vm.expectRevert(DUSDEngine.DUSDEngine__HealthFactorTooLow.selector);
        dUSDEngine.redeemCollateral(WETH_tokenAddress, 1 ether);
        vm.stopPrank();
    }

    function test_CanRedeemCollateralForDUSD()
        public
        depositedCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL)
        mintedMaxDUSD
    {
        vm.startPrank(USER);
        (uint256 totalDUSDMinted,) = dUSDEngine.getAccountInfo();

        ERC20Mock(address(dUSD)).approve(address(dUSDEngine), totalDUSDMinted);
        ERC20Mock(WETH_tokenAddress).approve(address(dUSDEngine), DEPOSIT_COLLATERAL);
        vm.expectEmit(true, true, true, true, address(dUSDEngine));
        emit CollateralRedeemed(USER, USER, WETH_tokenAddress, DEPOSIT_COLLATERAL);

        dUSDEngine.redeemCollateralForDUSD(WETH_tokenAddress, DEPOSIT_COLLATERAL, totalDUSDMinted);

        (uint256 totalDUSDMintedAfter, uint256 totalCollateralizedValueAfter) = dUSDEngine.getAccountInfo();
        assertEq(totalDUSDMintedAfter, 0);
        assertEq(totalCollateralizedValueAfter, 0);
        assertEq(dUSDEngine.getHealthFactor(USER), ZERO_DEBT_HEALTH_FACTOR);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               MINT DUSD
    //////////////////////////////////////////////////////////////*/
    function test_RevertIfMintingZeroCollateral() public depositedCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL) {
        vm.prank(USER);
        vm.expectRevert(DUSDEngine.DUSDEngine__NeedMoreThanZero.selector);
        dUSDEngine.mintDUSD(0);
    }

    function test_RevertMintingIfBrokenHealthFactor() public depositedCollateral(WETH_tokenAddress, 1 ether) {
        vm.startPrank(USER);
        uint256 collateralizedValueInUSD = dUSDEngine._getUSDValue(WETH_tokenAddress, 1 ether);
        vm.expectRevert(DUSDEngine.DUSDEngine__HealthFactorTooLow.selector);
        dUSDEngine.mintDUSD(collateralizedValueInUSD / OVERCOLLATERAL_RATIO + 1);

        vm.stopPrank();
    }

    function test_MintingMaxDUSDAtHealthFactorEqualToONE() public depositedCollateral(WETH_tokenAddress, 1 ether) {
        vm.startPrank(USER);
        uint256 collateralizedValueInUSD = dUSDEngine._getUSDValue(WETH_tokenAddress, 1 ether);
        dUSDEngine.mintDUSD(collateralizedValueInUSD / OVERCOLLATERAL_RATIO);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               BURN DUSD
    //////////////////////////////////////////////////////////////*/
    function test_RevertIfDoesNotHaveEnoughDUSDToBurn() public {
        vm.startPrank(USER);
        vm.expectRevert(DUSDEngine.DUSDEngine__InvalidDUSDAmount.selector);
        dUSDEngine.burnDUSD(1 ether);
        vm.stopPrank();
    }

    function test_RevertBurnIfAmountIsZERO() public depositedCollateral(WETH_tokenAddress, 1 ether) mintedMaxDUSD {
        vm.startPrank(USER);
        vm.expectRevert(DUSD.DUSD__MustBeMoreThanZero.selector);
        dUSDEngine.burnDUSD(0);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               LIQUIDATE
    //////////////////////////////////////////////////////////////*/
    function test_isLiquidable(uint256 amountDUSDMinted)
        public
        depositedCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL)
    {
        uint256 LIQUIDATION_PRECISION = dUSDEngine.getLiquidationPrecision();
        uint256 LIQUIDATION_BONUS = dUSDEngine.getLiquidationBonus();
        uint256 MIN_HEALTH_FACTOR = dUSDEngine.getMinHealthFactor();
        uint256 OVERCOLLATERALRATIO = dUSDEngine.getOvercollateralRatio();

        // vm.startPrank(USER);
        uint256 collateralizedValueInUSD = dUSDEngine._getUSDValue(WETH_tokenAddress, DEPOSIT_COLLATERAL);
        amountDUSDMinted = bound(amountDUSDMinted, 1e5, collateralizedValueInUSD / OVERCOLLATERALRATIO);
        uint256 EXPECTED_HF = collateralizedValueInUSD * PRECISION / (amountDUSDMinted * OVERCOLLATERALRATIO);

        uint256 minLiquidableHF = MIN_HEALTH_FACTOR * (LIQUIDATION_PRECISION + LIQUIDATION_BONUS)
            / (LIQUIDATION_PRECISION * OVERCOLLATERAL_RATIO);
        bool isLiquidable = EXPECTED_HF < MIN_HEALTH_FACTOR && EXPECTED_HF >= minLiquidableHF;

        vm.prank(USER);
        dUSDEngine.mintDUSD(amountDUSDMinted);

        assertEq(dUSDEngine.isLiquidable(USER), isLiquidable);
    }

    function test_RevertLiquidateIfHealthFactorIsGood()
        public
        depositedCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL)
        mintedMaxDUSD
    {
        address LIQUIDATOR = address(uint160(10));
        uint256 DEBT_TO_COVER = dUSDEngine.getMaxDebtToCover(USER);

        vm.prank(address(dUSDEngine));
        ERC20Mock(address(dUSD)).mint(LIQUIDATOR, DEBT_TO_COVER);

        uint256 STARTING_HEALTH_FACTOR = dUSDEngine.getHealthFactor(USER);
        assertEq(STARTING_HEALTH_FACTOR, 1 * PRECISION);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(address(dUSD)).approve(address(dUSDEngine), DEBT_TO_COVER);
        vm.expectRevert(DUSDEngine.DUSDEngine__HealthFactorIsGood.selector);
        dUSDEngine.liquidate(USER, DEBT_TO_COVER);

        vm.stopPrank();
    }

    function test_RevertIfLiquidateExceedDebt()
        public
        depositedCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL)
        mintedMaxDUSD
    {
        address LIQUIDATOR = address(uint160(10));
        MockV3Aggregator WETH_PriceFeed = MockV3Aggregator(priceFeeds[0]);
        uint256 PRICE_DECREASE_PERCENTAGE = 30;
        int256 NEW_WETH_PRICE = MOCK_WETH_INITIAL_ANSWER * (100 - int256(PRICE_DECREASE_PERCENTAGE)) / 100; // Price
        // Dropped by 30%

        // Update WETH Price
        MockV3Aggregator(WETH_PriceFeed).updateAnswer(NEW_WETH_PRICE);
        uint256 DEBT_TO_COVER = dUSDEngine.getMaxDebtToCover(USER) + 1;
        vm.prank(address(dUSDEngine));
        ERC20Mock(address(dUSD)).mint(LIQUIDATOR, DEBT_TO_COVER);

        vm.prank(LIQUIDATOR);
        vm.expectRevert(DUSDEngine.DUSDEngine__ExceedsDebt.selector);
        dUSDEngine.liquidate(USER, DEBT_TO_COVER);
    }

    function test_RevertIfLiquidateWhenNotEnoughAssetsToRedeem()
        public
        depositedCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL)
        mintedMaxDUSD
    {
        address LIQUIDATOR = address(uint160(10));
        uint256 LIQUIDATION_PRECISION = dUSDEngine.getLiquidationPrecision();
        MockV3Aggregator WETH_PriceFeed = MockV3Aggregator(priceFeeds[0]);
        uint256 PRICE_DECREASE_PERCENTAGE = 60; // Price Dropped by 60%
        int256 NEW_WETH_PRICE = MOCK_WETH_INITIAL_ANSWER * (100 - int256(PRICE_DECREASE_PERCENTAGE)) / 100;

        // Update WETH Price
        MockV3Aggregator(WETH_PriceFeed).updateAnswer(NEW_WETH_PRICE);
        uint256 DEBT_TO_COVER = dUSDEngine._getDUSDMinted(USER);
        uint256 EXPECTED_REQUIRED_VALUE =
            DEBT_TO_COVER * (LIQUIDATION_PRECISION + dUSDEngine.getLiquidationBonus()) / LIQUIDATION_PRECISION;

        vm.prank(address(dUSDEngine));
        ERC20Mock(address(dUSD)).mint(LIQUIDATOR, DEBT_TO_COVER);
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(address(dUSD)).approve(address(dUSDEngine), DEBT_TO_COVER);

        vm.expectRevert(
            abi.encodeWithSelector(
                DUSDEngine.DUSDEngine__NotEnoughAssetsToRedeem.selector, USER, DEBT_TO_COVER, EXPECTED_REQUIRED_VALUE
            )
        );
        dUSDEngine.liquidate(USER, DEBT_TO_COVER);
        vm.stopPrank();
    }

    function test_CanLiquidate() public depositedCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL) mintedMaxDUSD {
        address LIQUIDATOR = address(uint160(10));
        uint256 LIQUIDATION_PRECISION = dUSDEngine.getLiquidationPrecision();
        uint256 LIQUIDATION_BONUS = dUSDEngine.getLiquidationBonus();
        MockV3Aggregator WETH_PriceFeed = MockV3Aggregator(priceFeeds[0]);

        uint256 PRICE_DECREASE_PERCENTAGE = 30;
        int256 NEW_WETH_PRICE = MOCK_WETH_INITIAL_ANSWER * (100 - int256(PRICE_DECREASE_PERCENTAGE)) / 100; // Price
        // Dropped by 30%

        // Update WETH Price
        MockV3Aggregator(WETH_PriceFeed).updateAnswer(NEW_WETH_PRICE);
        uint256 DEBT_TO_COVER = dUSDEngine.getMaxDebtToCover(USER);
        vm.prank(address(dUSDEngine));
        ERC20Mock(address(dUSD)).mint(LIQUIDATOR, DEBT_TO_COVER);

        uint256 totalCollateralValueToReceive =
            DEBT_TO_COVER * (LIQUIDATION_BONUS + LIQUIDATION_PRECISION) / LIQUIDATION_PRECISION;

        uint256 STARTING_HEALTH_FACTOR = dUSDEngine.getHealthFactor(USER);

        vm.startPrank(LIQUIDATOR);

        ERC20Mock(address(dUSD)).approve(address(dUSDEngine), DEBT_TO_COVER);
        dUSDEngine.liquidate(USER, DEBT_TO_COVER);

        uint256 LiquidatorWETHValue =
            dUSDEngine._getUSDValue(WETH_tokenAddress, ERC20Mock(WETH_tokenAddress).balanceOf(LIQUIDATOR));
        uint256 LiquidatorWBTCValue =
            dUSDEngine._getUSDValue(WBTC_tokenAddress, ERC20Mock(WBTC_tokenAddress).balanceOf(LIQUIDATOR));

        assertEq(ERC20Mock(address(dUSD)).balanceOf(LIQUIDATOR), 0);
        assertApproxEqAbs(LiquidatorWETHValue + LiquidatorWBTCValue, totalCollateralValueToReceive, 1e17);
        vm.stopPrank();

        assertGt(dUSDEngine.getHealthFactor(USER), STARTING_HEALTH_FACTOR);
    }

    function test_CanLiquidateAndCanRedeemTheRightCollateralAmountWhenDepositedMultipleCollaterals()
        public
        depositedCollateral(WETH_tokenAddress, 1 ether)
        depositedCollateral(WBTC_tokenAddress, 5 ether)
        mintedMaxDUSD
    {
        address LIQUIDATOR = address(uint160(10));
        uint256 LIQUIDATION_PRECISION = dUSDEngine.getLiquidationPrecision();
        MockV3Aggregator WBTC_PriceFeed = MockV3Aggregator(priceFeeds[1]);
        uint256 PRICE_DECREASE_PERCENTAGE = 40; // Price Dropped by 20%
        int256 NEW_WBTC_PRICE = MOCK_WBTC_INITIAL_ANSWER * (100 - int256(PRICE_DECREASE_PERCENTAGE)) / 100;

        // Update WETH Price
        MockV3Aggregator(WBTC_PriceFeed).updateAnswer(NEW_WBTC_PRICE);
        uint256 DEBT_TO_COVER = dUSDEngine.getMaxDebtToCover(USER);
        uint256 EXPECTED_TOTAL_VALUE_TO_SEIZE =
            DEBT_TO_COVER * (LIQUIDATION_PRECISION + dUSDEngine.getLiquidationBonus()) / LIQUIDATION_PRECISION;

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            address tokenAddr = tokenAddresses[i];
            uint256 collateralAmount = dUSDEngine.getCollateralDeposited(USER, tokenAddr);
            if (collateralAmount == 0) continue;

            // Total USD value of the tokenAddr collateral
            uint256 collateralValue = dUSDEngine._getUSDValue(tokenAddr, collateralAmount);
            uint256 valueToSeize =
                (EXPECTED_TOTAL_VALUE_TO_SEIZE * collateralValue) / dUSDEngine.getAccountTotalCollateralValue(USER);
            uint256 amountToSeize = dUSDEngine.getTokenAmountFromUSD(tokenAddr, valueToSeize);

            // Cap at userBalance (hypothetically not needed)
            if (amountToSeize > collateralAmount) amountToSeize = collateralAmount;

            s_CollateralAmountToSeize[tokenAddr] = amountToSeize;
        }

        vm.prank(address(dUSDEngine));
        ERC20Mock(address(dUSD)).mint(LIQUIDATOR, DEBT_TO_COVER);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(address(dUSD)).approve(address(dUSDEngine), DEBT_TO_COVER);

        dUSDEngine.liquidate(USER, DEBT_TO_COVER);

        assertEq(s_CollateralAmountToSeize[WETH_tokenAddress], ERC20Mock(WETH_tokenAddress).balanceOf(LIQUIDATOR));
        assertEq(s_CollateralAmountToSeize[WBTC_tokenAddress], ERC20Mock(WBTC_tokenAddress).balanceOf(LIQUIDATOR));
        vm.stopPrank();
    }

    function test_RevertLiquidateIfHealthFactorImprovedButStillBroken()
        public
        depositedCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL)
        mintedMaxDUSD
    {
        address LIQUIDATOR = address(uint160(10));
        address WETH_PriceFeed = priceFeeds[0];
        uint256 PRICE_DECREASE_PERCENTAGE = 10;
        int256 NEW_WETH_PRICE = MOCK_WETH_INITIAL_ANSWER * (100 - int256(PRICE_DECREASE_PERCENTAGE)) / 100; // Price
        // Dropped by 50%

        MockV3Aggregator(WETH_PriceFeed).updateAnswer(NEW_WETH_PRICE);
        uint256 DEBT_TO_COVER = dUSDEngine.getMaxDebtToCover(USER) * PRICE_DECREASE_PERCENTAGE / 100;

        vm.prank(address(dUSDEngine));
        ERC20Mock(address(dUSD)).mint(LIQUIDATOR, DEBT_TO_COVER);

        uint256 STARTING_HEALTH_FACTOR = dUSDEngine.getHealthFactor(USER);
        assertLt(STARTING_HEALTH_FACTOR, MIN_HEALTH_FACTOR * PRECISION);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(address(dUSD)).approve(address(dUSDEngine), DEBT_TO_COVER);
        vm.expectRevert(DUSDEngine.DUSDEngine__HealthFactorTooLow.selector);
        dUSDEngine.liquidate(USER, DEBT_TO_COVER);

        vm.stopPrank();
    }

    function test_RevertLiquidateIfHealthFactorBelowOnePlusLiquidationBonus()
        public
        depositedCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL)
        mintedMaxDUSD
    {
        address LIQUIDATOR = address(uint160(10));
        address WETH_PriceFeed = priceFeeds[0];
        uint256 PRICE_DECREASE_PERCENTAGE = 100 / dUSDEngine.getOvercollateralRatio();
        int256 NEW_WETH_PRICE = MOCK_WETH_INITIAL_ANSWER * (100 - int256(PRICE_DECREASE_PERCENTAGE)) / 100; // Price
        // Dropped by 50%

        MockV3Aggregator(WETH_PriceFeed).updateAnswer(NEW_WETH_PRICE);
        uint256 DEBT_TO_COVER = dUSDEngine.getMaxDebtToCover(USER) * PRICE_DECREASE_PERCENTAGE / 100;

        vm.prank(address(dUSDEngine));
        ERC20Mock(address(dUSD)).mint(LIQUIDATOR, DEBT_TO_COVER);

        uint256 STARTING_HEALTH_FACTOR = dUSDEngine.getHealthFactor(USER);
        assertLt(STARTING_HEALTH_FACTOR, MIN_HEALTH_FACTOR * PRECISION);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(address(dUSD)).approve(address(dUSDEngine), DEBT_TO_COVER);
        vm.expectRevert(DUSDEngine.DUSDEngine__HealthFactorNotImproved.selector);
        dUSDEngine.liquidate(USER, DEBT_TO_COVER);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           LIQUIDATIONBYASSET
    //////////////////////////////////////////////////////////////*/
    function test_RevertIfLiquidateByAssetUsingUnapprovedCollateral()
        public
        depositedCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL)
        mintedMaxDUSD
    {
        address LIQUIDATOR = address(uint160(10));
        ERC20Mock unknownToken = new ERC20Mock("UN", "UN", USER, STARTING_BALANCE);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(DUSDEngine.DUSDEngine__TokenNotAllowedAsCollateral.selector);
        dUSDEngine.liquidateByAsset(address(unknownToken), USER, 1 ether);
    }

    function test_RevertLiquidateByAssetIfHealthFactorIsGood()
        public
        depositedCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL)
        mintedMaxDUSD
    {
        address LIQUIDATOR = address(uint160(10));
        uint256 DEBT_TO_COVER = dUSDEngine.getMaxDebtToCoverForSpecificCollateral(USER, WETH_tokenAddress);

        vm.prank(address(dUSDEngine));
        ERC20Mock(address(dUSD)).mint(LIQUIDATOR, DEBT_TO_COVER);

        uint256 STARTING_HEALTH_FACTOR = dUSDEngine.getHealthFactor(USER);
        assertEq(STARTING_HEALTH_FACTOR, 1 * PRECISION);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(address(dUSD)).approve(address(dUSDEngine), DEBT_TO_COVER);
        vm.expectRevert(DUSDEngine.DUSDEngine__HealthFactorIsGood.selector);
        dUSDEngine.liquidateByAsset(WETH_tokenAddress, USER, DEBT_TO_COVER);

        vm.stopPrank();
    }

    function test_RevertIfLiquidateByAssetExceedDebt()
        public
        depositedCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL)
        mintedMaxDUSD
    {
        address LIQUIDATOR = address(uint160(10));
        MockV3Aggregator WETH_PriceFeed = MockV3Aggregator(priceFeeds[0]);
        uint256 PRICE_DECREASE_PERCENTAGE = 30;
        int256 NEW_WETH_PRICE = MOCK_WETH_INITIAL_ANSWER * (100 - int256(PRICE_DECREASE_PERCENTAGE)) / 100; // Price
        // Dropped by 30%

        // Update WETH Price
        MockV3Aggregator(WETH_PriceFeed).updateAnswer(NEW_WETH_PRICE);
        uint256 DEBT_TO_COVER = dUSDEngine.getMaxDebtToCoverForSpecificCollateral(USER, WETH_tokenAddress) + 1;
        vm.prank(address(dUSDEngine));
        ERC20Mock(address(dUSD)).mint(LIQUIDATOR, DEBT_TO_COVER);

        vm.prank(LIQUIDATOR);
        vm.expectRevert(DUSDEngine.DUSDEngine__ExceedsDebt.selector);
        dUSDEngine.liquidateByAsset(WETH_tokenAddress, USER, DEBT_TO_COVER);
    }

    function test_RevertIfLiquidateByAssetWhenNotEnoughAssetsToRedeem()
        public
        depositedCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL)
        mintedMaxDUSD
    {
        address LIQUIDATOR = address(uint160(10));
        uint256 LIQUIDATION_PRECISION = dUSDEngine.getLiquidationPrecision();
        MockV3Aggregator WETH_PriceFeed = MockV3Aggregator(priceFeeds[0]);
        uint256 PRICE_DECREASE_PERCENTAGE = 30; // Price Dropped by 30%
        int256 NEW_WETH_PRICE = MOCK_WETH_INITIAL_ANSWER * (100 - int256(PRICE_DECREASE_PERCENTAGE)) / 100;

        // Update WETH Price
        MockV3Aggregator(WETH_PriceFeed).updateAnswer(NEW_WETH_PRICE);
        uint256 DEBT_TO_COVER = dUSDEngine.getMaxDebtToCoverForSpecificCollateral(USER, WETH_tokenAddress);
        uint256 EXPECTED_REQUIRED_VALUE =
            DEBT_TO_COVER * (LIQUIDATION_PRECISION + dUSDEngine.getLiquidationBonus()) / LIQUIDATION_PRECISION;

        vm.prank(address(dUSDEngine));
        ERC20Mock(address(dUSD)).mint(LIQUIDATOR, DEBT_TO_COVER);

        vm.prank(LIQUIDATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                DUSDEngine.DUSDEngine__NotEnoughAssetsToRedeem.selector, USER, DEBT_TO_COVER, EXPECTED_REQUIRED_VALUE
            )
        );
        dUSDEngine.liquidateByAsset(WBTC_tokenAddress, USER, DEBT_TO_COVER);
    }

    function test_CanLiquidateByAsset()
        public
        depositedCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL)
        mintedMaxDUSD
    {
        address LIQUIDATOR = address(uint160(10));
        address priceFeedAddr = priceFeeds[0];
        MockV3Aggregator WETH_PriceFeed = MockV3Aggregator(priceFeedAddr);

        uint256 PRICE_DECREASE_PERCENTAGE = 30;
        int256 NEW_WETH_PRICE = MOCK_WETH_INITIAL_ANSWER * (100 - int256(PRICE_DECREASE_PERCENTAGE)) / 100; // Price
        // Dropped by 30%

        // Update WETH Price
        MockV3Aggregator(WETH_PriceFeed).updateAnswer(NEW_WETH_PRICE);
        uint256 DEBT_TO_COVER = dUSDEngine.getMaxDebtToCoverForSpecificCollateral(USER, WETH_tokenAddress);
        vm.prank(address(dUSDEngine));
        ERC20Mock(address(dUSD)).mint(LIQUIDATOR, DEBT_TO_COVER);

        uint256 tokenAmountFromDebtCovered = dUSDEngine.getTokenAmountFromUSD(WETH_tokenAddress, DEBT_TO_COVER);
        uint256 bonusCollateral = tokenAmountFromDebtCovered * dUSDEngine.getLiquidationBonus() / 100;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        uint256 STARTING_HEALTH_FACTOR = dUSDEngine.getHealthFactor(USER);

        vm.startPrank(LIQUIDATOR);

        ERC20Mock(address(dUSD)).approve(address(dUSDEngine), DEBT_TO_COVER);
        dUSDEngine.liquidateByAsset(WETH_tokenAddress, USER, DEBT_TO_COVER);

        assertEq(ERC20Mock(address(dUSD)).balanceOf(LIQUIDATOR), 0);
        assertEq(ERC20Mock(WETH_tokenAddress).balanceOf(LIQUIDATOR), totalCollateralToRedeem);
        vm.stopPrank();

        assertGt(dUSDEngine.getHealthFactor(USER), STARTING_HEALTH_FACTOR);
    }

    function test_RevertLiquidateByAssetIfHealthFactorImprovedButStillBroken()
        public
        depositedCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL)
        mintedMaxDUSD
    {
        address LIQUIDATOR = address(uint160(10));
        address WETH_PriceFeed = priceFeeds[0];
        uint256 PRICE_DECREASE_PERCENTAGE = 10;
        int256 NEW_WETH_PRICE = MOCK_WETH_INITIAL_ANSWER * (100 - int256(PRICE_DECREASE_PERCENTAGE)) / 100; // Price
        // Dropped by 50%

        MockV3Aggregator(WETH_PriceFeed).updateAnswer(NEW_WETH_PRICE);
        uint256 DEBT_TO_COVER = dUSDEngine.getMaxDebtToCoverForSpecificCollateral(USER, WETH_tokenAddress)
            * PRICE_DECREASE_PERCENTAGE / 100;

        vm.prank(address(dUSDEngine));
        ERC20Mock(address(dUSD)).mint(LIQUIDATOR, DEBT_TO_COVER);

        uint256 STARTING_HEALTH_FACTOR = dUSDEngine.getHealthFactor(USER);
        assertLt(STARTING_HEALTH_FACTOR, MIN_HEALTH_FACTOR * PRECISION);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(address(dUSD)).approve(address(dUSDEngine), DEBT_TO_COVER);
        vm.expectRevert(DUSDEngine.DUSDEngine__HealthFactorTooLow.selector);
        dUSDEngine.liquidateByAsset(WETH_tokenAddress, USER, DEBT_TO_COVER);

        vm.stopPrank();
    }

    function test_RevertLiquidateByAssetIfHealthFactorBelowOnePlusLiquidationBonus()
        public
        depositedCollateral(WETH_tokenAddress, DEPOSIT_COLLATERAL)
        mintedMaxDUSD
    {
        address LIQUIDATOR = address(uint160(10));
        address WETH_PriceFeed = priceFeeds[0];
        uint256 PRICE_DECREASE_PERCENTAGE = 100 / dUSDEngine.getOvercollateralRatio();
        int256 NEW_WETH_PRICE = MOCK_WETH_INITIAL_ANSWER * (100 - int256(PRICE_DECREASE_PERCENTAGE)) / 100; // Price
        // Dropped by 50%

        MockV3Aggregator(WETH_PriceFeed).updateAnswer(NEW_WETH_PRICE);
        uint256 DEBT_TO_COVER = dUSDEngine.getMaxDebtToCoverForSpecificCollateral(USER, WETH_tokenAddress)
            * PRICE_DECREASE_PERCENTAGE / 100;

        vm.prank(address(dUSDEngine));
        ERC20Mock(address(dUSD)).mint(LIQUIDATOR, DEBT_TO_COVER);

        uint256 STARTING_HEALTH_FACTOR = dUSDEngine.getHealthFactor(USER);
        assertLt(STARTING_HEALTH_FACTOR, MIN_HEALTH_FACTOR * PRECISION);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(address(dUSD)).approve(address(dUSDEngine), DEBT_TO_COVER);
        vm.expectRevert(DUSDEngine.DUSDEngine__HealthFactorNotImproved.selector);
        dUSDEngine.liquidateByAsset(WETH_tokenAddress, USER, DEBT_TO_COVER);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                             UTIL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice  Should only use when expecting an event to emit
     * @dev     A helper function to return the correct topic if found, otherwise revert
     * @param   entries  event log
     * @param   signature  event topic in string
     * @return  bytes32[]  return the event that matches with the signature
     */
    function getTopic(Vm.Log[] memory entries, string memory signature) public pure returns (bytes32[] memory) {
        for (uint256 i = 0; i < entries.length; i++) {
            bytes32 topicHash = keccak256(bytes(signature));
            if (entries[i].topics[0] == topicHash) return entries[i].topics;
        }

        revert("Event not found");
    }

    function depositCollateral(address tokenAddr, uint256 amount) private {
        vm.startPrank(USER);

        ERC20Mock(tokenAddr).approve(address(dUSDEngine), amount);
        dUSDEngine.depositCollateral(tokenAddr, amount);
        vm.stopPrank();
    }
}
