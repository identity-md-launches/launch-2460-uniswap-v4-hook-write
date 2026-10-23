// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SwapBollinger} from "../contracts/libraries/SwapBollinger.sol";

contract BollingerHarness {
    using SwapBollinger for SwapBollinger.History;
    SwapBollinger.History private h;

    function push(uint160 price) external returns (int8) {
        return h.push(price);
    }

    function read() external view returns (SwapBollinger.Bands memory, uint8, uint8, uint64, int8) {
        return (h.bands(), h.next, h.count, h.observations, h.relation);
    }
}

contract SwapBollingerTest is Test {
    BollingerHarness internal history;

    function setUp() public {
        history = new BollingerHarness();
    }

    function test_emptyAndConstantPricesHaveZeroDeviation() public {
        (SwapBollinger.Bands memory b,, uint8 count,,) = history.read();
        assertEq(count, 0);
        assertEq(b.sma, 0);
        assertEq(b.upper, 0);
        for (uint256 i; i < 45; ++i) {
            assertEq(history.push(100), 0);
        }
        (b,, count,,) = history.read();
        assertEq(count, 20);
        assertEq(b.sma, 100);
        assertEq(b.standardDeviation, 0);
        assertEq(b.lower, 100);
        assertEq(b.upper, 100);
    }

    function test_populationDeviationAndBothBandsMatchHandCalculatedVector() public {
        // Ten 90s and ten 110s: mean 100, population variance 100, sigma 10.
        for (uint256 i; i < 20; ++i) {
            history.push(i < 10 ? 90 : 110);
        }
        (SwapBollinger.Bands memory b,,,,) = history.read();
        assertEq(b.sma, 100);
        assertEq(b.standardDeviation, 10);
        assertEq(b.lower, 80);
        assertEq(b.upper, 120);
    }

    function test_warmupBaselineDoesNotInventCross() public {
        for (uint256 i; i < 19; ++i) {
            assertEq(history.push(100), 0);
        }
        assertEq(history.push(200), 0, "sample 20 is only a baseline");
        assertEq(history.push(200), 0, "remaining above is not a new crossing");
        assertEq(history.push(100), 0, "returning inside is not a crossing");
        assertEq(history.push(10), 1, "a lower crossing sells token1");
    }

    function test_strictCrossesEqualityAndReturningInside() public {
        for (uint256 i; i < 20; ++i) {
            history.push(100);
        }
        assertEq(history.push(100), 0);
        assertEq(history.push(120), -1);
        assertEq(history.push(120), 0);
        assertEq(history.push(100), 0);
        assertEq(history.push(120), -1, "new crossing after reentering band");
        assertEq(history.push(60), 1);
        assertEq(history.push(60), 0);
    }

    function test_exactlyOnUpperOrLowerBandDoesNotCross() public {
        // Sixteen 100s and four 150s: mean 110, sigma 20, upper exactly 150.
        for (uint256 i; i < 16; ++i) {
            history.push(100);
        }
        for (uint256 i; i < 4; ++i) {
            history.push(150);
        }
        (SwapBollinger.Bands memory b,,,, int8 relation) = history.read();
        assertEq(b.upper, 150);
        assertEq(relation, 0);
        // Replace the first 100 with 100: still in-band. Replace another with 150:
        // the widened band contains 150, and no new strict crossing is emitted.
        assertEq(history.push(100), 0);
        assertEq(history.push(150), 0);
        BollingerHarness lower = new BollingerHarness();
        for (uint256 i; i < 16; ++i) {
            lower.push(100);
        }
        for (uint256 i; i < 4; ++i) {
            lower.push(50);
        }
        (b,,,, relation) = lower.read();
        assertEq(b.lower, 50);
        assertEq(relation, 0);
    }

    function test_extremePricesCannotOverflowAndNegativeLowerBandClampsToZero() public {
        for (uint256 i; i < 20; ++i) {
            history.push(i < 10 ? 0 : type(uint160).max);
        }
        (SwapBollinger.Bands memory b,,,,) = history.read();
        uint256 exactSigma = uint256(type(uint160).max) / 2;
        assertEq(b.sma, exactSigma);
        assertApproxEqAbs(b.standardDeviation, exactSigma, 1 << 38);
        assertEq(b.lower, 0);
        assertGt(b.upper, type(uint160).max, "upper bound must not truncate to uint160");
        for (uint256 i; i < 20; ++i) {
            history.push(type(uint160).max);
        }
        (b,,,,) = history.read();
        assertEq(b.sma, type(uint160).max);
        assertEq(b.standardDeviation, 0);
        assertEq(b.upper, type(uint160).max);
    }

    function test_extremeConstantOffsetRetainsSmallVolatility() public {
        for (uint256 i; i < 20; ++i) {
            history.push(type(uint160).max - (i < 10 ? 20 : 0));
        }
        (SwapBollinger.Bands memory b,,,,) = history.read();
        assertEq(b.sma, type(uint160).max - 10);
        assertEq(b.standardDeviation, 10);
        assertEq(b.lower, uint256(type(uint160).max) - 30);
        assertEq(b.upper, uint256(type(uint160).max) + 10);
    }

    function testFuzz_ringAndCrossesMatchNaivePopulationReference(bytes32 seed, uint8 extra) public {
        uint256 length = 20 + bound(extra, 0, 60);
        uint160[] memory prices = new uint160[](length);
        int8 previous;
        for (uint256 i; i < length; ++i) {
            // 120 bits lets the independent uncentered reference square its sum without overflow.
            prices[i] = uint120(uint256(keccak256(abi.encode(seed, i))));
            SwapBollinger.Bands memory referenceBands = _reference(prices, i);
            int8 relation = prices[i] > referenceBands.upper
                ? int8(1)
                : prices[i] < referenceBands.lower ? int8(-1) : int8(0);
            int8 expected;
            if (i >= 20) {
                if (relation > 0 && previous <= 0) expected = -1;
                if (relation < 0 && previous >= 0) expected = 1;
            }
            assertEq(history.push(prices[i]), expected);
            _assertRead(referenceBands, i, relation);
            previous = relation;
        }
    }

    function _reference(uint160[] memory prices, uint256 end)
        private
        pure
        returns (SwapBollinger.Bands memory b)
    {
        uint256 start = end < 20 ? 0 : end - 19;
        uint256 count = end - start + 1;
        uint256 sum;
        uint256 squares;
        for (uint256 j = start; j <= end; ++j) {
            sum += prices[j];
            squares += uint256(prices[j]) * prices[j];
        }
        b.sma = uint160(sum / count);
        b.standardDeviation = uint160(Math.sqrt((count * squares - sum * sum) / (count * count)));
        b.upper = uint256(b.sma) + 2 * uint256(b.standardDeviation);
        b.lower = b.sma > 2 * uint256(b.standardDeviation) ? b.sma - 2 * uint256(b.standardDeviation) : 0;
    }

    function _assertRead(SwapBollinger.Bands memory referenceBands, uint256 i, int8 relation) private view {
        (SwapBollinger.Bands memory b, uint8 next, uint8 count, uint64 observations, int8 actual) =
            history.read();
        assertEq(abi.encode(b), abi.encode(referenceBands));
        assertEq(next, (i + 1) % 20);
        assertEq(count, i < 20 ? i + 1 : 20);
        assertEq(observations, i + 1);
        assertEq(actual, i < 19 ? int8(0) : relation);
    }

    function testFuzz_fullRangeTwoPointDistribution(uint160 a, uint160 b) public {
        for (uint256 i; i < 20; ++i) {
            history.push(i < 10 ? a : b);
        }
        (SwapBollinger.Bands memory bands,,,,) = history.read();
        uint256 distance = a > b ? uint256(a) - b : uint256(b) - a;
        uint256 shift = Math.log2(distance) > 122 ? Math.log2(distance) - 122 : 0;
        assertEq(bands.sma, (uint256(a) + b) / 2);
        // Exactly sigma=|a-b|/2 before integer rounding; at most two normalization units error.
        assertApproxEqAbs(bands.standardDeviation, distance / 2, 2 << shift);
    }
}
