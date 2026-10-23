// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Standard 14-period Wilder RSI of consecutive swap price observations.
/// @dev The hook supplies sqrtPriceX96, matching this project's other swap-count indicators.
/// All functions are internal, so no separately deployed or linked library is required.
library SwapRSI {
    uint256 internal constant PERIOD = 14;
    uint256 internal constant RSI_SCALE = 10_000;
    uint256 internal constant FRACTION_BITS = 64;

    struct History {
        // Seed: sums of the first 14 gains/losses. Thereafter: 14 times the Wilder averages.
        // Both have 64 fractional bits to retain sub-unit changes during smoothing.
        uint256 gainX64;
        uint256 lossX64;
        uint160 previousPrice;
        uint64 observations;
        uint8 changes;
    }

    /// @return signal -1 for RSI > 70 (sell token0, toward lower), +1 for RSI < 30
    /// (sell token1, toward upper), zero for warmup or the inclusive neutral interval.
    /// A signal is a level condition on every observation, not a crossover or phase flip.
    function push(History storage self, uint160 price) internal returns (int8 signal) {
        if (self.observations == 0) {
            self.previousPrice = price;
            self.observations = 1;
            return 0;
        }

        uint256 previous = self.previousPrice;
        uint256 gain = price > previous ? (uint256(price) - previous) << FRACTION_BITS : 0;
        uint256 loss = price < previous ? (previous - uint256(price)) << FRACTION_BITS : 0;
        if (self.changes < PERIOD) {
            self.gainX64 += gain;
            self.lossX64 += loss;
            self.changes++;
        } else {
            // A_new = (13 * A_old + change) / 14. Keeping S = 14 * A gives
            // S_new = 13 * S_old / 14 + change, the same Wilder recurrence.
            self.gainX64 = self.gainX64 * (PERIOD - 1) / PERIOD + gain;
            self.lossX64 = self.lossX64 * (PERIOD - 1) / PERIOD + loss;
        }
        self.previousPrice = price;
        self.observations++;
        return direction(self);
    }

    /// @notice RSI in hundredths of a point (0..10000), rounded down; zero while warming up.
    /// @dev Read changes as well: only changes == 14 is ready. A flat ready history is neutral 50.
    /// RSI = 100 - 100/(1 + averageGain/averageLoss) = 100*gain/(gain+loss).
    /// uint160 samples, 14 terms and 64 fractional bits bound sums below 2^228;
    /// smoothing and the 10000 multiplier also fit comfortably in uint256.
    function value(History storage self) internal view returns (uint256 rsiBps) {
        if (self.changes < PERIOD) return 0;
        uint256 total = self.gainX64 + self.lossX64;
        if (total == 0) return RSI_SCALE / 2;
        return self.gainX64 * RSI_SCALE / total;
    }

    /// @dev Compare the unrounded RSI ratio, allowing for the arithmetic's rounding error.
    /// Each smoothed sum underestimates its exact value by less than 14 Q64 units:
    /// error_next < 13/14 * error_previous + 1. Seeding is exact. Use the conservative
    /// endpoint for each strict comparison so exact 30/70 cannot spuriously trade after
    /// smoothing. The resulting uncertainty is less than one raw sample unit / 2^64 in
    /// each average. The displayed RSI can round to 7000 while its direction is still -1.
    function direction(History storage self) internal view returns (int8) {
        if (self.changes < PERIOD) return 0;
        uint256 rounding = self.observations > PERIOD + 1 ? PERIOD : 0;
        if (3 * self.gainX64 > 7 * (self.lossX64 + rounding)) return -1;
        if (7 * (self.gainX64 + rounding) < 3 * self.lossX64) return 1;
        return 0;
    }
}
