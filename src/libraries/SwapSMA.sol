// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Constant-cost arithmetic means of the most recent 50 and 200 sqrtPriceX96 samples.
library SwapSMA {
    struct History {
        uint160[200] prices;
        uint256 sum50;
        uint256 sum200;
        uint64 observations;
        uint16 next;
        uint16 count;
        int8 relation;
    }

    /// @return cross +1 for a golden cross, -1 for a death cross, zero otherwise.
    function push(History storage self, uint160 price) internal returns (int8 cross) {
        uint256 next = self.next;
        uint256 count = self.count;
        if (count >= 50) self.sum50 -= self.prices[(next + 150) % 200];
        if (count == 200) self.sum200 -= self.prices[next];
        self.sum50 += price;
        self.sum200 += price;
        self.prices[next] = price;
        self.next = uint16((next + 1) % 200);
        self.observations++;
        if (count < 200) self.count = uint16(count + 1);

        if (self.count == 200) {
            // Compare rational averages without division/rounding. At most 168 bits are needed.
            uint256 shortScaled = self.sum50 * 4;
            int8 relation =
                shortScaled > self.sum200 ? int8(1) : shortScaled < self.sum200 ? int8(-1) : int8(0);
            // The 200th observation establishes the baseline; only subsequent observations can cross.
            if (count == 200) {
                if (relation > 0 && self.relation <= 0) cross = 1;
                else if (relation < 0 && self.relation >= 0) cross = -1;
            }
            self.relation = relation;
        }
    }

    function averages(History storage self) internal view returns (uint160 sma50, uint160 sma200) {
        uint256 count = self.count;
        if (count == 0) return (0, 0);
        sma50 = uint160(self.sum50 / (count < 50 ? count : 50));
        sma200 = uint160(self.sum200 / count);
    }
}
