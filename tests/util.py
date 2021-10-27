from brownie import Contract


def stateOfStrat(msg, balancer, providerA, providerB):
    decA = 10 ** Contract(providerA.want()).decimals()
    decB = 10 ** Contract(providerB.want()).decimals()
    decValA = 10 ** (Contract(providerA.want()).decimals() + 8)
    decValB = 10 ** (Contract(providerB.want()).decimals() + 8)

    print(f'\n=== STATE OF STRATEGY ===\n')
    print(f'\n{msg}\n')
    print(f'ProviderA debt: {providerA.totalDebt() / decA}')
    print(f'ProviderB debt: {providerB.totalDebt() / decB}')
    print(f'ProviderA balance: {providerA.balanceOfWant() / decA}')
    print(f'ProviderB balance: {providerB.balanceOfWant() / decB}')
    print(f'Loose balanceA: {balancer.looseBalanceA() / decA}')
    print(f'Loose balanceB: {balancer.looseBalanceB() / decB}')
    print(f'Pooled balanceA: {balancer.pooledBalanceA() / decA}')
    print(f'Pooled balanceB: {balancer.pooledBalanceB() / decB}')
    print(f'priceA: {providerA.getPriceFeed() / 1e8}')
    print(f'priceB: {providerB.getPriceFeed() / 1e8}')
    print(f'valuePooledA: {providerA.getPriceFeed() * balancer.pooledBalanceA() / decValA}')
    print(f'valuePooledB: {providerB.getPriceFeed() * balancer.pooledBalanceB() / decValB}')
    print(f'WeightA: {balancer.currentWeightA() / 1e18}')
    print(f'WeightB: {balancer.currentWeightB() / 1e18}')
    print(f'LBP balance: {balancer.balanceOfLbp() / decA}')
    print(f'Bal balance: {balancer.balanceOfReward() / decA}')


def simulate_bal_reward(rebalancer, reward, reward_whale):
    reward.approve(rebalancer, 2 ** 256 - 1, {'from': reward_whale})
    reward.transfer(rebalancer, 100 * 1e18, {"from": reward_whale})
