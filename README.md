## Stablecoins

A stable coin is a type of crypto currency whose "buying power" (or value) doesn't change much. It is less volatile as compared to other crypto like Bitcoin, Ether, Polygon etc.

### Different Types of Stable coins

1. **Pegged stable coin**: pegged to a more stable asset like US Dollar

2. **Floating stable coin**: use an algorithm to maintain a constant buying power

3. **Governed stable coin**: kinda centralized as minted/burned by a governing body. ex: USDC , DAI

4. **Algorithmic stable coin**: algorithm maintains stability without any human intervention. ex:DAI, FRX, RAI, UST

In context of stablecoins, **collateral** is an asset that is backing that stable coin. In case if stablecoin fails and the collateral also fails, then it is called as **Endogenous collateral**.

In case of endogenous collateral, the collateral is created specifically by the protocol to serve as a collateral and it can be that protocol owns the issue of underlying collateral.

Example of Endogenous collateral: USDC[USD], DAI[ETH]

In case failure of stablecoin doesn't automatically lead to failure of collateral, that is an **Exogenous collateral**. Exogenous collateral originates outside the protocol.

Example of Exogenous collateral: UST[Luna]

#### In this project we'll be developing a stablecoin with the following properties:

1. _Relative Stability: Pegged or Anchored to USD_
2. _Stability Mechanism: Algorithmic(Decentralized)_
   1. People can only mint the stablecoin with enough collateral(coded in smart contract)
3. _Collateral: Exogenous(Crypto)_
   1. wETH - ERC20 version of ETH
   2. wBTC - ERC20 version of BTC
