# Signing and custody

Every transaction in this skill is either run directly from a key in the user's
local keystore or signed by an external custodian, such as a multisig. Publishing
the auditor package always uses a local key, as described in
[setup and publishing](setup-and-publish.md). Verify current CLI help; never use
a local private key to impersonate an external owner.

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

`sui client publish` sends both capabilities to the publishing key, which must be
in the local keystore. If they belong with a multisig or other custody owner,
transfer them after publishing, once recipient control is verified. Create
PackageInfo while the UpgradeCap is available, or have its custodian sign that
step. Do not destroy the UpgradeCap as a shortcut before metadata creation.

For a transfer, verify the current owner/type on-chain and use an approved PTB
`--transfer-objects` for UpgradeCap/AuditAdminCap/AppCap. **PackageInfo is
key-only:** use `package_info::transfer`, not generic public transfer. Simulate,
show the destination to the user, request approval, then verify the resulting
owner. Do not share the capabilities or send them to an unverified address.
Record the current signer and any future custody destination separately. A
planned recipient cannot sign for objects still owned by the current custodian.
Gas sponsorship pays fees; it does not authorize another wallet's owned inputs.

## Before any transaction

Set `TX_SENDER` to the actual owner of the objects the transaction uses, and pass
it as `--sender "@$TX_SENDER"`. Set `TX_NETWORK` explicitly: it is **mainnet for
MVR naming**, even if the package being named is on testnet. Use a distinct
output directory `TX_DIR` per operation, outside source control.

The sender pays. The CLI uses its SUI coins or address balance, so there is no
gas coin to choose; check that the sender is funded on `TX_NETWORK`. This skill
supports sender-funded transactions only: stop if an operation needs a separate
gas sponsor.

Build the call with `--dry-run` and inspect its execution status and effects, not
just its exit status. Review sender, network, capability, recipients,
subject/mapping, and fees with the user before asking for approval.

## Local key: run the command

When `TX_SENDER` is a key in the user's local keystore, after explicit approval
run the reviewed command without `--dry-run`, adding `--json` and saving stdout
as `$TX_DIR/executed.json`. Require `.effects.status.status == "success"`. Never
read the keystore or request private keys; the CLI signs with the key itself.

Running the command again builds a new transaction, so a retry can repeat the
operation, for example issuing a second claim. On a timeout, check on-chain
whether the intended change happened before running it again.

## External custody: sign saved bytes

A multisig or custody service signs one fixed set of bytes: every signer must
sign the same bytes, and they cannot change after signing. Replace `--dry-run`
with `--serialize-unsigned-transaction`, saving stdout as `$TX_DIR/tx-bytes.b64`
and stderr separately. This submits nothing. Serializing again produces a
different transaction, so serialize once per approved operation.

Decode the saved bytes; they, not the dry run, are what custody signs:

```sh
set -euo pipefail
: "${TX_DIR:?Set a dedicated operation directory}"
TX_BYTES=$(<"$TX_DIR/tx-bytes.b64")
sui keytool decode-or-verify-tx --tx-bytes "$TX_BYTES" --json >"$TX_DIR/decoded.json"
```

Review the decoded commands and inputs, sender, gas owner, budget, and
expiration. Require the sender and gas owner to equal `TX_SENDER`, and stop
before signing if either differs.

Give custody the bytes, decoded transaction, CLI version, network/chain ID,
intended changes, and dry-run result. Request **Sui transaction signing**, not
personal-message signing or a signature over the base64 text. Multisig signers
must assemble a supported multisig signature; uncombined member signatures do
not replace the multisig authorization.

Saved bytes go stale. Bytes paid from the address balance expire at the end of
their `max_epoch`, the epoch after they were built (roughly one to two days on
testnet and mainnet). Bytes paid with a coin stop working if that coin is spent
elsewhere, and any owned input can change. If custody cannot sign in time,
explicitly cancel the pending request before serializing replacement bytes and
getting new approval; a transaction-not-found response does not cancel it. Keep
artifacts somewhere durable, not only in a temporary directory.

### Execute the returned signature

Custody may execute the transaction itself. In that case, get the digest, read the
result with `sui client --client.env "$TX_NETWORK" tx-block <digest> --json`, and
apply the checks below; **do not submit it again**.

Otherwise, set `SIGNATURE` to custody's base64 serialized Sui signature and verify
it against the saved bytes:

```sh
: "${SIGNATURE:?Set the returned serialized Sui signature}"
TX_BYTES=$(<"$TX_DIR/tx-bytes.b64")
sui keytool decode-or-verify-tx --tx-bytes "$TX_BYTES" --sig "$SIGNATURE" --json
```

Require successful verification for the expected sender. After explicit execution
approval:

```sh
sui client --client.env "$TX_NETWORK" execute-signed-tx \
  --tx-bytes "$TX_BYTES" --signatures "$SIGNATURE" --json \
  >"$TX_DIR/executed.json" 2>"$TX_DIR/executed.log"
jq -e '.effects.status.status == "success"' "$TX_DIR/executed.json"
```

If custody returns combined BCS `SenderSignedData`, use
`execute-combined-signed-tx --signed-tx-bytes '<combined base64>'` on the same
network instead, after decoding it and confirming it embeds the reviewed bytes.
Do not submit both formats.

Record confirmed effects, owners, and object IDs, not simulated ones. On a
timeout, resubmitting the same signed bytes is safe: they are one transaction
and execute at most once.
