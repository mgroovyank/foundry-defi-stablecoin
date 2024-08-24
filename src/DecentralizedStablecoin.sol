// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

//since ERC20Burnable implements ERC20, I'm able to import ERC20 here
import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Decentralized Stablecoin
 * @author Mayank Chhipa
 * @notice This is a decentralized stable coin contract
 * Relative Stability: Pegged to USD
 * Stability Mechanism: Algorithmic(Decentralized)
 * Collateral: Exogenous(BTC, ETH)
 *
 * This contract is governed by DSC Engine. This contract is just the ERC20 implementation of our stablecoin system.
 */
contract DecentralizedStablecoin is ERC20Burnable, Ownable {
    error DecentralizedStablecoin__BalanceMustBeMoreThanZero();
    error DecentralizedStablecoin__BurnAmountExceedsBalance();
    error DecentralizedStablecoin__ZeroAddress();
    error DecentralizedStablecoin__MintAmountMustBeMoreThanZero();

    constructor() ERC20("DecentralizedStablecoin", "DSC") Ownable(msg.sender) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentralizedStablecoin__BalanceMustBeMoreThanZero();
        }
        if (_amount > balance) {
            revert DecentralizedStablecoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStablecoin__ZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralizedStablecoin__MintAmountMustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
