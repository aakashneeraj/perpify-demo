// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/**
 * @title PerpifyReopenPyth
 * @notice Sequenced-clearing reopen demo anchored to real Pyth-signed SPY/USD prices.
 *
 * The story this contract proves on-chain:
 *   - The Friday close and Monday open are NOT inputs the operator chooses.
 *   - They are pulled from Pyth's Benchmarks API, signed by Pythnet, and
 *     verified inside this contract via parsePriceFeedUpdates().
 *   - If anything in the price blob is tampered with, the transaction reverts.
 *   - The gap is computed from those two verified prices.
 *   - Three positions are then cleared in tier order (HIGH → MED → LOW), with
 *     gap-aware margin already baked in for HIGH and MED before the close.
 *
 * Net effect: an investor watching the Basescan transaction can confirm that
 * (a) the Friday and Monday prices came from Pyth, (b) the gap is real, and
 * (c) Perpify's loss buffer absorbed it without breach.
 *
 * Out of scope (intentionally):
 *   - This is a demo contract for the reopen mechanism only. It is not a
 *     production matching engine, does not custody real user funds beyond the
 *     small ETH margin paid in, and does not implement a full perp exchange.
 *   - Margin model and tier logic are intentionally simplified versions of the
 *     production design described in the diligence pack. The point is to make
 *     the reopen behaviour auditable, not to ship the full venue.
 */
contract PerpifyReopenPyth {
    // ---------------------------------------------------------------------
    // Configuration
    // ---------------------------------------------------------------------

    /// Pyth core contract on Base mainnet.
    /// 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a
    IPyth public immutable pyth;

    /// SPY/USD price feed ID (Equity.US.SPY/USD).
    /// 0x19e09bb805456ada3979a7d1cbb4b6d63babc3a0f8e8a9509f68afa5c4c11cd5
    bytes32 public immutable spyFeedId;

    /// Operator (deployer) — can register replay events and reset state.
    /// Not a custodian: cannot move user margin.
    address public immutable operator;

    /// Maximum allowed staleness of either price update relative to its
    /// declared publish time, in seconds. Pyth gives us a window; we narrow it.
    uint256 public constant PUBLISH_WINDOW = 60;

    /// Loss buffer (insurance shield) that absorbs uncovered loss before the
    /// venue is considered insolvent. Set in constructor in wei.
    uint256 public lossBuffer;

    // ---------------------------------------------------------------------
    // Position model
    // ---------------------------------------------------------------------

    enum Tier { LOW, MED, HIGH }

    struct Position {
        address owner;
        uint256 sizeUsd;       // notional, 6 decimals (USDC convention)
        uint256 leverage;      // 2x, 3x, 4x, 6x ...
        bool isLong;
        Tier tier;
        uint256 ethMargin;     // wei deposited
        bool open;
    }

    Position[3] public positions;

    enum MarketState { OPEN, CLOSED, REOPENED }
    MarketState public marketState;

    // ---------------------------------------------------------------------
    // Reopen accounting
    // ---------------------------------------------------------------------

    struct ReopenResult {
        uint64 fridayPublishTime;
        uint64 mondayPublishTime;
        int64  fridayPriceRaw;     // Pyth fixed-point (expo applied off-chain)
        int64  mondayPriceRaw;
        int32  expo;
        int256 gapBps;             // signed basis points, e.g. -320 = -3.20%
        uint256 totalLossUsd;
        uint256 lossCoveredByEquity;
        uint256 lossUncovered;
        uint256 bufferUsedBps;     // out of 10000
        bool venueSurvives;
    }

    ReopenResult public lastResult;

    // ---------------------------------------------------------------------
    // Events — these are the on-chain audit trail an investor reads.
    // ---------------------------------------------------------------------

    event PositionOpened(uint8 indexed slot, address indexed owner, uint256 sizeUsd, uint256 leverage, bool isLong, Tier tier);
    event MarketClosed(uint64 fridayPublishTime, int64 fridayPriceRaw, int32 expo);
    event ReopenFired(
        uint64 fridayPublishTime,
        uint64 mondayPublishTime,
        int64 fridayPriceRaw,
        int64 mondayPriceRaw,
        int32 expo,
        int256 gapBps
    );
    event PositionCleared(uint8 indexed slot, Tier indexed tier, uint256 lossUsd, uint256 lossCoveredByEquity, uint256 lossUncovered);
    event BufferUsed(uint256 lossUncovered, uint256 bufferUsedBps, bool venueSurvives);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotOperator();
    error WrongState();
    error InvalidTimestampOrder();
    error PriceFeedMismatch();
    error InsufficientFee();
    error PositionAlreadyOpen();
    error InvalidLeverage();

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(address _pyth, bytes32 _spyFeedId, uint256 _lossBuffer) payable {
        pyth = IPyth(_pyth);
        spyFeedId = _spyFeedId;
        operator = msg.sender;
        lossBuffer = _lossBuffer;
        marketState = MarketState.OPEN;
    }

    // ---------------------------------------------------------------------
    // Step 1: open three positions (anyone can call; demo only)
    // ---------------------------------------------------------------------

    function openPosition(
        uint8 slot,
        uint256 sizeUsd,
        uint256 leverage,
        bool isLong,
        Tier tier
    ) external payable {
        if (marketState != MarketState.OPEN) revert WrongState();
        if (slot > 2) revert WrongState();
        if (positions[slot].open) revert PositionAlreadyOpen();
        if (leverage < 2 || leverage > 6) revert InvalidLeverage();

        // Required ETH margin scales with size, leverage, and tier.
        // HIGH and MED tiers face the gap-aware uplift baked into margin.
        uint256 baseRequirement = (sizeUsd * 1e12) / leverage / 1000; // notional-fraction in wei terms
        uint256 tierMultiplier = tier == Tier.HIGH ? 150 : tier == Tier.MED ? 120 : 100;
        uint256 required = (baseRequirement * tierMultiplier) / 100;
        if (msg.value < required) revert InsufficientFee();

        positions[slot] = Position({
            owner: msg.sender,
            sizeUsd: sizeUsd,
            leverage: leverage,
            isLong: isLong,
            tier: tier,
            ethMargin: msg.value,
            open: true
        });

        emit PositionOpened(slot, msg.sender, sizeUsd, leverage, isLong, tier);
    }

    // ---------------------------------------------------------------------
    // Step 2: close the market with a Pyth-signed Friday close print.
    //
    // priceUpdate is fetched off-chain from:
    //   GET https://hermes.pyth.network/v2/updates/price/{fridayCloseUnix}
    //       ?ids[]=<SPY feed id>&encoding=hex
    //
    // Pyth's parsePriceFeedUpdates verifies the Wormhole signature and
    // confirms the price is for the right feed and within the publish window.
    // ---------------------------------------------------------------------

    function closeMarket(
        bytes[] calldata priceUpdate,
        uint64 fridayCloseUnix
    ) external payable onlyOperator {
        if (marketState != MarketState.OPEN) revert WrongState();

        uint256 fee = pyth.getUpdateFee(priceUpdate);
        if (msg.value < fee) revert InsufficientFee();

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = spyFeedId;

        PythStructs.PriceFeed[] memory feeds = pyth.parsePriceFeedUpdates{value: fee}(
            priceUpdate,
            ids,
            uint64(fridayCloseUnix - PUBLISH_WINDOW),
            uint64(fridayCloseUnix + PUBLISH_WINDOW)
        );

        if (feeds[0].id != spyFeedId) revert PriceFeedMismatch();

        lastResult.fridayPublishTime = uint64(feeds[0].price.publishTime);
        lastResult.fridayPriceRaw = feeds[0].price.price;
        lastResult.expo = feeds[0].price.expo;

        marketState = MarketState.CLOSED;

        emit MarketClosed(lastResult.fridayPublishTime, lastResult.fridayPriceRaw, lastResult.expo);
    }

    // ---------------------------------------------------------------------
    // Step 3: fire the reopen with a Pyth-signed Monday open print.
    //
    // Sequenced clearing: HIGH risk first, then MED, then LOW.
    // Each tier's loss is computed from the verified gap, and any loss in
    // excess of the position's equity is taken from the loss buffer.
    // ---------------------------------------------------------------------

    function fireReopen(
        bytes[] calldata priceUpdate,
        uint64 mondayOpenUnix
    ) external payable onlyOperator {
        if (marketState != MarketState.CLOSED) revert WrongState();

        // Sanity: Monday must come after Friday.
        if (mondayOpenUnix <= lastResult.fridayPublishTime) revert InvalidTimestampOrder();

        uint256 fee = pyth.getUpdateFee(priceUpdate);
        if (msg.value < fee) revert InsufficientFee();

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = spyFeedId;

        PythStructs.PriceFeed[] memory feeds = pyth.parsePriceFeedUpdates{value: fee}(
            priceUpdate,
            ids,
            uint64(mondayOpenUnix - PUBLISH_WINDOW),
            uint64(mondayOpenUnix + PUBLISH_WINDOW)
        );

        if (feeds[0].id != spyFeedId) revert PriceFeedMismatch();
        if (feeds[0].price.expo != lastResult.expo) revert PriceFeedMismatch();

        lastResult.mondayPublishTime = uint64(feeds[0].price.publishTime);
        lastResult.mondayPriceRaw = feeds[0].price.price;

        // Compute gap in basis points using integer arithmetic.
        // gap_bps = ((monday - friday) / friday) * 10000
        int256 friday = int256(lastResult.fridayPriceRaw);
        int256 monday = int256(lastResult.mondayPriceRaw);
        int256 gapBps = ((monday - friday) * 10000) / friday;
        lastResult.gapBps = gapBps;

        emit ReopenFired(
            lastResult.fridayPublishTime,
            lastResult.mondayPublishTime,
            lastResult.fridayPriceRaw,
            lastResult.mondayPriceRaw,
            lastResult.expo,
            gapBps
        );

        // Sequenced clearing: HIGH → MED → LOW.
        _clearTier(Tier.HIGH, gapBps);
        _clearTier(Tier.MED, gapBps);
        _clearTier(Tier.LOW, gapBps);

        // Final accounting.
        uint256 bufferUsedBps = lossBuffer == 0
            ? 0
            : (lastResult.lossUncovered * 10000) / lossBuffer;
        lastResult.bufferUsedBps = bufferUsedBps;
        lastResult.venueSurvives = lastResult.lossUncovered <= lossBuffer;

        emit BufferUsed(lastResult.lossUncovered, bufferUsedBps, lastResult.venueSurvives);

        marketState = MarketState.REOPENED;
    }

    function _clearTier(Tier tier, int256 gapBps) internal {
        for (uint8 i = 0; i < 3; i++) {
            Position storage p = positions[i];
            if (!p.open || p.tier != tier) continue;

            // Adverse move in bps from the position's perspective.
            int256 adverseBps = p.isLong ? -gapBps : gapBps;
            uint256 lossUsd = 0;
            uint256 covered = 0;
            uint256 uncovered = 0;

            if (adverseBps > 0) {
                // loss = size * adverse / 10000
                lossUsd = (p.sizeUsd * uint256(adverseBps)) / 10000;
                // equity at risk = size / leverage
                uint256 equity = p.sizeUsd / p.leverage;
                if (lossUsd <= equity) {
                    covered = lossUsd;
                    uncovered = 0;
                } else {
                    covered = equity;
                    uncovered = lossUsd - equity;
                    lastResult.lossUncovered += uncovered;
                }
                lastResult.totalLossUsd += lossUsd;
                lastResult.lossCoveredByEquity += covered;
            }

            p.open = false;
            emit PositionCleared(i, tier, lossUsd, covered, uncovered);
        }
    }

    // ---------------------------------------------------------------------
    // Reset (operator only) — lets the same contract demo many reopens.
    // Refunds any held margin to position owners.
    // ---------------------------------------------------------------------

    function reset() external onlyOperator {
        for (uint8 i = 0; i < 3; i++) {
            Position storage p = positions[i];
            if (p.ethMargin > 0 && p.owner != address(0)) {
                uint256 amt = p.ethMargin;
                p.ethMargin = 0;
                (bool ok, ) = payable(p.owner).call{value: amt}("");
                require(ok, "refund failed");
            }
            delete positions[i];
        }
        delete lastResult;
        marketState = MarketState.OPEN;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getPosition(uint8 slot) external view returns (Position memory) {
        return positions[slot];
    }

    function getLastResult() external view returns (ReopenResult memory) {
        return lastResult;
    }
}
