//! Reading the localnet the way a consumer would: box addresses derived
//! off-chain, and what they own read through GraphQL.

use std::sync::LazyLock;
use std::time::Duration;

use anyhow::Context;
use anyhow::Result;
use anyhow::ensure;
use regex::Regex;
use serde::de::DeserializeOwned;
use serde_json::Value;
use serde_json::json;
use sui_graphql::Client;
use sui_graphql::graphql_query;
use sui_graphql_macros::Response;
use sui_sdk_types::Address;
use sui_sdk_types::TypeTag;

use crate::wait_for;

/// GraphQL's maximum page size. Nothing in the e2e run comes close; if
/// something ever does, reading fails rather than silently truncating.
const PAGE: u32 = 50;

/// A page of the registry's events.
const EVENTS: &str = graphql_query!(
    "query($type: String!, $first: Int, $after: String) {
      events(first: $first, after: $after, filter: { type: $type }) {
        pageInfo { hasNextPage endCursor }
        nodes { contents { type { repr } json } }
      }
    }"
);

/// What is at a subject's active box and revoked address.
const BOXES: &str = graphql_query!(
    "query($active: SuiAddress!, $revoked: SuiAddress!, $type: String!, $first: Int) {
      activeObject: object(address: $active) { asMoveObject { ...TypeRepr } }
      revokedObject: object(address: $revoked) { asMoveObject { ...TypeRepr } }
      active: address(address: $active) { ...Attestations }
      revoked: address(address: $revoked) { ...Attestations }
    }

    fragment TypeRepr on MoveObject {
      contents { type { repr } }
    }

    fragment Attestations on Address {
      objects(first: $first, filter: { type: $type }) {
        pageInfo { hasNextPage }
        nodes {
          ...TypeRepr
          contents { json display { output errors } }
        }
      }
    }"
);

/// `<registry package>::attestations::<Attested or Revoked><T>`.
static EVENT_TYPE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^0x[0-9a-f]+::attestations::(\w+)<(.+)>$").unwrap());

/// An `Attested<T>` or `Revoked<T>` event from the registry.
pub struct Event {
    /// `Attested` or `Revoked`.
    pub kind: String,
    /// `T`, with full addresses.
    pub schema: String,
    pub subject: Address,
}

/// An attestation, as GraphQL returns it.
#[derive(Response)]
#[response(root_type = "MoveObject")]
pub struct Attestation {
    /// `<registry package>::attestations::Attestation<T>`.
    #[field(path = "contents.type.repr")]
    pub type_repr: String,
    /// Its fields: `id`, `subject`, and `data`.
    #[field(path = "contents.json")]
    pub json: Value,
    /// Its rendered Display, if `T` has one.
    #[field(path = "contents.display?.output?")]
    pub display: Option<Value>,
    /// Display fields that failed to render.
    #[field(path = "contents.display?.errors?")]
    pub display_errors: Option<Value>,
}

/// What is at a subject's two box addresses.
pub struct SubjectState {
    /// The attestations at the active box.
    pub active: Vec<Attestation>,
    /// The attestations at the revoked address.
    pub revoked: Vec<Attestation>,
    /// The type of the object at the active box address, if there is one.
    pub active_object: Option<String>,
    /// The type of the object at the revoked address, if there is one.
    pub revoked_object: Option<String>,
}

pub struct Chain {
    client: Client,
}

#[derive(Response)]
struct EventsPage {
    #[field(path = "events.pageInfo.hasNextPage")]
    has_next_page: bool,
    #[field(path = "events.pageInfo.endCursor?")]
    end_cursor: Option<String>,
    #[field(path = "events.nodes[]")]
    nodes: Vec<EventNode>,
}

#[derive(Response)]
#[response(root_type = "Event")]
struct EventNode {
    #[field(path = "contents.type.repr")]
    type_repr: String,
    #[field(path = "contents.json")]
    json: Value,
}

#[derive(Response)]
struct Boxes {
    #[field(path = "activeObject:object?.asMoveObject?.contents.type.repr")]
    active_object: Option<String>,
    #[field(path = "revokedObject:object?.asMoveObject?.contents.type.repr")]
    revoked_object: Option<String>,
    #[field(path = "active:address.objects.pageInfo.hasNextPage")]
    active_has_more: bool,
    #[field(path = "active:address.objects.nodes[]")]
    active: Vec<Attestation>,
    #[field(path = "revoked:address.objects.pageInfo.hasNextPage")]
    revoked_has_more: bool,
    #[field(path = "revoked:address.objects.nodes[]")]
    revoked: Vec<Attestation>,
}

impl Chain {
    pub fn new(graphql_url: &str) -> Result<Self> {
        Ok(Self {
            client: Client::new(graphql_url)?,
        })
    }

    /// Wait until GraphQL has indexed the transaction `digest`, and every
    /// checkpoint up to the one it is in.
    pub async fn wait_for_transaction(&self, digest: &str) -> Result<()> {
        let checkpoint = wait_for(
            &format!("GraphQL to index transaction {digest}"),
            Duration::from_secs(120),
            Duration::from_millis(500),
            || async {
                Ok(self
                    .client
                    .get_transaction(digest)
                    .await?
                    .map(|tx| tx.checkpoint))
            },
        )
        .await?;

        wait_for(
            &format!("GraphQL to index checkpoint {checkpoint}"),
            Duration::from_secs(120),
            Duration::from_millis(500),
            || async {
                let latest = self.client.get_checkpoint(None).await?;
                Ok(latest
                    .filter(|cp| cp.summary.sequence_number >= checkpoint)
                    .map(|_| ()))
            },
        )
        .await
    }

    /// The registry's events, in the order they were emitted.
    pub async fn events(&self, registry_pkg: Address) -> Result<Vec<Event>> {
        let event_type = format!("{registry_pkg}::attestations");
        let mut events = Vec::new();
        let mut after: Option<String> = None;
        loop {
            let page: EventsPage = self
                .query(
                    EVENTS,
                    json!({ "type": event_type, "first": PAGE, "after": after }),
                )
                .await?;
            for node in page.nodes {
                let captures = EVENT_TYPE
                    .captures(&node.type_repr)
                    .with_context(|| format!("unexpected event type {}", node.type_repr))?;
                let subject = node.json["subject"]
                    .as_str()
                    .context("event without a subject")?;
                events.push(Event {
                    kind: captures[1].to_string(),
                    schema: captures[2].to_string(),
                    subject: subject.parse()?,
                });
            }
            if !page.has_next_page {
                return Ok(events);
            }
            after = page.end_cursor;
        }
    }

    /// What is at `subject`'s active box and revoked address.
    pub async fn subject_state(
        &self,
        registry: Address,
        registry_pkg: Address,
        subject: Address,
    ) -> Result<SubjectState> {
        let boxes: Boxes = self
            .query(
                BOXES,
                json!({
                    "active": box_address(registry, registry_pkg, subject, false)?.to_string(),
                    "revoked": box_address(registry, registry_pkg, subject, true)?.to_string(),
                    "type": format!("{registry_pkg}::attestations::Attestation"),
                    "first": PAGE,
                }),
            )
            .await?;
        ensure!(
            !boxes.active_has_more && !boxes.revoked_has_more,
            "more than {PAGE} attestations at one address; the e2e needs paging"
        );
        Ok(SubjectState {
            active: boxes.active,
            revoked: boxes.revoked,
            active_object: boxes.active_object,
            revoked_object: boxes.revoked_object,
        })
    }

    /// Run a query and return its data, failing on any GraphQL error.
    async fn query<T: DeserializeOwned>(&self, query: &str, variables: Value) -> Result<T> {
        let response = self.client.query::<T>(query, variables).await?;
        let errors: Vec<&str> = response.errors().iter().map(|e| e.message()).collect();
        ensure!(errors.is_empty(), "GraphQL error: {}", errors.join("; "));
        response.into_data().context("GraphQL returned no data")
    }
}

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
