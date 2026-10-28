//! Offline document rendering. Templates and licensed fonts are embedded; no filesystem,
//! package, network or system-font resolver is installed. Data is never evaluated as code.
use serde::{Deserialize, Serialize};
use std::{collections::BTreeSet, sync::OnceLock};
use typst::foundations::{Bytes, Dict, IntoValue};
use typst::text::Font;
use typst_as_lib::TypstEngine;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Document {
    pub title: String,
    pub subtitle: String,
    pub landscape: bool,
    pub sections: Vec<Section>,
    pub notes: Vec<String>,
    pub signatory: String,
    pub designation: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Section {
    pub title: String,
    pub columns: Vec<String>,
    pub widths: Vec<u32>,
    pub rows: Vec<Vec<String>>,
}
impl Section {
    pub fn new(title: &str, columns: &[&str], widths: &[u32], rows: Vec<Vec<String>>) -> Self {
        Self {
            title: title.into(),
            columns: columns.iter().map(|s| (*s).into()).collect(),
            widths: widths.into(),
            rows,
        }
    }
}
#[derive(Debug, thiserror::Error)]
pub enum RenderError {
    #[error("Invalid document structure")]
    Invalid,
    #[error("PDF data exceeds 16 MB. Choose a narrower report range.")]
    TooLarge,
    #[error("PDF could not be rendered: {0}")]
    Compile(String),
    #[error("The embedded PDF fonts cannot render one or more characters in this document")]
    UnsupportedText,
}
const FONTS: &[&[u8]] = &[
    include_bytes!("../fonts/NotoSans-Regular.ttf"),
    include_bytes!("../fonts/NotoSans-Bold.ttf"),
    include_bytes!("../fonts/NotoSansDevanagari-Regular.ttf"),
    include_bytes!("../fonts/NotoSansBengali-Regular.ttf"),
    include_bytes!("../fonts/NotoSansGujarati-Regular.ttf"),
    include_bytes!("../fonts/NotoSansGurmukhi-Regular.ttf"),
    include_bytes!("../fonts/NotoSansKannada-Regular.ttf"),
    include_bytes!("../fonts/NotoSansMalayalam-Regular.ttf"),
    include_bytes!("../fonts/NotoSansOriya-Regular.ttf"),
    include_bytes!("../fonts/NotoSansTamil-Regular.ttf"),
    include_bytes!("../fonts/NotoSansTelugu-Regular.ttf"),
    include_bytes!("../fonts/NotoSansArabic-Regular.ttf"),
];

pub fn render(document: &Document) -> Result<Vec<u8>, RenderError> {
    if document.sections.iter().any(|s| {
        s.columns.is_empty()
            || s.widths.len() != s.columns.len()
            || s.widths.contains(&0)
            || s.rows.iter().any(|r| r.len() != s.columns.len())
    }) {
        return Err(RenderError::Invalid);
    }
    let data = serde_json::to_string(document).map_err(|_| RenderError::Invalid)?;
    if data.len() > 16 * 1024 * 1024 {
        return Err(RenderError::TooLarge);
    }
    static LOADED_FONTS: OnceLock<Vec<Font>> = OnceLock::new();
    let fonts = LOADED_FONTS.get_or_init(|| {
        FONTS
            .iter()
            .map(|data| Font::new(Bytes::new(*data), 0).expect("Embedded font must be valid"))
            .collect()
    });
    // Check coverage ourselves: Typst does not warn for every missing glyph.
    let characters: BTreeSet<_> = data.chars().collect();
    if characters.into_iter().any(|c| !c.is_whitespace() && !matches!(c, '\u{200c}'..='\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}' | '\u{fe00}'..='\u{fe0f}') && !fonts.iter().any(|font| font.info().coverage.contains(c as u32))) {
        return Err(RenderError::UnsupportedText);
    }
    let mut inputs = Dict::new();
    inputs.insert("data".into(), data.into_value());
    let engine = TypstEngine::builder()
        .main_file(include_str!("document.typ"))
        .fonts(fonts.iter().cloned())
        .build();
    let result = engine.compile_with_input(inputs);
    // Missing glyphs must not silently become empty squares in official correspondence.
    if result
        .warnings
        .iter()
        .any(|w| w.message.contains("glyph") || w.message.contains("font"))
    {
        return Err(RenderError::UnsupportedText);
    }
    let doc = result
        .output
        .map_err(|e| RenderError::Compile(format!("{e:?}")))?;
    typst_pdf::pdf(&doc, &Default::default()).map_err(|e| RenderError::Compile(format!("{e:?}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn sample(text: &str) -> Document {
        Document {
            title: "SBCO Unicode check".into(),
            subtitle: text.into(),
            landscape: false,
            sections: vec![Section::new(
                "Transactions",
                &["Account", "Remark"],
                &[1, 3],
                vec![vec!["001".into(), text.into()]],
            )],
            notes: vec![],
            signatory: "अनिता".into(),
            designation: "SBCO Incharge".into(),
        }
    }
    #[test]
    fn shapes_indian_scripts_and_treats_template_syntax_as_literal_text() {
        let text = "₹ हिंदी বাংলা ગુજરાતી ਪੰਜਾਬੀ ಕನ್ನಡ മലയാളം ଓଡ଼ିଆ தமிழ் తెలుగు اردو #panic(\"not code\")";
        let pdf = render(&sample(text)).expect("Embedded fonts must render supported scripts");
        assert!(pdf.starts_with(b"%PDF-"));
        assert!(pdf.len() > 10000);
    }
    #[test]
    fn refuses_missing_glyphs() {
        assert!(matches!(
            render(&sample("\u{10FFFF}")),
            Err(RenderError::UnsupportedText)
        ));
    }
}
