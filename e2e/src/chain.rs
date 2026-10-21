//! Reading the localnet the way a consumer would: subject addresses derived
//! off-chain, and what they own read through GraphQL.

use std::time::Duration;

use anyhow::Context;
use anyhow::Result;
use anyhow::bail;
use anyhow::ensure;
use serde::de::DeserializeOwned;
use serde_json::Value;
use serde_json::json;
use sui_graphql::Client;
use sui_graphql::GraphQLError;
use sui_graphql::PageInfo;
use sui_graphql::graphql_query;
use sui_graphql_macros::Response;
use sui_sdk_types::Address;
use sui_sdk_types::StructTag;
use sui_sdk_types::TypeTag;

use crate::wait_for;

/// GraphQL's maximum page size. Nothing in the e2e run comes close; if
/// something ever does, reading fails rather than silently truncating.
const PAGE: u32 = 50;

/// An `Attested<T>` or `Revoked<T>` event from the registry.
pub struct Event {
    /// `Attested` or `Revoked`.
    pub kind: String,
    /// `T`.
    pub schema: TypeTag,
    pub subject: Address,
}

/// A Move value: its type, and its fields as JSON.
#[derive(Response)]
#[response(root_type = "MoveValue")]
pub struct MoveValue {
    #[field(path = "type.repr")]
    pub type_: TypeTag,
    #[field(path = "json")]
    pub json: Value,
}

/// An attestation, as GraphQL returns it.
#[derive(Response)]
#[response(root_type = "MoveObject")]
pub struct Attestation {
    /// `Attestation<T>`, with its `id`, `subject`, and `data`.
    #[field(path = "contents")]
    pub contents: MoveValue,
    /// Its rendered Display, if `T` has one.
    #[field(path = "contents.display?.output?")]
    pub display: Option<Value>,
    /// Display fields that failed to render.
    #[field(path = "contents.display?.errors?")]
    pub display_errors: Option<Value>,
}

/// What is at a subject's address: every attestation about it, split by
/// whether `revoked_at_ms` is set.
pub struct SubjectState {
    /// The attestations with no `revoked_at_ms`.
    pub live: Vec<Attestation>,
    /// The attestations with `revoked_at_ms` set.
    pub revoked: Vec<Attestation>,
    /// The type of the object at the address, if there is one.
    pub object: Option<TypeTag>,
}

pub struct Chain {
    client: Client,
}

impl Attestation {
    /// `T`, from the attestation's type `Attestation<T>`.
    pub fn schema(&self) -> Result<&TypeTag> {
        let type_ = &self.contents.type_;
        struct_tag(type_)?
            .type_params()
            .first()
            .with_context(|| format!("not an attestation: {type_}"))
    }
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
        const EVENTS: &str = graphql_query!(
            "query AttestationEvents($type: String!, $first: Int, $after: String) {
                events(first: $first, after: $after, filter: { type: $type }) {
                    pageInfo { ...FPageInfo }
                    nodes { contents { ...FMoveValue } }
                }
            }",
            @"fragments/FMoveValue.graphql",
            @"fragments/FPageInfo.graphql",
        );

        #[derive(Response)]
        struct Response {
            #[field(path = "events.pageInfo")]
            page_info: PageInfo,
            #[field(path = "events.nodes[].contents")]
            contents: Vec<MoveValue>,
        }

        let mut events = Vec::new();
        let mut after = None;
        loop {
            let variables = json!({
                "type": format!("{registry_pkg}::attestations"),
                "first": PAGE,
                "after": after,
            });
            let page: Response = self.query(EVENTS, variables).await?;
            for value in page.contents {
                let tag = struct_tag(&value.type_)?;
                let schema = tag
                    .type_params()
                    .first()
                    .with_context(|| format!("event without a schema: {}", value.type_))?;
                let subject = value.json["subject"]
                    .as_str()
                    .context("event without a subject")?;
                events.push(Event {
                    kind: tag.name().to_string(),
                    schema: schema.clone(),
                    subject: subject.parse()?,
                });
            }
            if !page.page_info.has_next_page {
                return Ok(events);
            }
            after = page.page_info.end_cursor;
        }
    }

    /// What is at `subject`'s address.
    pub async fn subject_state(
        &self,
        registry: Address,
        registry_pkg: Address,
        subject: Address,
    ) -> Result<SubjectState> {
        const ANCHOR: &str = graphql_query!(
            "query SubjectAnchor($anchor: SuiAddress!, $type: String!, $first: Int) {
                anchorObject: object(address: $anchor) {
                    asMoveObject { contents { ...FMoveValue } }
                }
                attestations: address(address: $anchor) { ...FAttestations }
            }",
            @"fragments/FAttestations.graphql",
            @"fragments/FMoveValue.graphql",
            @"fragments/FPageInfo.graphql",
        );

        #[derive(Response)]
        struct Response {
            #[field(path = "anchorObject:object?.asMoveObject?.contents")]
            object: Option<MoveValue>,
            #[field(path = "attestations:address.objects.pageInfo")]
            page: PageInfo,
            #[field(path = "attestations:address.objects.nodes[]")]
            attestations: Vec<Attestation>,
        }

        let variables = json!({
            "anchor": anchor_address(registry, subject)?,
            "type": format!("{registry_pkg}::attestations::Attestation"),
            "first": PAGE,
        });
        let anchor: Response = self.query(ANCHOR, variables).await?;
        ensure!(
            !anchor.page.has_next_page,
            "more than {PAGE} attestations at one address; the e2e needs paging"
        );
        let (revoked, live) = anchor
            .attestations
            .into_iter()
            .partition(|a| !a.contents.json["revoked_at_ms"].is_null());
        Ok(SubjectState {
            live,
            revoked,
            object: anchor.object.map(|value| value.type_),
        })
    }

    /// Run a query and return its data, failing on any GraphQL error.
    async fn query<T: DeserializeOwned>(&self, query: &str, variables: Value) -> Result<T> {
        let response = self.client.query::<T>(query, variables).await?;
        let errors: Vec<String> = response.errors().iter().map(graphql_error).collect();
        ensure!(errors.is_empty(), "GraphQL error: {}", errors.join("; "));
        response.into_data().context("GraphQL returned no data")
    }
}

/// The address every attestation about `subject` is owned by:
/// `derived_object::derive_address(registry, subject)`. The key is a plain
/// `0x2::object::ID`, so unlike the registry's own types it needs no package id.
pub fn anchor_address(registry: Address, subject: Address) -> Result<Address> {
    // In BCS an `ID` is just its 32 bytes.
    let key_type: TypeTag = "0x2::object::ID".parse()?;
    Ok(registry.derive_object_id(&key_type, subject.as_bytes()))
}

/// The struct tag of `type_`, which must be a struct type.
fn struct_tag(type_: &TypeTag) -> Result<&StructTag> {
    match type_ {
        TypeTag::Struct(tag) => Ok(tag),
        other => bail!("expected a struct type, got {other}"),
    }
}

/// One GraphQL error as `CODE: message`, or just the message if it has no code.
fn graphql_error(error: &GraphQLError) -> String {
    match error.code() {
        Some(code) => format!("{code}: {}", error.message()),
        None => error.message().to_string(),
    }
}
