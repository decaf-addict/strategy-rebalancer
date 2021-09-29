import time
from brownie import Contract, accounts, Wei, interface, chain
from datetime import datetime
from operator import xor
from brownie import ZERO_ADDRESS
import math
import os
import requests
from enum import Enum

telegram_bot_key = "1996350881:AAHhWdmdG4kTFng0k94BYG_j8mPkRMGaYtE"
chat_id = "-1001553383497"


def main():
    send(chat_id, "\n".join(status("0xC0685ED3ACf4Ff688298240825128425287feEAD")))


def status(contract):
    rebalancer = Contract(contract)
    providerA = Contract(rebalancer.providerA())
    providerB = Contract(rebalancer.providerB())

    decA = 10 ** Contract(providerA.want()).decimals()
    decB = 10 ** Contract(providerB.want()).decimals()
    decValA = 10 ** (Contract(providerA.want()).decimals() + 8)
    decValB = 10 ** (Contract(providerB.want()).decimals() + 8)
    output = ["```"]
    output.append(f'{rebalancer.name()[0]}{rebalancer.name()[1]}: {contract}')
    output.append(f'{providerA.name()}: {providerA}')
    output.append(f'{providerB.name()}: {providerB}')
    output.append(f'ProviderA balance: {providerA.balanceOfWant() / decA}')
    output.append(f'ProviderB balance: {providerB.balanceOfWant() / decB}')
    output.append(f'Loose balanceA: {rebalancer.looseBalanceA() / decA}')
    output.append(f'Loose balanceB: {rebalancer.looseBalanceB() / decB}')
    output.append(f'Pooled balanceA: {rebalancer.pooledBalanceA() / decA}')
    output.append(f'Pooled balanceB: {rebalancer.pooledBalanceB() / decB}')
    output.append(f'priceA: {providerA.getPriceFeed() / 1e8}')
    output.append(f'priceB: {providerB.getPriceFeed() / 1e8}')
    output.append(f'valuePooledA: {providerA.getPriceFeed() * rebalancer.pooledBalanceA() / decValA}')
    output.append(f'valuePooledB: {providerB.getPriceFeed() * rebalancer.pooledBalanceB() / decValB}')
    output.append(f'WeightA: {rebalancer.currentWeightA() / 1e18}')
    output.append(f'WeightB: {rebalancer.currentWeightB() / 1e18}')
    output.append(f'LBP balance: {rebalancer.balanceOfLbp() / 1e18}')
    output.append(f'Bal balance: {rebalancer.balanceOfReward() / 1e18}')

    action = "Do nothing"
    if providerA.harvestTrigger(0) or providerB.harvestTrigger(0):
        action = "Harvest"
    elif rebalancer.currentWeightA() < 0.1 * 1e18:
        action = "Raise Debt Ratio"
    elif rebalancer.currentWeightA() > 0.9 * 1e18:
        action = "Lower Debt Ratio"
    output.append(f'\nRecommended action: {action}')
    output.append("```")
    return output


def send(chat_id, text):
    payload = {"chat_id": chat_id, "text": text, "parse_mode": "MarkdownV2"}
    r = requests.get(
        "https://api.telegram.org/bot" + telegram_bot_key + "/sendMessage",
        params=payload,
    )

    print(r.content)
    print(r.text)
    print(r.headers)
