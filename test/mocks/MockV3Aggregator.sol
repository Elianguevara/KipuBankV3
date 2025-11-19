// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Consistent import using the @chainlink alias
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title MockV3Aggregator
 * @notice Mock Oracle for testing price feeds and failure scenarios.
 */
contract MockV3Aggregator is AggregatorV3Interface {
    uint8 public override decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;

    constructor(uint8 _decimals, int256 _initialAnswer) {
        decimals = _decimals;
        answer = _initialAnswer;
        updatedAt = block.timestamp;
        roundId = 1;
    }

    function updateAnswer(int256 _answer) public {
        answer = _answer;
        updatedAt = block.timestamp;
        roundId++;
    }
    
    function updateRoundData(uint80 _roundId, int256 _answer, uint256 _updatedAt, uint80 _answeredInRound) public {
        roundId = _roundId;
        answer = _answer;
        updatedAt = _updatedAt;
    }

    function description() external pure override returns (string memory) {
        return "v0.8/tests/MockV3Aggregator.sol";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (
            uint80 roundId_,
            int256 answer_,
            uint256 startedAt_,
            uint256 updatedAt_,
            uint80 answeredInRound_
        )
    {
        return (_roundId, answer, updatedAt, updatedAt, _id);
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId_,
            int256 answer_,
            uint256 startedAt_,
            uint256 updatedAt_,
            uint80 answeredInRound_
        )
    {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}