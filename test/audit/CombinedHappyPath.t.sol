// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Bastion} from "src/Bastion.sol";
import {Call} from "src/types/Structs.sol";
import {AuditBase} from "./AuditBase.sol";

contract Mock {
    uint256 public bar;

    function foo() external {
        bar++;
    }
}

/// Official happy path: sign 100, consume 10 twice, mapping 90 then 80.
contract CombinedHappyPath is AuditBase {
    function setUp() external {
        _deployFactory(address(0));
    }

    function test_combined_officialHappyPath_100_90_80() public {
        (,,,, Bastion bastion) = _officialGrant();
        Mock m = new Mock();

        Call[] memory calls = new Call[](1);
        calls[0] = Call({to: address(m), value: 0, data: abi.encodeWithSelector(Mock.foo.selector)});

        vm.prank(owner);
        bastion.executeWithAllowance(calls, address(token), 10);

        assertEq(factory.allowance(owner, address(bastion), address(token)), SIGNED_AMOUNT - 10);
        assertEq(token.allowance(owner, address(factory)), ERC20_APPROVE - 10);
        assertEq(token.balanceOf(owner), MINTED - 10);
        assertEq(token.balanceOf(address(bastion)), 10);
        assertEq(m.bar(), 1);

        vm.prank(operator);
        bastion.executeWithAllowance(calls, address(token), 10);

        assertEq(factory.allowance(owner, address(bastion), address(token)), SIGNED_AMOUNT - 20);
        assertEq(token.allowance(owner, address(factory)), ERC20_APPROVE - 20);
        assertEq(token.balanceOf(owner), MINTED - 20);
        assertEq(token.balanceOf(address(bastion)), 20);
        assertEq(m.bar(), 2);
    }
}
