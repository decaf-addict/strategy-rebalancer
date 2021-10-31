from brownie import Contract, accounts, config, network, project, web3, accounts


def main():
    aProvider = Contract("0xff3AeA00d3d58ba1a3672c766cc5060FfCb8cca3")
    bProvider = Contract("0xAB1d2ABbe31FA5945BfA0864f29dadDcB9cd9eAc")
    rebalancer = Contract("0x9AC6B9bEe8552F207C0f4e375b980955e6CF807F")
    balancerMathLib = Contract("0xd984d56465c82E7066898433b5479B4b0026D28D")
    aFeed = aProvider.getPriceFeed()
    bFeed = bProvider.getPriceFeed()
    aFeedDec = aProvider.getPriceFeedDecimals()
    bFeedDec = bProvider.getPriceFeedDecimals()
    aDebt = aProvider.totalDebt()
    bDebt = bProvider.totalDebt()
    aWeight = rebalancer.currentWeightA()
    bWeight = rebalancer.currentWeightB()

    aDebtUsd = aDebt * aFeed / 10 ** aFeedDec
    bDebtUsd = bDebt * bFeed / 10 ** bFeedDec
    totalUsd = aDebtUsd + bDebtUsd

    aIdealUsd = totalUsd * aWeight / 1e18
    bIdealUsd = totalUsd - aIdealUsd

    print(f'aIdealUsd ${aIdealUsd / 1e18}')
    print(f'aDebtUsd ${aDebtUsd / 1e18}')
    arb_in = (aIdealUsd - aDebtUsd)
    print(f'max arbable amount = ${abs(arb_in / 1e18)}')
    arb_in = (aIdealUsd - aDebtUsd) / aFeed * 10 ** aFeedDec

    if arb_in > 0:
        arb_out = balancerMathLib.calcOutGivenIn(rebalancer.pooledBalanceA(),
                                                 rebalancer.currentWeightA(),
                                                 rebalancer.pooledBalanceB(),
                                                 rebalancer.currentWeightB(),
                                                 arb_in, 0)
        out_perfect = (bDebtUsd - bIdealUsd) / bFeed * 10 ** bFeedDec
        print(f'out_perfect {out_perfect / 1e18} {Contract(rebalancer.tokenB()).symbol()}')
        print(
            f'arbed {arb_in / 1e18} {Contract(rebalancer.tokenA()).symbol()} for {arb_out / 1e18} {Contract(rebalancer.tokenB()).symbol()}')

    else:
        arb_in = (bIdealUsd - bDebtUsd) / bFeed * 10 ** bFeedDec
        arb_out = balancerMathLib.calcOutGivenIn(rebalancer.pooledBalanceB(),
                                                 rebalancer.currentWeightB(),
                                                 rebalancer.pooledBalanceA(),
                                                 rebalancer.currentWeightA(),
                                                 arb_in,
                                                 0)
        out_perfect = (aDebtUsd - aIdealUsd) / aFeed * 10 ** aFeedDec
        print(f'out_perfect {out_perfect / 1e18} {Contract(rebalancer.tokenA()).symbol()}')
        print(
            f'arbed {arb_in / 1e18} {Contract(rebalancer.tokenB()).symbol()} for {arb_out / 1e18} {Contract(rebalancer.tokenA()).symbol()}')

    if (arb_out > out_perfect):
        slippage_gain = (arb_out - out_perfect) / out_perfect * 100
        print(f'arber gained {slippage_gain}%')
