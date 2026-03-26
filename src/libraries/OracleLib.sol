// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @author  Lok Jing Lau
 * @title   OracleLib
 * @notice  This library is used to check the Chainlink Oracle for stale data.
 * If a price is stale, functions will revert, and render the DSCEngine unusable - this is by design.
 * We want the DSCEngine to freeze if prices become stale.
 * So if the Chainlink network explodes and you have a lot of money locked in the protocol... too bad.
 */
library OracleLib {
    error OracleLib__StalePrice();

    uint256 private constant TIME_OUT = 3 hours;

    function staleCheckLatestRoundData(AggregatorV3Interface priceFeedAddr)
        public
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) =
            AggregatorV3Interface(priceFeedAddr).latestRoundData();

        uint256 secondSince = block.timestamp - updatedAt;
        if (secondSince > TIME_OUT) revert OracleLib__StalePrice();
    }
}
