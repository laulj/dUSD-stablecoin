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

contract DUSDTest is Test, CodeConstants {
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

    /*//////////////////////////////////////////////////////////////
                                  BURN
    //////////////////////////////////////////////////////////////*/
    function test_BurnRevertWhenBalanceIsZero(uint256 _amount) public {
        _amount = bound(_amount, 1e5, type(uint96).max);
        vm.startPrank(address(dUSDEngine));

        vm.expectRevert(DUSD.DUSD__MustBeMoreThanZero.selector);
        dUSD.burn(_amount);
        vm.stopPrank();
    }

    function test_BurnRevertWhenNotEnoughBalance(uint256 _amount) public {
        _amount = bound(_amount, 1e5, type(uint96).max);
        vm.startPrank(address(dUSDEngine));
        dUSD.mint(address(dUSDEngine), _amount);

        vm.expectRevert(DUSD.DUSD__NotEnoughBalance.selector);
        dUSD.burn(_amount + 1);
        vm.stopPrank();
    }

    function test_CanBurn(uint256 _amount) public {
        _amount = bound(_amount, 1e5, type(uint96).max);
        vm.startPrank(address(dUSDEngine));
        dUSD.mint(address(dUSDEngine), _amount);

        dUSD.burn(_amount);
        assertEq(ERC20Mock(address(dUSD)).balanceOf(address(dUSDEngine)), 0);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                  MINT
    //////////////////////////////////////////////////////////////*/
    function test_MintRevertValueIsZero() public {
        vm.startPrank(address(dUSDEngine));

        vm.expectRevert(DUSD.DUSD__MustBeMoreThanZero.selector);
        dUSD.mint(address(dUSDEngine), 0);
        vm.stopPrank();
    }

    function test_MintRevertAddressZero() public {
        vm.startPrank(address(dUSDEngine));

        vm.expectRevert(DUSD.DUSD__AddressZero.selector);
        dUSD.mint(address(0), 0);
        vm.stopPrank();
    }

    function test_CanMint(uint256 _amount) public {
        _amount = bound(_amount, 1e5, type(uint96).max);
        vm.startPrank(address(dUSDEngine));
        dUSD.mint(address(dUSDEngine), _amount);

        assertEq(ERC20Mock(address(dUSD)).balanceOf(address(dUSDEngine)), _amount);
        vm.stopPrank();
    }
}
