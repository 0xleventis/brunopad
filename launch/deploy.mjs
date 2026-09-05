import 'dotenv/config';
import { Clanker } from 'clanker-sdk/v4';
import { robinhood } from 'clanker-sdk';
import { createPublicClient, createWalletClient, http, formatEther, parseEther } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const LAUNCHPAD_FEE_ETH = process.env.LAUNCHPAD_FEE_ETH ?? '0';
const TREASURY_ADDRESS = process.env.TREASURY_ADDRESS;
const LAUNCHPAD_NAME = process.env.LAUNCHPAD_NAME ?? 'Robinhood Launchpad';

async function main() {
  const account = privateKeyToAccount(process.env.PRIVATE_KEY);

  const publicClient = createPublicClient({
    chain: robinhood,
    transport: http(process.env.RPC_URL),
  });

  const walletClient = createWalletClient({
    account,
    chain: robinhood,
    transport: http(process.env.RPC_URL),
  });

  const feeWei = parseEther(LAUNCHPAD_FEE_ETH);
  const chargeFee = feeWei > 0n && TREASURY_ADDRESS && TREASURY_ADDRESS.toLowerCase() !== account.address.toLowerCase();

  const balance = await publicClient.getBalance({ address: account.address });
  console.log(`Deployer: ${account.address}`);
  console.log(`Balance:  ${formatEther(balance)} ETH on Robinhood Chain (chainId ${robinhood.id})`);
  if (feeWei > 0n) {
    console.log(`Launchpad fee: ${LAUNCHPAD_FEE_ETH} ETH -> ${TREASURY_ADDRESS}${chargeFee ? '' : ' (skipped: treasury == deployer, self-transfer would just burn gas)'}`);
  }

  if (balance === 0n) {
    console.error('\nBalance is 0. Fund this address with ETH on Robinhood Chain mainnet before deploying.');
    process.exitCode = 1;
    return;
  }

  if (chargeFee && balance <= feeWei) {
    console.error(`\nBalance (${formatEther(balance)} ETH) must exceed the launchpad fee (${LAUNCHPAD_FEE_ETH} ETH) plus gas.`);
    process.exitCode = 1;
    return;
  }

  const clanker = new Clanker({ wallet: walletClient, publicClient });

  const name = process.argv[2] ?? 'Test Token';
  const symbol = process.argv[3] ?? 'TEST';

  if (chargeFee) {
    console.log(`\nCharging launchpad fee: ${LAUNCHPAD_FEE_ETH} ETH -> ${TREASURY_ADDRESS}`);
    const feeTxHash = await walletClient.sendTransaction({ to: TREASURY_ADDRESS, value: feeWei });
    await publicClient.waitForTransactionReceipt({ hash: feeTxHash });
    console.log(`Fee tx confirmed: ${feeTxHash}`);
  }

  const treasuryForRewards = TREASURY_ADDRESS ?? account.address;

  console.log(`\nDeploying "${name}" (${symbol}) on Robinhood Chain...`);
  console.log(`Trading fee split: 70% creator (${account.address}) / 30% treasury (${treasuryForRewards})`);

  const { txHash, waitForTransaction, error } = await clanker.deploy({
    name,
    symbol,
    image: '',
    tokenAdmin: account.address,
    chainId: robinhood.id,
    vanity: true,
    context: {
      interface: LAUNCHPAD_NAME,
    },
    rewards: {
      recipients: [
        { admin: account.address, recipient: account.address, bps: 7000, token: 'Both' },
        { admin: treasuryForRewards, recipient: treasuryForRewards, bps: 3000, token: 'Both' },
      ],
    },
  });

  if (error) {
    console.error('Deploy call failed:', error);
    process.exitCode = 1;
    return;
  }

  console.log(`Tx submitted: ${txHash}`);
  const { address, error: txError } = await waitForTransaction();

  if (txError) {
    console.error('Transaction failed:', txError);
    process.exitCode = 1;
    return;
  }

  console.log(`\n✅ Token deployed at: ${address}`);
  console.log(`Explorer: https://robinhoodchain.blockscout.com/address/${address}`);
}

main();
