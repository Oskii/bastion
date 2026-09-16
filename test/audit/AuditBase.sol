// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {Bastion} from "src/Bastion.sol";
import {BastionFactory} from "src/BastionFactory.sol";
import {Approval} from "src/types/Structs.sol";

contract MockERC20 is ERC20 {
    function name() public pure override returns (string memory) {
        return "Mock";
    }

    function symbol() public pure override returns (string memory) {
        return "MOCK";
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }
}

abstract contract AuditBase is Test {
    uint256 internal constant MINTED = 10_000;
    uint256 internal constant ERC20_APPROVE = 5_000;
    uint256 internal constant SIGNED_AMOUNT = 100;
    uint256 internal constant PARTIAL = 10;

    BastionFactory internal factory;
    MockERC20 internal token;
    address internal owner;
    uint256 internal ownerKey;
    address internal operator;
    uint256 internal operatorKey;
    address internal attacker;

    function _deployFactory(address ep) internal {
        factory = new BastionFactory(ep);
        (owner, ownerKey) = makeAddrAndKey("Owner");
        (operator, operatorKey) = makeAddrAndKey("Opeartor");
        attacker = makeAddr("attacker");
        token = new MockERC20();
    }

    function _baseApproval() internal view returns (Approval memory approval) {
        approval = Approval({
            operator: abi.encodePacked(operator),
            token: address(token),
            amount: SIGNED_AMOUNT,
            domain: keccak256(abi.encodePacked("https://dashboard.zerodev.app")),
            salt: bytes32(0)
        });
    }

    function _grind(Approval memory approval)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s, address session, Approval memory out)
    {
        out = approval;
        session = address(0);
        while (session == address(0)) {
            out.salt = keccak256(abi.encodePacked(out.salt));
            (v, r, s) = vm.sign(ownerKey, factory.getDigest(out));
            session = factory.getBastionAddress(block.chainid, v, r, s);
        }
    }

    function _attach(uint8 v, bytes32 r, bytes32 s) internal {
        VmSafe.SignedDelegation memory auth = VmSafe.SignedDelegation({
            v: v - 27,
            r: r,
            s: s,
            nonce: uint64(0),
            implementation: address(factory.impl())
        });
        vm.attachDelegation(auth);
    }

    function _fundOwner() internal {
        token.mint(owner, MINTED);
        vm.prank(owner);
        token.approve(address(factory), ERC20_APPROVE);
    }

    function _officialGrant()
        internal
        returns (uint8 v, bytes32 r, bytes32 s, Approval memory approval, Bastion bastion)
    {
        _fundOwner();
        approval = _baseApproval();
        address session;
        (v, r, s, session, approval) = _grind(approval);
        _attach(v, r, s);
        factory.checkSig(approval, block.chainid, v, r, s);
        bastion = Bastion(session);
        assertEq(bastion.owner(), owner);
        assertEq(factory.allowance(owner, session, address(token)), SIGNED_AMOUNT);
        assertTrue(factory.usedDigest(factory.getDigest(approval)));
    }
}
