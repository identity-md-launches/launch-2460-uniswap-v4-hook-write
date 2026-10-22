// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwapSMA} from "../src/libraries/SwapSMA.sol";

contract SMAHarness {
    using SwapSMA for SwapSMA.History;
    SwapSMA.History private h;

    function push(uint160 price) external returns (int8) {
        return h.push(price);
    }

    function read() external view returns (uint160, uint160, uint256, uint256, uint16, uint16) {
        (uint160 a, uint160 b) = h.averages();
        return (a, b, h.sum50, h.sum200, h.next, h.count);
    }
}

contract SwapSMATest is Test {
    SMAHarness internal sma;

    function setUp() public {
        sma = new SMAHarness();
    }

    function test_warmupDoesNotInventCross() public {
        for (uint160 i = 1; i <= 200; ++i) {
            assertEq(sma.push(i), 0);
        }
        assertEq(sma.push(201), 0);
    }

    function test_equalThenGoldenThenDeathCross() public {
        for (uint256 i; i < 200; ++i) {
            assertEq(sma.push(100), 0);
        }
        assertEq(sma.push(101), 1, "compare exact sums despite equal rounded averages");
        assertEq(sma.push(101), 0);
        assertEq(sma.push(98), 0, "equality itself is not a cross");
        assertEq(sma.push(99), -1);
        assertEq(sma.push(99), 0);
    }

    function test_maximumPricesCannotOverflowSums() public {
        for (uint256 i; i < 450; ++i) {
            assertEq(sma.push(type(uint160).max), 0);
        }
        (uint160 a, uint160 b, uint256 s50, uint256 s200,,) = sma.read();
        assertEq(a, type(uint160).max);
        assertEq(b, type(uint160).max);
        assertEq(s50, uint256(type(uint160).max) * 50);
        assertEq(s200, uint256(type(uint160).max) * 200);
    }

    function testFuzz_ringMatchesNaiveReference(bytes32 seed, uint16 extra) public {
        uint256 length = 200 + bound(extra, 0, 450);
        uint160[] memory prices = new uint160[](length);
        int8 oldRelation;
        for (uint256 i; i < length; ++i) {
            prices[i] = uint160(uint256(keccak256(abi.encode(seed, i))));
            uint256 sum50;
            uint256 sum200;
            for (uint256 j = i >= 199 ? i - 199 : 0; j <= i; ++j) {
                sum200 += prices[j];
                if (j + 50 > i) sum50 += prices[j];
            }
            int8 expected;
            if (i >= 199) {
                int8 relation = sum50 * 4 > sum200 ? int8(1) : sum50 * 4 < sum200 ? int8(-1) : int8(0);
                if (i >= 200) {
                    if (relation > 0 && oldRelation <= 0) expected = 1;
                    if (relation < 0 && oldRelation >= 0) expected = -1;
                }
                oldRelation = relation;
            }
            assertEq(sma.push(prices[i]), expected);
            (uint160 a, uint160 b, uint256 actual50, uint256 actual200, uint16 next, uint16 count) =
                sma.read();
            assertEq(actual50, sum50);
            assertEq(actual200, sum200);
            assertEq(a, sum50 / (i < 50 ? i + 1 : 50));
            assertEq(b, sum200 / (i < 200 ? i + 1 : 200));
            assertEq(next, (i + 1) % 200);
            assertEq(count, i < 200 ? i + 1 : 200);
        }
    }
}
