// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Bastion} from "src/Bastion.sol";
import {PackedUserOperation} from "src/types/Structs.sol";
import {AuditBase} from "./AuditBase.sol";

/// B05: after a good sig, missingAccountFunds is sent to msg.sender (EntryPoint).
contract B05_PrefundPosted is AuditBase {
    uint256 internal constant MISSING = 1 ether;
    uint256 internal constant PREFUND_ON_ACCOUNT = 5 ether;

    MockEntryPoint internal ep;

    function setUp() external {
        ep = new MockEntryPoint();
        _deployFactory(address(ep));
    }

    function test_B05_goodSigPostsMissingAccountFundsToEntryPoint() public {
        (,,,, Bastion bastion) = _officialGrant();
        vm.deal(address(bastion), PREFUND_ON_ACCOUNT);

        bytes32 userOpHash = keccak256("patched-b05");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorKey, userOpHash);
        PackedUserOperation memory userOp;
        userOp.sender = address(bastion);
        userOp.signature = abi.encodePacked(r, s, v);

        uint256 accountBefore = address(bastion).balance;
        uint256 epBefore = address(ep).balance;
        uint256 depositBefore = ep.depositOf(address(bastion));

        vm.prank(address(ep));
        uint256 validationData = bastion.validateUserOp(userOp, userOpHash, MISSING);

        assertEq(validationData, 0);
        assertEq(address(bastion).balance, accountBefore - MISSING);
        assertTrue(
            address(ep).balance == epBefore + MISSING || ep.depositOf(address(bastion)) == depositBefore + MISSING,
            "B05: EntryPoint must receive wei or increase deposit"
        );
        assertEq(address(ep).balance, epBefore + MISSING);
        assertEq(ep.depositOf(address(bastion)), depositBefore + MISSING);
    }

    function test_B05_failedSigDoesNotPostPrefund() public {
        (,,,, Bastion bastion) = _officialGrant();
        vm.deal(address(bastion), PREFUND_ON_ACCOUNT);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorKey, keccak256("other-hash"));
        PackedUserOperation memory userOp;
        userOp.sender = address(bastion);
        userOp.signature = abi.encodePacked(r, s, v);

        vm.prank(address(ep));
        uint256 validationData = bastion.validateUserOp(userOp, keccak256("patched-b05"), MISSING);

        assertEq(validationData, 1);
        assertEq(address(bastion).balance, PREFUND_ON_ACCOUNT);
        assertEq(ep.depositOf(address(bastion)), 0);
    }
}

contract MockEntryPoint {
    mapping(address => uint256) public depositOf;

    receive() external payable {
        depositOf[msg.sender] += msg.value;
    }
}
