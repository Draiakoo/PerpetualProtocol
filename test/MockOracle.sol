// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract MockOracle is AggregatorV3Interface {

    uint8 public decimals;
    uint256 public latestTimestamp;
    int256 public price;

    constructor(uint8 _decimals, int256 _price) {
        decimals = _decimals;
        price = _price;
        latestTimestamp = block.timestamp;
    }

    function updatePrice(int256 _price) public {
        price = _price;
        latestTimestamp = block.timestamp;
    }

    function latestRoundData() external view returns(uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound){
        return(
            0,
            price,
            0,
            latestTimestamp,
            0
        );
    }
}