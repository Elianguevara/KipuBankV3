// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// FINAL CORRECTION: Using 'shared/interfaces' 
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title MockV3Aggregator
 * @notice Mock Oracle for testing price feeds and failure scenarios.
 * @dev Simulates the Chainlink AggregatorV3Interface.
 */
contract MockV3Aggregator is AggregatorV3Interface {
    /// @notice The simulated number of price decimals.
    uint8 public override decimals;
    /// @notice The current simulated price value.
    int256 public answer;
    /// @notice The timestamp of the last price update.
    uint256 public updatedAt;
    /// @notice The current round identifier.
    uint80 public roundId;
    /// @notice The round ID in which the answer was computed.
    uint80 public answeredInRound; // ⭐ NUEVA VARIABLE DE ESTADO

    /**
     * @notice Constructor for the Mock.
     * @param _decimals Initial decimals.
     * @param _initialAnswer Initial price answer.
     */
    constructor(uint8 _decimals, int256 _initialAnswer) {
        decimals = _decimals;
        answer = _initialAnswer;
        updatedAt = block.timestamp;
        roundId = 1;
        answeredInRound = 1; // ⭐ INICIALIZAR
    }

    /**
     * @notice Updates the simulated price answer and increments the round.
     * @param _answer New price answer.
     * @dev Used by tests to simulate price changes normally.
     */
    function updateAnswer(int256 _answer) public {
        answer = _answer;
        updatedAt = block.timestamp;
        roundId++;
        answeredInRound = roundId; // ⭐ MANTENER SINCRONIZADO NORMALMENTE
    }
    
    /**
     * @notice Allows setting specific round data for complex testing scenarios.
     * @dev Used to simulate anomalies (e.g. stale rounds).
     */
    function updateRoundData(uint80 _roundId, int256 _answer, uint256 _updatedAt, uint80 _answeredInRound) public {
        roundId = _roundId;
        answer = _answer;
        updatedAt = _updatedAt;
        answeredInRound = _answeredInRound; // ⭐ PERMITIR MANIPULACIÓN
    }

    /**
     * @notice Alias for updateRoundData to match the test naming convention used in KipuBankV3.t.sol
     */
    function setRoundData(uint80 _roundId, int256 _answer, uint256 _updatedAt, uint80 _answeredInRound) public {
        updateRoundData(_roundId, _answer, _updatedAt, _answeredInRound);
    }

    /// @notice Returns the description of the mock.
    function description() external pure override returns (string memory) {
        return "v0.8/tests/MockV3Aggregator.sol";
    }

    /// @notice Returns the version of the mock.
    function version() external pure override returns (uint256) {
        return 1;
    }

    /**
     * @notice Returns data for a specific round (simulated).
     */
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
        // ⭐ DEVOLVER LA VARIABLE DE ESTADO MANIPULABLE
        return (_roundId, answer, updatedAt, updatedAt, answeredInRound);
    }

    /**
     * @notice Returns the latest simulated price data.
     */
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
        // ⭐ DEVOLVER LA VARIABLE DE ESTADO MANIPULABLE
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}