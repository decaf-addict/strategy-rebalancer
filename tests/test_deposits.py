import brownie
from brownie import Contract
import pytest
import util


def test_1_deposit(providerA, tokenA, amountA, vaultA, rebalancer, user, chain, RELATIVE_APPROX, gov, setup,
                   providerB):
    tokenA.approve(vaultA.address, amountA, {"from": user})
    vaultA.deposit(amountA, {"from": user})
    assert tokenA.balanceOf(vaultA.address) == amountA

    # harvest
    chain.sleep(1)
    before = rebalancer.pooledBalanceA()

    # deposit goes into adapterA, which deposits into dynamic_balancer
    providerA.harvest({"from": gov})
    after = rebalancer.pooledBalanceA()

    # fund remains idle in rebalancer
    assert rebalancer.looseBalanceA() == amountA
    # no new lp created bc only one sided deposit
    assert after - before == 0


def test_2_deposits(providerA, providerB, tokenA, tokenB, amountA, amountB, vaultA, vaultB, rebalancer, user, gov,
                    setup, RELATIVE_APPROX, testSetup):
    beforeBpt = rebalancer.balanceOfLbp()
    util.stateOfStrat("before harvest", rebalancer, providerA, providerB)

    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    afterBpt = rebalancer.balanceOfLbp()
    util.stateOfStrat("after harvest", rebalancer, providerA, providerB)

    assert providerA.balanceOfWant() == 0
    assert providerB.balanceOfWant() == 0

    assert afterBpt > beforeBpt

    weightABefore = rebalancer.currentWeightA()
    # test partial withdraw
    vaultA.withdraw(50 * 1e18, user, 1, {"from": user})
    # assert withdraw doesn't need a tend afterward
    assert rebalancer.shouldTend() == False
    # makes sure weight updates after withdraw
    assert rebalancer.currentWeightA() < weightABefore
    util.stateOfStrat("after withdraw", rebalancer, providerA, providerB)

    # withdraw rest of it
    vaultA.withdraw({"from": user})
    assert pytest.approx(tokenA.balanceOf(user), rel=RELATIVE_APPROX) == amountA


# test deposits that highly skews the pool to one side (over the 2%-98% pool ratio limit)
def test_skewed_deposits(providerA, providerB, tokenA, tokenB, amountA, amountB, vaultA, vaultB, rebalancer, user,
                         gov, setup, RELATIVE_APPROX):
    tokenA.approve(vaultA.address, amountA, {"from": user})
    vaultA.deposit(amountA, {"from": user})
    assert tokenA.balanceOf(vaultA.address) == amountA
    print(f'\ndeposited {amountA / 1e18} tokenA to vaultA\n')

    # large A small B deposit
    amountB = 1 * 1e18
    tokenB.approve(vaultB.address, 2 ** 256 - 1, {"from": user})
    vaultB.deposit(amountB, {"from": user})
    assert tokenB.balanceOf(vaultB.address) == amountB
    print(f'deposited {amountB / 1e18} tokenB to vaultB\n')

    beforeBpt = rebalancer.balanceOfLbp()
    util.stateOfStrat("before harvest", rebalancer, providerA, providerB)

    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    # public swap is paused bc deposit would be skewed
    assert rebalancer.shouldTend() == False
    assert rebalancer.getPublicSwap() == False

    util.stateOfStrat("after harvest skewed", rebalancer, providerA, providerB)

    assert providerA.balanceOfWant() == 0
    assert providerB.balanceOfWant() == 0

    # add more debt so it's not skewed anymore
    amountB2 = 999 * 1e18
    vaultB.deposit(amountB2, {"from": user})

    providerB.harvest({"from": gov})

    assert rebalancer.shouldTend() == False
    util.stateOfStrat("after harvest normal", rebalancer, providerA, providerB)

    assert rebalancer.getPublicSwap() == True

    afterBpt = rebalancer.balanceOfLbp()
    assert afterBpt > beforeBpt

    vaultA.withdraw({"from": user})
    # assert withdraw all doesn't need a tend afterward
    assert rebalancer.shouldTend() == False
    assert pytest.approx(tokenA.balanceOf(user), rel=RELATIVE_APPROX) == amountA

    # make sure that pool is disabled since one side has no liquidity
    assert rebalancer.getPublicSwap() == False

    util.stateOfStrat("after withdraw A", rebalancer, providerA, providerB)

    vaultB.withdraw({"from": user})
    assert pytest.approx(tokenB.balanceOf(user), rel=RELATIVE_APPROX) == amountB + amountB2

    util.stateOfStrat("after withdraw B", rebalancer, providerA, providerB)
