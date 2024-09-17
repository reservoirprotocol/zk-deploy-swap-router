// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Ownable} from "solady/src/auth/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAllowanceTransfer} from "permit2-relay/src/interfaces/IAllowanceTransfer.sol";
import {ISignatureTransfer} from "permit2-relay/src/interfaces/ISignatureTransfer.sol";
import {IPermit2} from "permit2-relay/src/interfaces/IPermit2.sol";
import {IMulticaller} from "./interfaces/IMulticaller.sol";

struct RelayerWitness {
    address relayer;
}

contract ERC20Router is Ownable {
    using SafeERC20 for IERC20;

    // --- Errors --- //

    /// @notice Revert if array lengths do not match
    error ArrayLengthsMismatch();

    /// @notice Revert if this contract is set as the recipient
    error InvalidRecipient(address recipient);

    /// @notice Revert if the native transfer failed
    error NativeTransferFailed();

    IPermit2 private immutable PERMIT2;
    address private immutable MULTICALLER;

    string public constant _RELAYER_WITNESS_TYPE_STRING =
        "RelayerWitness witness)RelayerWitness(address relayer)TokenPermissions(address token,uint256 amount)";
    bytes32 public constant _EIP_712_RELAYER_WITNESS_TYPE_HASH =
        keccak256("RelayerWitness(address relayer)");

    constructor(address permit2, address multicaller, address owner) {
        // Set the address of the Permit2 contract
        PERMIT2 = IPermit2(permit2);

        // Set the address of the multicaller contract
        MULTICALLER = multicaller;

        // Set the owner that can withdraw funds stuck in the contract
        _initializeOwner(owner);
    }

    receive() external payable {}

    function withdraw() external onlyOwner {
        _send(msg.sender, address(this).balance);
    }

    /// @notice Pull user ERC20 tokens through a signed batch permit
    ///         and perform an arbitrary multicall. Pass in an empty
    ///         permitSignature to only perform the multicall.
    /// @dev msg.value will persist across all calls in the multicall
    /// @param user The address of the user
    /// @param permit The permit details
    /// @param targets The addresses of the contracts to call
    /// @param datas The calldata for each call
    /// @param values The value to send with each call
    /// @param refundTo The address to refund any leftover ETH to
    /// @param permitSignature The signature for the permit
    function permitMulticall(
        address user,
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        address[] calldata targets,
        bytes[] calldata datas,
        uint256[] calldata values,
        address refundTo,
        bytes memory permitSignature
    ) external payable returns (bytes memory) {
        // Revert if array lengths do not match
        if (targets.length != datas.length || datas.length != values.length) {
            revert ArrayLengthsMismatch();
        }

        if (permitSignature.length != 0) {
            // Use permit to transfer tokens from user to router
            _handlePermitBatch(user, permit, permitSignature);
        }

        // Perform the multicall and send leftover to refundTo
        bytes memory data = _delegatecallMulticall(
            targets,
            datas,
            values,
            refundTo
        );

        return data;
    }

    /// @notice Call the Multicaller with a delegatecall to set the ERC20Router as the
    ///         sender of the calls to the targets.
    /// @dev    If a multicall is expecting to mint ERC721s or ERC1155s, the recipient must be explicitly set
    ///         All calls to ERC721s and ERC1155s in the multicall will have the same recipient set in refundTo
    ///         If refundTo is address(this), be sure to transfer tokens out of the router as part of the multicall
    /// @param targets The addresses of the contracts to call
    /// @param datas The calldata for each call
    /// @param values The value to send with each call
    /// @param refundTo The address to send any leftover ETH and set as recipient of ERC721/ERC1155 mints
    function delegatecallMulticall(
        address[] calldata targets,
        bytes[] calldata datas,
        uint256[] calldata values,
        address refundTo
    ) external payable returns (bytes memory) {
        // Revert if array lengths do not match
        if (targets.length != datas.length || datas.length != values.length) {
            revert ArrayLengthsMismatch();
        }

        // Perform the multicall
        bytes memory data = _delegatecallMulticall(
            targets,
            datas,
            values,
            refundTo
        );

        return data;
    }

    /// @notice Send leftover ERC20 tokens to the refundTo address
    /// @dev Should be included in the multicall if the router is expecting to receive tokens
    /// @param token The address of the ERC20 token
    /// @param refundTo The address to refund the tokens to
    function cleanupERC20(address token, address refundTo) external {
        // Check the router's balance for the token
        uint256 balance = IERC20(token).balanceOf(address(this));

        // Transfer the token to the refundTo address
        if (balance > 0) {
            IERC20(token).safeTransfer(refundTo, balance);
        }
    }

    /// @notice Internal function to handle a permit batch transfer
    /// @param user The address of the user
    /// @param permit The permit details
    /// @param permitSignature The signature for the permit
    function _handlePermitBatch(
        address user,
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        bytes memory permitSignature
    ) internal {
        // Create the witness that should be signed over
        bytes32 witness = keccak256(
            abi.encode(_EIP_712_RELAYER_WITNESS_TYPE_HASH, msg.sender)
        );

        // Create the SignatureTransferDetails array
        ISignatureTransfer.SignatureTransferDetails[]
            memory signatureTransferDetails = new ISignatureTransfer.SignatureTransferDetails[](
                permit.permitted.length
            );
        for (uint256 i = 0; i < permit.permitted.length; i++) {
            uint256 amount = permit.permitted[i].amount;

            signatureTransferDetails[i] = ISignatureTransfer
                .SignatureTransferDetails({
                    to: address(this),
                    requestedAmount: amount
                });
        }

        // Use the SignatureTransferDetails and permit signature to transfer tokens to the router
        PERMIT2.permitWitnessTransferFrom(
            permit,
            signatureTransferDetails,
            // When using a permit signature, cannot deposit on behalf of someone else other than `user`
            user,
            witness,
            _RELAYER_WITNESS_TYPE_STRING,
            permitSignature
        );
    }

    /// @notice Internal function to delegatecall the Multicaller contract
    /// @param targets The addresses of the contracts to call
    /// @param datas The calldata for each call
    /// @param values The value to send with each call
    /// @param refundTo The address to send any leftover ETH and set as recipient of ERC721/ERC1155 mints
    function _delegatecallMulticall(
        address[] calldata targets,
        bytes[] calldata datas,
        uint256[] calldata values,
        address refundTo
    ) internal returns (bytes memory) {
        // Perform the multicall and refund to the user
        (bool success, bytes memory data) = MULTICALLER.delegatecall(
            abi.encodeWithSignature(
                "aggregate(address[],bytes[],uint256[],address)",
                targets,
                datas,
                values,
                refundTo
            )
        );

        if (!success) {
            assembly {
                let returnDataSize := mload(data)
                revert(add(data, 32), returnDataSize)
            }
        }

        return data;
    }

    function _send(address to, uint256 value) internal {
        bool success;
        assembly {
            // Save gas by avoiding copying the return data to memory.
            // Provide at most 100k gas to the internal call, which is
            // more than enough to cover common use-cases of logic for
            // receiving native tokens (eg. SCW payable fallbacks).
            success := call(100000, to, value, 0, 0, 0, 0)
        }

        if (!success) {
            revert NativeTransferFailed();
        }
    }
}
