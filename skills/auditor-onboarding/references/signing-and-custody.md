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

## Build unsigned bytes for custody

For a PTB, set `--sender "@$TX_SENDER"` to the actual capability owner and use
`--serialize-unsigned-transaction`. For `sui client publish`, use
`--sender "$TX_SENDER"` and the same serialization flag. Do not use
`--serialize-signed-transaction` without a local signer.

Set `TX_NETWORK` for this operation explicitly. It is **mainnet for MVR naming**,
even if the package being named is on testnet. Use a distinct output directory
`TX_DIR` per operation, outside source control. Check the owner's gas balance;
pin a suitable gas coin and reviewed budget where the custody process needs
stable inputs. A separate gas sponsor requires that sponsor's signature too.

1. Build the proposed call with `--dry-run`; inspect its execution status and
   effects, not just its exit status.
2. Review sender, network, capability, recipients, subject/mapping, and fees with
   the user. Replace `--dry-run` with `--serialize-unsigned-transaction` to save
   stdout as `tx-bytes.b64` and stderr separately. This does not submit anything.
3. Decode and simulate the **exact saved bytes**, not a rebuilt transaction:

```sh
: "${TX_NETWORK:?Set the transaction execution network}"
: "${TX_DIR:?Set a dedicated operation directory}"
TX_BYTES=$(<"$TX_DIR/tx-bytes.b64")
sui keytool decode-or-verify-tx --tx-bytes "$TX_BYTES" --json >"$TX_DIR/decoded.json"
sui client --client.env "$TX_NETWORK" serialized-tx "$TX_BYTES" --dry-run \
  >"$TX_DIR/simulation.txt" 2>"$TX_DIR/simulation.log"
sui client --client.env "$TX_NETWORK" serialized-tx "$TX_BYTES" --tx-digest \
  >"$TX_DIR/digest.txt"
```

Require a successful simulation and the intended decoded commands. CLI versions
may print human-readable simulation output even with `--json`; do not parse it
as JSON blindly. Stop if these inspection commands are unavailable, rather than
executing the transaction to discover whether it works.

Give custody the bytes, digest, decoded transaction, network, sender, gas
owner/coin/budget, intended changes, and simulation result. Request **Sui
transaction signing**, not personal-message signing or a signature over the
base64 text. Multisig signers must assemble a supported multisig signature;
uncombined member signatures do not replace the multisig authorization.

Serialization does not reserve gas or capabilities. If an owned input changes
version, rebuild and obtain new approval/signatures. Never change bytes after
signing, and do not regenerate another transaction while the first is pending
execution. Keep artifacts somewhere durable, not only in a temporary directory.

## Verify and execute a returned signature

Custody may execute the approved transaction itself. In that case, request the
digest and retrieve its result with `sui client --client.env "$TX_NETWORK"
tx-block "$DIGEST" --json`; **do not submit a second operation**.

Otherwise, set `SIGNATURE` to custody's base64 serialized Sui signature:

```sh
: "${SIGNATURE:?Set the returned serialized Sui signature}"
sui keytool decode-or-verify-tx --tx-bytes "$TX_BYTES" --sig "$SIGNATURE" --json
```

Inspect the result and require successful verification for the expected sender
(and sponsor, if any). After explicit execution approval:

```sh
sui client --client.env "$TX_NETWORK" execute-signed-tx \
  --tx-bytes "$TX_BYTES" --signatures "$SIGNATURE" --json \
  >"$TX_DIR/executed.json" 2>"$TX_DIR/executed.log"
jq -e '.effects.status.status == "success"' "$TX_DIR/executed.json"
```

If custody returns combined BCS `SenderSignedData`, use
`execute-combined-signed-tx --signed-tx-bytes '<combined base64>'` on the same
network instead. Do not confuse that artifact with unsigned bytes or a signature.

Record confirmed effects and object IDs, not simulated ones. On a timeout, query
the recorded digest before retrying. For a local signer, skip the external
handoff but retain simulation, review, explicit execution approval, and checks.
