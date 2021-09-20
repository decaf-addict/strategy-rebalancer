from brownie import Contract


def stateOfStrat(msg, balancer, providerA, providerB):
    print(f'\n=== STATE OF STRATEGY ===\n')
    print(f'\n{msg}\n')
    print(f'ProviderA balance: {providerA.balanceOfWant() / 1e18}')
    print(f'ProviderB balance: {providerB.balanceOfWant() / 1e18}')
    print(f'Loose balanceA: {balancer.looseBalanceA() / 1e18}')
    print(f'Loose balanceB: {balancer.looseBalanceB() / 1e18}')
    print(f'Pooled balanceA: {balancer.pooledBalanceA() / 1e18}')
    print(f'Pooled balanceB: {balancer.pooledBalanceB() / 1e18}')
    print(f'priceA: {providerA.getPriceFeed() / 1e8}')
    print(f'priceB: {providerB.getPriceFeed() / 1e8}')
    print(f'valuePooledA: {providerA.getPriceFeed() * balancer.pooledBalanceA() / 1e26}')
    print(f'valuePooledB: {providerB.getPriceFeed() * balancer.pooledBalanceB() / 1e26}')
    print(f'WeightA: {balancer.currentWeightA() / 1e18}')
    print(f'WeightB: {balancer.currentWeightB() / 1e18}')
    print(f'LBP balance: {balancer.balanceOfLbp() / 1e18}')
    print(f'Bal balance: {balancer.balanceOfReward() / 1e18}')


# trade that keeps the pool mostly in balance
def simulate_2_sided_trades(rebalancer, tokenA, tokenB, providerA, providerB, rando, accounts):
    print(f'\n=== SIMULATE TRADES ===\n')

    # random user trading using pool
    tokenA.approve(rebalancer, 2 ** 256 - 1, {'from': rando})
    tokenB.approve(rebalancer, 2 ** 256 - 1, {'from': rando})

    amountIn = 10 * 1e18
    bVault = Contract(rebalancer.bVault())

    traded = rebalancer.onSwap(True, tokenA, tokenB, amountIn, rando, {'from': rando}).return_value

    print(f'Traded {traded}')
    stateOfStrat("after swap A for B", rebalancer, providerA, providerB)
    assert False
    # beforeB = tokenB.balanceOf(rando)
    # rebalancer.queryBatchSwap(True, tokenB, tokenA, 10 * 1e18, rando)
    # rebalancer.queryBatchSwap(False, tokenA, tokenB, 10 * 1e18, rando)
    # afterB = tokenB.balanceOf(rando)
    # print(f'{beforeB}, {afterB}')
    # assert beforeB > afterB
    #
    # # earnings from trading fee
    # afterSwapB = rebalancer.pooledBalanceB()
    # assert afterSwapB > beforeSwapB
    #
    # print(f'\nEarned {(afterSwapA - beforeSwapA) / 1e18} tokenA\n')
    # print(f'\nEarned {(afterSwapB - beforeSwapB) / 1e18} tokenB\n')


# trade that skews the pool to one side heavily
def simulate_1_sided_trade(rebalancer, tokenA, tokenB, providerA, providerB, pool, rando):
    print(f'\n=== SIMULATE TRADES ===\n')

    # random user trading using pool
    tokenA.approve(pool, 2 ** 256 - 1, {'from': rando})
    tokenB.approve(pool, 2 ** 256 - 1, {'from': rando})

    # simulate some trades to generate trading fees
    stateOfStrat("before swap B for A", rebalancer, providerA, providerB)
    beforeA = rebalancer.pooledBalanceA()
    beforeB = rebalancer.pooledBalanceB()
    pool.swapExactAmountIn(tokenB, 100 * 10 ** 18, tokenA, 0, 2 ** 256 - 1, {'from': rando})
    stateOfStrat("after swap", rebalancer, providerA, providerB)

    afterA = rebalancer.pooledBalanceA()
    afterB = rebalancer.pooledBalanceB()
    return afterA - beforeA, afterB - beforeB


def simulate_bal_reward(dynamic_balancer, reward, reward_whale):
    reward.approve(dynamic_balancer, 2 ** 256 - 1, {'from': reward_whale})
    reward.transfer(dynamic_balancer, 100 * 1e18, {"from": reward_whale})
