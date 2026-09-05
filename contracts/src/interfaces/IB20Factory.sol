// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal interface for Base's own B-20 standard factory — a real, permissionless system
///         contract at a fixed address (0xB20f000000000000000000000000000000000000 on Base mainnet),
///         not something this codebase deploys or controls. Every token it mints gets a real
///         `0xb20...`-prefixed address. Trimmed to just what BrunoB20Deployer needs; see Base's own
///         `base-std` library (`lib/base-std/src/interfaces/IB20Factory.sol` and `IB20.sol` in the
///         verified source of 0x1176122eb77ad6a2339322cda7c4d7ea9bfa63dc on Basescan) for the full
///         surface, including the token-side ABI (mint/burn/pause/roles) that `initCalls` below target.
interface IB20Factory {
    /// @notice Which canonical token implementation `params`/`initCalls` target. Encoded in the
    ///         resulting token's own address (byte [10]) by the factory itself — not something a caller
    ///         chooses independently of `variant`.
    enum B20Variant {
        ASSET,
        STABLECOIN
    }

    /// @notice Deploys a new B-20 token deterministically from `(variant, msg.sender, salt)`, then runs
    ///         `initCalls` against it in the same transaction while still inside the creation
    ///         ("bootstrap") window — the only time `params.initialAdmin` can call admin/mint-gated
    ///         functions on it without an explicit `grantRole` first (confirmed against a real, live
    ///         createB20 call on Base mainnet, see BrunoB20Deployer.sol's own header).
    /// @param variant   ASSET or STABLECOIN — decides how `params` is decoded.
    /// @param salt      Caller-chosen salt for deterministic address derivation.
    /// @param params    ABI-encoded, variant-specific creation struct, leading with a version byte.
    ///                  For ASSET: abi.encode(uint8 version, string name, string symbol,
    ///                  address initialAdmin, uint8 decimals).
    /// @param initCalls Bootstrap calls run against the new token right after creation.
    /// @return token The address of the newly created token.
    function createB20(B20Variant variant, bytes32 salt, bytes calldata params, bytes[] calldata initCalls)
        external
        payable
        returns (address token);

    /// @notice Predicts the address `createB20` would assign for `(variant, sender, salt)` — a real,
    ///         permissionless view call confirmed to work for any sender, not just Base's own
    ///         registered issuers.
    function getB20Address(B20Variant variant, address sender, bytes32 salt) external view returns (address);

    /// @notice Whether `token` was created by this factory.
    function isB20(address token) external view returns (bool);

    /// @notice Whether `token`'s `createB20` call has finished running (flips exactly once).
    function isB20Initialized(address token) external view returns (bool);
}
