// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Standard 20-swap Bollinger bands of sqrtPriceX96, using population standard deviation.
library SwapBollinger {
    uint256 internal constant PERIOD = 20;
    uint256 internal constant DEVIATIONS = 2;

    struct History {
        uint160[20] prices;
        uint64 observations;
        uint8 next;
        uint8 count;
        int8 relation;
    }

    struct Bands {
        uint160 sma;
        uint160 standardDeviation;
        uint256 lower;
        uint256 upper;
    }

    /// @return direction -1 when crossing above the upper band (sell token0, move lower),
    /// +1 when crossing below the lower band (sell token1, move upper), otherwise zero.
    function push(History storage self, uint160 price) internal returns (int8 direction) {
        bool warmedUp = self.count == PERIOD;
        self.prices[self.next] = price;
        self.next = uint8((uint256(self.next) + 1) % PERIOD);
        self.observations++;
        if (!warmedUp) self.count++;

        if (self.count == PERIOD) {
            Bands memory b = bands(self);
            int8 relation = price > b.upper ? int8(1) : price < b.lower ? int8(-1) : int8(0);
            // The 20th observation establishes a baseline; only later observations can cross.
            if (warmedUp) {
                if (relation > 0 && self.relation <= 0) direction = -1;
                else if (relation < 0 && self.relation >= 0) direction = 1;
            }
            self.relation = relation;
        }
    }

    /// @dev Includes the newest sample. Divides variance by N (population), never N-1.
    /// Subtract a common origin before squaring to avoid cancellation. For spans wider than
    /// 123 bits, discard at most 37 low bits before squaring, then restore X96 units. This
    /// bounds N*sum(x*x) and sum(x)^2 below 2^256 even at uint160 price extremes. No scaling
    /// is needed for ordinary or tightly clustered prices, including clusters near uint160.max.
    function bands(History storage self) internal view returns (Bands memory b) {
        uint256 count = self.count;
        if (count == 0) return b;
        uint256 minimum = self.prices[0];
        uint256 maximum = minimum;
        uint256 sum;
        for (uint256 i; i < count; ++i) {
            uint256 price = self.prices[i];
            minimum = Math.min(minimum, price);
            maximum = Math.max(maximum, price);
            sum += price;
        }
        // The SMA is exact (rounded down) even when the variance needs scaling.
        b.sma = uint160(sum / count);
        uint256 spanBits = Math.log2(maximum - minimum);
        uint256 shift = spanBits > 122 ? spanBits - 122 : 0;
        uint256 sumOffsets;
        uint256 sumSquares;
        for (uint256 i; i < count; ++i) {
            uint256 offset = (uint256(self.prices[i]) - minimum) >> shift;
            sumOffsets += offset;
            sumSquares += offset * offset;
        }
        // Var(X) = E[X^2] - E[X]^2; round only after forming the exact numerator.
        uint256 variance = (count * sumSquares - sumOffsets * sumOffsets) / (count * count);
        b.standardDeviation = uint160(Math.sqrt(variance) << shift);
        uint256 width = DEVIATIONS * uint256(b.standardDeviation);
        b.upper = uint256(b.sma) + width;
        // A negative lower band cannot be crossed by a nonnegative pool price.
        b.lower = b.sma > width ? b.sma - width : 0;
    }
}
