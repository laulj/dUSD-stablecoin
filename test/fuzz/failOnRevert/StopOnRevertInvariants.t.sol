// SPDX-License-Identifier: MIT
/*
    Invariants
    1. The total supply of DUSD should be less than the total value collateralized,
    2. Getter function should never revert <- evergreen invariant.
*/
pragma solidity ^0.8.19;

import { Test, console } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";

import { DUSD } from "../../../src/DUSDStableCoin.sol";
import { DUSDEngine } from "../../../src/DUSDEngine.sol";
import { DUSDScript } from "../../../script/DeployDUSD.s.sol";
import { HelperConfig } from "../../../script/HelperConfig.s.sol";
import { InvariantsHandler } from "./StopOnRevertHandler.t.sol";
import { ERC20Mock } from "../../../test/mocks/ERC20Mock.sol";

contract InvariantsTest is StdInvariant, Test {
    DUSD dUSD;
    DUSDEngine dUSDEngine;
    HelperConfig helperConfig;
    InvariantsHandler handler;
    address[] public tokenAddresses;
    address[] public priceFeeds;
    address public WETH_tokenAddress;
    address public WBTC_tokenAddress;
    ERC20Mock WETH;
    ERC20Mock WBTC;

    address public USER = makeAddr("USER");
    uint256 public constant STARTING_BALANCE = 10 ether;
    uint256 public constant DEPOSIT_COLLATERAL = 10 ether;
    uint256 public constant INTERVAL = 60;

    function setUp() external {
        DUSDScript deployer = new DUSDScript();
        (dUSD, dUSDEngine, helperConfig) = deployer.deployContract();

        HelperConfig.NetworkConfig memory networkConfig = helperConfig.getConfig();

        tokenAddresses = networkConfig.tokenAddresses;
        priceFeeds = networkConfig.priceFeeds;
        WETH_tokenAddress = tokenAddresses[0];
        WBTC_tokenAddress = tokenAddresses[1];
        WETH = ERC20Mock(WETH_tokenAddress);
        WBTC = ERC20Mock(WBTC_tokenAddress);

        handler = new InvariantsHandler(dUSD, dUSDEngine);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalSupply = dUSD.totalSupply();
        uint256 totalWETHDeposited = WETH.balanceOf(address(dUSDEngine));
        uint256 totalWBTCDeposited = WBTC.balanceOf(address(dUSDEngine));

        uint256 totalValueInUSD = dUSDEngine._getUSDValue(WETH_tokenAddress, totalWETHDeposited)
            + dUSDEngine._getUSDValue(WBTC_tokenAddress, totalWBTCDeposited);

        console.log("totalSupply of DUSD:", totalSupply);
        console.log("total WETH, WBTC deposited:", totalWETHDeposited, totalWBTCDeposited);
        console.log("totalValueInUSD:", totalValueInUSD);
        console.log("noOfTimesMintIsCalled", handler.noOfTimesMintIsCalled());
        console.log("noOfTimesLiquidateByAssetIsCalled:", handler.noOfTimesLiquidateByAssetIsCalled());
        console.log("noOfTimesLiquidateIsCalled:", handler.noOfTimesLiquidateIsCalled());

        assert(totalSupply <= totalValueInUSD);
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_gettersShouldNotRevert() public view {
        dUSDEngine._getDUSDMinted(msg.sender);
        dUSDEngine.getAccountTotalCollateralValue(msg.sender);
        dUSDEngine.getAccountCollateralValue(msg.sender, WETH_tokenAddress);
        dUSDEngine.getAccountInfo();
        dUSDEngine.getCollateralDeposited(USER, WETH_tokenAddress);
        dUSDEngine.getCollateralTokenPriceFeed(WETH_tokenAddress);
        dUSDEngine.getCollateralTokens();
        dUSDEngine.getDusd();
        dUSDEngine.getHealthFactor(msg.sender);
        dUSDEngine.getMinHealthFactor();
        dUSDEngine.getOvercollateralRatio();
        dUSDEngine.getPrecision();
        dUSDEngine.getLiquidationBonus();
        dUSDEngine.getMaxDebtToCover(msg.sender);
        dUSDEngine.getLiquidationPrecision();
        dUSDEngine.isLiquidable(msg.sender);
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_protocolMustNotLiquidateUserAboveMinHealthFactor() public view {
        assertEq(handler.liquidationFailedInvariant(), false);
    }
}
