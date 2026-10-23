// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BitMath} from "v4-core/src/libraries/BitMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Independent arithmetic checks for the protected dependencies flagged by Slither.
contract DependencyMathTest is Test {
    function test_bitLookupAtEveryPowerOfTwo() public pure {
        for (uint256 i; i < 256; ++i) {
            uint256 x = uint256(1) << i;
            assertEq(BitMath.mostSignificantBit(x), i);
            assertEq(BitMath.leastSignificantBit(x), i);
        }
    }

    function testFuzz_bitLookupMatchesSimpleLoops(uint256 x) public pure {
        if (x == 0) x = 1;
        uint256 highest;
        uint256 remaining = x;
        while (remaining > 1) {
            remaining >>= 1;
            highest++;
        }
        uint256 lowest;
        while (((x >> lowest) & 1) == 0) lowest++;
        assertEq(BitMath.mostSignificantBit(x), highest);
        assertEq(BitMath.leastSignificantBit(x), lowest);
    }

    function testFuzz_modularInverseMulDivPreservesExactQuotient(uint256 a, uint256 b) public pure {
        // Odd divisors exercise the modular inverse, including products wider than 256 bits.
        b |= 1;
        assertEq(FullMath.mulDiv(a, b, b), a);
        assertEq(Math.mulDiv(a, b, b), a);
    }
}
