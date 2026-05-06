// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceFeed} from "../../src/interfaces/IPriceFeed.sol";

contract MockV3Aggregator is IPriceFeed {
    uint8 public override decimals;
    int256 private answer;
    uint256 private updatedAt;
    uint80 private roundId;
    uint80 private answeredInRound;

    constructor(uint8 decimals_, int256 answer_, uint256 updatedAt_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = updatedAt_;
        roundId = 1;
        answeredInRound = 1;
    }

    function setAnswer(int256 newAnswer) external {
        answer = newAnswer;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 newUpdatedAt) external {
        updatedAt = newUpdatedAt;
    }

    function setRoundData(uint80 newRoundId, int256 newAnswer, uint256 newUpdatedAt, uint80 newAnsweredInRound)
        external
    {
        roundId = newRoundId;
        answer = newAnswer;
        updatedAt = newUpdatedAt;
        answeredInRound = newAnsweredInRound;
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId_,
            int256 answer_,
            uint256 startedAtIgnored_,
            uint256 updatedAt_,
            uint80 answeredInRound_
        )
    {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}
