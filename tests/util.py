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

def simulate_bal_reward(rebalancer, reward, reward_whale):
    reward.approve(rebalancer, 2 ** 256 - 1, {'from': reward_whale})
    reward.transfer(rebalancer, 100 * 1e18, {"from": reward_whale})
