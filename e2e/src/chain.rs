//! Reading the localnet the way a consumer would: box addresses derived
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

/// What is at a subject's two box addresses.
pub struct SubjectState {
    /// The attestations at the active box.
    pub active: Vec<Attestation>,
    /// The attestations at the revoked address.
    pub revoked: Vec<Attestation>,
    /// The type of the object at the active box address, if there is one.
    pub active_object: Option<TypeTag>,
    /// The type of the object at the revoked address, if there is one.
    pub revoked_object: Option<TypeTag>,
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

    /// What is at `subject`'s active box and revoked address.
    pub async fn subject_state(
        &self,
        registry: Address,
        registry_pkg: Address,
        subject: Address,
    ) -> Result<SubjectState> {
        const BOXES: &str = graphql_query!(
            "query SubjectBoxes(
                $active: SuiAddress!,
                $revoked: SuiAddress!,
                $type: String!,
                $first: Int,
            ) {
                activeObject: object(address: $active) {
                    asMoveObject { contents { ...FMoveValue } }
                }
                revokedObject: object(address: $revoked) {
                    asMoveObject { contents { ...FMoveValue } }
                }
                active: address(address: $active) { ...FAttestations }
                revoked: address(address: $revoked) { ...FAttestations }
            }",
            @"fragments/FAttestations.graphql",
            @"fragments/FMoveValue.graphql",
            @"fragments/FPageInfo.graphql",
        );

        #[derive(Response)]
        struct Response {
            #[field(path = "activeObject:object?.asMoveObject?.contents")]
            active_object: Option<MoveValue>,
            #[field(path = "revokedObject:object?.asMoveObject?.contents")]
            revoked_object: Option<MoveValue>,
            #[field(path = "active:address.objects.pageInfo")]
            active_page: PageInfo,
            #[field(path = "active:address.objects.nodes[]")]
            active: Vec<Attestation>,
            #[field(path = "revoked:address.objects.pageInfo")]
            revoked_page: PageInfo,
            #[field(path = "revoked:address.objects.nodes[]")]
            revoked: Vec<Attestation>,
        }

        let variables = json!({
            "active": box_address(registry, registry_pkg, subject, false)?,
            "revoked": box_address(registry, registry_pkg, subject, true)?,
            "type": format!("{registry_pkg}::attestations::Attestation"),
            "first": PAGE,
        });
        let boxes: Response = self.query(BOXES, variables).await?;
        ensure!(
            !boxes.active_page.has_next_page && !boxes.revoked_page.has_next_page,
            "more than {PAGE} attestations at one address; the e2e needs paging"
        );
        Ok(SubjectState {
            active: boxes.active,
            revoked: boxes.revoked,
            active_object: boxes.active_object.map(|value| value.type_),
            revoked_object: boxes.revoked_object.map(|value| value.type_),
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
