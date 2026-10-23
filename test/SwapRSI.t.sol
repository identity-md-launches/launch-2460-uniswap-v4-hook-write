// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwapRSI} from "../contracts/libraries/SwapRSI.sol";

contract SwapRSITest is Test {
    using SwapRSI for SwapRSI.History;

    SwapRSI.History private history;
    SwapRSI.History private second;

    function test_emptyAndFourteenPricesAreNotReady() public {
        assertEq(history.value(), 0);
        assertEq(history.direction(), 0);
        for (uint160 i; i < 14; ++i) {
            assertEq(history.push(100 + i), 0);
            assertEq(history.value(), 0);
        }
        assertEq(history.observations, 14);
        assertEq(history.changes, 13);
        // Fourteen *changes* require fifteen observations. The first full RSI can already trade.
        assertEq(history.push(114), -1);
        assertEq(history.changes, 14);
        assertEq(history.observations, 15);
        assertEq(history.value(), 10000);
    }

    function test_flatReadyHistoryIsNeutralFifty() public {
        for (uint256 i; i < 30; ++i) {
            assertEq(history.push(1234), 0);
        }
        assertEq(history.value(), 5000);
        assertEq(history.observations, 30);
        assertEq(history.changes, 14);
    }

    function test_onlyGainsAndOnlyLossesIncludeZeroAndMaximumPrices() public {
        for (uint160 i; i < 30; ++i) {
            history.push(i);
            second.push(type(uint160).max - i);
        }
        assertEq(history.value(), 10000);
        assertEq(history.direction(), -1);
        assertEq(second.value(), 0);
        assertEq(second.direction(), 1);
    }

    function test_exactThirtyAndSeventyAreNeutral() public {
        _seed(history, 7, 3);
        _seed(second, 3, 7);
        assertEq(history.value(), 7000);
        assertEq(second.value(), 3000);
        assertEq(history.direction(), 0);
        assertEq(second.direction(), 0);
    }

    function test_unchangedPricesPreserveNeutralThresholdsDespiteRounding() public {
        _seed(history, 7, 3);
        _seed(second, 3, 7);
        // Both averages decay equally in exact arithmetic, leaving RSI exactly at 70 and 30.
        // Rounding the two sums separately must not turn either equality into a strict signal.
        for (uint256 i; i < 100; ++i) {
            assertEq(history.push(history.previousPrice), 0);
            assertEq(second.push(second.previousPrice), 0);
            assertApproxEqAbs(history.value(), 7000, 1);
            assertApproxEqAbs(second.value(), 3000, 1);
        }
    }

    function test_thresholdsCompareUnroundedRatio() public {
        _seed(history, 700001, 300000);
        _seed(second, 299999, 700000);
        assertEq(history.value(), 7000, "display rounds but strict condition is still met");
        assertEq(history.direction(), -1);
        assertEq(second.value(), 2999);
        assertEq(second.direction(), 1);
    }

    function test_neutralRatioJustInsideBothThresholds() public {
        _seed(history, 699999, 300000);
        _seed(second, 300001, 700000);
        assertEq(history.value(), 6999);
        assertEq(second.value(), 3000);
        assertEq(history.direction(), 0);
        assertEq(second.direction(), 0);
    }

    function test_wilderUpdateUsesAllPriorHistoryAfterSeed() public {
        _seed(history, 10, 4);
        assertEq(history.value(), 7142);
        assertEq(history.direction(), -1);
        // One new loss: Wilder G=(13*10/14), L=(13*4/14 + 1), RSI=66.3265306...
        assertEq(history.push(history.previousPrice - 1), 0);
        assertEq(history.value(), 6632);
        // A simple rolling window would now discard the old +10. Wilder retains its decaying weight.
        history.push(history.previousPrice);
        assertEq(history.value(), 6632);
        assertGt(history.gainX64, 0);
    }

    function test_standardPriceVector() public {
        uint160[21] memory prices = [
            uint160(4434),
            4409,
            4415,
            4361,
            4433,
            4483,
            4510,
            4542,
            4584,
            4608,
            4589,
            4603,
            4561,
            4628,
            4628,
            4600,
            4603,
            4641,
            4622,
            4564,
            4621
        ];
        uint256[7] memory expected = [uint256(7046), 6624, 6648, 6934, 6629, 5791, 6288];
        for (uint256 i; i < prices.length; ++i) {
            history.push(prices[i]);
            if (i >= 14) assertEq(history.value(), expected[i - 14]);
        }
    }

    function test_persistentConditionIsNotACrossingOrPhaseFlip() public {
        _seed(history, 10, 0);
        for (uint256 i; i < 40; ++i) {
            assertEq(history.push(history.previousPrice + 1), -1);
        }
        assertEq(history.value(), 10000);
    }

    function test_smallMovesAtMaximumPriceRetainFractionalAverages() public {
        for (uint160 i; i < 15; ++i) {
            history.push(type(uint160).max - i % 2);
        }
        assertEq(history.value(), 5000);
        uint256 seedGain = history.gainX64;
        history.push(type(uint160).max);
        assertEq(history.value(), 5000);
        assertLt(history.gainX64, seedGain);
        assertGt(history.gainX64 % (1 << 64), 0, "smoothing keeps fractional sample units");
    }

    function testFuzz_fullUint160DomainDoesNotOverflow(uint256 entropy) public {
        for (uint256 i; i < 64; ++i) {
            uint160 price = i < 2
                ? (i == 0 ? 0 : type(uint160).max)
                : uint160(uint256(keccak256(abi.encode(entropy, i))));
            int8 signal = history.push(price);
            assertLe(history.value(), 10000);
            assertTrue(signal >= -1 && signal <= 1);
            assertLe(history.gainX64 + history.lossX64, uint256(type(uint160).max) * 14 << 64);
        }
        assertEq(history.observations, 64);
        assertEq(history.changes, 14);
    }

    function testFuzz_matchesExactRationalWilderReference(uint256 entropy) public {
        // Independent exact rational reference: grow a common denominator instead of rounding
        // or maintaining scaled sums. Thirty-two uint96 prices fit the rational numerators in uint256.
        uint256 gainNumerator;
        uint256 lossNumerator;
        uint256 denominator = 14;
        uint160 previous;
        for (uint256 i; i < 32; ++i) {
            uint160 price = uint96(uint256(keccak256(abi.encode(entropy, i))));
            if (i != 0) {
                uint256 gain = price > previous ? price - previous : 0;
                uint256 loss = price < previous ? previous - price : 0;
                if (i <= 14) {
                    gainNumerator += gain;
                    lossNumerator += loss;
                } else {
                    gainNumerator = 13 * gainNumerator + gain * denominator;
                    lossNumerator = 13 * lossNumerator + loss * denominator;
                    denominator *= 14;
                }
            }
            history.push(price);
            previous = price;
            if (i >= 14) {
                uint256 total = gainNumerator + lossNumerator;
                uint256 expected = total == 0 ? 5000 : 10000 * gainNumerator / total;
                assertApproxEqAbs(history.value(), expected, 1);
                int8 expectedDirection = 3 * gainNumerator > 7 * lossNumerator
                    ? int8(-1)
                    : 7 * gainNumerator < 3 * lossNumerator ? int8(1) : int8(0);
                assertEq(history.direction(), expectedDirection);
            }
        }
    }

    function testFuzz_translationDoesNotChangeRSI(uint128 entropy) public {
        uint160 offset = type(uint160).max - type(uint128).max;
        for (uint256 i; i < 48; ++i) {
            uint160 price = uint128(uint256(keccak256(abi.encode(entropy, i))));
            assertEq(history.push(price), second.push(price + offset));
            assertEq(history.value(), second.value());
        }
    }

    function _seed(SwapRSI.History storage h, uint160 gain, uint160 loss) private {
        uint160 price = 1_000_000;
        h.push(price);
        price += gain;
        h.push(price);
        price -= loss;
        h.push(price);
        for (uint256 i; i < 12; ++i) {
            h.push(price);
        }
        assertEq(h.changes, 14);
        assertEq(h.observations, 15);
    }
}
