import brownie
from brownie import Contract
import pytest
import util


def test_slippage(providerATestOracle, providerBTestOracle, tokenA, tokenB, amountA, amountB, vaultA, vaultB,
                  rebalancer, testOracleA, testOracleB,
                  user, pool, gov, setupTestOracle, rando, transferToRando, chain, testSetup, reward, reward_whale):
    testOracleA.setPrice(1 * 1e8, {'from': rando})
    testOracleB.setPrice(1 * 1e8, {'from': rando})

    providerATestOracle.harvest({"from": gov})
    providerBTestOracle.harvest({"from": gov})

    util.stateOfStrat("1", rebalancer, providerATestOracle, providerBTestOracle)

    testOracleA.setPrice(0.98 * 1e8, {'from': rando})
    testOracleB.setPrice(1.05 * 1e8, {'from': rando})

    util.stateOfStrat("B price increase", rebalancer, providerATestOracle, providerBTestOracle)
    # favorable trade for user, should give user some positive slippage
    tokenA.approve(pool, 2 ** 256 - 1, {'from': rando})
    tokenB.approve(pool, 2 ** 256 - 1, {'from': rando})

    diffBalA = (
                       rebalancer.pooledBalanceB() * providerBTestOracle.getPriceFeed() - rebalancer.pooledBalanceA() * providerATestOracle.getPriceFeed()) / 2 / providerATestOracle.getPriceFeed()
    pool.swapExactAmountIn(tokenA, diffBalA, tokenB, 0, 2 ** 256 - 1, {'from': rando})

    util.stateOfStrat("trades after B price double", rebalancer, providerATestOracle, providerBTestOracle)

    providerATestOracle.harvest({"from": gov})
    providerBTestOracle.harvest({"from": gov})

    util.stateOfStrat("after harvest", rebalancer, providerATestOracle, providerBTestOracle)

    util.stateOfStrat("after trades", rebalancer, providerATestOracle, providerBTestOracle)

    valueTotal = providerBTestOracle.getPriceFeed() * rebalancer.pooledBalanceB() + providerATestOracle.getPriceFeed() * rebalancer.pooledBalanceA()
    total = providerBTestOracle.getPriceFeed() * providerBTestOracle.totalDebt() + providerATestOracle.getPriceFeed() * providerATestOracle.totalDebt()

    print(f'lost {(total - valueTotal) / total}% to slippage')

    chain.sleep(3600)
    chain.mine(1)
