// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// A Uniswap-V3-shaped observation ring, for a V4 pool that has none.
///
/// V4 core stores no observations -- the oracle moved into hooks -- so a V4 pool can only be TWAP-priced by
/// something that samples it. The sampler must not choose the sample times: a sample's weight is the time until
/// the NEXT sample, so an external `poke()` would let an attacker do swap -> poke -> swap back inside one block,
/// with no arbitrage exposure, and have the poisoned sample carry the whole interval.
///
/// Writing from a hook's `afterSwap` does not have that weakness: every swap writes, whoever made it. That gives
/// the V3 property: to move the mean you must HOLD the price across real time, exposed to arbitrage the whole way.
///
/// The V3 rules this copies:
///   - at most one observation per second, so a griefer cannot spend the ring in a single block;
///   - the stored tick is the one in force GOING FORWARD from that timestamp, and the cumulative is advanced by
///     the PREVIOUS tick over the elapsed time -- get this backwards and the mean lags by one swap;
///   - a window the ring cannot serve answers `false` rather than a shorter mean, so "not enough history" is never
///     mistaken for a price.
library TwapRing {
    /// one storage word: 32 + 24 + 56 bits
    struct Obs { uint32 ts; int24 tick; int56 cum; }

    uint16 internal constant SLOTS = 1024;

    struct Ring {
        Obs[1024] obs;
        uint16 index;       // where the newest observation lives
        uint16 filled;      // how many slots have ever been written, capped at SLOTS
    }

    /// @notice first observation, at the pool's opening tick
    function initialize(Ring storage r, int24 tick) internal {
        if (r.filled != 0) return;
        r.obs[0] = Obs(uint32(block.timestamp), tick, 0);
        r.index = 0;
        r.filled = 1;
    }

    /// @notice record `tick` as the tick in force from now on. At most one write per second, like V3.
    function write(Ring storage r, int24 tick) internal {
        if (r.filled == 0) { initialize(r, tick); return; }
        Obs memory last = r.obs[r.index];
        uint32 nowTs = uint32(block.timestamp);
        // same second: the interval has no width, but the tick that closes it must still be the LAST one. Dropping
        // the write would keep the first swap's tick as "the price since", so a shove and its unwind inside one
        // second would leave the shove in force until somebody else traded: weight (seconds until the next
        // swap)/window for a price held for zero seconds.
        if (nowTs == last.ts) { r.obs[r.index].tick = tick; return; }
        int56 cum = last.cum + int56(last.tick) * int56(uint56(nowTs - last.ts));
        uint16 next = (r.index + 1) % SLOTS;
        r.obs[next] = Obs(nowTs, tick, cum);
        r.index = next;
        if (r.filled < SLOTS) r.filled += 1;
    }

    /// @notice the mean tick over the last `window` seconds
    /// @return ok false when the ring cannot serve the window -- no history that old, or a griefer flipping the
    ///         tick every second has pushed it out of the ring. Callers must refuse, never treat it as a price.
    function meanTick(Ring storage r, uint32 window, int24 currentTick) internal view returns (bool ok, int24 mean) {
        if (window == 0 || r.filled == 0) return (false, 0);
        uint32 nowTs = uint32(block.timestamp);
        Obs memory last = r.obs[r.index];
        if (nowTs < last.ts) return (false, 0);
        int56 cumNow = last.cum + int56(last.tick) * int56(uint56(nowTs - last.ts));

        if (nowTs < window) return (false, 0);
        uint32 target = nowTs - window;

        Obs memory oldest = r.obs[r.filled == SLOTS ? (r.index + 1) % SLOTS : 0];
        if (oldest.ts > target) return (false, 0);                      // the window reaches past what we hold

        (bool found, Obs memory at) = _atOrBefore(r, target);
        if (!found) return (false, 0);
        int56 cumThen = at.cum + int56(at.tick) * int56(uint56(target - at.ts));

        int56 delta = cumNow - cumThen;
        int56 w = int56(uint56(window));
        int56 m = delta / w;
        // Solidity truncates toward zero, so a negative delta rounds the mean UP by up to a tick -- a free basis
        // point wherever the mean is used as a bound. Uniswap's own OracleLibrary makes the same correction.
        if (delta < 0 && delta % w != 0) m -= 1;
        currentTick;                                                     // (kept for interface symmetry with V3)
        return (true, int24(m));
    }

    /// @dev binary search for the newest observation at or before `target`. 10 loads at SLOTS = 1024.
    function _atOrBefore(Ring storage r, uint32 target) private view returns (bool, Obs memory) {
        uint16 n = r.filled;
        uint16 start = n == SLOTS ? (r.index + 1) % SLOTS : 0;           // oldest
        uint16 lo = 0;
        uint16 hi = n - 1;                                               // logical positions, 0 = oldest
        Obs memory best;
        bool found;
        while (lo <= hi) {
            uint16 mid = lo + (hi - lo) / 2;
            Obs memory o = r.obs[(start + mid) % SLOTS];
            if (o.ts <= target) { best = o; found = true; lo = mid + 1; }
            else { if (mid == 0) break; hi = mid - 1; }
        }
        return (found, best);
    }
}
