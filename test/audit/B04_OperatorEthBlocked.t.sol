// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Bastion} from "src/Bastion.sol";
import {Call} from "src/types/Structs.sol";
import {AuditBase} from "./AuditBase.sol";

/// B04: operator Call.value > 0 reverts EthNotAllowed. Owner can still send value.
contract B04_OperatorEthBlocked is AuditBase {
    uint256 internal constant SESSION_ETH = 5 ether;

    function setUp() external {
        _deployFactory(address(0));
    }

    function test_B04_operatorValueRevertsEthNotAllowed() public {
        (,,,, Bastion bastion) = _officialGrant();
        vm.deal(address(bastion), SESSION_ETH);
        uint256 attackerBefore = attacker.balance;

        Call[] memory calls = new Call[](1);
        calls[0] = Call({to: attacker, value: SESSION_ETH, data: ""});

        vm.prank(operator);
        vm.expectRevert(Bastion.EthNotAllowed.selector);
        bastion.executeWithAllowance(calls, address(token), 0);

        assertEq(address(bastion).balance, SESSION_ETH);
        assertEq(attacker.balance, attackerBefore);
    }

    function test_B04_operatorValueRevertsEvenWithTokenConsume() public {
        (,,,, Bastion bastion) = _officialGrant();
        vm.deal(address(bastion), SESSION_ETH);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({to: attacker, value: 1 ether, data: ""});

        vm.prank(operator);
        vm.expectRevert(Bastion.EthNotAllowed.selector);
        bastion.executeWithAllowance(calls, address(token), 1);

        assertEq(address(bastion).balance, SESSION_ETH);
        assertEq(token.balanceOf(address(bastion)), 0);
    }

    function test_B04_ownerCanSendValue() public {
        (,,,, Bastion bastion) = _officialGrant();
        vm.deal(address(bastion), SESSION_ETH);
        uint256 attackerBefore = attacker.balance;

        Call[] memory calls = new Call[](1);
        calls[0] = Call({to: attacker, value: 2 ether, data: ""});

        vm.prank(owner);
        bastion.executeWithAllowance(calls, address(token), 0);

        assertEq(address(bastion).balance, SESSION_ETH - 2 ether);
        assertEq(attacker.balance, attackerBefore + 2 ether);
    }
}
