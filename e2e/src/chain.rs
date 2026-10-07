//! Reading the localnet the way a consumer would: box addresses derived
//! off-chain, and what they own read through GraphQL. The fullnode's JSON-RPC
//! is only used to tell when GraphQL has caught up.

use std::time::Duration;

use anyhow::{Context, Result, bail};
use regex::Regex;
use serde_json::{Value, json};
use sui_sdk_types::{Address, TypeTag};

use crate::wait_for;

/// GraphQL's maximum page size. Nothing in the e2e run comes close; if
/// something ever does, reading fails rather than silently truncating.
const PAGE: u32 = 50;

/// What GraphQL reports as the latest checkpoint before its indexer has
/// committed anything, so it must not be read as "caught up".
const NO_CHECKPOINT: u64 = i64::MAX as u64;

/// The address of a subject's active box (`revoked: false`) or revoked address
/// (`revoked: true`): `derived_object::derive_address(registry, BoxKey {
/// subject, revoked })`.
pub fn box_address(
    registry: Address,
    registry_pkg: Address,
    subject: Address,
    revoked: bool,
) -> Result<Address> {
    // `BoxKey` is defined in the registry package's first version. In BCS it is
    // the subject's 32 bytes followed by the bool.
    let key_type: TypeTag = format!("{registry_pkg}::attestations::BoxKey").parse()?;
    let mut key = subject.as_bytes().to_vec();
    key.push(u8::from(revoked));
    Ok(registry.derive_object_id(&key_type, &key))
}

/// An `Attested<T>` or `Revoked<T>` event from the registry.
pub struct Event {
    /// `Attested` or `Revoked`.
    pub kind: String,
    /// `T`, with full addresses.
    pub schema: String,
    pub subject: Address,
}

/// What is at a subject's two box addresses.
pub struct SubjectState {
    /// The attestations at the active box: GraphQL `MoveValue` contents, with
    /// `type`, `json`, and `display`.
    pub active: Vec<Value>,
    /// The attestations at the revoked address, likewise.
    pub revoked: Vec<Value>,
    /// The type of the object at the active box address, if there is one.
    pub active_object: Option<String>,
    /// The type of the object at the revoked address, if there is one.
    pub revoked_object: Option<String>,
}

pub struct Chain {
    graphql_url: String,
    rpc_url: String,
}

impl Chain {
    pub fn new(graphql_url: impl Into<String>, rpc_url: impl Into<String>) -> Self {
        Self {
            graphql_url: graphql_url.into(),
            rpc_url: rpc_url.into(),
        }
    }

    /// Run a GraphQL query and return its `data`.
    pub fn query(&self, query: &str, variables: Value) -> Result<Value> {
        let mut body = post(
            &self.graphql_url,
            &json!({ "query": query, "variables": variables }),
        )?;
        if let Some(errors) = body.get("errors").filter(|e| !e.is_null()) {
            bail!("GraphQL error: {errors:#}");
        }
        Ok(body["data"].take())
    }

    fn rpc(&self, method: &str, params: Value) -> Result<Value> {
        let mut body = post(
            &self.rpc_url,
            &json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params }),
        )?;
        if let Some(error) = body.get("error") {
            bail!("JSON-RPC {method} failed: {error}");
        }
        Ok(body["result"].take())
    }

    /// Block until GraphQL has indexed `sender`'s last transaction. Every
    /// transaction in the run is sent from that one address, so once its last
    /// one is indexed, everything is.
    pub fn wait_for_indexer(&self, sender: &str) -> Result<()> {
        let last = self.rpc(
            "suix_queryTransactionBlocks",
            json!([{ "filter": { "FromAddress": sender }, "options": {} }, null, 1, true]),
        )?;
        let digest = last["data"][0]["digest"]
            .as_str()
            .with_context(|| format!("{sender} has sent no transactions"))?
            .to_string();

        // A transaction is executed before it is in a checkpoint, so its
        // checkpoint can be missing for a moment.
        let target: u64 = wait_for(
            &format!("transaction {digest} to be checkpointed"),
            Duration::from_secs(60),
            Duration::from_millis(500),
            || {
                let tx = self.rpc("sui_getTransactionBlock", json!([digest, {}]))?;
                Ok(match tx["checkpoint"].as_str() {
                    Some(checkpoint) => Some(checkpoint.parse()?),
                    None => None,
                })
            },
        )?;

        wait_for(
            &format!("GraphQL to index checkpoint {target}"),
            Duration::from_secs(120),
            Duration::from_millis(500),
            || {
                let data = self.query("{ checkpoint { sequenceNumber } }", json!({}))?;
                let seen = data["checkpoint"]["sequenceNumber"].as_u64().unwrap_or(0);
                Ok((target <= seen && seen < NO_CHECKPOINT).then_some(()))
            },
        )
    }

    /// The registry's events, in the order they were emitted.
    pub fn events(&self, registry_pkg: Address) -> Result<Vec<Event>> {
        let query = format!(
            "query($type: String!, $after: String) {{
              events(first: {PAGE}, after: $after, filter: {{ type: $type }}) {{
                pageInfo {{ hasNextPage endCursor }}
                nodes {{ contents {{ type {{ repr }} json }} }}
              }}
            }}"
        );
        let event_type = Regex::new(r"^0x[0-9a-f]+::attestations::(\w+)<(.+)>$")?;

        let mut events = Vec::new();
        let mut after = Value::Null;
        loop {
            let data = self.query(
                &query,
                json!({ "type": format!("{registry_pkg}::attestations"), "after": after }),
            )?;
            let page = &data["events"];
            for node in page["nodes"].as_array().context("events.nodes")? {
                let repr = node["contents"]["type"]["repr"]
                    .as_str()
                    .context("event type")?;
                let captures = event_type
                    .captures(repr)
                    .with_context(|| format!("unexpected event type {repr}"))?;
                let subject = node["contents"]["json"]["subject"]
                    .as_str()
                    .context("event subject")?;
                events.push(Event {
                    kind: captures[1].to_string(),
                    schema: captures[2].to_string(),
                    subject: subject.parse()?,
                });
            }
            if page["pageInfo"]["hasNextPage"] != Value::Bool(true) {
                return Ok(events);
            }
            after = page["pageInfo"]["endCursor"].clone();
        }
    }

    /// What is at `subject`'s active box and revoked address.
    pub fn subject_state(
        &self,
        registry: Address,
        registry_pkg: Address,
        subject: Address,
    ) -> Result<SubjectState> {
        let query = format!(
            "query($active: SuiAddress!, $revoked: SuiAddress!, $type: String!) {{
              activeObject: object(address: $active) {{ asMoveObject {{ contents {{ type {{ repr }} }} }} }}
              revokedObject: object(address: $revoked) {{ asMoveObject {{ contents {{ type {{ repr }} }} }} }}
              active: address(address: $active) {{ ...attestations }}
              revoked: address(address: $revoked) {{ ...attestations }}
            }}

            fragment attestations on Address {{
              objects(first: {PAGE}, filter: {{ type: $type }}) {{
                pageInfo {{ hasNextPage }}
                nodes {{ contents {{ type {{ repr }} json display {{ output errors }} }} }}
              }}
            }}"
        );
        let data = self.query(
            &query,
            json!({
                "active": box_address(registry, registry_pkg, subject, false)?.to_string(),
                "revoked": box_address(registry, registry_pkg, subject, true)?.to_string(),
                "type": format!("{registry_pkg}::attestations::Attestation"),
            }),
        )?;

        let object_type = |key: &str| {
            data[key]["asMoveObject"]["contents"]["type"]["repr"]
                .as_str()
                .map(str::to_string)
        };
        let attestations = |key: &str| -> Result<Vec<Value>> {
            let objects = &data[key]["objects"];
            if objects["pageInfo"]["hasNextPage"] == Value::Bool(true) {
                bail!("more than {PAGE} attestations at one address; the e2e needs paging");
            }
            let nodes = objects["nodes"].as_array().context("objects.nodes")?;
            Ok(nodes.iter().map(|node| node["contents"].clone()).collect())
        };

        Ok(SubjectState {
            active: attestations("active")?,
            revoked: attestations("revoked")?,
            active_object: object_type("activeObject"),
            revoked_object: object_type("revokedObject"),
        })
    }
}

fn post(url: &str, body: &Value) -> Result<Value> {
    let response = ureq::post(url)
        .timeout(Duration::from_secs(30))
        .send_json(body)
        .with_context(|| format!("POST {url}"))?;
    Ok(response.into_json()?)
}
