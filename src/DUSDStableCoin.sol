// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { ERC20, ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract DUSD is ERC20Burnable, Ownable {
    error DUSD__NotEnoughBalance();
    error DUSD__MustBeMoreThanZero();
    error DUSD__AddressZero();

    constructor() ERC20("DUSDStableCoin", "DUSD") Ownable(msg.sender) { }

    function burn(uint256 amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);

        if (balance <= 0) {
            revert DUSD__MustBeMoreThanZero();
        } else if (balance < amount) {
            revert DUSD__NotEnoughBalance();
        }

        super.burn(amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            // Hypotheticall unreachable due to ERC20.ERC20InvalidApprover
            revert DUSD__AddressZero();
        } else if (_amount <= 0) {
            revert DUSD__MustBeMoreThanZero();
        }

        _mint(_to, _amount);
        return true;
    }
}
