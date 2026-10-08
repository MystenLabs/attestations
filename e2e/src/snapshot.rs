//! The attestation state as readable text that stays the same from run to
//! run: every address is replaced with the name of the package or object it
//! belongs to.

use std::collections::HashMap;
use std::path::Path;
use std::path::PathBuf;
use std::sync::LazyLock;
use std::time::Duration;

use anyhow::Context;
use anyhow::Result;
use bimap::BiHashMap;
use regex::Regex;
use serde::Deserialize;
use serde_json::Map;
use serde_json::Value;
use sui_sdk_types::Address;
use sui_sdk_types::TypeTag;
use tokio::time::sleep;

use crate::chain::Attestation;
use crate::chain::Chain;
use crate::chain::Event;
use crate::chain::SubjectState;

/// A full-length address anywhere in a string.
static ADDRESS: LazyLock<Regex> = LazyLock::new(|| Regex::new("0x[0-9a-f]{64}").unwrap());

/// Readable labels for addresses: packages, the registry, made-up subjects.
/// Addresses without one are numbered in the order they are first seen.
#[derive(Default)]
pub struct Names {
    labels: BiHashMap<Address, String>,
    unnamed: HashMap<Address, String>,
}

/// The parts of a `Pub.<env>.toml` pubfile we need.
#[derive(Deserialize)]
struct Pubfile {
    published: Vec<Published>,
}

#[derive(Deserialize)]
#[serde(rename_all = "kebab-case")]
struct Published {
    source: Source,
    published_at: Address,
    original_id: Address,
    version: u64,
}

#[derive(Deserialize)]
struct Source {
    local: PathBuf,
}

impl Names {
    pub fn add(&mut self, address: Address, label: impl Into<String>) {
        self.labels.insert(address, label.into());
    }

    /// Name every package in `pubfile` after its directory: `name`, or
    /// `name@v1`, `name@vN` for the first and latest versions of an upgraded
    /// package. Returns the registry package's id.
    pub fn add_packages(&mut self, pubfile: &Path) -> Result<Address> {
        let text = std::fs::read_to_string(pubfile)?;
        let pubfile: Pubfile = toml::from_str(&text)?;
        let mut registry_pkg = None;
        for pkg in pubfile.published {
            let name = pkg
                .source
                .local
                .file_name()
                .context("a package source without a directory name")?
                .to_string_lossy()
                .into_owned();
            if pkg.version > 1 {
                self.add(pkg.original_id, format!("{name}@v1"));
                self.add(pkg.published_at, format!("{name}@v{}", pkg.version));
            } else {
                self.add(pkg.original_id, &name);
            }
            if name == "attestations" {
                // Types are named after the package version that defined
                // them, and `Attestation` and `BoxKey` are in the first.
                registry_pkg = Some(pkg.original_id);
            }
        }
        registry_pkg.context("no packages/attestations entry in the pubfile")
    }

    /// The address with this label.
    pub fn address_of(&self, label: &str) -> Result<Address> {
        self.labels
            .get_by_right(label)
            .copied()
            .with_context(|| format!("no address is named {label}"))
    }

    pub fn label(&mut self, address: Address) -> String {
        if let Some(label) = self.labels.get_by_left(&address) {
            return label.clone();
        }
        let next = self.unnamed.len() + 1;
        self.unnamed
            .entry(address)
            .or_insert_with(|| format!("<unnamed-{next}>"))
            .clone()
    }

    /// `text` with every full-length address replaced by its label.
    pub fn rename(&mut self, text: &str) -> String {
        let mut out = String::new();
        let mut last = 0;
        for found in ADDRESS.find_iter(text) {
            out.push_str(&text[last..found.start()]);
            match found.as_str().parse() {
                Ok(address) => out.push_str(&self.label(address)),
                Err(_) => out.push_str(found.as_str()),
            }
            last = found.end();
        }
        out.push_str(&text[last..]);
        out
    }
}

/// Render the attestation state: for each subject in the registry's events,
/// then each of `extra_subjects`, what is at its active box and revoked
/// address; then every event, in order.
pub async fn render(
    chain: &Chain,
    names: &mut Names,
    registry: Address,
    registry_pkg: Address,
    extra_subjects: &[Address],
) -> Result<String> {
    let events = chain.events(registry_pkg).await?;
    let mut subjects: Vec<Address> = Vec::new();
    for subject in events
        .iter()
        .map(|e| e.subject)
        .chain(extra_subjects.iter().copied())
    {
        if !subjects.contains(&subject) {
            subjects.push(subject);
        }
    }

    let mut blocks = Vec::new();
    for subject in subjects {
        // The consistent store that serves owned objects can trail the
        // indexer by a moment, so give a mismatch with the events a few
        // chances before reporting it.
        let mut state = chain.subject_state(registry, registry_pkg, subject).await?;
        for _ in 0..20 {
            if consistent(&state, subject, &events) {
                break;
            }
            sleep(Duration::from_millis(500)).await;
            state = chain.subject_state(registry, registry_pkg, subject).await?;
        }
        blocks.push(render_subject(subject, &state, &events, names)?);
    }
    blocks.push(render_events(&events, names));

    Ok(blocks
        .iter()
        .map(|block| block.join("\n"))
        .collect::<Vec<_>>()
        .join("\n\n"))
}

/// How many `Attested` and `Revoked` events name `subject`.
fn event_counts(subject: Address, events: &[Event]) -> (usize, usize) {
    let count = |kind: &str| {
        events
            .iter()
            .filter(|e| e.kind == kind && e.subject == subject)
            .count()
    };
    (count("Attested"), count("Revoked"))
}

fn consistent(state: &SubjectState, subject: Address, events: &[Event]) -> bool {
    let (attested, revoked) = event_counts(subject, events);
    state.active.len() + state.revoked.len() == attested && state.revoked.len() == revoked
}

fn render_subject(
    subject: Address,
    state: &SubjectState,
    events: &[Event],
    names: &mut Names,
) -> Result<Vec<String>> {
    let (attested, revoked) = event_counts(subject, events);
    let mut lines = vec![
        format!("== {} ==", names.label(subject)),
        format!("events: {attested} attested, {revoked} revoked"),
        String::new(),
    ];

    let found = state.active.len() + state.revoked.len();
    if attested > found {
        lines.push(format!(
            "!! {} attestation(s) announced by events are at neither address",
            attested - found
        ));
    }
    if revoked != state.revoked.len() {
        lines.push(format!(
            "!! {revoked} revoked by events, but {} at the revoked address",
            state.revoked.len()
        ));
    }

    lines.extend(render_location(
        "active box",
        state.active_object.as_ref(),
        &state.active,
        subject,
        names,
    )?);
    lines.push(String::new());
    lines.extend(render_location(
        "revoked address",
        state.revoked_object.as_ref(),
        &state.revoked,
        subject,
        names,
    )?);
    Ok(lines)
}

fn render_location(
    heading: &str,
    object_type: Option<&TypeTag>,
    attestations: &[Attestation],
    subject: Address,
    names: &mut Names,
) -> Result<Vec<String>> {
    let found = match object_type {
        Some(object_type) => format!("{} object", names.rename(&object_type.to_string())),
        None => "no object".to_string(),
    };
    let mut lines = vec![format!("{heading} ({found})")];

    let mut rendered = attestations
        .iter()
        .map(|a| render_attestation(a, subject, names))
        .collect::<Result<Vec<_>>>()?;
    rendered.sort();
    if rendered.is_empty() {
        lines.push("  (none)".to_string());
    }
    lines.extend(rendered.into_iter().flatten());
    Ok(lines)
}

fn render_attestation(
    attestation: &Attestation,
    subject: Address,
    names: &mut Names,
) -> Result<Vec<String>> {
    let schema = attestation.schema()?.to_string();
    let mut lines = vec![format!("  {}", names.rename(&schema))];

    let json = &attestation.contents.json;
    let field_subject: Address = json["subject"]
        .as_str()
        .context("attestation without a subject")?
        .parse()?;
    if field_subject != subject {
        lines.push(format!(
            "    !! its subject field is {}",
            names.label(field_subject)
        ));
    }
    lines.extend(render_fields("data", json["data"].as_object(), names));

    let display = attestation.display.as_ref().and_then(Value::as_object);
    lines.extend(render_fields("display", display, names));
    match &attestation.display_errors {
        None => {}
        Some(Value::Object(errors)) if errors.is_empty() => {}
        Some(Value::Object(errors)) => {
            lines.extend(render_fields("display errors", Some(errors), names))
        }
        Some(other) => lines.push(format!("    display errors: {other}")),
    }
    Ok(lines)
}

fn render_fields(
    heading: &str,
    fields: Option<&Map<String, Value>>,
    names: &mut Names,
) -> Vec<String> {
    let Some(fields) = fields.filter(|f| !f.is_empty()) else {
        return vec![format!("    {heading}: none")];
    };
    let mut lines = vec![format!("    {heading}:")];
    for (key, value) in fields {
        let text = match value {
            Value::String(s) => s.clone(),
            other => other.to_string(),
        };
        lines.push(format!("      {key}: {}", names.rename(&text)));
    }
    lines
}

fn render_events(events: &[Event], names: &mut Names) -> Vec<String> {
    let rows: Vec<(&str, String, String)> = events
        .iter()
        .map(|e| {
            (
                e.kind.as_str(),
                names.rename(&e.schema.to_string()),
                names.label(e.subject),
            )
        })
        .collect();
    let width = rows
        .iter()
        .map(|(_, schema, _)| schema.len())
        .max()
        .unwrap_or(0);

    let mut lines = vec!["== events, in order ==".to_string()];
    if rows.is_empty() {
        lines.push("  (none)".to_string());
    }
    for (kind, schema, subject) in rows {
        lines.push(format!("{kind:<8}  {schema:<width$}  {subject}"));
    }
    lines
}
