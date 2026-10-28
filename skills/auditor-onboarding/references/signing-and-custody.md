# Signing and custody

Use this flow for any publication, metadata, mapping, issuance, revocation, or
capability transfer. Verify current CLI help; never use a local private key to
impersonate an external owner.

## Choose owners before publishing

| Object | Authority | Network |
| --- | --- | --- |
| UpgradeCap | Change the auditor package's code within its upgrade policy | Auditor deployment network |
| AuditAdminCap | Issue and revoke that auditor's claims | Auditor deployment network |
| PackageInfo | Manage source and package metadata | Auditor deployment network |
| MVR AppCap | Manage the company's registered package name | Mainnet |
| SuiNS registration | Control the company's namespace; track its renewal | Mainnet |

Recommend an independently controlled multisig, such as 2-of-3, for production
capabilities. The user chooses participants, threshold, and operational custody;
do not invent a multisig address. A single key is supported if the user accepts
its compromise/loss risk. Multisig protection of UpgradeCap alone does not
protect an AuditAdminCap left in a hot wallet. Consider source metadata custody
as well, because misleading metadata can harm readers without changing code.

Publish directly with the chosen owner as sender when practical, or transfer
capabilities after verifying recipient control. Create PackageInfo while the
UpgradeCap is available, or have its custodian sign that step. Do not destroy
the UpgradeCap as a shortcut before metadata creation.

For a transfer, verify the current owner/type on-chain and use an approved PTB
`--transfer-objects` for UpgradeCap/AuditAdminCap/AppCap. **PackageInfo is
key-only:** use `package_info::transfer`, not generic public transfer. Simulate,
show the destination to the user, request approval, then verify the resulting
owner. Do not share the capabilities or send them to an unverified address.
Record the current signer and any future custody destination separately. A
planned recipient cannot sign for objects still owned by the current custodian.
Gas sponsorship pays fees; it does not authorize another wallet's owned inputs.

## Build unsigned bytes for custody

For a PTB, set `--sender "@$TX_SENDER"` to the actual capability owner and use
`--serialize-unsigned-transaction`. For `sui client publish`, use
`--sender "$TX_SENDER"` and the same serialization flag. Do not use
`--serialize-signed-transaction` without a local signer.

Set `TX_NETWORK` for this operation explicitly. It is **mainnet for MVR naming**,
even if the package being named is on testnet. Use a distinct output directory
`TX_DIR` per operation, outside source control. For this flow, select an explicit
SUI gas coin and budget: add `--gas-coin "@$GAS_COIN" --gas-budget "$GAS_BUDGET"`
to PTBs, or `--gas "$GAS_COIN" --gas-budget "$GAS_BUDGET"` to `publish`.
This recipe supports **sender-funded transactions only**: require the gas coin's
owner to equal `TX_SENDER`, and verify its balance, version, and digest. Stop if
the operation requires a separate gas sponsor. The verification command below
checks only the sender's signature, and the submission recipe supplies only that
signature; it does not implement sponsored signing.

With CLI 1.82.1, address-balance-funded transactions produced different saved-byte,
simulation, and execution digests in an observed rollout. Do not assume
`serialized-tx` preserves bytes merely because its input is serialized. The
independent digest comparison below is required even with an explicit gas coin.

1. Build the proposed call with `--dry-run`; inspect its execution status and
   effects, not just its exit status.
2. Review sender, network, capability, recipients, subject/mapping, and fees with
   the user. Replace `--dry-run` with `--serialize-unsigned-transaction` to save
   stdout as `tx-bytes.b64` and stderr separately. This does not submit anything.
3. Decode the saved BCS `TransactionData`, compute its digest offline, and require
   the simulation to report that same digest:

```sh
set -euo pipefail
: "${TX_NETWORK:?Set the transaction execution network}"
: "${TX_DIR:?Set a dedicated operation directory}"
TX_BYTES=$(<"$TX_DIR/tx-bytes.b64")
sui keytool decode-or-verify-tx --tx-bytes "$TX_BYTES" --json >"$TX_DIR/decoded.json"
python3 - "$TX_DIR/tx-bytes.b64" >"$TX_DIR/digest.txt" <<'PY'
import base64, hashlib, pathlib, sys
raw = base64.b64decode(pathlib.Path(sys.argv[1]).read_text().strip(), validate=True)
if not raw:
    raise SystemExit('STOP: empty transaction bytes')
hash_bytes = hashlib.blake2b(b'TransactionData::' + raw, digest_size=32).digest()
alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
number, digest = int.from_bytes(hash_bytes, 'big'), ''
while number:
    number, remainder = divmod(number, 58)
    digest = alphabet[remainder] + digest
print('1' * (len(hash_bytes) - len(hash_bytes.lstrip(b'\0'))) + digest)
PY
EXPECTED_DIGEST=$(<"$TX_DIR/digest.txt")
sui client --client.env "$TX_NETWORK" serialized-tx "$TX_BYTES" --dry-run --json \
  >"$TX_DIR/simulation.json" 2>"$TX_DIR/simulation.log"
jq -e --arg expected "$EXPECTED_DIGEST" '
  .effects.status.status == "success" and .effects.transactionDigest == $expected
' "$TX_DIR/simulation.json"
```

The offline calculation follows the Sui SDK's
[`TransactionData` digest](https://github.com/MystenLabs/ts-sdks/blob/main/packages/sui/src/transactions/TransactionData.ts)
(Base58 of Blake2b-256 over `TransactionData::` followed by BCS bytes). It is not
the signing intent or a hash of the base64 text.

Stop on a failed command, failed simulation, unexpected response format, or
mismatched digest. Do not replace the independently calculated digest with the
CLI's answer. Use a supported toolchain or investigate before signing.
Review all decoded inputs and commands, sender, gas owner/coin/budget/price, and
expiration, including any epoch limits and nonce. Require both the decoded sender
and gas owner to equal `TX_SENDER`, the explicit gas coin you selected, and only
the intended effects. Stop before signing if either address differs; matching
digests alone do not prove that the transaction is authorized or correct.

Give custody the bytes, digest, decoded transaction, CLI version, network/chain
ID, current sender, gas owner/coin/budget, expiration, intended changes, and
simulation result. Request **Sui
transaction signing**, not personal-message signing or a signature over the
base64 text. Multisig signers must assemble a supported multisig signature;
uncombined member signatures do not replace the multisig authorization.

Serialization does not reserve gas or capabilities. Before signing/submission,
recheck owned input references, gas price, expiration, and the target's state;
repeat the saved-byte simulation and digest check. If rebuilding is necessary,
first reconcile whether custody already signed or submitted the old request.
A transaction-not-found response does not cancel a pending custody request.
Explicitly cancel/supersede that request before preparing replacement bytes, then
obtain new approval/signatures. Never change bytes after signing. Keep artifacts
somewhere durable, not only in a temporary directory.

## Verify and execute a returned signature

Custody may execute the approved transaction itself. In that case, request the
digest and require it to equal `EXPECTED_DIGEST`. Retrieve its result with
`sui client --client.env "$TX_NETWORK" tx-block "$EXPECTED_DIGEST" --json` and
apply the execution checks below; **do not submit a second operation**.

Otherwise, set `SIGNATURE` to custody's base64 serialized Sui signature:

```sh
: "${SIGNATURE:?Set the returned serialized Sui signature}"
sui keytool decode-or-verify-tx --tx-bytes "$TX_BYTES" --sig "$SIGNATURE" --json
```

Inspect the result and require successful verification for the expected sender.
After explicit execution approval:

```sh
sui client --client.env "$TX_NETWORK" execute-signed-tx \
  --tx-bytes "$TX_BYTES" --signatures "$SIGNATURE" --json \
  >"$TX_DIR/executed.json" 2>"$TX_DIR/executed.log"
jq -e --arg expected "$EXPECTED_DIGEST" '
  .digest == $expected and .effects.transactionDigest == $expected and
  .effects.status.status == "success"
' "$TX_DIR/executed.json"
```

If custody returns combined BCS `SenderSignedData`, use
`execute-combined-signed-tx --signed-tx-bytes '<combined base64>'` on the same
network instead. Decode and verify its embedded transaction and signatures
against the approved bytes first, then apply the same execution digest/effects
checks. Do not submit both formats.

Record confirmed effects, owners, and object IDs, not simulated ones. If the
execution digest differs, stop and reconcile both digests; do not retry. On a
timeout, query `EXPECTED_DIGEST` and check custody status before any resubmission.

## Local signing of the reviewed bytes

Use the same serialization, inspection, and digest checks. After signing approval,
let the user or their authorized signing environment run
`sui keytool sign --address "$TX_SENDER" --data "$TX_BYTES" --json` with the
default Sui transaction intent. Never read the keystore or request private keys.
Take the serialized signature from that result, verify it as above, and submit
only after execution approval. Do not rebuild the original PTB or execute
`serialized-tx` without an inspection flag as a shortcut to signing.
