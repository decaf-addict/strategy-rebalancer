from brownie import Contract, accounts, config, network, project, web3, accounts


def main():
    aProvider = Contract("0x4050eB90c15F27aa75b5CFcb934a26fDE60Cf9Cb")
    bProvider = Contract("0x580Ae3AeD3E8e8d83c970FA6D2766C0Fb8AF759F")
    rebalancer = Contract("0xD950Ded4ABC40412c896439bD6c2F38B17Ee78f3")
    balancerMathLib = Contract("0xFad59eDB20D1FFE60BB3feD124a4aaae1D225534")
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

    slippage_gain = 0
    if (arb_out > out_perfect):
        slippage_gain = (arb_out - out_perfect) / out_perfect * 100

    print(f'arber gained {slippage_gain}%')
    print(f'should tend? {slippage_gain > 0}')
