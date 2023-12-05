// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract StableCoin is ERC20Burnable, Ownable {
    error StableCoin__NotZeroAddress();
    error StableCoin__CannotBurnZeroAmount();
    error StableCoin__AmountExceedsBalance();
    error StableCoin__MustBeMoreThanZero();

    event MintedCoin(address indexed to, uint256 indexed amount);
    event BurnedCoin(uint256 indexed amount);

    constructor() ERC20("StableCoin", "SC") {}

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        // Checks
        if (_to == address(0)) {
            revert StableCoin__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert StableCoin__MustBeMoreThanZero();
        }

        // Effects
        _mint(_to, _amount);

        // Interactions
        emit MintedCoin(_to, _amount);
        return true;
    }

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        // Checks
        if (_amount == 0) {
            revert StableCoin__CannotBurnZeroAmount();
        }
        if (balance < _amount) {
            revert StableCoin__AmountExceedsBalance();
        }

        // Effects
        super.burn(_amount);

        // Interactions
        emit BurnedCoin(_amount);
    }
}
