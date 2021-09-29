import time
from brownie import Contract, accounts, Wei, interface, chain
from datetime import datetime
from operator import xor
from brownie import ZERO_ADDRESS
import math
import os
import requests

def main():
    list_of_vaults = [
        Contract("0x36e7aF39b921235c4b01508BE38F27A535851a5c"),  # wftm_yVault_v32
        Contract("0x0DEC85e74A92c52b7F708c4B10207D9560CEFaf0"),  # wftm_yVault_v43
        Contract("0xEea0714eC1af3b0D41C624Ba5ce09aC92F4062b1"),  # ice_yVault_v32
        Contract("0x79330397e161C67703e9bce2cA2Db73937D5fc7e"),  # boo_yVault_v32
        Contract("0x1E9eC284BA99E14436f809291eBF7dC8CCDB12e1"),  # fusdt_yVault_v32
        Contract("0x6fCE944d1f2f877B3972e0E8ba81d27614D62BeD"),  # woofy_yVault_v32
        Contract("0x6864355183462A0ECA10b5Ca90BC89BB1361d3CB"),  # woofy_yVault_v43
        Contract("0x2C850cceD00ce2b14AA9D658b7Cad5dF659493Db"),  # yfi_yVault_v43
        Contract("0x3935486EE039B476241DA653baf06A8fc366e67F"),  # usdc_yVault_v43
    ]

    list_of_joints = [
        Contract("0x4BB56aA3e4d5A6434E53425A30070B6B03C7e83b"),  # iceJointOfWFTMICE
        Contract("0x08C5bd9832e57d67e25104c74d54DC279fB32507"),  # booJointOfWFTMBOO
        Contract("0x241de7CF5E2c2ba581E8499912A5CBb5de4A9d49"),  # spiritJointOfYFIWOOFY
        Contract("0xb3b545dAf579262dA4D232D89E7b7D08AaC23D00"),  # booJointOfFTMUSDC
    ]

    # oracles:
    spookyCalculations = Contract("0x9212e46786e05Ba0C0db547521B648493E2da2C1")

    # fixed epoch for non hedgil joints:
    fixed_epoch_days = 7

    # Enjoy:

    output = ["```"]

    list_of_providers = []
    for i in list_of_joints:
        a = i.providerA()
        b = i.providerB()

        list_of_providers.append(Contract(a))
        list_of_providers.append(Contract(b))

    while True:
        now = datetime.now()
        now_UNIX = int(now.strftime("%s"))

        output.append(f"\n{now.ctime()} - Fantom yVault and Joint Status:")

        for i in list_of_vaults:
            vault = i
            name = vault.name()
            version = vault.apiVersion()
            uninvested = Contract(vault.token()).balanceOf(vault) / (10 ** Contract(vault.token()).decimals())
            strategies = []
            for i in range(20):
                s = vault.withdrawalQueue(i)
                if s == ZERO_ADDRESS:
                    break

                strategies.append(Contract(s))
            buffer_strategies = {x for x in strategies if x not in list_of_providers}
            buffer_in_strategies = []
            for i in buffer_strategies:
                t = i.estimatedTotalAssets()

                buffer_in_strategies.append(t)
            avail_buffer = ((sum(buffer_in_strategies) + Contract(vault.token()).balanceOf(
                vault)) / vault.totalAssets()) * 100
            avail_ratio = 10_000 - vault.debtRatio()
            total_assets = vault.totalAssets() / (10 ** Contract(vault.token()).decimals())
            deposit_limit = vault.totalAssets() / vault.depositLimit() * 100 if vault.depositLimit() > 0 else 0
            total_assets_usdc = (spookyCalculations.getPriceUsdc(vault.token()) / 1e6) * (
                        vault.totalAssets() / (10 ** Contract(vault.token()).decimals()))

            output.append(
                f" {name} v{version}: uninvested: {uninvested:,.2f} | buffer: {avail_buffer:.0f}% ({avail_ratio}) | assets: {total_assets:,.2f} ({deposit_limit:.2f}%) - usd {total_assets_usdc:,.2f}")

        for i in list_of_joints:
            joint = i
            name = joint.name()
            providerA = Contract(joint.providerA())
            providerB = Contract(joint.providerB())
            vaultA = Contract(providerA.vault())
            vaultB = Contract(providerB.vault())
            tokenA = Contract(vaultA.token())
            tokenB = Contract(vaultB.token())
            reward = Contract(joint.reward())
            providerA_initial_capital = vaultA.strategies(providerA).dict()['totalDebt']
            providerB_initial_capital = vaultB.strategies(providerB).dict()['totalDebt']
            if providerA_initial_capital == 0 or providerB_initial_capital == 0:
                output.append(f"\n{name}: Inactive Joint")
            else:
                providerA_profit = joint.estimatedTotalAssetsAfterBalance()[
                                       0] + providerA.balanceOfWant() - providerA_initial_capital
                providerA_profit_usd = (providerA_profit / (10 ** tokenA.decimals())) * (
                            spookyCalculations.getPriceUsdc(tokenA.address) / 1e6)
                providerA_margin = providerA_profit / providerA_initial_capital
                providerB_profit = joint.estimatedTotalAssetsAfterBalance()[
                                       1] + providerB.balanceOfWant() - providerB_initial_capital
                providerB_profit_usd = (providerB_profit / (10 ** tokenB.decimals())) * (
                            spookyCalculations.getPriceUsdc(tokenB.address) / 1e6)
                providerB_margin = providerB_profit / providerB_initial_capital
                pending_reward = joint.pendingReward()
                pending_reward_usd = (pending_reward / (10 ** Contract(joint.reward()).decimals())) * (
                            spookyCalculations.getPriceUsdc(reward.address) / 1e6)
                impact_usd = ((providerA_profit_usd + providerB_profit_usd) - pending_reward_usd) * -1
                performance_impact = (
                                                 impact_usd / pending_reward_usd) * 100 if pending_reward_usd > 0 else 404  # reward not found
                last_harvest_UNIX = vaultA.strategies(providerA).dict()['lastReport']
                days_from_harvest = int((now_UNIX - last_harvest_UNIX) / 86400)
                hours_from_harvest = int((now_UNIX - last_harvest_UNIX - (days_from_harvest * 86400)) / 3600)
                exchange_rate_init = (vaultB.strategies(providerB).dict()['maxDebtPerHarvest'] / (
                            10 ** tokenB.decimals())) / (vaultA.strategies(providerA).dict()['maxDebtPerHarvest'] / (
                            10 ** tokenA.decimals()))
                exchange_rate_actual = ((spookyCalculations.getPriceUsdc(tokenA.address) / 1e6) * 1) / (
                            (spookyCalculations.getPriceUsdc(tokenB.address) / 1e6) * 1)
                if exchange_rate_init > exchange_rate_actual:
                    price_movement = ((exchange_rate_init - exchange_rate_actual) / exchange_rate_init) * 100
                elif exchange_rate_actual > exchange_rate_init:
                    price_movement = ((exchange_rate_actual - exchange_rate_init) / exchange_rate_init) * 100

                output.append(f"\n{name}:")
                output.append(
                    f"{tokenA.symbol()} invested: {providerA_initial_capital / (10 ** tokenA.decimals()):,.2f} - profit in USD: {providerA_profit_usd:,.2f} - profit/loss margin: ({providerA_margin * 100:.4f}%)")
                output.append(
                    f"{tokenB.symbol()} invested: {providerB_initial_capital / (10 ** tokenB.decimals()):,.2f} - profit in USD: {providerB_profit_usd:,.2f} - profit/loss margin: ({providerB_margin * 100:.4f}%)")
                output.append(
                    f"PendingRewardsUSD: {pending_reward_usd:,.2f} - impact over Rewards: ~{performance_impact:.2f}% | last hervest: {days_from_harvest}d, {hours_from_harvest}h ago")
                if not hasattr(joint, "hedgil"):
                    if providerA_margin < 0 or providerB_margin < 0:
                        output.append(
                            f"Exchange rate {tokenA.symbol()}:{tokenB.symbol()} init ({exchange_rate_init:,.2f}:1) | actual ({exchange_rate_actual:,.2f}:1) | price movement: {price_movement:,.2f}%")
                        output.append(f"Is everything ok? No, IL is bigger than rewards")
                    # elif boo_ftmBoo_ftm_gp >= 0 or boo_ftmBoo_boo_gp >= 0:
                    #     if boo_ftmBoo_days_from_harvest > fixed_epoch_days:
                    #         output.append(f"Is everything ok? Yes, it's time to HARVEST")
                    #     else:
                    #         output.append(f"Is everything ok? Yes")
                else:
                    hedgil = Contract(joint.hedgil())
                    hedgeId = joint.activeHedgeID()
                    if hedgeId == 0:
                        output.append(f"Hedgil is off or has expired")
                        if providerA_margin < 0 or providerB_margin < 0:
                            output.append(
                                f"Exchange rate {tokenA.symbol()}:{tokenB.symbol()} init ({exchange_rate_init:,.2f}:1) | actual ({exchange_rate_actual:,.2f}:1) | price movement: {price_movement:,.2f}%")
                            output.append(f"Is everything ok? No, IL is bigger than rewards")
                        # elif boo_ftmBoo_ftm_gp >= 0 or boo_ftmBoo_boo_gp >= 0:
                        #     if boo_ftmBoo_days_from_harvest > fixed_epoch_days:
                        #         output.append(f"Is everything ok? Yes, it's time to HARVEST")
                        else:
                            output.append(f"Is everything ok? Yes")
                    else:
                        hedgilInfo = hedgil.hedgils(hedgeId)
                        expriration_days = int((hedgilInfo[5] - now_UNIX) / 86400)
                        expiration_hours = int((hedgilInfo[5] - now_UNIX - (expriration_days * 86400)) / 3600)
                        if hedgilInfo[3] / (10 ** tokenA.decimals()) > exchange_rate_actual:
                            price_change = ((hedgilInfo[3] / (10 ** tokenA.decimals()) - exchange_rate_actual) /
                                            hedgilInfo[3] / (10 ** tokenA.decimals())) * 100
                        elif exchange_rate_actual > hedgilInfo[3] / (10 ** tokenA.decimals()):
                            price_change = ((exchange_rate_actual - hedgilInfo[3] / (10 ** tokenA.decimals())) / (
                                        hedgilInfo[3] / (10 ** tokenA.decimals()))) * 100

                        output.append(f"\n---- Hedgil ---- ")
                        output.append(f"Cost: {hedgilInfo[6] / (10 ** tokenB.decimals()):,.2f} {tokenB.symbol()}")
                        output.append(
                            f"Strike price: {hedgilInfo[3] / (10 ** tokenA.decimals()):,.2f} {tokenA.symbol()} | Actual price: {exchange_rate_actual:,.2f}")
                        output.append(f"\nMax price change: {hedgilInfo[4] / 100}% | Actual price change: {price_change:,.2f}%")
                        output.append(
                            f"Expiration date: {(datetime.utcfromtimestamp(hedgilInfo[5]).strftime('%Y-%m-%d %H:%M:%S'))} UTC - Expires in {expriration_days}d, {expiration_hours}h")

                        if price_change * 100 < hedgilInfo[4] and expiration_hours > 0:
                            output.append(f"Is everything ok? Yes")
                        elif price_change * 100 > hedgilInfo[4]:
                            output.append(f"Is everything ok? No, the price change is greater than our option")
                        elif expiration_hours > 0:
                            output.append(f"Is everything ok? No, hedgil has expired")

                time.sleep(1200)