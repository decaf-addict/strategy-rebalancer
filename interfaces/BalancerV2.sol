// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.6.0 <0.7.0;
pragma experimental ABIEncoderV2;

import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";


interface ILiquidityBootstrappingPoolFactory {
    function create(
        string memory name,
        string memory symbol,
        IERC20[] memory tokens,
        uint256[] memory weights,
        uint256 swapFeePercentage,
        address owner,
        bool swapEnabledOnStart
    ) external returns (address);
}

interface ILiquidityBootstrappingPool {
    enum SwapKind {GIVEN_IN, GIVEN_OUT}

    struct SwapRequest {
        SwapKind kind;
        IERC20 tokenIn;
        IERC20 tokenOut;
        uint256 amount;
        bytes32 poolId;
        uint256 lastChangeBlock;
        address from;
        address to;
        bytes userData;
    }

    function balanceOf(address) external view returns (uint _amount);

    function transfer(address _recepient, uint _amount) external;

    function updateWeightsGradually(uint _startTime, uint _endTime, uint[] calldata _endWeights) external;

    function getPoolId() external view returns (bytes32 _id);

    function getNormalizedWeights() external view returns (uint[] calldata _normalizedWeights);

    function setSwapFeePercentage(uint _fee) external;

    function getSwapFeePercentage() external view returns (uint _fee);

    function setSwapEnabled(bool) external;

    function getSwapEnabled() external view returns (bool);

    function getVault() external view returns (address);

    function onSwap(
        SwapRequest memory request,
        uint256 balanceTokenIn,
        uint256 balanceTokenOut
    ) external returns (uint256);
}

interface IBalancerVault {
    enum PoolSpecialization {GENERAL, MINIMAL_SWAP_INFO, TWO_TOKEN}
    enum JoinKind {INIT, EXACT_TOKENS_IN_FOR_BPT_OUT, TOKEN_IN_FOR_EXACT_BPT_OUT, ALL_TOKENS_IN_FOR_EXACT_BPT_OUT}
    enum ExitKind {EXACT_BPT_IN_FOR_ONE_TOKEN_OUT, EXACT_BPT_IN_FOR_TOKENS_OUT, BPT_IN_FOR_EXACT_TOKENS_OUT}
    enum SwapKind {GIVEN_IN, GIVEN_OUT}

    /**
 * @dev Performs a series of swaps with one or multiple Pools. In each individual swap, the caller determines either
 * the amount of tokens sent to or received from the Pool, depending on the `kind` value.
 *
 * Returns an array with the net Vault asset balance deltas. Positive amounts represent tokens (or ETH) sent to the
 * Vault, and negative amounts represent tokens (or ETH) sent by the Vault. Each delta corresponds to the asset at
 * the same index in the `assets` array.
 *
 * Swaps are executed sequentially, in the order specified by the `swaps` array. Each array element describes a
 * Pool, the token to be sent to this Pool, the token to receive from it, and an amount that is either `amountIn` or
 * `amountOut` depending on the swap kind.
 *
 * Multihop swaps can be executed by passing an `amount` value of zero for a swap. This will cause the amount in/out
 * of the previous swap to be used as the amount in for the current one. In a 'given in' swap, 'tokenIn' must equal
 * the previous swap's `tokenOut`. For a 'given out' swap, `tokenOut` must equal the previous swap's `tokenIn`.
 *
 * The `assets` array contains the addresses of all assets involved in the swaps. These are either token addresses,
 * or the IAsset sentinel value for ETH (the zero address). Each entry in the `swaps` array specifies tokens in and
 * out by referencing an index in `assets`. Note that Pools never interact with ETH directly: it will be wrapped to
 * or unwrapped from WETH by the Vault.
 *
 * Internal Balance usage, sender, and recipient are determined by the `funds` struct. The `limits` array specifies
 * the minimum or maximum amount of each token the vault is allowed to transfer.
 *
 * `batchSwap` can be used to make a single swap, like `swap` does, but doing so requires more gas than the
 * equivalent `swap` call.
 *
 * Emits `Swap` events.
 */
    struct BatchSwapStep {
        bytes32 poolId;
        uint256 assetInIndex;
        uint256 assetOutIndex;
        uint256 amount;
        bytes userData;
    }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address payable recipient;
        bool toInternalBalance;
    }

    struct SingleSwap {
        bytes32 poolId;
        SwapKind kind;
        IAsset assetIn;
        IAsset assetOut;
        uint256 amount;
        bytes userData;
    }

    // enconding formats https://github.com/balancer-labs/balancer-v2-monorepo/blob/master/pkg/balancer-js/src/pool-weighted/encoder.ts
    struct JoinPoolRequest {
        IAsset[] assets;
        uint256[] maxAmountsIn;
        bytes userData;
        bool fromInternalBalance;
    }

    struct ExitPoolRequest {
        IAsset[] assets;
        uint256[] minAmountsOut;
        bytes userData;
        bool toInternalBalance;
    }

    function joinPool(
        bytes32 poolId,
        address sender,
        address recipient,
        JoinPoolRequest memory request
    ) external payable;

    function exitPool(
        bytes32 poolId,
        address sender,
        address payable recipient,
        ExitPoolRequest calldata request
    ) external;

    function getPool(bytes32 poolId) external view returns (address poolAddress, PoolSpecialization);

    function getPoolTokenInfo(bytes32 poolId, IERC20 token) external view returns (
        uint256 cash,
        uint256 managed,
        uint256 lastChangeBlock,
        address assetManager
    );

    function getPoolTokens(bytes32 poolId) external view returns (
        IERC20[] calldata tokens,
        uint256[] calldata balances,
        uint256 lastChangeBlock
    );

    /**
     * @dev Simulates a call to `batchSwap`, returning an array of Vault asset deltas. Calls to `swap` cannot be
     * simulated directly, but an equivalent `batchSwap` call can and will yield the exact same result.
     *
     * Each element in the array corresponds to the asset at the same index, and indicates the number of tokens (or ETH)
     * the Vault would take from the sender (if positive) or send to the recipient (if negative). The arguments it
     * receives are the same that an equivalent `batchSwap` call would receive.
     *
     * Unlike `batchSwap`, this function performs no checks on the sender or recipient field in the `funds` struct.
     * This makes it suitable to be called by off-chain applications via eth_call without needing to hold tokens,
     * approve them for the Vault, or even know a user's address.
     *
     * Note that this function is not 'view' (due to implementation details): the client code must explicitly execute
     * eth_call instead of eth_sendTransaction.
     */
    function queryBatchSwap(
        SwapKind kind,
        BatchSwapStep[] memory swaps,
        IAsset[] memory assets,
        FundManagement memory funds
    ) external returns (int256[] memory assetDeltas);

    function swap(
        SingleSwap memory singleSwap,
        FundManagement memory funds,
        uint256 limit,
        uint256 deadline
    ) external;
}

interface IAsset {
    // solhint-disable-previous-line no-empty-blocks
}

interface IBalancerVaultHelper {
    struct JoinPoolRequest {
        IAsset[] assets;
        uint256[] maxAmountsIn;
        bytes userData;
        bool fromInternalBalance;
    }

    struct ExitPoolRequest {
        IAsset[] assets;
        uint256[] minAmountsOut;
        bytes userData;
        bool toInternalBalance;
    }

    function queryJoin(
        bytes32 poolId,
        address sender,
        address recipient,
        IBalancerVault.JoinPoolRequest memory request
    ) external view returns (uint256 bptOut, uint256[] memory amountsIn);

    function queryExit(
        bytes32 poolId,
        address sender,
        address recipient,
        IBalancerVault.ExitPoolRequest memory request
    ) external view returns (uint256 bptIn, uint256[] memory amountsOut);
}