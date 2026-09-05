# Brunopad contracts

A real fork of [Clanker v4](https://github.com/clanker-devco/v4-contracts)'s protocol (MIT licensed) —
factory, fee locker, hooks, LP lockers, MEV modules, extensions — deployed as Brunopad's own,
independently-owned instance rather than calling Clanker's shared, already-live deployment (which is what
`../launch/deploy.mjs`'s `clanker-sdk` call does today).

Every `Clanker*`/`IClanker*` file and identifier in the vendored source was renamed to `Bruno*`/`IBruno*` —
this is meant to be a Bruno-branded launchpad, not a visibly-Clanker one, and the original names would
otherwise show up as the "Contract Name" on any block explorer once these are verified. This README still
says "Clanker" wherever it's genuinely talking about the real upstream project (what this was forked from,
whose live contracts some addresses/reads below point at) — only the actual code identifiers changed.

## Setup

`contracts/lib/` is gitignored (Foundry dependency clones, not vendored) and must be fetched at the exact
commits Clanker's own real upstream repo pins — these versions are known to compile this source
successfully (confirmed live: the real `clanker-devco/v4-contracts` `.gitmodules` lists these same SHAs).
Different versions may not compile, or may compile to different bytecode.

```sh
mkdir -p lib && cd lib

git clone --depth 1 https://github.com/foundry-rs/forge-std
git clone --depth 1 https://github.com/Uniswap/v4-core
git clone --depth 1 https://github.com/Uniswap/v4-periphery
git clone --depth 1 https://github.com/openzeppelin/openzeppelin-contracts
git clone --depth 1 https://github.com/Uniswap/universal-router
git clone --depth 1 https://github.com/Uniswap/permit2

# Pin each to Clanker's own exact commit (fetch+checkout since --depth 1 has no history for these SHAs):
for pair in "forge-std:77041d2ce690e692d6e03cc812b57d1ddaa4d505" \
            "openzeppelin-contracts:a7d38c7a3321e3832ca84f7ba1125dff9a91361e" \
            "permit2:cc56ad0f3439c502c246fc5cfcc3db92bb8b7219" \
            "universal-router:3663f6db6e2fe121753cd2d899699c2dc75dca86" \
            "v4-core:5f00c8416c19a7e6a5a5d0539fad30fd124f7b86" \
            "v4-periphery:9628c36b4f5083d19606e63224e4041fe748edae"; do
  name="${pair%%:*}"; sha="${pair##*:}"
  (cd "$name" && git fetch --depth 1 origin "$sha" && git checkout "$sha")
done

# optimism is a huge monorepo — only ClankerToken.sol's superchain-bridging interfaces are needed, so this
# sparse-checks-out just those two subdirectories instead of the whole thing.
mkdir optimism && cd optimism
git init -q && git remote add origin https://github.com/ethereum-optimism/optimism
git config core.sparseCheckout true
echo "packages/contracts-bedrock/interfaces/" >> .git/info/sparse-checkout
echo "packages/contracts-bedrock/src/libraries/" >> .git/info/sparse-checkout
git fetch --depth 1 origin 0a6bb1c16fc24d71680a09a93484bfb52f4e592a
git checkout FETCH_HEAD
cd ../..

forge build
```

### `remappings.txt`'s extra `permit2/=lib/permit2/` line

Foundry auto-discovers a `permit2/=lib/permit2/src/` remapping from permit2's own project config, which is
wrong for this codebase — `v4-periphery` imports `permit2/src/interfaces/IAllowanceTransfer.sol`, and that
auto-discovered mapping doubles the `src/` segment. The explicit line in `remappings.txt` overrides it.

### Why `optimizer_runs = 1`, not Clanker's own `200`

Building with Clanker's own real settings (confirmed via their verified `ClankerLpLockerFeeConversion` —
now `BrunoLpLockerFeeConversion` post-rename, identical source otherwise — on Robinhood Chain: solc 0.8.28,
viaIR, `optimizer.runs: 200`, `bytecodeHash: none`) still compiles this vendored source to a *larger*
`BrunoLpLockerFeeConversion` than Clanker's real deployment (24,529 bytes vs. their live 24,150) — likely a
subtle difference in exactly which historical commit of an upstream dependency their real deployment was
built against vs. what's pinned above. `runs = 200` still fits under EIP-170's
24,576-byte limit, but with only 47 bytes of headroom — too fragile for a setting anyone could accidentally
tip over later. `runs = 1` buys real margin (141 bytes) at the cost of somewhat higher runtime gas on the
locker's own functions, an acceptable tradeoff for a contract that's deployed once and not
called with the frequency a hot-path contract would be.

## Deploying

`script/DeployBrunopad.s.sol` deploys a fresh factory + fee locker + pool-extension allowlist + hook + LP
locker (each address read directly from Clanker's own live Robinhood Chain deployment via RPC — see the
script's own header comment), reusing Clanker's existing MEV module as-is (it has no constructor and no
factory-binding, confirmed by reading its source, so it's generic infrastructure safe to share).

Dry run first (no `--broadcast`, no cost) to confirm it still simulates cleanly against current chain state.
`--sender` matters here even without broadcasting: the wiring calls (`setHook`, `setLocker`,
`setMevModule`) are `onlyOwner`, and without an explicit sender `forge script` simulates as its own
arbitrary placeholder address instead of the real `OWNER` — reverting with `Unauthorized()` even though
nothing is actually wrong (confirmed live: this is exactly what happened omitting it). The real broadcast
below doesn't need this flag since `--private-key` already fixes the sender to the right address.

```sh
forge script script/DeployBrunopad.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --sender 0xdb5FbCd6fb5C46F6F52B62ACAE333a3AE0b0F108 -vvvv
```

Then, run by whoever holds the `OWNER` address's private key (currently hardcoded in the script as
`0xdb5FbCd6fb5C46F6F52B62ACAE333a3AE0b0F108` — never pass a private key through anything other than your own
local environment):

```sh
forge script script/DeployBrunopad.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --broadcast --private-key $PRIVATE_KEY -vvvv
```

Fund that address with at least ~0.03 ETH on Robinhood Chain first for margin — dry runs have estimated
anywhere from ~0.02 to ~0.025 ETH total gas for all 5 deployments + 4 wiring calls, depending on the
network's gas price at the time.

After a successful broadcast, save the 5 deployed addresses it logs (factory, fee locker, allowlist, hook,
LP locker) — the Hoodbrunos frontend's `/launch` page needs the factory address to call `deployToken` on.
