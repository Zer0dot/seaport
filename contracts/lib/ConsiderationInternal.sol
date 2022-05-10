// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import { Side, ItemType } from "./ConsiderationEnums.sol";

// prettier-ignore
import {
    AdditionalRecipient,
    OfferItem,
    ConsiderationItem,
    SpentItem,
    ReceivedItem,
    OrderParameters,
    Fulfillment,
    FulfillmentComponent,
    Execution,
    Order,
    AdvancedOrder,
    CriteriaResolver,
    BatchExecution
} from "./ConsiderationStructs.sol";

import { BasicOrderFulfiller } from "./BasicOrderFulfiller.sol";

import { CriteriaResolution } from "./CriteriaResolution.sol";

import { AmountDeriver } from "./AmountDeriver.sol";

import { FulfillmentApplier } from "./FulfillmentApplier.sol";

import { ExecutionCompression } from "./ExecutionCompression.sol";

import { GenericHelpers } from "./GenericHelpers.sol";

import "./ConsiderationConstants.sol";

/**
 * @title ConsiderationInternal
 * @author 0age
 * @notice ConsiderationInternal contains all internal functions.
 */
contract ConsiderationInternal is
    BasicOrderFulfiller,
    CriteriaResolution,
    AmountDeriver,
    FulfillmentApplier,
    ExecutionCompression,
    GenericHelpers
{
    /**
     * @dev Derive and set hashes, reference chainId, and associated domain
     *      separator during deployment.
     *
     * @param conduitController A contract that deploys conduits, or proxies
     *                          that may optionally be used to transfer approved
     *                          ERC20/721/1155 tokens.
     */
    constructor(address conduitController)
        BasicOrderFulfiller(conduitController)
    {}

    /**
     * @dev Internal function to validate an order and update its status, adjust
     *      prices based on current time, apply criteria resolvers, determine
     *      what portion to fill, and transfer relevant tokens.
     *
     * @param advancedOrder       The order to fulfill as well as the fraction
     *                            to fill. Note that all offer and consideration
     *                            components must divide with no remainder for
     *                            the partial fill to be valid.
     * @param criteriaResolvers   An array where each element contains a
     *                            reference to a specific offer or
     *                            consideration, a token identifier, and a proof
     *                            that the supplied token identifier is
     *                            contained in the order's merkle root. Note
     *                            that a criteria of zero indicates that any
     *                            (transferrable) token identifier is valid and
     *                            that no proof needs to be supplied.
     * @param fulfillerConduitKey A bytes32 value indicating what conduit, if
     *                            any, to source the fulfiller's token approvals
     *                            from. The zero hash signifies that no conduit
     *                            should be used, with direct approvals set on
     *                            Consideration.
     *
     * @return A boolean indicating whether the order has been fulfilled.
     */
    function _validateAndFulfillAdvancedOrder(
        AdvancedOrder memory advancedOrder,
        CriteriaResolver[] memory criteriaResolvers,
        bytes32 fulfillerConduitKey
    ) internal returns (bool) {
        // Ensure this function cannot be triggered during a reentrant call.
        _setReentrancyGuard();

        // Declare empty bytes32 array (unused, will remain empty).
        bytes32[] memory priorOrderHashes;

        // Validate order, update status, and determine fraction to fill.
        (
            bytes32 orderHash,
            uint256 fillNumerator,
            uint256 fillDenominator
        ) = _validateOrderAndUpdateStatus(
                advancedOrder,
                criteriaResolvers,
                true,
                priorOrderHashes
            );

        // Create an array with length 1 containing the order.
        AdvancedOrder[] memory advancedOrders = new AdvancedOrder[](1);
        advancedOrders[0] = advancedOrder;

        // Apply criteria resolvers using generated orders and details arrays.
        _applyCriteriaResolvers(advancedOrders, criteriaResolvers);

        // Retrieve the order parameters after applying criteria resolvers.
        OrderParameters memory orderParameters = advancedOrders[0].parameters;

        // Perform each item transfer with the appropriate fractional amount.
        _applyFractionsAndTransferEach(
            orderParameters,
            fillNumerator,
            fillDenominator,
            orderParameters.conduitKey,
            fulfillerConduitKey
        );

        // Emit an event signifying that the order has been fulfilled.
        _emitOrderFulfilledEvent(
            orderHash,
            orderParameters.offerer,
            orderParameters.zone,
            msg.sender,
            orderParameters.offer,
            orderParameters.consideration
        );

        // Clear the reentrancy guard.
        _clearReentrancyGuard();

        return true;
    }

    /**
     * @dev Internal function to transfer each item contained in a given single
     *      order fulfillment after applying a respective fraction to the amount
     *      being transferred.
     *
     * @param orderParameters     The parameters for the fulfilled order.
     * @param numerator           A value indicating the portion of the order
     *                            that should be filled.
     * @param denominator         A value indicating the total order size.
     * @param offererConduitKey   An address indicating what conduit, if any, to
     *                            source the offerer's token approvals from. The
     *                            zero hash signifies that no conduit should be
     *                            used, with direct approvals set on
     *                            Consideration.
     * @param fulfillerConduitKey A bytes32 value indicating what conduit, if
     *                            any, to source the fulfiller's token approvals
     *                            from. The zero hash signifies that no conduit
     *                            should be used, with direct approvals set on
     *                            Consideration.
     */
    function _applyFractionsAndTransferEach(
        OrderParameters memory orderParameters,
        uint256 numerator,
        uint256 denominator,
        bytes32 offererConduitKey,
        bytes32 fulfillerConduitKey
    ) internal {
        // Derive order duration, time elapsed, and time remaining.
        uint256 duration = orderParameters.endTime - orderParameters.startTime;
        uint256 elapsed = block.timestamp - orderParameters.startTime;
        uint256 remaining = duration - elapsed;

        // Put ether value supplied by the caller on the stack.
        uint256 etherRemaining = msg.value;

        bytes memory accumulator = new bytes(32);

        // As of solidity 0.6.0, inline assembly can not directly access function
        // definitions, but can still access locally scoped function variables.
        // This means that in order to recast the type of a function, we need to
        // create a local variable to reference the internal function definition
        // (using the same type) and a local variable with the desired type,
        // and then cast the original function pointer to the desired type.

        /**
         * Repurpose existing OfferItem memory regions on the offer array for
         * the order by overriding the _transfer function pointer to accept a
         * modified OfferItem argument in place of the usual ReceivedItem:
         *
         *   ========= OfferItem ==========   ====== ReceivedItem ======
         *   ItemType itemType; ------------> ItemType itemType;
         *   address token; ----------------> address token;
         *   uint256 identifierOrCriteria; -> uint256 identifier;
         *   uint256 startAmount; ----------> uint256 amount;
         *   uint256 endAmount; ------------> address recipient;
         */

        // Declare a nested scope to minimize stack depth.
        {
            // Declare a virtual function pointer taking an OfferItem argument.
            function(OfferItem memory, address, bytes32, bytes memory)
                internal _transferOfferItem;

            {
                // Assign _transfer function to a new function pointer (it takes a
                // ReceivedItem as its initial argument)
                function(ReceivedItem memory, address, bytes32, bytes memory)
                    internal _transferReceivedItem = _transfer;

                // Utilize assembly to override the virtual function pointer.
                assembly {
                    // Cast initial ReceivedItem argument type to an OfferItem type.
                    _transferOfferItem := _transferReceivedItem
                }
            }

            // Iterate over each offer on the order.
            for (uint256 i = 0; i < orderParameters.offer.length; ) {
                // Retrieve the offer item.
                OfferItem memory offerItem = orderParameters.offer[i];

                // Apply fill fraction to derive offer item amount to transfer.
                uint256 amount = _applyFraction(
                    offerItem.startAmount,
                    offerItem.endAmount,
                    numerator,
                    denominator,
                    elapsed,
                    remaining,
                    duration,
                    false
                );

                // Utilize assembly to set overloaded offerItem arguments.
                assembly {
                    // Write derived fractional amount to startAmount as amount.
                    mstore(add(offerItem, 0x60), amount)
                    // Write fulfiller (i.e. caller) to endAmount as recipient.
                    mstore(add(offerItem, 0x80), caller())
                }

                // Reduce available value if offer spent ETH or a native token.
                if (offerItem.itemType == ItemType.NATIVE) {
                    // Ensure that sufficient native tokens are still available.
                    if (amount > etherRemaining) {
                        revert InsufficientEtherSupplied();
                    }

                    // Skip underflow check as a comparison has just been made.
                    unchecked {
                        etherRemaining -= amount;
                    }
                }

                // Transfer the item from the offerer to the caller.
                _transferOfferItem(
                    offerItem,
                    orderParameters.offerer,
                    offererConduitKey,
                    accumulator
                );

                // Skip overflow check as for loop is indexed starting at zero.
                unchecked {
                    ++i;
                }
            }
        }

        /**
         * Repurpose existing ConsiderationItem memory regions on the
         * consideration array for the order by overriding the _transfer
         * function pointer to accept a modified ConsiderationItem argument in
         * place of the usual ReceivedItem:
         *
         *   ====== ConsiderationItem =====   ====== ReceivedItem ======
         *   ItemType itemType; ------------> ItemType itemType;
         *   address token; ----------------> address token;
         *   uint256 identifierOrCriteria;--> uint256 identifier;
         *   uint256 startAmount; ----------> uint256 amount;
         *   uint256 endAmount;        /----> address recipient;
         *   address recipient; ------/
         */

        // Declare a nested scope to minimize stack depth.
        {
            // Declare virtual function pointer with ConsiderationItem argument.
            function(ConsiderationItem memory, address, bytes32, bytes memory)
                internal _transferConsiderationItem;
            {
                // Reassign _transfer function to a new function pointer (it takes a
                /// ReceivedItem as its initial argument).
                function(ReceivedItem memory, address, bytes32, bytes memory)
                    internal _transferReceivedItem = _transfer;

                // Utilize assembly to override the virtual function pointer.
                assembly {
                    // Cast ReceivedItem argument type to ConsiderationItem type.
                    _transferConsiderationItem := _transferReceivedItem
                }
            }

            // Iterate over each consideration on the order.
            for (uint256 i = 0; i < orderParameters.consideration.length; ) {
                // Retrieve the consideration item.
                ConsiderationItem memory considerationItem = (
                    orderParameters.consideration[i]
                );

                // Apply fraction & derive considerationItem amount to transfer.
                uint256 amount = _applyFraction(
                    considerationItem.startAmount,
                    considerationItem.endAmount,
                    numerator,
                    denominator,
                    elapsed,
                    remaining,
                    duration,
                    true
                );

                // Use assembly to set overloaded considerationItem arguments.
                assembly {
                    // Write derived fractional amount to startAmount as amount.
                    mstore(add(considerationItem, 0x60), amount)

                    // Write original recipient to endAmount as recipient.
                    mstore(
                        add(considerationItem, 0x80),
                        mload(add(considerationItem, 0xa0))
                    )
                }

                // Reduce available value if offer spent ETH or a native token.
                if (considerationItem.itemType == ItemType.NATIVE) {
                    // Ensure that sufficient native tokens are still available.
                    if (amount > etherRemaining) {
                        revert InsufficientEtherSupplied();
                    }

                    // Skip underflow check as a comparison has just been made.
                    unchecked {
                        etherRemaining -= amount;
                    }
                }

                // Transfer item from caller to recipient specified by the item.
                _transferConsiderationItem(
                    considerationItem,
                    msg.sender,
                    fulfillerConduitKey,
                    accumulator
                );

                // Skip overflow check as for loop is indexed starting at zero.
                unchecked {
                    ++i;
                }
            }
        }

        // Trigger any remaining accumulated transfers via call to the conduit.
        _triggerIfArmed(accumulator);

        // If any ether remains after fulfillments...
        if (etherRemaining != 0) {
            // return it to the caller.
            _transferEth(payable(msg.sender), etherRemaining);
        }
    }

    /**
     * @dev Internal function to validate a group of orders, update their
     *      statuses, reduce amounts by their previously filled fractions, apply
     *      criteria resolvers, and emit OrderFulfilled events.
     *
     * @param advancedOrders    The advanced orders to validate and reduce by
     *                          their previously filled amounts.
     * @param criteriaResolvers An array where each element contains a reference
     *                          to a specific order as well as that order's
     *                          offer or consideration, a token identifier, and
     *                          a proof that the supplied token identifier is
     *                          contained in the order's merkle root. Note that
     *                          a root of zero indicates that any transferrable
     *                          token identifier is valid and that no proof
     *                          needs to be supplied.
     * @param revertOnInvalid   A boolean indicating whether to revert on any
     *                          order being invalid; setting this to false will
     *                          instead cause the invalid order to be skipped.
     * @param maximumFulfilled  The maximum number of orders to fulfill.
     */
    function _validateOrdersAndPrepareToFulfill(
        AdvancedOrder[] memory advancedOrders,
        CriteriaResolver[] memory criteriaResolvers,
        bool revertOnInvalid,
        uint256 maximumFulfilled
    ) internal {
        // Ensure this function cannot be triggered during a reentrant call.
        _setReentrancyGuard();

        // Read length of orders array and place on the stack.
        uint256 totalOrders = advancedOrders.length;

        // Track the order hash for each order being fulfilled.
        bytes32[] memory orderHashes = new bytes32[](totalOrders);

        // Override orderHashes length to zero after memory has been allocated.
        assembly {
            mstore(orderHashes, 0)
        }

        // Skip overflow checks as all for loops are indexed starting at zero.
        unchecked {
            // Iterate over each order.
            for (uint256 i = 0; i < totalOrders; ++i) {
                // Retrieve the current order.
                AdvancedOrder memory advancedOrder = advancedOrders[i];

                // Determine if max number orders have already been fulfilled.
                if (maximumFulfilled == 0) {
                    // Mark fill fraction as zero as the order will not be used.
                    advancedOrder.numerator = 0;

                    // Update the length of the orderHashes array.
                    assembly {
                        mstore(orderHashes, add(i, 1))
                    }

                    // Continue iterating through the remaining orders.
                    continue;
                }

                // Validate it, update status, and determine fraction to fill.
                (
                    bytes32 orderHash,
                    uint256 numerator,
                    uint256 denominator
                ) = _validateOrderAndUpdateStatus(
                        advancedOrder,
                        criteriaResolvers,
                        revertOnInvalid,
                        orderHashes
                    );

                // Update the length of the orderHashes array.
                assembly {
                    mstore(orderHashes, add(i, 1))
                }

                // Do not track hash or adjust prices if order is not fulfilled.
                if (numerator == 0) {
                    // Mark fill fraction as zero if the order is not fulfilled.
                    advancedOrder.numerator = 0;

                    // Continue iterating through the remaining orders.
                    continue;
                }

                // Otherwise, track the order hash in question.
                orderHashes[i] = orderHash;

                // Decrement the number of fulfilled orders.
                maximumFulfilled--;

                // Place the start time for the order on the stack.
                uint256 startTime = advancedOrder.parameters.startTime;

                // Derive the duration for the order and place it on the stack.
                uint256 duration = advancedOrder.parameters.endTime - startTime;

                // Derive time elapsed since the order started & place on stack.
                uint256 elapsed = block.timestamp - startTime;

                // Derive time remaining until order expires and place on stack.
                uint256 remaining = duration - elapsed;

                // Retrieve array of offer items for the order in question.
                OfferItem[] memory offer = advancedOrder.parameters.offer;

                // Iterate over each offer item on the order.
                for (uint256 j = 0; j < offer.length; ++j) {
                    // Retrieve the offer item.
                    OfferItem memory offerItem = offer[j];

                    // Apply order fill fraction to offer item end amount.
                    uint256 endAmount = _getFraction(
                        numerator,
                        denominator,
                        offerItem.endAmount
                    );

                    // Reuse same fraction if start and end amounts are equal.
                    if (offerItem.startAmount == offerItem.endAmount) {
                        // Apply derived amount to both start and end amount.
                        offerItem.startAmount = endAmount;
                    } else {
                        // Apply order fill fraction to offer item start amount.
                        offerItem.startAmount = _getFraction(
                            numerator,
                            denominator,
                            offerItem.startAmount
                        );
                    }

                    // Update end amount in memory to match the derived amount.
                    offerItem.endAmount = endAmount;

                    // Adjust offer amount using current time; round down.
                    offerItem.startAmount = _locateCurrentAmount(
                        offerItem.startAmount,
                        offerItem.endAmount,
                        elapsed,
                        remaining,
                        duration,
                        false // round down
                    );
                }

                // Retrieve array of consideration items for order in question.
                ConsiderationItem[] memory consideration = (
                    advancedOrder.parameters.consideration
                );

                // Iterate over each consideration item on the order.
                for (uint256 j = 0; j < consideration.length; ++j) {
                    // Retrieve the consideration item.
                    ConsiderationItem memory considerationItem = (
                        consideration[j]
                    );

                    // Apply fraction to consideration item end amount.
                    uint256 endAmount = _getFraction(
                        numerator,
                        denominator,
                        considerationItem.endAmount
                    );

                    // Reuse same fraction if start and end amounts are equal.
                    if (
                        considerationItem.startAmount ==
                        considerationItem.endAmount
                    ) {
                        // Apply derived amount to both start and end amount.
                        considerationItem.startAmount = endAmount;
                    } else {
                        // Apply fraction to consideration item start amount.
                        considerationItem.startAmount = _getFraction(
                            numerator,
                            denominator,
                            considerationItem.startAmount
                        );
                    }

                    // Update end amount in memory to match the derived amount.
                    considerationItem.endAmount = endAmount;

                    // Adjust consideration amount using current time; round up.
                    considerationItem.startAmount = (
                        _locateCurrentAmount(
                            considerationItem.startAmount,
                            considerationItem.endAmount,
                            elapsed,
                            remaining,
                            duration,
                            true // round up
                        )
                    );

                    // Utilize assembly to manually "shift" the recipient value.
                    assembly {
                        // Write recipient to endAmount, as endAmount is not
                        // used from this point on and can be repurposed to fit
                        // the layout of a ReceivedItem.
                        mstore(
                            add(considerationItem, 0x80), // endAmount
                            mload(add(considerationItem, 0xa0)) // recipient
                        )
                    }
                }
            }
        }

        // Apply criteria resolvers to each order as applicable.
        _applyCriteriaResolvers(advancedOrders, criteriaResolvers);

        // Determine the fulfiller (revertOnInvalid ? address(0) : msg.sender).
        address fulfiller;

        // Utilize assembly to operate on revertOnInvalid boolean as an integer.
        assembly {
            // Set the fulfiller to the caller if revertOnValid is false.
            fulfiller := mul(iszero(revertOnInvalid), caller())
        }

        // Emit an event for each order signifying that it has been fulfilled.
        // Skip overflow checks as all for loops are indexed starting at zero.
        unchecked {
            // Iterate over each order.
            for (uint256 i = 0; i < totalOrders; ++i) {
                // Do not emit an event if no order hash is present.
                if (orderHashes[i] == bytes32(0)) {
                    continue;
                }

                // Retrieve parameters for the order in question.
                OrderParameters memory orderParameters = (
                    advancedOrders[i].parameters
                );

                // Emit an OrderFulfilled event.
                _emitOrderFulfilledEvent(
                    orderHashes[i],
                    orderParameters.offerer,
                    orderParameters.zone,
                    fulfiller,
                    orderParameters.offer,
                    orderParameters.consideration
                );
            }
        }
    }

    /**
     * @dev Internal function to fulfill an arbitrary number of orders, either
     *      full or partial, after validating, adjusting amounts, and applying
     *      criteria resolvers.
     *
     * @param advancedOrders     The orders to match, including a fraction to
     *                           attempt to fill for each order.
     * @param fulfillments       An array of elements allocating offer
     *                           components to consideration components. Note
     *                           that the final amount of each consideration
     *                           component must be zero for a match operation to
     *                           be considered valid.
     *
     * @return standardExecutions An array of elements indicating the sequence
     *                            of non-batch transfers performed as part of
     *                            matching the given orders.
     * @return batchExecutions    An array of elements indicating the sequence
     *                            of batch transfers performed as part of
     *                            matching the given orders.
     */
    function _fulfillAdvancedOrders(
        AdvancedOrder[] memory advancedOrders,
        Fulfillment[] calldata fulfillments
    )
        internal
        returns (
            Execution[] memory standardExecutions,
            BatchExecution[] memory batchExecutions
        )
    {
        // Retrieve fulfillments array length and place on the stack.
        uint256 totalFulfillments = fulfillments.length;

        // Allocate executions by fulfillment and apply them to each execution.
        Execution[] memory executions = new Execution[](totalFulfillments);

        // Skip overflow checks as all for loops are indexed starting at zero.
        unchecked {
            // Track number of filtered executions.
            uint256 totalFilteredExecutions = 0;

            // Iterate over each fulfillment.
            for (uint256 i = 0; i < totalFulfillments; ++i) {
                /// Retrieve the fulfillment in question.
                Fulfillment calldata fulfillment = fulfillments[i];

                // Derive the execution corresponding with the fulfillment.
                Execution memory execution = _applyFulfillment(
                    advancedOrders,
                    fulfillment.offerComponents,
                    fulfillment.considerationComponents
                );

                // If offerer and recipient on the execution are the same...
                if (execution.item.recipient == execution.offerer) {
                    // increment total filtered executions.
                    totalFilteredExecutions += 1;
                } else {
                    // Otherwise, assign the execution to the executions array.
                    executions[i - totalFilteredExecutions] = execution;
                }
            }

            // If some number of executions have been filtered...
            if (totalFilteredExecutions != 0) {
                // reduce the total length of the executions array.
                assembly {
                    mstore(
                        executions,
                        sub(mload(executions), totalFilteredExecutions)
                    )
                }
            }
        }

        // Perform final checks and compress executions into standard and batch.
        (
            ,
            standardExecutions,
            batchExecutions
        ) = _performFinalChecksAndExecuteOrders(advancedOrders, executions);

        // Return both standard and batch ERC1155 executions.
        return (standardExecutions, batchExecutions);
    }

    /**
     * @notice Internal function to attempt to fill a group of orders, fully or
     *         partially, with an arbitrary number of items for offer and
     *         consideration per order alongside criteria resolvers containing
     *         specific token identifiers and associated proofs. Any order that
     *         is not currently active, has already been fully filled, or has
     *         been cancelled will be omitted. Remaining offer and consideration
     *         items will then be aggregated where possible as indicated by the
     *         supplied offer and consideration component arrays and aggregated
     *         items will be transferred to the fulfiller or to each intended
     *         recipient, respectively. Note that a failing item transfer or an
     *         issue with order formatting will cause the entire batch to fail.
     *
     * @param advancedOrders            The orders to fulfill along with the
     *                                  fraction of those orders to attempt to
     *                                  fill. Note that both the offerer and the
     *                                  fulfiller must first approve this
     *                                  contract (or a conduit if indicated by
     *                                  the order) to transfer any relevant
     *                                  tokens on their behalf and that
     *                                  contracts must implement
     *                                  `onERC1155Received` in order to receive
     *                                  ERC1155 tokens as consideration. Also
     *                                  note that all offer and consideration
     *                                  components must have no remainder after
     *                                  multiplication of the respective amount
     *                                  with the supplied fraction for an
     *                                  order's partial fill amount to be
     *                                  considered valid.
     * @param criteriaResolvers         An array where each element contains a
     *                                  reference to a specific offer or
     *                                  consideration, a token identifier, and a
     *                                  proof that the supplied token identifier
     *                                  is contained in the merkle root held by
     *                                  the item in question's criteria element.
     *                                  Note that an empty criteria indicates
     *                                  that any (transferrable) token
     *                                  identifier on the token in question is
     *                                  valid and that no associated proof needs
     *                                  to be supplied.
     * @param offerFulfillments         An array of FulfillmentComponent arrays
     *                                  indicating which offer items to attempt
     *                                  to aggregate when preparing executions.
     * @param considerationFulfillments An array of FulfillmentComponent arrays
     *                                  indicating which consideration items to
     *                                  attempt to aggregate when preparing
     *                                  executions.
     * @param fulfillerConduitKey       A bytes32 value indicating what conduit,
     *                                  if any, to source the fulfiller's token
     *                                  approvals from. The zero hash signifies
     *                                  that no conduit should be used (and
     *                                  direct approvals set on Consideration).
     * @param maximumFulfilled          The maximum number of orders to fulfill.
     *
     * @return availableOrders    An array of booleans indicating if each order
     *                            with an index corresponding to the index of
     *                            the returned boolean was fulfillable or not.
     * @return standardExecutions An array of elements indicating the sequence
     *                            of non-batch transfers performed as part of
     *                            matching the given orders.
     * @return batchExecutions    An array of elements indicating the sequence
     *                            of batch transfers performed as part of
     *                            matching the given orders.
     */
    function _fulfillAvailableAdvancedOrders(
        AdvancedOrder[] memory advancedOrders,
        CriteriaResolver[] memory criteriaResolvers,
        FulfillmentComponent[][] calldata offerFulfillments,
        FulfillmentComponent[][] calldata considerationFulfillments,
        bytes32 fulfillerConduitKey,
        uint256 maximumFulfilled
    )
        internal
        returns (
            bool[] memory availableOrders,
            Execution[] memory standardExecutions,
            BatchExecution[] memory batchExecutions
        )
    {
        // Validate orders, apply amounts, & determine if they utilize conduits.
        _validateOrdersAndPrepareToFulfill(
            advancedOrders,
            criteriaResolvers,
            false, // Signifies that invalid orders should NOT revert.
            maximumFulfilled
        );

        // Aggregate used offer and consideration items and execute transfers.
        (
            availableOrders,
            standardExecutions,
            batchExecutions
        ) = _executeAvailableFulfillments(
            advancedOrders,
            offerFulfillments,
            considerationFulfillments,
            fulfillerConduitKey
        );

        // Return order fulfillment details and executions.
        return (availableOrders, standardExecutions, batchExecutions);
    }

    /**
     * @dev Internal function to fulfill a group of validated orders, fully or
     *      partially, with an arbitrary number of items for offer and
     *      consideration per order and to execute transfers. Any order that is
     *      not currently active, has already been fully filled, or has been
     *      cancelled will be omitted. Remaining offer and consideration items
     *      will then be aggregated where possible as indicated by the supplied
     *      offer and consideration component arrays and aggregated items will
     *      be transferred to the fulfiller or to each intended recipient,
     *      respectively. Note that a failing item transfer or an issue with
     *      order formatting will cause the entire batch to fail.
     *
     * @param advancedOrders            The orders to fulfill along with the
     *                                  fraction of those orders to attempt to
     *                                  fill. Note that both the offerer and the
     *                                  fulfiller must first approve this
     *                                  contract (or the conduit if indicated by
     *                                  the order) to transfer any relevant
     *                                  tokens on their behalf and that
     *                                  contracts must implement
     *                                  `onERC1155Received` in order to receive
     *                                  ERC1155 tokens as consideration. Also
     *                                  note that all offer and consideration
     *                                  components must have no remainder after
     *                                  multiplication of the respective amount
     *                                  with the supplied fraction for an
     *                                  order's partial fill amount to be
     *                                  considered valid.
     * @param offerFulfillments         An array of FulfillmentComponent arrays
     *                                  indicating which offer items to attempt
     *                                  to aggregate when preparing executions.
     * @param considerationFulfillments An array of FulfillmentComponent arrays
     *                                  indicating which consideration items to
     *                                  attempt to aggregate when preparing
     *                                  executions.
     * @param fulfillerConduitKey       A bytes32 value indicating what conduit,
     *                                  if any, to source the fulfiller's token
     *                                  approvals from. The zero hash signifies
     *                                  that no conduit should be used, with
     *                                  direct approvals set on Consideration.
     *
     * @return availableOrders    An array of booleans indicating if each order
     *                            with an index corresponding to the index of
     *                            the returned boolean was fulfillable or not.
     * @return standardExecutions An array of elements indicating the sequence
     *                            of non-batch transfers performed as part of
     *                            matching the given orders.
     * @return batchExecutions    An array of elements indicating the sequence
     *                            of batch transfers performed as part of
     *                            matching the given orders.
     */
    function _executeAvailableFulfillments(
        AdvancedOrder[] memory advancedOrders,
        FulfillmentComponent[][] memory offerFulfillments,
        FulfillmentComponent[][] memory considerationFulfillments,
        bytes32 fulfillerConduitKey
    )
        internal
        returns (
            bool[] memory availableOrders,
            Execution[] memory standardExecutions,
            BatchExecution[] memory batchExecutions
        )
    {
        // Retrieve length of offer fulfillments array and place on the stack.
        uint256 totalOfferFulfillments = offerFulfillments.length;

        // Retrieve length of consideration fulfillments array & place on stack.
        uint256 totalConsiderationFulfillments = (
            considerationFulfillments.length
        );

        // Allocate an execution for each offer and consideration fulfillment.
        Execution[] memory executions = new Execution[](
            totalOfferFulfillments + totalConsiderationFulfillments
        );

        // Skip overflow checks as all for loops are indexed starting at zero.
        unchecked {
            // Track number of filtered executions.
            uint256 totalFilteredExecutions = 0;

            // Iterate over each offer fulfillment.
            for (uint256 i = 0; i < totalOfferFulfillments; ++i) {
                /// Retrieve the offer fulfillment components in question.
                FulfillmentComponent[] memory components = (
                    offerFulfillments[i]
                );

                // Derive aggregated execution corresponding with fulfillment.
                Execution memory execution = _aggregateAvailable(
                    advancedOrders,
                    Side.OFFER,
                    components,
                    fulfillerConduitKey
                );

                // If offerer and recipient on the execution are the same...
                if (execution.item.recipient == execution.offerer) {
                    // increment total filtered executions.
                    totalFilteredExecutions += 1;
                } else {
                    // Otherwise, assign the execution to the executions array.
                    executions[i - totalFilteredExecutions] = execution;
                }
            }

            // Iterate over each consideration fulfillment.
            for (uint256 i = 0; i < totalConsiderationFulfillments; ++i) {
                /// Retrieve consideration fulfillment components in question.
                FulfillmentComponent[] memory components = (
                    considerationFulfillments[i]
                );

                // Derive aggregated execution corresponding with fulfillment.
                Execution memory execution = _aggregateAvailable(
                    advancedOrders,
                    Side.CONSIDERATION,
                    components,
                    fulfillerConduitKey
                );

                // If offerer and recipient on the execution are the same...
                if (execution.item.recipient == execution.offerer) {
                    // increment total filtered executions.
                    totalFilteredExecutions += 1;
                } else {
                    // Otherwise, assign the execution to the executions array.
                    executions[
                        i + totalOfferFulfillments - totalFilteredExecutions
                    ] = execution;
                }
            }

            // If some number of executions have been filtered...
            if (totalFilteredExecutions != 0) {
                // reduce the total length of the executions array.
                assembly {
                    mstore(
                        executions,
                        sub(mload(executions), totalFilteredExecutions)
                    )
                }
            }
        }

        // Revert if no orders are available.
        if (executions.length == 0) {
            revert NoSpecifiedOrdersAvailable();
        }

        // Perform final checks, compress executions, and return.
        return _performFinalChecksAndExecuteOrders(advancedOrders, executions);
    }

    /**
     * @dev Internal function to perform a final check that each consideration
     *      item for an arbitrary number of fulfilled orders has been met and to
     *      compress and trigger associated execututions, transferring the
     *      respective items.
     *
     * @param advancedOrders     The orders to check and perform executions for.
     * @param executions         An array of uncompressed elements indicating
     *                           the sequence of transfers to perform when
     *                           fulfilling the given orders.
     *
     * @return availableOrders    An array of booleans indicating if each order
     *                            with an index corresponding to the index of
     *                            the returned boolean was fulfillable or not.
     * @return standardExecutions An array of elements indicating the sequence
     *                            of non-batch transfers performed as part of
     *                            fulfilling the given orders.
     * @return batchExecutions    An array of elements indicating the sequence
     *                            of batch transfers performed as part of
     *                            fulfilling the given orders.
     */
    function _performFinalChecksAndExecuteOrders(
        AdvancedOrder[] memory advancedOrders,
        Execution[] memory executions
    )
        internal
        returns (
            bool[] memory availableOrders,
            Execution[] memory standardExecutions,
            BatchExecution[] memory batchExecutions
        )
    {
        // Retrieve the length of the advanced orders array and place on stack.
        uint256 totalOrders = advancedOrders.length;

        // Initialize array for tracking available orders.
        availableOrders = new bool[](totalOrders);

        // Skip overflow checks as all for loops are indexed starting at zero.
        unchecked {
            // Iterate over orders to ensure all considerations are met.
            for (uint256 i = 0; i < totalOrders; ++i) {
                // Retrieve the order in question.
                AdvancedOrder memory advancedOrder = advancedOrders[i];

                // Skip consideration item checks for order if not fulfilled.
                if (advancedOrder.numerator == 0) {
                    // Note: orders do not need to be marked as unavailable as a
                    // new memory region has been allocated. Review carefully if
                    // altering compiler version or managing memory manually.
                    continue;
                }

                // Mark the order as available.
                availableOrders[i] = true;

                // Retrieve consideration items to ensure they are fulfilled.
                ConsiderationItem[] memory consideration = (
                    advancedOrder.parameters.consideration
                );

                // Iterate over each consideration item to ensure it is met.
                for (uint256 j = 0; j < consideration.length; ++j) {
                    // Retrieve remaining amount on the consideration item.
                    uint256 unmetAmount = consideration[j].startAmount;

                    // Revert if the remaining amount is not zero.
                    if (unmetAmount != 0) {
                        revert ConsiderationNotMet(i, j, unmetAmount);
                    }
                }
            }
        }

        // Split executions into "standard" (no batch) and "batch" executions.
        (standardExecutions, batchExecutions) = _compressExecutions(executions);

        // Put ether value supplied by the caller on the stack.
        uint256 etherRemaining = msg.value;

        bytes memory accumulator = new bytes(32);

        // Iterate over each standard execution.
        for (uint256 i = 0; i < standardExecutions.length; ) {
            // Retrieve the execution and the associated received item.
            Execution memory execution = standardExecutions[i];
            ReceivedItem memory item = execution.item;

            // If execution transfers native tokens, reduce value available.
            if (item.itemType == ItemType.NATIVE) {
                // Ensure that sufficient native tokens are still available.
                if (item.amount > etherRemaining) {
                    revert InsufficientEtherSupplied();
                }

                // Skip underflow check as amount is less than ether remaining.
                unchecked {
                    etherRemaining -= item.amount;
                }
            }

            // Transfer the item specified by the execution.
            _transfer(
                item,
                execution.offerer,
                execution.conduitKey,
                accumulator
            );

            // Skip overflow check as for loop is indexed starting at zero.
            unchecked {
                ++i;
            }
        }

        // Trigger any remaining accumulated transfers via call to the conduit.
        _triggerIfArmed(accumulator);

        // Skip overflow check as for loop is indexed starting at zero.
        unchecked {
            uint256 totalBatchExecutions = batchExecutions.length;

            // Iterate over each batch execution.
            for (uint256 i = 0; i < totalBatchExecutions; ++i) {
                // Perform the batch transfer.
                _batchTransferERC1155(batchExecutions[i]);
            }
        }

        // If any ether remains after fulfillments, return it to the caller.
        if (etherRemaining != 0) {
            _transferEth(payable(msg.sender), etherRemaining);
        }

        // Clear the reentrancy guard.
        _clearReentrancyGuard();

        // Return arrays with available orders and triggered executions.
        return (availableOrders, standardExecutions, batchExecutions);
    }

    /**
     * @dev Internal function to emit an OrderFulfilled event. OfferItems are
     *      translated into SpentItems and ConsiderationItems are translated
     *      into ReceivedItems.
     *
     * @param orderHash     The order hash.
     * @param offerer       The offerer for the order.
     * @param zone          The zone for the order.
     * @param fulfiller     The fulfiller of the order, or the null address if
     *                      the order was fulfilled via order matching.
     * @param offer         The offer items for the order.
     * @param consideration The consideration items for the order.
     */
    function _emitOrderFulfilledEvent(
        bytes32 orderHash,
        address offerer,
        address zone,
        address fulfiller,
        OfferItem[] memory offer,
        ConsiderationItem[] memory consideration
    ) internal {
        // Cast already-modified offer memory region as spent items.
        SpentItem[] memory spentItems;
        assembly {
            spentItems := offer
        }

        // Cast already-modified consideration memory region as received items.
        ReceivedItem[] memory receivedItems;
        assembly {
            receivedItems := consideration
        }

        // Emit an event signifying that the order has been fulfilled.
        emit OrderFulfilled(
            orderHash,
            offerer,
            zone,
            fulfiller,
            spentItems,
            receivedItems
        );
    }
}
